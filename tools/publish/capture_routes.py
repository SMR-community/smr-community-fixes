"""mitmproxy addon: record the Paradox Mods routes the game actually calls.

    pip install mitmproxy
    mitmdump -s tools/publish/capture_routes.py

Trust the mitmproxy CA in the Windows machine store, set the system proxy to
127.0.0.1:8080, then upload the mod once from the game's Mod Editor. Every
request to a paradox-interactive.com API host is appended to routes.json with
its method, path, header names and body field names.

Credentials never reach the file: header values are dropped, and any field whose
name looks like a secret is replaced with its type. What is recorded is shape,
not content — exactly what filling ROUTES in pdx_client.py needs.
"""

from __future__ import annotations

import json
import os
from typing import Any

OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "routes.json")
API_HOSTS = ("api.paradox-interactive.com",)
SECRET_HINTS = ("pass", "token", "secret", "key", "mac", "nonce", "auth", "email")

# Storage hosts a presigned upload can land on. Anything else off the API host
# is unrelated traffic - Windows telemetry, the launcher, a browser.
STORAGE_HINTS = ("amazonaws.com", "cloudfront.net", "paradoxplaza.com", "akamai")

# mitmproxy hot-reloads this file when it changes, which resets module state.
# Load what is already on disk so an edit mid-capture cannot discard it.
def _load() -> list[dict]:
    try:
        with open(OUTPUT, encoding="utf-8") as handle:
            existing = json.load(handle)
            return existing if isinstance(existing, list) else []
    except (OSError, ValueError):
        return []


_records: list[dict] = _load()


def _shape(value: Any, depth: int = 0) -> Any:
    """Field names and types, never values."""
    if depth > 4:
        return "..."
    if isinstance(value, dict):
        return {
            k: ("<redacted>" if any(h in k.lower() for h in SECRET_HINTS)
                else _shape(v, depth + 1))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [_shape(value[0], depth + 1)] if value else []
    return type(value).__name__


def _body_shape(content: bytes | None, content_type: str) -> Any:
    if not content:
        return None
    if "json" in content_type:
        try:
            return _shape(json.loads(content))
        except (ValueError, UnicodeDecodeError):
            return f"<unparsed json, {len(content)} bytes>"
    return f"<{content_type or 'binary'}, {len(content)} bytes>"


def auth_scheme(flow) -> str:  # noqa: ANN001
    """Classify the Authorization header. Never returns any of its content.

    Paradox does not use a space-separated scheme here: the header is a JSON
    object such as {"session":{"token":...}} or {"hawk":{"email":...}}. An
    earlier version of this function returned the part before the first space,
    which for a JSON header is the entire header - email, password hash and
    session token included. Only the top-level key names are reported now, and
    only from a fixed allow-list, so no value can escape through this path.
    """
    value = flow.request.headers.get("authorization", "")
    if not value:
        return ""
    known = ("session", "hawk", "steam", "bearer", "basic", "refresh")
    found = [name for name in known if f'"{name}"' in value.lower()
             or value.lower().startswith(name)]
    return "+".join(found) if found else "<unrecognised>"


def response(flow) -> None:  # noqa: ANN001 - mitmproxy passes its own flow type
    host = flow.request.pretty_host
    if not any(host.endswith(h) for h in API_HOSTS):
        # Bytes go to a storage host via a presigned URL. Record that it
        # happened - method, host, size - never the signed URL, which is a
        # short-lived credential.
        if (flow.request.method in ("PUT", "POST") and flow.request.raw_content
                and any(hint in host for hint in STORAGE_HINTS)):
            _records.append({
                "method": flow.request.method,
                "path": f"<presigned upload to {host}>",
                "status": flow.response.status_code,
                "request_headers": sorted(flow.request.headers.keys()),
                "request_content_type": flow.request.headers.get("content-type", ""),
                "request_body": f"<{len(flow.request.raw_content)} bytes>",
                "response_body": None,
                "auth_scheme": auth_scheme(flow),
            })
            with open(OUTPUT, "w", encoding="utf-8") as handle:
                json.dump(_records, handle, indent=2, sort_keys=True)
            print(f"[pdx] {flow.request.method} {host} "
                  f"({len(flow.request.raw_content)} bytes) -> {flow.response.status_code}")
        return

    record = {
        "method": flow.request.method,
        "path": flow.request.path,
        "status": flow.response.status_code,
        "auth_scheme": auth_scheme(flow),
        "request_headers": sorted(flow.request.headers.keys()),
        "request_content_type": flow.request.headers.get("content-type", ""),
        "request_body": _body_shape(
            flow.request.raw_content, flow.request.headers.get("content-type", "")
        ),
        "response_body": _body_shape(
            flow.response.raw_content, flow.response.headers.get("content-type", "")
        ),
    }
    _records.append(record)

    with open(OUTPUT, "w", encoding="utf-8") as handle:
        json.dump(_records, handle, indent=2, sort_keys=True)

    print(f"[pdx] {record['method']} {record['path']} -> {record['status']}")


def done() -> None:
    print(f"[pdx] wrote {len(_records)} request(s) to {OUTPUT}")
