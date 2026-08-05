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

_records: list[dict] = []


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


def response(flow) -> None:  # noqa: ANN001 - mitmproxy passes its own flow type
    if not any(flow.request.pretty_host.endswith(h) for h in API_HOSTS):
        return

    record = {
        "method": flow.request.method,
        "path": flow.request.path,
        "status": flow.response.status_code,
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
