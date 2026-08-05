"""Publish this mod to Paradox Mods over HTTP, without the game.

Everything here is confirmed against PDXSDK.dll except the routes in ROUTES,
which are runtime-assembled and must come from one capture run. See
PDX_API_NOTES.md. The client refuses to run while any route is None, rather than
guessing and sending a request nobody can predict the effect of.

Usage:
    PDX_USER=... PDX_PASS=... python tools/publish/pdx_client.py --payload dist/SMRCF.zip

Standard library only.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

HOSTS = {
    "prod": "https://api.paradox-interactive.com",
    "sandbox": "https://sandbox-api.paradox-interactive.com",
    "staging": "https://staging-api.paradox-interactive.com",
    "test": "https://test-api.paradox-interactive.com",
}

# Sent on every request. Values mirror what the game reports about itself; the
# service uses them to scope the mod to the right title.
PDX_HEADERS = {
    "X-PDX-Game-Name": "surviving_mars_relaunched",
    "X-PDX-Game-Version": "1.0.7",
    "X-PDX-Platform": "pc",
    "X-PDX-SDK-Type": "cpp",
    "X-PDX-SDK-Version": "1.0",
    "X-PDX-Error-Version": "2",
}

# Fill from routes.json after a capture run. Each value is (METHOD, PATH).
# PATH may contain {placeholders} substituted per call.
ROUTES: dict[str, tuple[str, str] | None] = {
    "login": None,            # account credentials -> session + hawk key
    "renew": None,            # refresh_token -> new session
    "mod_details": None,      # {mod_id} -> current published state
    "setup_publish": None,    # -> {modName, modFolderPath}
    "upload_asset": None,     # thumbnail / screenshot, octet-stream
    "upload_content": None,   # the payload archive, octet-stream
    "publish": None,          # first publication
    "publish_new_version": None,  # subsequent versions
}


class PdxError(RuntimeError):
    pass


def missing_routes() -> list[str]:
    return sorted(name for name, route in ROUTES.items() if route is None)


# --------------------------------------------------------------------------
# Hawk request signing (https://github.com/mozilla/hawk)
# --------------------------------------------------------------------------


@dataclass
class Credentials:
    """A Hawk credential pair plus the session tokens issued at login."""

    id: str
    key: str
    algorithm: str = "sha256"
    session_token: str | None = None
    refresh_token: str | None = None


def payload_hash(body: bytes, content_type: str) -> str:
    """Hawk payload hash: base64(sha256("hawk.1.payload\\n<type>\\n<body>\\n"))."""
    normalized = b"hawk.1.payload\n" + content_type.encode() + b"\n" + body + b"\n"
    return base64.b64encode(hashlib.sha256(normalized).digest()).decode()


def hawk_header(
    creds: Credentials,
    method: str,
    url: str,
    body: bytes = b"",
    content_type: str = "",
    ext: str = "",
) -> str:
    parts = urlsplit(url)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    path = parts.path + (f"?{parts.query}" if parts.query else "")
    ts = str(int(time.time()))
    nonce = secrets.token_urlsafe(6)
    hash_value = payload_hash(body, content_type) if body else ""

    normalized = (
        "hawk.1.header\n"
        f"{ts}\n{nonce}\n{method.upper()}\n{path}\n"
        f"{parts.hostname}\n{port}\n{hash_value}\n{ext}\n"
    )
    digest = hmac.new(
        creds.key.encode(), normalized.encode(), getattr(hashlib, creds.algorithm)
    ).digest()
    mac = base64.b64encode(digest).decode()

    fields = [f'id="{creds.id}"', f'ts="{ts}"', f'nonce="{nonce}"']
    if hash_value:
        fields.append(f'hash="{hash_value}"')
    if ext:
        fields.append(f'ext="{ext}"')
    fields.append(f'mac="{mac}"')
    return "Hawk " + ", ".join(fields)


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------


class PdxSession:
    def __init__(self, base: str = HOSTS["prod"], timeout: int = 300) -> None:
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.creds: Credentials | None = None

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: bytes = b"",
        content_type: str = "",
        signed: bool = True,
    ) -> Any:
        url = f"{self.base}{path}"
        headers = dict(PDX_HEADERS)
        if content_type:
            headers["Content-Type"] = content_type
        if signed:
            if self.creds is None:
                raise PdxError("not logged in")
            headers["Authorization"] = hawk_header(
                self.creds, method, url, body, content_type
            )

        request = urllib.request.Request(url, data=body or None, method=method.upper())
        for name, value in headers.items():
            request.add_header(name, value)

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            raise PdxError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise PdxError(f"{method} {path} -> {exc.reason}") from exc

        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw

    def _json(self, route: str, payload: dict, *, signed: bool = True, **fmt) -> Any:
        method, path = _route(route)
        body = json.dumps(payload).encode()
        return self._request(
            method, path.format(**fmt), body=body,
            content_type="application/json", signed=signed,
        )

    def _binary(self, route: str, blob: bytes, **fmt) -> Any:
        method, path = _route(route)
        return self._request(
            method, path.format(**fmt), body=blob,
            content_type="application/octet-stream",
        )

    # -- API surface, mirroring PDX_Upload's call order --------------------

    def login(self, user: str, password: str) -> None:
        data = self._json("login", {"email": user, "password": password}, signed=False)
        self.creds = Credentials(
            id=data["session"]["id"],
            key=data["session"]["key"],
            algorithm=data["session"].get("algorithm", "sha256"),
            session_token=data.get("sessionToken"),
            refresh_token=data.get("refresh_token"),
        )

    def mod_details(self, mod_id: int) -> dict:
        method, path = _route("mod_details")
        return self._request(method, path.format(mod_id=mod_id))

    def setup_for_publish(self, folder_name: str | None = None) -> dict:
        return self._json("setup_publish", {"folderName": folder_name} if folder_name else {})

    def upload_asset(self, mod_name: str, file_path: str) -> str:
        blob = _read_limited(file_path, 2 * 1024 * 1024, "asset")
        return self._binary("upload_asset", blob, mod_name=mod_name)["fileName"]

    def upload_content(self, mod_name: str, payload_path: str) -> str:
        with open(payload_path, "rb") as handle:
            blob = handle.read()
        return self._binary("upload_content", blob, mod_name=mod_name)["fileName"]

    def publish(self, body: dict, mod_id: int | None) -> dict:
        if mod_id:
            return self._json("publish_new_version", body | {"modId": mod_id})
        return self._json("publish", body)


def _route(name: str) -> tuple[str, str]:
    route = ROUTES.get(name)
    if route is None:
        raise PdxError(
            f"route '{name}' is unknown. Run a capture (see PDX_API_NOTES.md) "
            f"and fill ROUTES in {os.path.basename(__file__)}."
        )
    return route


def _read_limited(path: str, limit: int, what: str) -> bytes:
    size = os.path.getsize(path)
    if size > limit:
        raise PdxError(f"{what} {path} is {size} bytes; the service rejects over {limit}")
    with open(path, "rb") as handle:
        return handle.read()


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def publish_mod(args: argparse.Namespace) -> int:
    user = os.environ.get("PDX_USER")
    password = os.environ.get("PDX_PASS")
    if not user or not password:
        print("error: set PDX_USER and PDX_PASS", file=sys.stderr)
        return 2

    session = PdxSession(HOSTS[args.env])
    session.login(user, password)

    details = session.mod_details(args.mod_id) if args.mod_id else {}
    existing_name = details.get("Name") or None
    setup = session.setup_for_publish(existing_name)
    mod_name = existing_name or setup["modName"]

    thumbnail = session.upload_asset(mod_name, args.thumbnail)
    screenshots = [session.upload_asset(mod_name, s) for s in args.screenshot]
    content = session.upload_content(mod_name, args.payload)

    result = session.publish(
        {
            "modName": mod_name,
            "displayName": args.title,
            "shortDescription": args.short_description,
            "longDescription": _read_text(args.description_file),
            "thumbnail": thumbnail,
            "screenshotNames": screenshots,
            "fileName": content,
            "version": args.version,
            "gameName": PDX_HEADERS["X-PDX-Game-Name"],
            "tags": args.tag,
        },
        args.mod_id,
    )
    print(json.dumps(result, indent=2))
    return 0


def _read_text(path: str | None) -> str:
    if not path:
        return ""
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", required=True, help="packed mod archive to upload")
    parser.add_argument("--thumbnail", required=True, help="cover image, max 2 MB")
    parser.add_argument("--screenshot", action="append", default=[], help="repeatable")
    parser.add_argument("--title", default="SMR Community Fixes")
    parser.add_argument("--short-description", default="")
    parser.add_argument("--description-file")
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--mod-id", type=int, help="omit for a first publication")
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--env", choices=sorted(HOSTS), default="prod")
    args = parser.parse_args(argv)

    unknown = missing_routes()
    if unknown:
        print(
            "error: these routes are still unknown: " + ", ".join(unknown) +
            "\nRun one capture against the real service and fill ROUTES."
            "\nSee tools/publish/PDX_API_NOTES.md.",
            file=sys.stderr,
        )
        return 3

    try:
        return publish_mod(args)
    except PdxError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
