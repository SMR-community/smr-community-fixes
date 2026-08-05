# Paradox Mods upload API — what is known

Findings from static analysis of `PDXSDK.dll` (2.6 MB, shipped in the game root)
and the game's own Lua, for the purpose of publishing **this mod**, from **your
own account**, without opening the game.

**Status: complete and verified against the live service.** Every route, header
and required field below was exercised for real. The only call never run to
completion is the final version PUT, whose body was validated by the service
(it accepted the fields and then failed on a deliberately nonexistent mod id).

Files here:

```text
pdx_client.py      the client: session renewal, the upload sequence, per-step
                   reporting, retry of transient failures only
capture.py         one command: capture the routes and finish the client
capture_routes.py  the mitmproxy addon capture.py drives
finish_routes.py   turns a capture into a filled-in ROUTES table
```

The three capture files are only needed if Paradox changes the API. See
*Afterwards: delete the capture tooling*.

**Only the capture needs the game.** `pdx_client.py` speaks HTTP and nothing
else — it runs on a hosted Linux runner with no game, no SDK and no Paradox
install. The game is needed exactly once, by one person, because it is the only
program that already knows the routes. After that nobody needs it again.

## Where the upload happens

Not in Lua. `PDX_Upload` in `ModTools\Src\CommonLua\Libs\Paradox\ParadoxMods.lua`
is a thin driver over native functions exported by `PDXSDK.dll`:

```
PDX_Upload(mod, params)
  AsyncPdxGetModDetails      { ModID }                        -> mod details or empty
  AsyncPdxSetupModForPublish { FolderName? }                  -> { ModName, ModFolderPath }
  AsyncPdxUploadModAsset     { ModName, FilePath }            -> { FileName }   thumbnail
  AsyncPdxUploadModAsset     { ModName, FilePath }            -> { FileName }   each screenshot
  AsyncPdxUploadModContent   { ModName, ModFolderName }       -> { FileName }   the .fpk payload
  AsyncPdxPublishMod         { ModName, DisplayName, ... }    -> new mod
  AsyncPublishNewModVersion  { ModId, ... }                   -> new version of an existing mod
```

Login is native too: `PdxSDK:LogIn(user, pass)` → `AsyncPdxLoginAccount(user, pass)`
(`ModTools\Src\CommonLua\Libs\Paradox\PdxSDK.lua`).

Consequences worth being explicit about:

* No HTTP request is constructed anywhere in Lua, so nothing can be copied out.
* The `-cfg` Lua injection path the game supports is gated behind
  `not Platform.goldmaster`, so it only works with `MarsDebug.exe`. That rules
  out driving the retail game from CI even locally.
* A GitHub-hosted runner has neither the game nor the SDK, which is why this
  client talks to the service directly instead.

## Hosts

Extracted from `PDXSDK.dll`:

```
https://api.paradox-interactive.com            production
https://sandbox-api.paradox-interactive.com    sandbox
https://staging-api.paradox-interactive.com    staging
https://test-api.paradox-interactive.com       test
```

Telemetry hosts exist alongside each and are irrelevant here.

## Authentication: a JSON Authorization header, not Hawk

The DLL carries `AuthorizationHawk`, `AuthorizationSession`, `AuthorizationSteam`
and `AuthorizationRenewal` types, which reads like Hawk request signing. It is
not. **There is no HMAC anywhere.** The `Authorization` header is a JSON object
whose single key names the scheme:

```
{"hawk":{"email":…,"sha256(password+salt)":…}}   password login (unusable, see below)
{"renewal":{"token":"<refresh token>"}}          exchange a refresh token
{"session":{"token":"<session token>"}}          every other call
```

So `"hawk"` is only the key name of the password-login object, and the login hash
is not a signature.

**The password path cannot be reproduced off the machine that logged in.** Login
sends `sha256(password + salt)` where the salt is a per-account random value:
it never crosses the wire (a cold-start capture shows no salt fetch before
login), it is not in the SDK's on-disk store, and 40+ candidate constructions
failed to reproduce a captured hash. It is computed inside `PDXSDK.dll`. Do not
pursue it — use a refresh token, which is what the client does.

The refresh token is in
`%LOCALAPPDATA%\PDX\SDK\surviving_mars_relaunched\account.json` as `refreshToken`.
It does **not** rotate on renewal, so it can be stored once as the `PDX_REFRESH`
secret; it does change if you log out and back in.

## Required headers

Literal in the DLL, and sent on every api-host call:

```
X-PDX-Game-Name      X-PDX-Game-Version    X-PDX-Platform
X-PDX-SDK-Type       X-PDX-SDK-Version     X-PDX-Error-Version
```

Content types in use: `application/json`, `application/octet-stream`.

### `x-accept-version` is per-endpoint, and this one wastes an afternoon

Its value is a **bare integer**, and each endpoint is versioned separately:

