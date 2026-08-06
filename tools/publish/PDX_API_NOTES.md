# The Paradox Mods upload API

This is how `pdx_client.py` publishes the mod without the game installed. The
service is undocumented, so everything here was established against the live API
and confirmed by a real publish. It can change without notice.

The host is `https://api.paradox-interactive.com`. The sandbox and staging hosts
named inside the SDK have never answered for this game, so there is nothing to
rehearse against — `--dry-run` is the rehearsal, and it sends nothing.

## Why not just use the game

The game's own `PDX_Upload` is a thin Lua wrapper over native code in
`PDXSDK.dll`. The HTTP request is built inside the DLL, where it can neither be
read nor reused, and a CI runner has neither the game nor the SDK. Talking to
the service directly is the only option that works from a hosted runner.

## Authentication

There is no request signing, despite the `AuthorizationHawk` name in the DLL.
`Authorization` is a JSON object whose single key names the scheme:

```
{"renewal":{"token":"<refresh token>"}}   to exchange a refresh token
{"session":{"token":"<session token>"}}   on every other call
```

A password cannot be used. The game sends `sha256(password + salt)`, where the
salt is a random per-account value computed inside the DLL: it never crosses the
wire and is not stored on disk, so the hash cannot be reproduced anywhere else.

The refresh token is used instead. It lives in `account.json` under
`%LOCALAPPDATA%\PDX\SDK\surviving_mars_relaunched\` as `refreshToken`, and two
of its properties are what make unattended publishing possible:

* Renewing does not rotate it — the reply carries no new refresh token.
* Logging out of the game does not revoke it. Logging out blanks the value on
  disk, but the token itself keeps working.

The practical consequences are that the token has to be copied out while the
account is logged in, since logging out erases the only local copy, and that it
should be treated as long-lived rather than as a session credential.

## Headers

Every call to the API host carries the game and SDK identification headers:

```
X-PDX-Game-Name      X-PDX-Game-Version    X-PDX-Platform
X-PDX-SDK-Type       X-PDX-SDK-Version     X-PDX-Error-Version
```

`x-accept-version` is the one that causes trouble. It is a bare integer, and the
correct value differs per endpoint:

| Call | Value | What a wrong value does |
|---|---|---|
| renew | omit the header | — |
| `GET /mods` | `1` | `2` returns 200 with an empty `modDetail` |
| `POST /mods/presigned-urls` | `2` | `1` returns 404 |
| `PUT /mods/{modId}/versions` | `2` | `1` returns 404 |

A malformed value such as `2.0` or `v2` is rejected as `invalid-api-version`,
which is clear enough. A well-formed value on the wrong endpoint returns a bare
404, which looks exactly like a route that does not exist — so a correct route
can appear permanently missing when only this header is wrong.

## The sequence

```
1. renew    PUT  /accounts/sessions/surviving_mars_relaunched
            Authorization: {"renewal":{"token":…}}, no body
            -> {"session":{"token":…}}

2. read     GET  /mods?arch=Any&modId=154004&os=Windows
            -> {"result":"OK","modDetail":{…}}

3. presign  POST /mods/presigned-urls
            {"fileName":…,"gameName":…,"modName":<uuid>}
            -> {"presignedUrl","contentType","fileName","modName"}
            once per file

4. upload   PUT  <presignedUrl>    raw bytes to S3, no auth, no PDX headers

5. publish  PUT  /mods/154004/versions
            -> {"result":"OK","state":"publishing","modId":…,"version":N}
```

The mod UUID that step 3 needs is `modDetail.name` from step 2 — not `modName`,
and not a top-level field. `DELETE /accounts/sessions/{game}` logs out and is
not used.

## The version PUT

Six fields are mandatory:

```
displayName   shortDescription   longDescription
contentFileName   changelogEntry   recommendedGameVersion
```

`recommendedGameVersion` must be the mod's `lua_revision` integer as a string
(for example `"350453"`), not a human version like `"1.0.7"`. The game's mod
browser passes the value through `tonumber` and compares it to `ModMinLuaRevision`
and `LuaRevision`; `"1.0.7"` does not parse and triggers a false incompatibility
warning on install. The in-game publisher sends `tostring(mod.lua_revision)`;
`pdx_client.py` reads the same field from `metadata.lua` unless overridden.

`thumbnail`, `tags`, `userModVersion`, `arch`, `os` and `acl` are optional.

Three of the mandatory six are the mod page's own text, which means every
publish rewrites the page description, and anything left blank is published
blank. That is why the client reads the mod first and sends those values back
unchanged unless told otherwise. It echoes the optional fields for the same
reason instead of assuming them: the live mod is `arch: Any, os: Any`, so
hardcoding `Windows` would have quietly narrowed it. `longDescription` is HTML
and holds wording that exists nowhere else, so it is edited on the mod page
rather than in this repository.

Two quirks are worth knowing. Fields are validated before the mod is looked up,
so a request aimed at a nonexistent mod id reports the missing requirements one
at a time without being able to publish anything — which is how the list above
was worked out. And optional fields are not type-checked: a deliberately absurd
`screenshots: 12345` was accepted without complaint, so a mistake in an optional
field fails silently rather than erroring.

Errors come back in a fixed shape where only `errorMessage` says anything
useful, `result` being `Failure` in every case:

```json
{"result":"Failure","errorCode":"bad-input",
 "errorMessage":"recommendedGameVersion: Must be set","detail":""}
```

## Images

Covers and screenshots are uploaded exactly the same way. Nothing in the upload
itself distinguishes them: the service files an image according to which field
of the version PUT names it, into `content/covers/` or `content/screenshots/`,
keeping the filename and generating the resized variants itself.

This repository publishes the cover only. If screenshots are ever wanted, note
that `screenshots` is the field the service reads *back*, as `{image, thumbnail}`
URL objects; which field the request uses to send them was never established.
`screenshotNames` is the likelier name, being a separate literal in the DLL, but
since optional fields are not validated the only way to confirm it is to publish
and look at the result.

## If the API changes

There is no certificate pinning, so the routes can be recovered by putting the
game through an intercepting proxy such as mitmproxy and uploading a mod once
from its own Mod Editor. Requests are easiest to match to calls by method and
body field names rather than by path, since the path is the thing being looked
for.

`x-accept-version` cannot be recovered that way if the capture omits header
values, which it should. It was originally found by sending `GET /mods` with
candidate values until one returned 200 instead of `invalid-api-version`.

Capture method, path, status, header *names* and body *field names* only, never
values. An early capture of a login logged an entire header and wrote an account
email, the login hash and live session tokens into a file. Removing the proxy
and its certificate afterwards matters for the same reason.

## Risks

* The API is undocumented and unsupported. Any change on Paradox's side breaks
  publishing with no warning, and their terms are worth reading before relying
  on it.
* The token can stop working. A publish that fails at `renew` with a 401 needs a
  fresh `refreshToken` and a new `gh secret set PDX_REFRESH`. A dry run reports
  this before a tag does.
