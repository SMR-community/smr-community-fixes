"""Publish this mod to Paradox Mods over HTTP, without the game.

The protocol was recovered by capturing the game's own traffic (see
PDX_API_NOTES.md and HANDOFF.md). The real upload is:

    establish session   (refresh token -> session token)
    GET  /mods?modId=…                      current mod state, gives modName
    POST /mods/presigned-urls   x2          one per file: thumbnail, content zip
    PUT  <presignedUrl>         x2          raw bytes to a storage host
    PUT  /mods/{modId}/versions             publish the new version

Auth is NOT Hawk request signing (despite the SDK type names). Requests carry
`Authorization: {"session":{"token":"<uuid>"}}`. The session token is obtained
from a refresh token via the renewal endpoint — no password, no salt. The
password login the game uses hashes the password with a per-account salt kept
inside PDXSDK.dll and never written to disk, so it cannot be reproduced here;
the refresh token replaces it.

Usage:
    PDX_REFRESH=<token> python tools/publish/pdx_client.py \\
        --payload dist/SMRCF.zip --thumbnail Images/cover.jpg \\
        --version 3 --mod-id 154004

Standard library only.

Remaining unknowns, each marked TODO(capture) below, resolved by one more
capture that records request/response *bodies* (values, not just field names):
  * the renewal route and its exact request shape (ROUTES["renew"]);
  * the value of the x-accept-version header (ACCEPT_VERSION);
  * the acl / recommendedGameVersion values in the version PUT.
Until ROUTES["renew"] is filled the client stops cleanly at session setup.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

HOSTS = {
    "prod": "https://api.paradox-interactive.com",
    "sandbox": "https://sandbox-api.paradox-interactive.com",
    "staging": "https://staging-api.paradox-interactive.com",
    "test": "https://test-api.paradox-interactive.com",
}

GAME_NAME = "surviving_mars_relaunched"

# Sent on every api-host request. Confirmed present in the capture.
PDX_HEADERS = {
    "X-PDX-Game-Name": GAME_NAME,
    "X-PDX-Game-Version": "1.0.7",
    "X-PDX-Platform": "pc",
    "X-PDX-SDK-Type": "cpp",
    "X-PDX-SDK-Version": "1.0",
    "X-PDX-Error-Version": "2",
}

# TODO(capture): the presigned-urls and versions calls also sent an
# `x-accept-version` header. Its value was redacted; "2.0" is a guess. Confirm
# from a body-level capture, or the version PUT may 400.
ACCEPT_VERSION = "2.0"

# Routes recovered from the capture. Each is (METHOD, PATH); {placeholders} are
# filled per call. `renew` is the one still unknown - see module docstring.
ROUTES: dict[str, tuple[str, str] | None] = {
    # TODO(capture): refresh token -> session token. The renewal endpoint never
    # fired in capture because every session was valid. The DLL has an
    # `AuthorizationRenewal` type and a `renewal` string; expect something like
    # ("POST", "/accounts/sessions/" + GAME_NAME + "/renew") carrying the
    # refresh token. Left None so the client stops cleanly here.
    "renew": None,
    "logout": ("DELETE", "/accounts/sessions/" + GAME_NAME),
    "mod_details": ("GET", "/mods"),                     # + ?arch=&modId=&os=
    "presign": ("POST", "/mods/presigned-urls"),
    "publish_version": ("PUT", "/mods/{mod_id}/versions"),
}

DEFAULT_ARCH = "Any"
DEFAULT_OS = "Windows"
# TODO(capture): acl and recommendedGameVersion values were redacted. These are
# reasonable defaults; confirm against a captured version PUT body.
DEFAULT_ACL = "public"
DEFAULT_RECOMMENDED_GAME_VERSION = "1.0.7"


class PdxError(RuntimeError):
    """A failed call, carrying enough to tell somebody what went wrong."""

    def __init__(self, step: str, message: str, status: int | None = None,
                 retryable: bool = False) -> None:
        super().__init__(message)
        self.step = step
        self.status = status
        self.retryable = retryable


def missing_routes() -> list[str]:
    return sorted(name for name, route in ROUTES.items() if route is None)


# --------------------------------------------------------------------------
# Reporting: which step failed, why, and how long each one took
# --------------------------------------------------------------------------

# A content-upload timeout is the one transient already seen against this
# service, so those retry; a 4xx is the caller's fault and never does.
RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}
MAX_ATTEMPTS = 4
BACKOFF_SECONDS = 3.0


@dataclass
class StepResult:
    name: str
    ok: bool
    attempts: int = 1
    elapsed_ms: int = 0
    status: int | None = None
    message: str = ""

    def line(self) -> str:
        mark = "ok  " if self.ok else "FAIL"
        status = str(self.status) if self.status else "-"
        retries = f" after {self.attempts} attempts" if self.attempts > 1 else ""
        detail = f"  {self.message}" if self.message else ""
        return f"  {mark}  {self.name:<18} {status:>4}  {self.elapsed_ms:>6} ms{retries}{detail}"


class Reporter:
    """Collects step outcomes and publishes them where a person will see them."""

    def __init__(self) -> None:
        self.steps: list[StepResult] = []

    def add(self, result: StepResult) -> None:
        self.steps.append(result)
        print(result.line(), flush=True)

    @property
    def failure(self) -> StepResult | None:
        return next((s for s in self.steps if not s.ok), None)

    def reached(self, name: str) -> bool:
        return any(s.name == name and s.ok for s in self.steps)

    def summary_markdown(self, title: str) -> str:
        lines = [f"### {title}", "", "| Step | Result | Status | Time | Detail |",
                 "|---|---|---|---|---|"]
        for step in self.steps:
            mark = "✅" if step.ok else "❌"
            detail = step.message.replace("|", "\\|")[:200] or "—"
            lines.append(
                f"| `{step.name}` | {mark} | {step.status or '—'} | "
                f"{step.elapsed_ms} ms | {detail} |"
            )
        return "\n".join(lines) + "\n"

    def publish(self, title: str, result_path: str | None = None) -> None:
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, "a", encoding="utf-8") as handle:
                handle.write(self.summary_markdown(title))
        if result_path:
            payload = {
                "ok": self.failure is None,
                "failed_step": self.failure.name if self.failure else None,
                "status": self.failure.status if self.failure else None,
                "message": self.failure.message if self.failure else "",
                "steps": [vars(s) for s in self.steps],
            }
            with open(result_path, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)


def server_message(raw: bytes) -> str:
    """Best-effort human-readable message out of an error body."""
    text = raw.decode("utf-8", "replace").strip()
    try:
        data = json.loads(text)
    except (ValueError, UnicodeDecodeError):
        return text[:300]
    if isinstance(data, dict):
        # Confirmed error shape: {"error":{"detail":…,"category":…}, …}
        error = data.get("error")
        if isinstance(error, dict):
            for key in ("detail", "message", "category", "subCategory"):
                value = error.get(key)
                if isinstance(value, str) and value:
                    return value[:300]
        for key in ("message", "detail", "error_description", "result"):
            value = data.get(key)
            if isinstance(value, str) and value:
                return value[:300]
    return text[:300]


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------


@dataclass
class Auth:
    session_token: str | None = None
    refresh_token: str | None = None

    def header(self) -> str:
        if not self.session_token:
            raise PdxError("auth", "no session token")
        # The Authorization header is a JSON object, not a scheme string.
        return json.dumps({"session": {"token": self.session_token}})


class PdxSession:
    def __init__(self, base: str = HOSTS["prod"], timeout: int = 300) -> None:
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.auth = Auth()
        self.report = Reporter()

    # -- low-level ---------------------------------------------------------

    def _send_once(self, method: str, url: str, *, body: bytes, content_type: str,
                   headers: dict[str, str]) -> Any:
        request = urllib.request.Request(url, data=body or None, method=method.upper())
        for name, value in headers.items():
            request.add_header(name, value)
        if content_type:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            raise PdxError("http", server_message(exc.read()) or exc.reason,
                           status=exc.code, retryable=exc.code in RETRY_STATUSES) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise PdxError("network", f"{getattr(exc, 'reason', exc)}", retryable=True) from exc
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw

    def _call(self, step: str, method: str, url: str, *, body: bytes = b"",
              content_type: str = "", headers: dict[str, str] | None = None) -> Any:
        """One reported, retried step against a full URL."""
        started = time.monotonic()
        hdrs = headers if headers is not None else self._api_headers()
        for attempt in range(1, MAX_ATTEMPTS + 1):
            try:
                result = self._send_once(method, url, body=body,
                                         content_type=content_type, headers=hdrs)
            except PdxError as exc:
                if exc.retryable and attempt < MAX_ATTEMPTS:
                    delay = BACKOFF_SECONDS * (2 ** (attempt - 1))
                    print(f"  ...  {step} failed ({exc}), retry {attempt + 1}"
                          f"/{MAX_ATTEMPTS} in {delay:.0f}s", flush=True)
                    time.sleep(delay)
                    continue
                self.report.add(StepResult(
                    step, ok=False, attempts=attempt,
                    elapsed_ms=int((time.monotonic() - started) * 1000),
                    status=exc.status,
                    message=f"{exc}" + (" (gave up after retries)" if exc.retryable else "")))
                exc.step = step
                raise
            self.report.add(StepResult(
                step, ok=True, attempts=attempt,
                elapsed_ms=int((time.monotonic() - started) * 1000), status=200))
            return result
        raise AssertionError("unreachable")

    def _api_headers(self) -> dict[str, str]:
        headers = dict(PDX_HEADERS)
        headers["Authorization"] = self.auth.header()
        headers["x-accept-version"] = ACCEPT_VERSION
        return headers

    def _api(self, step: str, route: str, *, json_body: dict | None = None,
             query: dict | None = None, **fmt) -> Any:
        method, path = _route(route)
        url = self.base + path.format(**fmt)
        if query:
            url += "?" + urlencode(query)
        body = json.dumps(json_body).encode() if json_body is not None else b""
        return self._call(step, method, url, body=body,
                          content_type="application/json" if json_body is not None else "")

    # -- API surface -------------------------------------------------------

    def establish_session(self, refresh_token: str) -> None:
        """Exchange a refresh token for a session token via the renewal call."""
        self.auth.refresh_token = refresh_token
        method, path = _route("renew")  # raises cleanly while unknown
        # TODO(capture): confirm the request shape. Most likely the refresh
        # token goes in the Authorization header as {"session":{"token":…}} or a
        # {"renewal":{…}} object, possibly with an empty body. Adjust once seen.
        headers = dict(PDX_HEADERS)
        headers["Authorization"] = json.dumps({"session": {"token": refresh_token}})
        headers["x-accept-version"] = ACCEPT_VERSION
        data = self._call("renew", method, self.base + path, headers=headers)
        session = (data or {}).get("session", {})
        token = session.get("token")
        if not token:
            raise PdxError("renew", "renewal returned no session token")
        self.auth.session_token = token
        # A rotated refresh token, if the response carries one, is worth surfacing.
        self.auth.refresh_token = session.get("refresh_token", refresh_token)

    def mod_details(self, mod_id: int) -> dict:
        return self._api("mod_details", "mod_details",
                         query={"arch": DEFAULT_ARCH, "modId": mod_id, "os": DEFAULT_OS}) or {}

    def presign(self, mod_name: str, file_name: str) -> dict:
        """Ask for a presigned upload URL for one file."""
        return self._api("presign", "presign",
                         json_body={"fileName": file_name, "gameName": GAME_NAME,
                                    "modName": mod_name})

    def upload_to_storage(self, step: str, presigned_url: str, blob: bytes,
                          content_type: str) -> None:
        """PUT raw bytes to the storage host. No PDX headers, no auth - the
        presigned URL carries its own signature."""
        self._call(step, "PUT", presigned_url, body=blob,
                  content_type=content_type or "application/octet-stream", headers={})

    def publish_version(self, mod_id: int, body: dict) -> dict:
        return self._api("publish_version", "publish_version",
                         json_body=body, mod_id=mod_id)


def _route(name: str) -> tuple[str, str]:
    route = ROUTES.get(name)
    if route is None:
        raise PdxError(name, f"route '{name}' is not known yet. One capture of a "
                             f"session renewal fills it - see HANDOFF.md.")
    return route


def _read(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


def publish_mod(args: argparse.Namespace) -> int:
    refresh = os.environ.get("PDX_REFRESH")
    if not refresh:
        print("error: set PDX_REFRESH (the Paradox account refresh token)", file=sys.stderr)
        return 2

    session = PdxSession(HOSTS[args.env])
    title = f"Publish to Paradox Mods ({args.env}) — version {args.version}"

    try:
        session.establish_session(refresh)

        details = session.mod_details(args.mod_id)
        mod_name = details.get("Name") or details.get("modName")
        if not mod_name:
            raise PdxError("mod_details", f"mod {args.mod_id} returned no name")

        # Thumbnail: presign, then PUT the bytes to the returned URL.
        thumb_name = os.path.basename(args.thumbnail)
        thumb = session.presign(mod_name, thumb_name)
        session.upload_to_storage("upload_thumbnail", thumb["presignedUrl"],
                                  _read(args.thumbnail), thumb.get("contentType", ""))

        # Content zip: same two steps.
        content_name = os.path.basename(args.payload)
        content = session.presign(mod_name, content_name)
        session.upload_to_storage("upload_content", content["presignedUrl"],
                                  _read(args.payload), content.get("contentType", ""))

        result = session.publish_version(args.mod_id, {
            "contentFileName": content["fileName"],
            "thumbnail": thumb["fileName"],
            "displayName": args.title,
            "shortDescription": args.short_description,
            "longDescription": _read_text(args.description_file),
            "changelogEntry": args.changelog,
            "tags": args.tag,
            "userModVersion": str(args.version),
            "arch": DEFAULT_ARCH,
            "os": DEFAULT_OS,
            "acl": DEFAULT_ACL,
            "recommendedGameVersion": DEFAULT_RECOMMENDED_GAME_VERSION,
        })
    except PdxError as exc:
        session.report.publish(title, args.result_json)
        partial = session.report.reached("upload_content")
        print(f"\nFAILED at step '{exc.step}'"
              + (f" (HTTP {exc.status})" if exc.status else "") + f": {exc}", file=sys.stderr)
        if partial:
            print("The content was uploaded but the version was never published. "
                  "Nothing is live; re-running replaces it.", file=sys.stderr)
        return 5 if partial else 1

    session.report.publish(title, args.result_json)
    print("\npublished successfully")
    print(json.dumps(result, indent=2))
    return 0


def preflight(args: argparse.Namespace) -> int:
    """Check everything that does not touch the network, and report."""
    ok = True

    if args.mod_id:
        print(f"  ok      updating existing mod {args.mod_id}")
    else:
        print("  MISSING --mod-id: this repository only ever updates mod 154004")
        ok = False

    if os.environ.get("PDX_REFRESH"):
        print(f"  ok      PDX_REFRESH present ({len(os.environ['PDX_REFRESH'])} chars)")
    else:
        print("  MISSING PDX_REFRESH")
        ok = False

    for label, path, limit in (("payload", args.payload, None),
                               ("thumbnail", args.thumbnail, 2 * 1024 * 1024)):
        if not path or not os.path.exists(path):
            print(f"  MISSING {label} {path}")
            ok = False
        elif limit and os.path.getsize(path) > limit:
            print(f"  TOO BIG {label} {path} ({os.path.getsize(path)} bytes > {limit})")
            ok = False
        else:
            print(f"  ok      {label} {path} ({os.path.getsize(path)} bytes)")

    unknown = missing_routes()
    print(f"  {'ok     ' if not unknown else 'PENDING'} routes: "
          + ("all known" if not unknown else f"{len(unknown)} unknown - " + ", ".join(unknown)))

    print("\ndry run complete: " + ("ready to publish" if ok and not unknown
                                    else "plumbing verified; capture the renewal route to go live"))
    return 0 if ok else 1


def _read_text(path: str | None) -> str:
    if not path:
        return ""
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Publish the mod to Paradox Mods.")
    parser.add_argument("--payload", required=True, help="packed mod archive")
    parser.add_argument("--thumbnail", required=True, help="cover image, max 2 MB")
    parser.add_argument("--title", default="SMR Community Fixes")
    parser.add_argument("--short-description", default="")
    parser.add_argument("--description-file")
    parser.add_argument("--changelog", default="")
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--mod-id", type=int, required=True)
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--env", choices=sorted(HOSTS), default="prod")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--result-json", default="publish-result.json")
    args = parser.parse_args(argv)

    if args.dry_run:
        return preflight(args)

    unknown = missing_routes()
    if unknown:
        print("error: unknown routes: " + ", ".join(unknown)
              + "\nCapture a session renewal to fill them. See HANDOFF.md.", file=sys.stderr)
        return 3

    return publish_mod(args)


if __name__ == "__main__":
    raise SystemExit(main())
