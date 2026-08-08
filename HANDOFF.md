# HANDOFF.md — SMR Community Fixes

## Current request

Keep SMR Community Fixes disabled, but apply Bug Fixes' general Unicode glyph
cascade so Filter Landing Spots shows real arrow glyphs after the
font-independent assertion fix. Deploy its updated folder without changing
active-mod settings, and commit it.

## Version 22 size-validated Unicode cascade

Repository: `D:\PROJS\SMR\smr-community-fixes`, branch `main`. Version advances
21 -> 22 in feature commit `9952e1c` (`Render Unicode with validated UI font
cascade`). The branch was 0 behind / 7 ahead after the feature commit. Nothing
was pushed. The module is
byte-identical to Bug Fixes v54 at SHA-256
`D2E5F594443C663A528DF4C9F863C892C72F9ECB05AADEEAC8851FD30F0C01ED`.

The user's v53 Bug Fixes screenshot proves the Invalid font id assertion is
gone, but the access breadcrumb's `→` characters are missing-glyph boxes. The
newest game log remained a 488-byte header with no runtime evidence; the prior
12:06 log still proves Community Fixes was discovered but disabled and only Bug
Fixes was active. No log was edited or deleted.

Protocol 12 keeps supported Unicode in the active body font and dynamically
routes each unsupported non-ASCII glyph through private styles built from font
names already present in loaded `TextStyles`. It hardcodes no font family and
requires the exact glyph at body/h2/h1 sizes at both 100% and the current UI
scale before inserting a local style. Common punctuation has a safe ASCII
last-resort; unrelated unsupported characters remain harmless missing-glyph
marks. It never emits `<fallback_font>`, replaces `config.FallbackFonts`, or
hooks `GetFontHeightAndBaseline`. Disable/reload/unload restores every private
style still owned by the fix. Debug remains false; installation details and a
no-candidate warning are gated, while required-API and ownership errors are not.

Read-only engine and extracted references inspected were XTextParser,
`TextStyle:GetFontIdHeightBaseline`, loaded TextStyle definitions, and shipped
font tables under `C:\Games\Surviving Mars Relaunched\ModTools\Src` and
`D:\PROJS\SMR\fpks`. They confirm active-scale font creation, the broken
size-10 fallback probe, and a shipped loaded UI face containing U+2192. No game,
ModTools, FPK, save, generated, or editor-managed file was changed.

Checks performed:

* Community Fixes `luac -p`: 20/20 Lua files passed.
* `lua tools/sync_mod.lua check`: 15 fixes, 16 code entries, 16 items; passed.
* The byte-identical Bug Fixes module passed all 15 restore-audit rows, including
  general arrow/bullet routing, body-supported accent preservation, validation
  at sizes 20/22/24/30/33/36, eight browser hooks, reload, and exact unload.
* Bug Fixes passed 19/19 Lua parses and 7/7 Python tests.
* `git diff --check` passed in both repositories.

All 20 payload files were copied from this repository to
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\smr-community-fixes`
and verified with zero missing, stale/destination-only, or hash-mismatched files.
The final module recopy also matches the source hash. Active-mod settings were
not touched; Community Fixes remains disabled. No destination file was deleted.

Manual verification is intentionally through Bug Fixes only: keep Community
Fixes disabled, enable Bug Fixes v54 and Repair Mod Manager Browser, open Filter
Landing Spots at several UI scales, and confirm `New Game → Mission Setup Screen
→ Rocket Payload Screen → Colony Site → Filter` shows real arrows and the newest
log contains neither `Invalid font id` nor `font_id = -1`.

## Version 21 font-independent Mod Manager text

Repository: `D:\PROJS\SMR\smr-community-fixes`, branch `main`. Version advances
20 -> 21 in feature commit `1bd673a` (`Avoid XText fallback font assertions`).
The branch was 0 behind / 5 ahead after the feature commit. Nothing was pushed.
The module is byte-identical to Bug Fixes v53 at SHA-256
`4B120AD64229D4BAC001BC76D37832002E7DE4E4E14E1E7B6A3FD0D785F6E283`.

The newest log,
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\logs\MarsDebug.exe-20260808-12.06.00-69e75da5.log`,
discovered Community Fixes v20 but did not include `SMRCF` in the loaded-item
list; only Bug Fixes v52 (`SMRBF107`) was enabled. That active browser repair
still reached `Noto Sans CJK SC Regular`, `Invalid font id`, and `font_id = -1`
on Filter Landing Spots. The protocol-10 global wrapper emitted no correction,
so the engine's failing XText call bypassed it. No log was deleted.

Read-only ModTools and extracted FPK `XTextParser.lua` sources confirm that
`<fallback_font>` alone sets the state that enters the faulty branch at line
922. Protocol 11 removes that tag from both formatted output paths, requires and
inherits the active `ModsUIDetailsDescription.FontName`, names no font, and
leaves `config.FallbackFonts` and `GetFontHeightAndBaseline` unchanged. Missing
glyphs may use the active font's normal missing-glyph mark without invalidating
the font id. A guarded migration restores exact protocol 8-10 font globals still
owned during live reload. Debug remains false; migration success is gated Info,
while missing legacy originals are ungated Errors.

Checks performed:

* Community Fixes `luac -p`: 20/20 Lua files passed.
* `lua tools/sync_mod.lua check`: 15 fixes, 16 code entries, 16 items; passed.
* The byte-identical Bug Fixes module passed the 15-fix restore audit, including
  font-global identity, no fallback tag, arbitrary active-font inheritance,
  protocol-10 migration, seven-hook disable, reload, and exact unload checks.
* Bug Fixes also passed 19/19 Lua parses and 7/7 Python tests.
* `git diff --check` passed in both repositories.

The game was not running. All 20 payload files were copied to
`C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\smr-community-fixes`
and verified: missing 0, stale/destination-only 0, hash mismatch 0. Active-mod
settings were not changed; Community Fixes remains disabled. No game, ModTools,
FPK, generated, savegame, or log file was edited or deleted.

Manual verification is intentionally through Bug Fixes only: keep Community
Fixes disabled, enable Bug Fixes v53 and Repair Mod Manager Browser, open Filter
Landing Spots at several UI scales, and confirm the newest log contains neither
`Invalid font id` nor `font_id = -1`.

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