| Call | Value | Wrong value gives |
|---|---|---|
| `PUT /accounts/sessions/{game}` (renew) | header omitted | — |
| `GET /mods` | `1` (or omitted) | `2` returns 200 with an **empty** `modDetail` |
| `POST /mods/presigned-urls` | `2` | `1` returns **404** |
| `PUT /mods/{modId}/versions` | `2` | `1` returns **404** |

Two traps. A malformed value (`2.0`, `v2`, a date) is rejected as
`invalid-api-version`, which is at least honest. But a *well-formed* value for
the wrong endpoint returns a bare `404 not-found`, which reads as a route that
does not exist — so a correct route can look permanently missing because of a
header. And version `2` of `GET /mods` answers `200` with nothing in it, so it
fails silently rather than loudly.

## JSON field names

Recovered as literals, so request bodies can be built with confidence:

```
modId          modName        modVersion      userModVersion
displayName    shortDescription   longDescription
displayImagePath   thumbnail   screenshots    screenshotNames
tags           tagName        externalLinks   fileName
game           gameName       gameNames       version
session        sessionToken   refresh_token   userAgent
```

## The protocol, verified

Host `https://api.paradox-interactive.com`. Five calls, in this order:

```
1. renew     PUT  /accounts/sessions/surviving_mars_relaunched   no api version
             Authorization: {"renewal":{"token":"<refresh>"}}, empty body
             -> {"session":{"token":"<uuid>",…}}     no new refresh token

2. read      GET  /mods?arch=Any&modId=154004&os=Windows         api version 1
             -> {"result":"OK","modDetail":{…}}
             modDetail.name is the mod's UUID, needed as `modName` below.
             It is NOT `modName` or `Name` at the top level.

3. presign   POST /mods/presigned-urls                           api version 2
             {"fileName":…,"gameName":…,"modName":<uuid>}
             -> {"presignedUrl","contentType","fileName","modName"}
             Once per file: thumbnail, then the content zip.

4. upload    PUT  <presignedUrl>            (S3; no PDX headers, no auth)
             raw bytes, Content-Type from the presign reply.

5. publish   PUT  /mods/154004/versions                          api version 2
             -> {"modId","version","state","result"}

   logout (optional)  DELETE /accounts/sessions/surviving_mars_relaunched
```

### What the version PUT requires

Exactly six fields are mandatory. The service validates them one at a time, and
**validates before it looks the mod up** — so the full set can be discovered
safely against a nonexistent mod id, which is how this list was obtained:

```
displayName        shortDescription   longDescription
contentFileName    changelogEntry     recommendedGameVersion
```

Everything else is optional: `thumbnail`, `screenshotNames`, `tags`,
`userModVersion`, `arch`, `os`, `acl`.

**Optional fields are not type-checked.** A deliberately absurd
`screenshots: 12345` was accepted as readily as a correct value, while a
required field with the wrong type is caught (`recommendedGameVersion: Must be
a string`). So passing validation says nothing about an optional field being
right — it can only be confirmed by publishing and looking at the page.

Three of the six are the mod page's own text. That means **every publish
rewrites the page's description**, and a client that does not supply it blanks
it. `pdx_client.py` therefore reads the mod (step 2) and sends those values
back unchanged unless explicitly overridden. The optional fields are echoed back
for the same reason rather than assumed — the live mod is `arch: Any, os: Any`,
so hardcoding `os: Windows` would have narrowed it.

`longDescription` is HTML (`<p>`, `<strong>`, `<a>`, `<ol>`), not the plain text
in `metadata.lua`, and it contains wording that exists only on the mod page.

### Images: covers and screenshots

Both upload identically — presign, then PUT the bytes. Nothing about the upload
says what kind of image it is; the service files it by **which field of the
version PUT names it**, into `content/covers/` or `content/screenshots/`, and
generates the resized variants itself:

```
displayImagePath  …/content/covers/cover_2.jpg
screenshots       [ { "image":     …/content/screenshots/screenshot_01.jpg,
                      "thumbnail": …/content/screenshots/screenshot_01_thumb.jpg } ]
```

The uploaded file name is kept verbatim, so `screenshot_01.jpg` in this
repository becomes `screenshot_01.jpg` there.

`screenshots` is definitely the field the service **reads back**, as those
objects. The request side sends *names*, and the DLL carries a separate
`screenshotNames` literal for exactly that, which is what the client sends.
This is the one field in the whole protocol not confirmed by observation —
optional fields are not validated, so a wrong key here does not error, the
screenshots simply never appear. If a publish leaves the page without them, send
the same list under `screenshots` instead.

A read of any mod that has screenshots shows the shape; mod ids are global
across Paradox games, so a neighbouring id works even if it belongs to another
game.

### Error shape

```json
{"result":"Failure","errorCode":"bad-input",
 "errorMessage":"recommendedGameVersion: Must be set","detail":""}
```

