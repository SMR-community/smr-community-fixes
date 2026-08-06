"""Publish this mod to Paradox Mods over HTTP, without the game.

The protocol was recovered by capturing the game's own traffic and then checked
against the live service; PDX_API_NOTES.md records it. The upload is:

    establish session   (refresh token -> session token)
    GET  /mods?modId=…                      current mod state; its `name` is the
                                            mod UUID the presign calls need
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

Every route, header and field below was checked against the live service. Two
details cost the most to find, so they are stated plainly:

  * `x-accept-version` is per-endpoint and its value is a bare integer. Reading
    a mod is version 1; presigning and publishing are version 2. A malformed
    value is rejected as `invalid-api-version`, and a well-formed value for the
    wrong endpoint returns 404 - which reads as a missing route rather than a
    wrong header, so it is worth being sure which is which.
  * The version PUT requires displayName, shortDescription, longDescription,
    contentFileName, changelogEntry and recommendedGameVersion. The mod page's
    own text is therefore mandatory on every publish, so it is read back from
    the service first and sent unchanged unless explicitly overridden. Building
    it from local files instead would rewrite the page each release.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, NamedTuple
from urllib.parse import urlencode

# Named in PDXSDK.dll. Only prod has ever answered for this game, so there is no
# sandbox to rehearse against; --dry-run is the rehearsal.
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


class Route(NamedTuple):
    method: str
    path: str
    # Value for the `x-accept-version` header; None omits it. Each endpoint is
    # versioned on its own: /mods answers version 1 and returns an empty record
    # for version 2, while presign and versions answer 2 and 404 for 1.
    api_version: str | None


ROUTES: dict[str, Route] = {
    # PUT with Authorization {"renewal":{"token":<refresh>}} and no body returns
    # {"session":{"token":<session>,…}}. No new refresh token comes back, so the
    # stored one does not rotate.
    "renew": Route("PUT", "/accounts/sessions/" + GAME_NAME, None),
    "logout": Route("DELETE", "/accounts/sessions/" + GAME_NAME, None),
    "mod_details": Route("GET", "/mods", "1"),           # + ?arch=&modId=&os=
    "presign": Route("POST", "/mods/presigned-urls", "2"),
    "publish_version": Route("PUT", "/mods/{mod_id}/versions", "2"),
}

# These only narrow the mod *read*. What gets published keeps whatever arch and
# os the mod already carries, which is not necessarily either of these.
QUERY_ARCH = "Any"
QUERY_OS = "Windows"

# The game compares this field to LuaRevision (an integer build id), not to a
# human version like "1.0.7". The in-game publisher sends tostring(mod.lua_revision).
_LUA_REVISION_RE = re.compile(r"""['"]lua_revision['"]\s*,\s*(\d+)""")


def read_lua_revision(metadata_path: str = "metadata.lua") -> str:
    """Return metadata.lua's lua_revision as a string for recommendedGameVersion."""
    with open(metadata_path, encoding="utf-8") as handle:
        text = handle.read()
    match = _LUA_REVISION_RE.search(text)
    if not match:
        raise PdxError("metadata",
                       f"could not read lua_revision from {metadata_path}")
    return match.group(1)


def resolved_recommended_game_version(args: argparse.Namespace) -> str:
    if args.recommended_game_version.strip():
        return args.recommended_game_version.strip()
    return read_lua_revision(args.metadata)


