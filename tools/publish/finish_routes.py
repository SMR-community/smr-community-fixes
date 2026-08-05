"""Turn a capture into a finished client.

    python tools/publish/finish_routes.py

Reads routes.json written by capture_routes.py, works out which captured
request is which call, and rewrites the ROUTES table in pdx_client.py in place.
Path components that vary between calls (a mod id, a generated mod name) are
replaced with the placeholders pdx_client.py substitutes.

Nothing here talks to the network. Run it after the capture, then run the
publisher's --dry-run to confirm every route is filled.
"""

from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CAPTURE = os.path.join(HERE, "routes.json")
CLIENT = os.path.join(HERE, "pdx_client.py")

# How each call is recognised in the capture. Ordered: the first rule that
# matches an unclaimed request wins, so the specific rules come before the
# general ones. Matching is on method, body field names and content type -
# never on path, which is the unknown we are recovering.
RULES: list[tuple[str, dict]] = [
    ("login", {"method": "POST", "fields": {"password", "email"}}),
    ("renew", {"method": "POST", "fields": {"refresh_token"}}),
    ("upload_content", {"method": "POST", "content_type": "application/octet-stream", "largest": True}),
    ("upload_asset", {"method": "POST", "content_type": "application/octet-stream"}),
    ("publish_new_version", {"method": "POST", "fields": {"modId"}}),
    ("publish", {"method": "POST", "fields": {"displayName"}}),
    ("setup_publish", {"method": "POST", "response_fields": {"modName"}}),
    ("mod_details", {"method": "GET"}),
]

# Path segments that are per-call values rather than part of the route.
PLACEHOLDER_RULES = [
    (re.compile(r"/\d{3,}(?=/|$)"), "/{mod_id}"),
    (re.compile(r"/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=/|$)", re.I), "/{mod_name}"),
]


def field_names(shape) -> set[str]:
    return set(shape) if isinstance(shape, dict) else set()


def size_of(shape) -> int:
    if isinstance(shape, str):
        match = re.search(r"(\d+) bytes", shape)
        return int(match.group(1)) if match else 0
    return 0


def matches(record: dict, rule: dict) -> bool:
    if record["method"] != rule["method"]:
        return False
    if "content_type" in rule and rule["content_type"] not in record.get("request_content_type", ""):
        return False
    if "fields" in rule and not rule["fields"] <= field_names(record.get("request_body")):
        return False
    if "response_fields" in rule and not rule["response_fields"] <= field_names(record.get("response_body")):
        return False
    return True


def templatise(path: str) -> str:
    for pattern, replacement in PLACEHOLDER_RULES:
        path = pattern.sub(replacement, path)
    return path


def resolve(records: list[dict]) -> dict[str, tuple[str, str]]:
    remaining = [r for r in records if 200 <= r.get("status", 0) < 300]
    if not remaining:
        sys.exit("no successful requests in the capture - did the upload actually complete?")

    resolved: dict[str, tuple[str, str]] = {}
    for name, rule in RULES:
        candidates = [r for r in remaining if matches(r, rule)]
        if not candidates:
            continue
        chosen = max(candidates, key=lambda r: size_of(r.get("request_body"))) if rule.get("largest") else candidates[0]
        resolved[name] = (chosen["method"], templatise(chosen["path"]))
        remaining.remove(chosen)
    return resolved


def rewrite(resolved: dict[str, tuple[str, str]]) -> int:
    with open(CLIENT, encoding="utf-8") as handle:
        source = handle.read()

    start = source.index("ROUTES: dict[str, tuple[str, str] | None] = {")
    end = source.index("\n}\n", start) + 3

    lines = ["ROUTES: dict[str, tuple[str, str] | None] = {"]
    for name, _ in RULES:
        if name in resolved:
            method, path = resolved[name]
            lines.append(f'    "{name}": ("{method}", "{path}"),')
        else:
            lines.append(f'    "{name}": None,  # not seen in the capture')
    lines.append("}\n")

    with open(CLIENT, "w", encoding="utf-8") as handle:
        handle.write(source[:start] + "\n".join(lines) + source[end:])
    return len(resolved)


def main() -> int:
    if not os.path.exists(CAPTURE):
        sys.exit(f"no capture at {CAPTURE} - run the capture first, see PDX_API_NOTES.md")

    with open(CAPTURE, encoding="utf-8") as handle:
        records = json.load(handle)

    resolved = resolve(records)
    written = rewrite(resolved)

    for name, _ in RULES:
        if name in resolved:
            method, path = resolved[name]
            print(f"  {name:<20} {method:<5} {path}")
        else:
            print(f"  {name:<20} NOT FOUND")

    print(f"\n{written}/{len(RULES)} routes written to pdx_client.py")
    if written < len(RULES):
        print("Missing ones were not exercised by the capture. A first-time publish and an\n"
              "update of an existing mod use different calls, so capture both to get all of them.")
        return 1
    print("Run: python tools/publish/pdx_client.py --dry-run ... to confirm.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