`result` is always the word `Failure`; `errorMessage` is the part worth reading.
A client that reports `result` says nothing useful.

## Re-capturing, if Paradox changes the API

There is no certificate pinning in the DLL — the only TLS-adjacent string is an
OpenSSL path from the bundled PGP library — so an intercepting proxy works.

### Doing the capture

On the machine with the game — Windows, macOS or Linux:

```
python tools/publish/capture.py
```

It installs mitmproxy, generates its CA, and prints the commands your platform
needs to trust it and route traffic through it. On Windows the system proxy is
also set and restored for you. Upload this mod once from the game's Mod Editor,
press Ctrl+C, and it fills in `ROUTES`. Confirm with a dry run:

```
python tools/publish/pdx_client.py --dry-run --payload dist/SMRCF.zip \
    --thumbnail Images/smr_community_fixes.jpg --version 1 --mod-id 154004 \
    --changelog "rehearsal"
```

Only shape is recorded — method, path, header names and body field names. Values,
including your password, are redacted before anything reaches disk.

A capture records header *names*, so it will show that `x-accept-version` was
sent but not which integer. Recover the value the way it was found the first
time: call `GET /mods` with candidate values, since anything malformed comes
back as `invalid-api-version` and a valid one returns `200`.

The mod already exists as
[154004](https://mods.paradoxplaza.com/mods/154004/Any), so capturing one
**update** is enough: it exercises every call this repository will ever make.

`finish_routes.py` will report `publish` as `NOT FOUND`, and that is expected —
that route creates a *new* mod page, which this repository must never do again.
Everything else must be filled.

### Afterwards: delete the capture tooling

Once a publish has actually succeeded, **delete `capture.py`,
`capture_routes.py`, `finish_routes.py` and `routes.json`**. They exist for one
afternoon's work and are dead weight after it. This file is the record; the
section above is enough to rebuild them if Paradox ever changes the API.

There is no usable sandbox for this game — the non-production hosts named in the
DLL have never answered — so the first real publish is the only end-to-end test
there is.

### Rebuilding the capture by hand

Everything the tooling did, in the order it did it:

```
pip install mitmproxy
mitmdump --listen-port 8080            # once, to generate ~/.mitmproxy/
```

Trust the CA — `~/.mitmproxy/mitmproxy-ca-cert.pem`:

```text
Windows   certutil -addstore -f ROOT "%USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.pem"
macOS     sudo security add-trusted-cert -d -r trustRoot \
              -k /Library/Keychains/System.keychain ~/.mitmproxy/mitmproxy-ca-cert.pem
Linux     sudo cp ~/.mitmproxy/mitmproxy-ca-cert.pem \
              /usr/local/share/ca-certificates/mitmproxy.crt && sudo update-ca-certificates
```

Route the game's traffic through it:

```text
Windows   Internet Settings → proxy 127.0.0.1:8080, or the ProxyEnable and
          ProxyServer values under HKCU\Software\Microsoft\Windows\
          CurrentVersion\Internet Settings
macOS     sudo networksetup -setwebproxy Wi-Fi 127.0.0.1 8080
          sudo networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 8080
Linux     launch the game with HTTPS_PROXY=http://127.0.0.1:8080
```

Run `mitmdump` with an addon whose `response(flow)` hook records, for each
request to `api.paradox-interactive.com`, the method, path, status, header
*names*, and the *field names* of the request and response bodies — never the
values, so credentials are not written down. Then upload the mod once from the
Mod Editor.

Match each captured request to a call by **method and body field names**, never
by path, since the path is the unknown being recovered:

```text
login                POST, body has password
renew                POST, body has refresh_token
upload_content       POST, octet-stream, the largest body
upload_asset         POST, octet-stream
publish_new_version  POST, body has modId
publish              POST, body has displayName
setup_publish        POST, response has modName
mod_details          GET
```

Replace the per-call parts of each path with the placeholders `pdx_client.py`
substitutes: a run of 3+ digits becomes `{mod_id}`, a UUID becomes `{mod_name}`.
Undo the proxy and CA changes afterwards.

## Risks, stated once

* **Undocumented and unsupported.** Paradox publishes no API contract. Any
  change on their side breaks this with no notice and no deprecation period.
  Check their terms before relying on it.
* **Secrets are readable by every organisation member.** Anyone who can push a
  workflow can print a secret. Membership of SMR-community is open by invitation
  and every member can push to `main`, so `PDX_REFRESH` is effectively shared
  with all of them. It is a refresh token rather than a password, so it is
  revocable — logging out in the game invalidates it — but it still grants
  publishing rights to the account. Use a dedicated publishing account.
* **The token expires eventually.** A publish that fails at `renew` with a 401
  needs a fresh `refreshToken` from `account.json` and a new `gh secret set`.
