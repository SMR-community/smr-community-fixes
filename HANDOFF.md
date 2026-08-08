# HANDOFF.md — SMR Community Fixes

## Current request

Apply the Filter Landing Spots **Invalid font id** correction from Bug Fixes to
SMR Community Fixes, deploy it to the local Mods folder, and commit it.

## Version 20 live fallback-font resolution

Repository: `D:\PROJS\SMR\smr-community-fixes`, branch `main`. Version advances
19 -> 20 in feature commit `0c93018` (`Guard live fallback font resolution`).
The branch was 0 behind / 3 ahead of upstream after that commit. Nothing was
pushed.

The module is byte-identical to Bug Fixes version 52 at SHA-256
`951C718C1BA15A712CC950B09DAB8D3869735AC1FE2B461655181F7A2207C3CD`.
Protocol 10 keeps multi-size prevalidation but adds a guarded wrapper around the
engine's actual `GetFontHeightAndBaseline(font, size)` call. If a face from the
fallback list owned by this fix returns an invalid id at the live size, it is
removed and the same call is resolved through a remaining fallback or confirmed
UI face. Arbitrary runtime sizes are supported without enumeration. Valid calls,
third-party lists, and original errors remain unchanged, and disable/unload
restores the exact captured function and original fallback table.

The newest relevant game log read was
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\logs\MarsDebug.exe-20260808-11.49.41-69e75da5.log`.
It showed only Bug Fixes version 51 active, then `Noto Sans CJK SC Regular`
failing, `Invalid font id`, and `font_id = -1` on Filter Landing Spots. Community
Fixes was not active in that reproduction. No log was deleted.

Read-only references inspected:

* `C:\Games\Surviving Mars Relaunched\ModTools\Src\CommonLua\X\XTextParser.lua`
* matching XTextParser and TextStyle sources under `D:\PROJS\SMR\fpks\Packs\Lua`
* ModTools TextStyle definitions confirming shipped Noto/Source Sans UI faces

No game installation, ModTools, FPK, savegame, generated file, or editor-managed
hash was edited. Publish debug remains false. Actual replacements log a gated
Warn and `Bug fix invoked:` Info with failed font, requested size, replacement,
and id; inability to find any replacement logs an ungated Error.

Checks performed:

* `luac -p`: 20/20 Lua files passed.
* `lua tools/sync_mod.lua check`: 15 fix files, 16 code entries, 16 items; passed.
* The byte-identical Bug Fixes module passed `lua tools/restore_audit.lua .`,
  including live failures after successful preflight at arbitrary sizes 37 and
  241, eight active hooks, individual restore, reload, and exact unload restore.
* The Bug Fixes suite also passed 7/7 Python tests.
* `git diff --check` passed in both repositories.

Deployment source:
`D:\PROJS\SMR\smr-community-fixes`. Destination:
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\smr-community-fixes`.
The game was not running. All 20 exact payload files were copied and verified;
missing 0, stale/destination-only 0, SHA-256 mismatch 0. Repository-only files
were excluded and no destination file was deleted.

Not yet verified in game: restart/reload mods, enable only SMR Community Fixes,
open Filter Landing Spots in Paradox Mod Manager at several UI scales, and
confirm the newest log has neither `Invalid font id` nor `font_id = -1`. Disable
the fix afterward and confirm vanilla Mod Manager behavior still works.
