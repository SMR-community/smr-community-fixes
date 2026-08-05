# The Paradox Mods upload API

How `pdx_client.py` publishes mod 154004 without the game. Every route, header
and field here was verified against the live service, and a real publish has
gone through it.

Paradox documents none of this. It can break without notice.

## Why not use the game

`PDX_Upload` in the game's Lua is a thin driver over native functions in
`PDXSDK.dll`, so no HTTP request is built anywhere you can read or reuse, and a
hosted runner has neither the game nor the SDK. Hence a direct HTTP client.

Host: `https://api.paradox-interactive.com`. The sandbox, staging and test hosts
named in the DLL have never answered for this game, so there is nothing to
rehearse against — `--dry-run` is the rehearsal.

## Authentication

Despite `AuthorizationHawk` in the DLL there is **no HMAC and no request
signing**. `Authorization` is a JSON object whose single key names the scheme:

```
{"renewal":{"token":"<refresh token>"}}   exchange a refresh token
{"session":{"token":"<session token>"}}   every other call
```

**A password cannot be used.** The game's login sends `sha256(password + salt)`,
where the salt is a random per-account value: it never crosses the wire, it is
not on disk, and 40+ candidate constructions failed to reproduce a captured
hash. It is computed inside `PDXSDK.dll`. So no runner can log in with a
password, however freely the password is shared. This is settled; do not
re-investigate.

The refresh token, in
`%LOCALAPPDATA%\PDX\SDK\surviving_mars_relaunched\account.json` as
`refreshToken`, replaces it. Both of these were tested, not assumed:

* **Renewing does not rotate it.** The reply carries no new refresh token.
* **Logging out does not revoke it.** Logging out of the game blanks
  `refreshToken` on disk, but the value keeps working: CI authenticated and
  confirmed edit rights on the mod with the account logged out.

That is what lets anyone publish at any time. Two consequences:

* **Read the token out while logged in** — logout erases the only local copy,
  and only a fresh login mints another.
* **Logging out is not a revocation.** Treat the token as long-lived.

## Headers

Sent on every call to the api host:

```
X-PDX-Game-Name      X-PDX-Game-Version    X-PDX-Platform
X-PDX-SDK-Type       X-PDX-SDK-Version     X-PDX-Error-Version
```

### `x-accept-version`, which costs an afternoon

A **bare integer**, and **versioned per endpoint**:

| Call | Value | A wrong value gives |
|---|---|---|
| renew | omit the header | — |
| `GET /mods` | `1` | `2` returns 200 with an **empty** `modDetail` |
| `POST /mods/presigned-urls` | `2` | `1` returns **404** |
| `PUT /mods/{modId}/versions` | `2` | `1` returns **404** |

A malformed value (`2.0`, `v2`) is rejected as `invalid-api-version`, which is
honest. A well-formed value on the wrong endpoint returns a bare `404`, which
reads as a route that does not exist — so a correct route can look permanently
missing when only the header is wrong.

## The five calls

```
1. renew    PUT  /accounts/sessions/surviving_mars_relaunched
            Authorization: {"renewal":{"token":…}}, no body
            -> {"session":{"token":…}}

2. read     GET  /mods?arch=Any&modId=154004&os=Windows
            -> {"result":"OK","modDetail":{…}}
            modDetail.name is the mod UUID that presign needs. Not `modName`,
            and not at the top level.

3. presign  POST /mods/presigned-urls
            {"fileName":…,"gameName":…,"modName":<uuid>}
            -> {"presignedUrl","contentType","fileName","modName"}
            Once per file.

4. upload   PUT  <presignedUrl>      raw bytes, S3, no PDX headers, no auth

5. publish  PUT  /mods/154004/versions
            -> {"result":"OK","state":"publishing","modId":…,"version":N}
```

`DELETE /accounts/sessions/{game}` logs out, and is not needed.

## The version PUT

Six fields are mandatory:

```
displayName   shortDescription   longDescription
contentFileName   changelogEntry   recommendedGameVersion
```

Optional: `thumbnail`, `tags`, `userModVersion`, `arch`, `os`, `acl`.

**Three of the six are the mod page's own text, so every publish rewrites the
description.** Anything left blank is published blank. The client therefore
reads the mod first and sends those values back unchanged unless overridden, and
echoes the optional fields for the same reason rather than assuming them — the
live mod is `arch: Any, os: Any`, so a hardcoded `Windows` would have narrowed
it. `longDescription` is HTML, and holds wording that exists only on the page.

Two behaviours worth knowing:

* **Fields are validated before the mod is looked up.** Aiming a request at a
  nonexistent mod id reveals the required set one message at a time while having
  nothing it could publish. That is how the list above was found.
* **Optional fields are not type-checked.** A deliberately absurd
  `screenshots: 12345` was accepted, while a required field with a bad type is
  caught. So a wrong optional field fails silently instead of erroring.

### Errors

```json
{"result":"Failure","errorCode":"bad-input",
 "errorMessage":"recommendedGameVersion: Must be set","detail":""}
```

`result` is always `Failure` and says nothing; `errorMessage` is the useful part.

### Images

This repository publishes the cover and nothing else. Recorded in case
screenshots are ever wanted:

Covers and screenshots upload identically. Nothing in the upload says which is
which — the service files an image by **the field of the version PUT that names
it**, into `content/covers/` or `content/screenshots/`, keeping the filename and
generating the resized variants itself.

`screenshots` is what the service reads *back*, as `{image, thumbnail}` URL
objects. Which field the *request* uses was never established; `screenshotNames`
is likelier, being a separate DLL literal, but optional fields are not
validated, so it can only be confirmed by publishing and looking. Try
`screenshotNames` first, `screenshots` second. Any mod that has screenshots
shows the read shape, and mod ids are global across Paradox games.

## If Paradox changes the API

There is no certificate pinning, so an intercepting proxy recovers the routes.
The tooling that did this originally has been deleted; it was a day's work and
this file is its output. To redo it:

```
pip install mitmproxy
mitmdump --listen-port 8080     # once, to generate ~/.mitmproxy/
```

Trust `~/.mitmproxy/mitmproxy-ca-cert.pem`, then send the game through the proxy
and upload the mod once from its Mod Editor:

```text
Windows   certutil -addstore -f ROOT "%USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.pem"
          then Internet Settings -> proxy 127.0.0.1:8080
macOS     sudo security add-trusted-cert -d -r trustRoot \
              -k /Library/Keychains/System.keychain ~/.mitmproxy/mitmproxy-ca-cert.pem
          sudo networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 8080
Linux     copy the CA into /usr/local/share/ca-certificates and update-ca-certificates
          launch with HTTPS_PROXY=http://127.0.0.1:8080
```

Record only method, path, status, header *names* and body *field names* — never
values. A capture of a login once leaked an account email, the login hash and
session tokens into a file because the addon logged a whole header. Match
requests to calls by method and body field names rather than by path, since the
path is the unknown. Undo the proxy and remove the CA afterwards
(`certutil -user -delstore Root mitmproxy`).

A capture cannot give you `x-accept-version`, since it records names and not
values. Recover it as it was found the first time: send `GET /mods` with
candidate values until one returns 200 instead of `invalid-api-version`.

## Risks

* **Undocumented and unsupported.** Any change on Paradox's side breaks this
  with no notice. Check their terms before relying on it.
* **`PDX_REFRESH` is readable by every organisation member**, since anyone who
  can push a workflow can print a secret, and every member can push to `main`.
  Logging out does *not* withdraw it, so use a dedicated publishing account that
  owns nothing else.
* **The token can stop working.** A publish that fails at `renew` with 401 needs
  a fresh `refreshToken` and a new `gh secret set PDX_REFRESH`. A dry run
  reports this before a tag does.