class PdxError(RuntimeError):
    """A failed call, carrying enough to tell somebody what went wrong."""

    def __init__(self, step: str, message: str, status: int | None = None,
                 retryable: bool = False) -> None:
        super().__init__(message)
        self.step = step
        self.status = status
        self.retryable = retryable


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
        # The service's own shape. `errorMessage` carries the part worth reading
        # ("recommendedGameVersion: Must be set"), while `result` is always the
        # word "Failure" and says nothing.
        named = [data.get(key) for key in ("errorMessage", "errorCode", "detail")]
        useful = [value for value in named if isinstance(value, str) and value]
        if useful:
            return " / ".join(dict.fromkeys(useful))[:300]
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

    def _call(self, step: str, method: str, url: str, *,
              headers: dict[str, str], body: bytes = b"",
              content_type: str = "") -> Any:
        """One reported, retried step against a full URL."""
        started = time.monotonic()
        hdrs = headers
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

    def _api_headers(self, api_version: str | None) -> dict[str, str]:
        headers = dict(PDX_HEADERS)
        headers["Authorization"] = self.auth.header()
        if api_version is not None:
            headers["x-accept-version"] = api_version
        return headers

    def _api(self, step: str, route_name: str, *, json_body: dict | None = None,
             query: dict | None = None, **fmt) -> Any:
        route = _route(route_name)
        url = self.base + route.path.format(**fmt)
        if query:
            url += "?" + urlencode(query)
        body = json.dumps(json_body).encode() if json_body is not None else b""
        return self._call(step, route.method, url, body=body,
                          content_type="application/json" if json_body is not None else "",
                          headers=self._api_headers(route.api_version))

    # -- API surface -------------------------------------------------------

    def establish_session(self, refresh_token: str) -> None:
        """Exchange a refresh token for a session token via the renewal call.

        Confirmed shape: PUT the sessions endpoint with the refresh token in the
        Authorization object under the `renewal` discriminator, and no body. The
        response `session.token` is the working session token; no refresh token
        comes back, so the stored one is reused unchanged.
        """
        self.auth.refresh_token = refresh_token
        route = _route("renew")
        headers = dict(PDX_HEADERS)
        headers["Authorization"] = json.dumps({"renewal": {"token": refresh_token}})
        data = self._call("renew", route.method, self.base + route.path,
                          headers=headers)
        token = (data or {}).get("session", {}).get("token")
        if not token:
            raise PdxError("renew", "renewal returned no session token")
        self.auth.session_token = token

    def mod_details(self, mod_id: int) -> dict:
        """The mod as the service currently holds it, out of its envelope.

        The reply is {"result":"OK","modDetail":{…}}, and everything a republish
        has to preserve lives in modDetail.
        """
        reply = self._api("mod_details", "mod_details",
                          query={"arch": QUERY_ARCH, "modId": mod_id,
                                 "os": QUERY_OS}) or {}
        return reply.get("modDetail") or {}

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


def _route(name: str) -> Route:
    route = ROUTES.get(name)
    if route is None:
        raise PdxError(name, f"no route named '{name}'")
    return route


