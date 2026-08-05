# Paradox Mods upload API — what is known

Findings from static analysis of `PDXSDK.dll` (2.6 MB, shipped in the game root)
and the game's own Lua, for the purpose of publishing **this mod**, from **your
own account**, without opening the game.

**Status: incomplete.** Everything below is confirmed. The request routes are
not, and cannot be recovered from strings — see *What is still missing*. The
client in `pdx_client.py` is complete except for those routes, and refuses to
run until they are supplied.

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

## Authentication: Hawk

The SDK carries `AuthorizationHawk`, `AuthorizationSession`, `AuthorizationSteam`
and `AuthorizationRenewal` types, plus a literal `Authorization` header name and
`refresh_token`. So: log in with account credentials, receive a session, and sign
each subsequent request with [Hawk](https://github.com/mozilla/hawk) — an HMAC
scheme over a normalised request string, not a bearer token.

`pdx_client.py` implements Hawk signing in full (`hawk_header`). It is a public
specification, so this part needs no discovery:

```
hawk.1.header \n ts \n nonce \n METHOD \n path \n host \n port \n payload-hash \n ext \n
```

signed with HMAC-SHA256 and sent as
`Authorization: Hawk id="…", ts="…", nonce="…", hash="…", mac="…"`.

## Required headers

Literal in the DLL:

```
X-PDX-Game-Name      X-PDX-Game-Version    X-PDX-Platform
X-PDX-SDK-Type       X-PDX-SDK-Version     X-PDX-Error-Version
```

Content types in use: `application/json`, `application/octet-stream`.

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

## What is still missing

**The routes.** Paths are assembled at runtime rather than stored, so no amount
of string extraction yields them. One capture run against the real service
supplies every one of them at once.

There is no certificate pinning in the DLL — the only TLS-adjacent string is an
OpenSSL path from the bundled PGP library — so an intercepting proxy works.

To capture, on the machine with the game:

```
pip install mitmproxy
mitmdump -s tools/publish/capture_routes.py --set confdir=~/.mitmproxy
```

Trust `~/.mitmproxy/mitmproxy-ca-cert.cer` in the Windows machine store, point
the system proxy at `127.0.0.1:8080`, then upload this mod once from the game's
Mod Editor. `capture_routes.py` writes every `api.paradox-interactive.com`
request to `tools/publish/routes.json` with method, path, headers and body
shape, redacting credentials as it goes.

Fill the `ROUTES` table in `pdx_client.py` from that file and the client is
complete.

## Risks, stated once

* **Undocumented and unsupported.** Paradox publishes no API contract. Any
  change on their side breaks this with no notice and no deprecation period.
  Check their terms before relying on it.
* **Credentials in GitHub Secrets are readable by every organisation member.**
  Anyone who can push a workflow can print a secret. Membership of
  SMR-community is open by invitation and every member can push to `main`, so
  the Paradox account stored there is effectively shared with all of them. Use a
  dedicated publishing account that owns nothing else.
* **Server-side rate limits and lockouts** apply to password login. A workflow
  that retries on failure can lock the account.