def _read(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


def version_body(args: argparse.Namespace, live: dict, thumb: dict,
                 content: dict) -> dict:
    """The body of the version PUT, defaulting to what the page already shows.

    The service makes the page's own text mandatory on every publish, so a
    release that only means to ship new code still has to restate the
    description, and anything left blank here would be published as blank. Each
    such field therefore falls back to the value just read from the service, and
    only an explicit argument replaces it.
    """
    display_name = args.title or live.get("displayName") or ""
    short_description = args.short_description or live.get("shortDescription") or ""
    long_description = (_read_text(args.description_file)
                        or live.get("longDescription") or "")

    empty = [name for name, value in (
        ("displayName", display_name),
        ("shortDescription", short_description),
        ("longDescription", long_description),
        ("changelogEntry", args.changelog),
    ) if not value.strip()]
    if empty:
        raise PdxError(
            "publish_version",
            "the service requires " + ", ".join(empty) + ", and neither the "
            "command line nor the current mod record supplies one. Publishing "
            "now would blank it on the mod page.")

    return {
        "contentFileName": content["fileName"],
        "thumbnail": thumb["fileName"],
        "displayName": display_name,
        "shortDescription": short_description,
        "longDescription": long_description,
        "changelogEntry": args.changelog,
        "recommendedGameVersion": resolved_recommended_game_version(args),
        "userModVersion": str(args.version),
        # Optional to send, but echoed back rather than assumed: the mod is
        # published for every arch and os, and naming one here would quietly
        # narrow it.
        "tags": args.tag or live.get("tags") or [],
        "arch": live.get("arch") or "Any",
        "os": live.get("os") or "Any",
        "acl": live.get("acl") or "public",
        # No screenshot field is sent. The cover is the only image this
        # publishes, and naming screenshots is left to the mod page.
    }


def publish_mod(args: argparse.Namespace) -> int:
    refresh = os.environ.get("PDX_REFRESH")
    if not refresh:
        print("error: set PDX_REFRESH (the Paradox account refresh token)", file=sys.stderr)
        return 2

    # Checked here rather than at the version PUT, which happens after both
    # uploads: there is no reason to spend them on a release the service will
    # reject for a missing changelog.
    if not args.changelog.strip():
        print("error: --changelog is required; the service rejects a version "
              "without a changelog entry", file=sys.stderr)
        return 2

    session = PdxSession(HOSTS[args.env])
    title = f"Publish to Paradox Mods ({args.env}) — version {args.version}"

    try:
        session.establish_session(refresh)

        live = session.mod_details(args.mod_id)
        mod_name = live.get("name")
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

        result = session.publish_version(
            args.mod_id, version_body(args, live, thumb, content))
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


def check_credential(args: argparse.Namespace) -> bool:
    """Prove the stored token still works, without publishing anything.

    Presence is not validity. The token is issued to one Paradox account, and
    logging that account in again elsewhere can replace it - after which every
    offline check still passes and only the tag fails. So the dry run spends two
    reads to say plainly whether a publish would get through, which is what lets
    somebody who has no Paradox account of their own confirm the repository is
    ready before tagging.
    """
    session = PdxSession(HOSTS[args.env])
    try:
        session.establish_session(os.environ["PDX_REFRESH"])
    except PdxError as exc:
        status = f" (HTTP {exc.status})" if exc.status else ""
        print(f"  REJECTED PDX_REFRESH was not accepted{status}: {exc}")
        print("           The token has been revoked or replaced. Log in once as"
              " the publishing account, read refreshToken from the SDK's"
              " account.json, and re-run `gh secret set PDX_REFRESH`.")
        return False

    try:
        live = session.mod_details(args.mod_id)
    except PdxError as exc:
        print(f"  FAILED  could not read mod {args.mod_id}: {exc}")
        return False

    ok = True
    if live.get("actions", {}).get("canEdit"):
        print(f"  ok      mod {args.mod_id} \"{live.get('displayName')}\" is "
              f"editable by this account")
    else:
        print(f"  DENIED  this account cannot edit mod {args.mod_id}; publishing "
              f"would be refused")
        ok = False

    published = live.get("latestVersion")
    if isinstance(published, int) and args.version <= published:
        print(f"  STALE   version {args.version} is not above the published "
              f"{published}; bump 'version' in metadata.lua")
        ok = False
    else:
        print(f"  ok      version {args.version} follows the published {published}")
    return ok


def preflight(args: argparse.Namespace) -> int:
    """Report whether a publish would succeed, without publishing."""
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

    # Required by the service on every publish, and the one such field with no
    # value on the mod page to fall back to.
    if args.changelog.strip():
        print(f"  ok      changelog entry {args.changelog[:60]!r}")
    else:
        print("  MISSING changelog entry (--changelog): the service rejects a "
              "version without one")
        ok = False

    try:
        recommended = resolved_recommended_game_version(args)
        print(f"  ok      recommendedGameVersion {recommended!r} "
              f"(from {args.metadata})")
    except PdxError as exc:
        print(f"  MISSING {exc}")
        ok = False

    # Last, and only if the rest holds: no point asking the service anything
    # when the payload is already wrong.
    if ok and os.environ.get("PDX_REFRESH") and not args.offline:
        ok = check_credential(args)

    print("\ndry run complete: "
          + ("ready to publish" if ok else "not ready, see above"))
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
    # Each of these overrides what the mod page already shows. Left unset, the
    # current value is read from the service and republished unchanged.
    parser.add_argument("--title", default="")
    parser.add_argument("--short-description", default="")
    parser.add_argument("--description-file")
    parser.add_argument("--changelog", default="")
    parser.add_argument("--metadata", default="metadata.lua",
                        help="mod metadata.lua; lua_revision becomes "
                             "recommendedGameVersion unless overridden")
    parser.add_argument("--recommended-game-version", default="",
                        help="override recommendedGameVersion; default is "
                             "lua_revision from --metadata")
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--mod-id", type=int, required=True)
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--env", choices=sorted(HOSTS), default="prod")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--offline", action="store_true",
                        help="with --dry-run, check only the files and arguments "
                             "and never contact Paradox")
    parser.add_argument("--result-json", default="publish-result.json")
    args = parser.parse_args(argv)

    if args.dry_run:
        return preflight(args)

    return publish_mod(args)


if __name__ == "__main__":
    raise SystemExit(main())
