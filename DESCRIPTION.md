# DESCRIPTION.md — Mod Requirements: SMR Community Fixes

The single source of requirements for this mod. `CONTRIBUTING.md` covers how to
write and submit a fix.

## 1. Mod identity

```text
Mod display name:      SMR Community Fixes
Mod folder name:       smr-community-fixes
Mod id:                SMRCF (never change after release)
Prefix for new files:  smrcf_
Payload folder:        . (the repository root is the mod payload)
Git remote:            https://github.com/SMR-community/smr-community-fixes.git
Target game version:   Surviving Mars: Relaunched v1.0.7 (current list; each
                       later version gets its own, see section 4)
Mod API revision:      350453 (the 'lua_revision' every mod declares; 392284 is
                       the game build, recorded separately as saved_with_revision)
```

Every completed change set is committed, pushed, and copied to the local Mods
folder. Anyone in the SMR-community organisation can push to `main` — see *Who
can push* in `CONTRIBUTING.md`.

Deployment copies `metadata.lua`, `items.lua`, every registered file under
`Code\`, and all of `Images\`. It never copies `README.md`, `CONTRIBUTING.md`,
`DESCRIPTION.md`, `templates\`, `tools\`, or `.github\`.

## 1A. Code layout: exactly two kinds of file

`Code\` contains only these two kinds of file, and nothing else:

* `Code\SMRCommunityFixes.lua` — the single framework file: configuration, logging,
  settings storage, the fix registry, the Options category, the checklist UI, and
  the lifecycle. It never names an individual bug.
* `Code\smrcf_restore_<fix>.lua` — one bug fix per file. Each is **completely
  self-contained**: it may use game/engine globals only (`ModLog`, `GameTime`,
  `const`, `SharedModEnv`, `rawget`, `T`, …) and must not call any function,
  or read any global, defined by another file in this mod. Each carries its own
  `FIX` descriptor, its own inline logger, and its own repair.

A fix registers itself by appending its `FIX` descriptor to the plain global list
`_G.SMRCommunityFixesPending`. `SMRCommunityFixes.lua` adopts that list, disables
any fix that disappeared since the previous Lua load, and clears it. Position in
the `'code'` list does not matter: the framework adopts descriptors already
registered when it loads, and picks up later ones at `ClassesBuilt`, seeding
defaults for those.

Every fix must still be listed in `metadata.lua` `'code'` and `items.lua`,
because the engine mod sandbox blocks `io`, `dofile` and `dofolder`
(`ModEnvBlacklist` in `Src\CommonLua\Classes\Mod.lua`), so no Lua inside the mod
can discover a file or edit its own registration.

Only `id`, `description` and `set_enabled` are required of a descriptor. The
framework normalizes the rest when absent — `number` (next free), `beta` (true),
`versions` (the default target version), `default_enabled` (false), `debug`
(false), `label` (derived from the id) and `quiesce` (switch yourself off) — so a
short descriptor is a valid descriptor and the defaults are the conservative ones.

Adding a fix is a Lua-only job and stays that way: no build step, nothing to
install. A contributor copies `templates\smrcf_restore_TEMPLATE.lua` to
`Code\smrcf_restore_<fix>.lua` and edits Lua. The two registration entries — one
in the `metadata.lua` `'code'` list, one matching `ModItemCode` in `items.lua` —
are written by CI as soon as the branch is pushed (section 1B), so nobody adds
them by hand. `CONTRIBUTING.md` documents the descriptor contract.
`templates\` is not deployed.

## 1B. Continuous integration

`tools\sync_mod.lua` is a standard-Lua script that performs the registration a
sandboxed mod cannot perform on itself:

```text
lua tools/sync_mod.lua check    report problems (exit 1) and registration drift (exit 0)
lua tools/sync_mod.lua sync     append new fixes at the end of both lists, bump 'version'
```

Three GitHub workflows drive it, and a fourth publishes (section 1C).
`.github\workflows\` and `tools\` are not deployed:

* `register-on-branch.yml` — on push to any branch but `main` touching `Code\`.
  Runs `sync` and commits the registration back to that branch, so a pull request
  arrives already registered. `check` runs last here, so a work-in-progress branch
  is still registered while the check reports what is left to fix. On a fork it
  runs in the fork, with the fork's own token.
* `check-fixes.yml` — on every pull request touching the payload. Parses every
  Lua file with `luac -p`, then runs `check`. Read-only, so it is safe for pull
  requests from forks. It fails only on findings a person must resolve: duplicate
  id, a pinned number already in use, a template placeholder, `debug = true`, a
  reference to framework internals, or a missing `description`/`set_enabled`.
* `register-fixes.yml` — on push to `main` touching `Code\`. The safety net for
  what a branch run missed: a fork with Actions disabled, or a commit straight to
  `main`. Here `check` runs **first**, so a fix with a problem is never registered
  on `main`.

Both registering workflows commit with `[skip ci]` and skip the
`github-actions[bot]` actor, so neither retriggers itself.

The mod itself is unaffected by any of them: no runtime code, asset, or behavior
depends on them, and the version bump they make is the same integer a maintainer
would edit by hand.

## 1C. Publishing

Players get the mod from Paradox Mods, and that page is updated from GitHub, not
from the game's Mod Editor. `PDX_Upload` in the game is a driver over native
functions in `PDXSDK.dll`, so nothing can be reused from Lua and no hosted runner
can run it; `tools\publish\pdx_client.py` therefore talks to the service
directly, signing each request with Hawk and authenticating with the `PDX_USER`
and `PDX_PASS` repository secrets.

Merging never publishes. Pushing a `v*` tag runs `publish.yml`, which:

1. runs the same `sync_mod.lua check` as a pull request;
2. refuses the tag unless `'version'` exceeds the previously tagged release,
   which would otherwise overwrite it rather than add one;
3. packs `metadata.lua`, `items.lua`, `Code\` and `Images\` — the deployment set
   from section 1, and nothing else;
4. uploads it, reporting each of the five calls with status, elapsed time and
   attempts.

Timeouts, connection errors, `429` and `5xx` retry with backoff; `4xx` never
does, because retrying a rejected password locks the account. A failed tag opens
an issue naming the step, the status and the server's message. Exit codes
distinguish a fatal error, missing credentials, unknown routes, and a failure
after the payload uploaded but before it went live.

The API is undocumented, so the request routes come from one capture run against
the real service; `tools\publish\PDX_API_NOTES.md` records what is known and
reduces the capture to a single command. Until those routes are filled the
publish step stops cleanly and sends nothing.

## 2. Task type

```text
Task type: bug-fix collection and options UI
```

## 3. Goal

Create a modular, version-gated collection of independently toggleable fixes
for confirmed Surviving Mars: Relaunched bugs. Add **SMR Community Fixes** directly below
**Credits** in the main Options category list. Selecting it opens a dedicated,
modal checklist modeled on the Mute Notifications mod, with a game-version
dropdown followed by one labeled square checkbox and explanation per fix for
the selected version.

## 4. Fix catalog and UI behavior

1. The category is named **SMR Community Fixes** and is inserted immediately after the
   vanilla **Credits** category without modifying vanilla files.
2. Selecting the category opens a centered modal panel over the Options screen.
   The panel shows the **SMR Community Fixes** title without the obsolete explanatory
   sentence below it. The title uses the same font family and size as **Search:**
   while retaining its original blue-gray color.
3. The panel begins with a **Game version** dropdown. Fixes are separated by
   game version: each one appears only under the versions it was confirmed on,
   declared in its `versions` table, so every game version has its own list and
   no repair runs against a build nobody verified it against. Version `1.0.7`
   contains Restore Rains, Restore Disasters, and thirteen default-off beta fixes.
   The dropdown contains **All** and **1.0.7**, defaults to `1.0.7` whenever the
   panel opens, and filters only the displayed rows; **All** never changes the
   active runtime target. Later verified versions are added to the data-driven
   version list. The closed field, popup, list items, and arrow use the same dark
   charcoal palette as the panel; no dropdown state uses the stock white
   background.
4. The filter changes the displayed rows immediately and is not persisted.
   Checkbox changes remain staged until **Apply**. Apply persists all checkbox
   changes atomically; Back and Escape discard unapplied checkbox changes.
5. Existing settings migrate to version `1.0.7`. The previously available
   `unsupported` selection and any unknown or invalid persisted version value
   normalize to the sole configured `1.0.7` profile.
6. The version catalog remains data-driven so additional verified game versions
   can be added later without redesigning the selector or persistence model.
7. The panel has a scrollable list suitable for future fixes. Each row's narrow
   left column contains a real square checkbox, its zero-padded permanent number,
   and, while that fix is under testing, a **[Beta]** badge. The displayed order
   is checkbox, number, then optional badge, such as **003 [Beta]**. The right
   column stacks only the unnumbered fix title above its explanation, following
   the Mute Notifications row hierarchy. Filtering never renumbers a bug. Do not
   repeat the fix title or show separate Enabled/Disabled text in the explanation.
8. Checkbox changes remain panel-local until **Apply** is pressed. **Select group**
   and **Unselect group** stage the corresponding state for only the rows currently
   shown by the search and version filters. Both group actions update the existing
   checkbox controls in place and preserve the list's exact vertical scroll
   position. **Reset** clears both filters and stages **every** fix off, including
   the two that default on; it is the one-press "turn everything off" action. Apply
   commits all staged changes together and leaves the panel open. Back and Escape discard unapplied changes and return to Options.
9. The Game version toolbar ends with
   `<shown> shown / <total> total / <selected> selected`; this summary updates
   immediately as the filter or staged checkboxes change. The old `xx fix(es)`
   footer text is absent. A left-aligned footer shows **Select group**, **Unselect
   group**, **Apply**, **Reset**, and **Back** in that order, with centered labels,
   neutral group/reset buttons, a green Apply button, and a red Back button.
10. The active runtime target (`1.0.7`) and checkbox choices persist between game
    sessions using the confirmed per-mod persistent storage API. The display
    filter does not persist.
11. Each fix is independent. Disabling a fix restores the captured vanilla
    functions and restarts only the affected mod-managed scheduler path.
12. **Restore Rains** and **Restore Disasters** are both default **enabled** for
    the default `1.0.7` profile. Every descriptor whose beta badge is enabled
    defaults **disabled** and runs no hook until the user explicitly selects and
    applies it.
13. The two stable fixes repair eligible stale state in existing v1.0.7 savegames as well as
    games started after the mod is installed. The deferred `LoadGame` lifecycle
    pass must preserve genuinely active disasters while repairing only state that
    the fix can prove stale. Every beta fix can also be enabled in an existing
    v1.0.7 save. Modules with identifiable saved corruption reconcile it on
    enable/load; transient UI and interaction fixes take effect immediately for
    the next affected action. No module may guess at or reconstruct irreversible
    history that vanilla did not save.
14. Each bug is a self-registering module whose single `smrcf_restore_*.lua` script
    owns its permanent number, id, supported versions, default, beta status,
    unnumbered plain-text title and description, own diagnostic flag (`debug`),
    runtime enable/disable function, reload-safe quiesce callback, event
    callbacks, and repair implementation. The framework file must not name an
    individual bug. If a module and its engine-required `metadata.lua`/`items.lua`
    load-list entries are removed, its row and behavior disappear automatically
    while all remaining bugs keep their permanent numbers and continue to work.
    Titles and explanations are plain strings; the UI renders them, and the
    zero-padded `number`, with `Translate=false`, so no fix has to allocate
    localization ids. The framework invokes the quiesce callback before it adopts
    a new registry, so deleting the script and its two load-list entries disables
    its hook and removes its row without naming the bug in framework code.

## 5. Restore Rains behavior

When enabled, Restore Rains must:

1. Preserve the vanilla rain simulation, thresholds, timings, notifications,
   soil changes, vegetation effects, toxic pools, FX, and Cloud Seeding outcome.
2. Repair the vanilla scheduler deadlock in which
   `RainsDisasterActivation()` returns because another disaster is active or
   predicted while `RainsDisasterLoop()` waits forever for a
   `RainDisasterEnd` message that can never occur.
3. Wait for the actual rain activation thread to finish. A skipped attempt must
   return to the normal spawn delay and try again later.
4. Validate `RainsDisasterThreads.normal` and `.toxic` before direct calls such
   as Cloud Seeding reach `RainProcedure()`.
5. Before `WaitCurrentDisaster()` blocks a special project, remove only disaster
   prediction flags proven stale because their matching notification no longer
   exists. Never clear a live prediction or active disaster.
6. On load and mod enable, detect a persisted `g_RainDisaster` whose rain main
   thread is no longer alive, run the vanilla finish/cleanup path when available,
   and rebuild eligible rain schedulers.
7. Rebuild schedulers through the confirmed vanilla `UpdateRainsThreads()`
   selection logic. Do not duplicate threshold or preset-selection logic.
8. Be idempotent across code reload, ClassesBuilt, CityStart, LoadGame,
   ModsReloaded, enable, disable, and repeated panel toggles.
9. Restore captured vanilla functions when disabled, without overwriting a later
   third-party wrapper.
10. Reuse one persistent gated wrapper per hooked function across mod-code
    reloads. If the engine refreshes a global or another mod owns the outer
    function, preserve that downstream chain, prevent recursion/double calls,
    and leave the disabled SMR Community Fixes gate as an inert pass-through.
11. Keep every function reachable from a persistent
    `RainsDisasterThreads.*.activation_thread` free of locally captured C
    functions. Global helpers such as `table.unpack` must be resolved when used,
    never retained as wrapper upvalues that `PersistGame` attempts to serialize.

## 5A. Restore Disasters behavior

When enabled, Restore Disasters must:

1. Preserve vanilla meteor frequency, warning times, targeting, damage, FX, and
   all non-meteor disaster tuning.
2. After `MeteorsDisaster(..., "storm")` actually returns, remove the completed
   `DisasterMeteorStorm` notification/prediction state that vanilla leaves set.
3. Repair the zero-meteor early-return path, which otherwise also leaves
   `g_MeteorStorm` true.
4. On load and mod enable, clear saved meteor-storm state only when no matching
   notification, predicted meteor object, or falling meteor remains.
5. Never clear a live meteor warning or active/falling meteor.
6. Removing the stale shared blocker must allow vanilla cold-wave scheduling,
   dust-storm scheduling, natural rain activation, Cloud Seeding, Import
   Greenhouse Gases, Melt the Polar Caps, and Inner Light/Dream mirages to resume.
7. Preserve vanilla Dust Devil behavior without replacing its scheduler: calm
   weather uses the normal randomized schedule; a real Dust Storm removes active
   Dust Devils and suppresses new ones; after the storm ends, the ordinary
   schedule resumes when Dust Devils are otherwise allowed, with no catch-up or
   accelerated spawning.
8. Restore Disasters owns only the shared stale meteor-state cleanup. Restore
   Rains remains responsible for the separate rain-loop deadlock, rain thread
   initialization, and stale active-rain recovery.
9. Be idempotent across reload, lifecycle messages, and repeated toggles.
10. Restore the captured vanilla `MeteorsDisaster` function when disabled without
   overwriting a later third-party wrapper.
11. Reuse one persistent gated meteor wrapper across reloads with the same
    downstream-chain, no-recursion, and inert-pass-through guarantees as Restore
    Rains.
12. Keep the persistent wrapper closure graph free of locally captured C
    functions for savegame compatibility.

## 5B. [Beta] Restore Dust Devils behavior

When enabled, Restore Dust Devils must:

1. Replace only the v1.0.7 Dust Devil global scheduler and marker-thread creator
   through reload-safe gates owned by this module.
2. Apply `spawn_chance` as an actual percentage roll and, only after a successful
   roll, select an integer count from `count_min` through `count_max`. Do not
   multiply the chosen count by a percentage and use the fractional result as a
   Lua numeric-loop limit.
3. Read the natural Dust Devil preset from `MainMap.mapdata`, even when the user
   is viewing an underground or asteroid map.
4. Suppress marker spawns while `DustStormsDisabled` is true and recheck that
   gate before a warned marker Dust Devil starts.
5. Preserve the vanilla No Disasters rule, timing ranges, warning delay,
   positions, movement, major/electrostatic selection, FX, and Dust Storm checks.
6. On enable, disable, reload, or old-save load, restart only the Dust Devil
   scheduler path. Preserve later third-party outer hooks and make a removed
   module's retained gate inert.
7. Default disabled and emit `Bug fix invoked:` evidence when corrected
   spawn-chance, map-selection, or marker-gating behavior is actually used.

## 5C. [Beta] Restore Asteroid Visits behavior

When enabled, Restore Asteroid Visits must:

1. Preserve vanilla availability results except for the confirmed operator-
   precedence false positive in `PlanetaryAsteroidVisitPossible()`.
2. Require `Refuel`, `WaitLaunchOrder`, or eligible `LoadAndLaunch` commands to
   belong to a `LanderRocketBase`; an ordinary rocket with the latter two
   commands must not open an empty asteroid-rocket selector.
3. Preserve valid `UniversalRocketBase` and `LanderRocketBase` eligibility and
   later third-party results that are not caused by the confirmed false-positive
   pattern.
4. Default disabled, restore the captured predicate when disabled, and emit a
   timed `Bug fix invoked:` event when it rejects a false-positive rocket.

## 5D. [Beta] Restore Soil Overlay behavior

When enabled, Restore Soil Overlay must:

1. Correct the v1.0.7 boolean grouping in `GetOverlayGrid()` so both
   `soil_transparent` and `soil_solid` require `CurrentMap == MainMap`.
2. Preserve the surface SoilGrid and all water, custom-supply, and electricity
   overlay behavior.
3. Change only the confirmed off-surface `soil_solid` result that incorrectly
   returns the surface `SoilGrid`.
4. Default disabled, restore the captured overlay function when disabled, and
   emit one timed `Bug fix invoked:` event per game-state run when it blocks the
   wrong grid.

## 5E. [Beta] Restore Saint Blessing behavior

When enabled, Restore Saint Blessing must:

1. Correct only the Saint dome-modifier target from vanilla `Religious` to the
   actual colonist label returned by `GetTraitLabel("Religious")`.
2. Reconcile Saints already living in Domes when the fix is enabled, preserving
   the documented +10 base Morale per Saint and its stacking behavior.
3. Preserve every non-Saint trait modifier and any third-party outer hook.
4. Default disabled, restore the captured trait methods and vanilla label
   behavior when disabled, and emit timed `Bug fix invoked:` evidence when it
   corrects an existing or newly applied Saint modifier.

## 5F. [Beta] Restore SpaceY Description behavior

When enabled, Restore SpaceY Description must:

1. Change only SpaceY's sponsor-effect text to state both verified Drone Hub
   benefits: four additional starting Drones and twenty additional maximum
   command capacity.
2. Leave the existing `Effect_ModifyLabel` gameplay values untouched.
3. Default disabled, restore the exact captured text when disabled, and emit a
   timed `Bug fix invoked:` event when it replaces the incomplete description.

## 5G. [Beta] Restore Jumbo Cave Reinforcements behavior

When enabled, Restore Jumbo Cave Reinforcements must:

1. Delegate every Waste Rock drone approach to the captured vanilla method.
2. Act only after that approach fails and only when the exact Waste Rock blocker
   belongs to a `JumboCaveReinforcementStructure` construction site.
3. Remove that unreachable blocker through the vanilla object-destruction path,
   allowing `OnWasteRockObstructorCleared` to retest the construction site.
4. Preserve normally reachable Waste Rock, all other construction classes, and
   any third-party outer hook.
5. Default disabled, restore the captured approach method when disabled, and
   emit timed `Bug fix invoked:` evidence when it releases a stuck site.

## 5H. [Beta] Restore No Disasters Cave-in Protection behavior

When enabled, Restore No Disasters Cave-in Protection must:

1. Correct only the v1.0.7 `UndergroundMarsquake` map repeat, whose vanilla
   condition omits the `NoDisasters` game-rule check used by other natural
   disaster schedulers.
2. Stop and remove an already running periodic underground-marsquake thread
   when the rule is active, including an existing save.
3. Preserve mystery, scripted, cheat/manual, and surface marsquakes and cave-ins;
   the No Disasters rule explicitly excludes mystery events.
4. Default disabled, restore the exact captured repeat condition and only the
   scheduler threads this fix suppressed when disabled, and emit a timed
   `Bug fix invoked:` event for each map on which it enforces the rule.

## 5I. [Beta] Restore Trade Rocket Protection behavior

When enabled, Restore Trade Rocket Protection must:

1. Extend RC Transport's existing legacy trade/refugee-rocket exclusion only to
   the v1.0.7 `UniversalTradeRocket` class.
2. Block both interaction eligibility and a direct interaction command before
   the RC Transport can interrupt the rocket.
3. Preserve RC Transport interaction with ordinary storage, colony rockets, and
   every other target, and preserve any third-party outer method.
4. Default disabled, restore the captured RC Transport methods when disabled,
   and emit a timed `Bug fix invoked:` event when the guard blocks a target.

## 5J. [Beta] Restore Asteroid Lander Cargo Safety behavior

When enabled, Restore Asteroid Lander Cargo Safety must:

1. Guard only the v1.0.7 asteroid `LanderRocketBase` payload request while a
   Drone or passenger remains in the confirmed cargo-ramp tracking lists.
2. Make the payload action unavailable until the ramp clears, preventing the
   subsequent cargo-request update from interrupting a unit in its exit/entry
   spline. Never move, delete, respawn, or otherwise repair a unit speculatively.
3. Preserve payload editing as soon as the ramp is clear and preserve every
   other Lander, cargo, launch, and Drone behavior.
4. Default disabled, restore the captured `CanRequestPayload` method when
   disabled, and emit one timed `Bug fix invoked:` event per guarded ramp cycle.

## 5K. [Beta] Restore Localized UI Text behavior

When enabled, Restore Localized UI Text must:

1. Route the literal v1.0.7 **OVERALL TERRAFORMING PROGRESS** heading through
   its existing official localization id `914616772802`.
2. Replace only the Universal Rocket **Back to Earth** rollover's two
   untranslated v1.0.7 XDef ids with the existing official localized ids
   `407456913268` and `316233855405`.
3. Preserve the English source text and all gameplay/UI behavior. Do not invent
   a translation for **COLONY DATA**, which has no reusable localization record
   in the installed language CSVs.
4. Default disabled, restore both captured UI constructors when disabled, and
   emit a timed `Bug fix invoked:` event whenever either corrected UI is built.

## 5L. [Beta] Restore Track Demolition behavior

When enabled, Restore Track Demolition must:

1. Delegate every track-element demolition to the exact captured
   `TrackGridElement:DemolishAndSplitTrack()` method.
2. Act only when that method leaves a valid `TrackBase` in the exact terminal
   v1.0.7 shell state: `demolishing == true`, `elements == false`, and
   `elements_under_construction == false`.
3. Complete the missing object-destruction lifecycle through `DoneObject()`,
   supplying empty transient collections only for the duplicate cleanup
   performed by `TrackBase:Done()`. Preserve normal track shortening,
   splitting, construction repair, refunds, station reconnection, and every
   non-terminal path.
4. On enable/load, enumerate loaded-map `TrackBase` objects and remove only those
   already stored in the same exact terminal shell state. Collect matches before
   deleting them so the scan never mutates its iterator. Perform no broad track
   repair, timer, saved marker, or persistent object tracking. Disabling restores
   the exact captured method when the module owns the hook; a later third-party
   outer wrapper keeps only an inert pass-through gate.
5. Default disabled and emit a timed `Bug fix invoked:` event whenever it
   deletes a terminal Track object that vanilla left alive.

## 5M. [Beta] Restore Clustered Lights behavior

When enabled, Restore Clustered Lights must:

1. Capture and wrap the confirmed v1.0.7 global `NightLightsOn()` function
   without replacing light classes, changing renderer `hr` values, or modifying
   the game installation.
2. Preserve instant (`total_delay == 0`) refreshes exactly. For vanilla delayed
   night-light turn-on transitions only, call the captured function once with a
   zero delay so all eligible light attachments enter the renderer in the same
   Lua update instead of a game-time-compressed staggered burst.
3. Leave `NightLightsOff()`, light ownership, the 3,000-light limit, eligibility,
   entity specifications, colors, intensity, shadows, and ordinary day/night
   scheduling unchanged.
4. Restore the exact captured function when disabled, remain idempotent across
   enable/disable and code reload, and keep no saved object, timer, or marker.
5. Default disabled and emit a timed `Bug fix invoked:` event only when a
   positive vanilla delay is replaced with the atomic turn-on call.

## 5N. [Beta] Restore Mod Screenshots behavior

`ModUI_Entry` derives from `ProtectedPropertyObject`, whose `__newindex` asserts
on any key the class never declared (`CommonLua\PropertyObject.lua:1819-1823`).
The class declares `ScreenshotPaths` (`CommonLua\UI\ModManager.lua:1229`) but
never `ScreenshotUrls`, which line 797 assigns and
`CommonLua\Libs\Paradox\ParadoxMods.lua:249` reads back. Opening a mod page in
the Paradox Mods browser therefore asserts, and where asserts halt, the
`ModsUIDownloadScreenshots` call on line 799 is never reached.

When enabled, Restore Mod Screenshots must:

1. Declare `ScreenshotUrls` on the confirmed v1.0.7 `ModUI_Entry` class as
   `false`, matching how the neighbouring `ScreenshotPaths` is declared, without
   wrapping any function or modifying the game installation.
2. Do nothing when the field is already declared, so a later official
   declaration is never disturbed.
3. Remove only a declaration this fix added, and only while it still holds the
   value this fix wrote, so disabling restores vanilla exactly.
4. Remain idempotent across enable/disable and code reload, retrying on
   `GameStateStarting` in case the class did not exist when first enabled, and
   keep no saved object, timer, or marker.
5. Default disabled and emit a timed `Bug fix invoked:` event once per enable,
   only when it actually adds the missing declaration.

## 6. Configuration and persistence

Framework configuration lives in the local `Config` table inside
`Code\SMRCommunityFixes.lua`. There is no shared configuration file and no per-fix flag in
framework code:

```text
Config.ENABLE_MOD: true
Config.DEFAULT_TARGET_VERSION: "1.0.7"
Config.DEBUG_LOGS: false (publish default; no Info/Warn output)
Config.DEBUG_API: false
Config.DEBUG_UI: false
Config.DEBUG_PERSISTENCE: false
Config.PANEL_LIST_HEIGHT_PER_MILLE: 600
Config.PANEL_LIST_FALLBACK_HEIGHT: 640
```

The canonical mod version is the integer `'version'` in `metadata.lua`. Runtime
code reads it from the engine-injected `CurrentModDef.version`; there is no second
version constant.

Each fix owns its own default and its own diagnostic flag inside its descriptor:
`default_enabled` (true for Restore Rains and Restore Disasters, false for the
thirteen betas) and `debug = false` for the publish build. A fix's inline logger
emits Info only while its own `debug` is true; `ERROR` is never gated. Setting
`Config.DEBUG_LOGS = true` also turns on every fix's `debug` when the framework
adopts the registry, which produces a full diagnostic build in one edit.

The runtime target version and checkbox states persist together through the
per-mod storage table (schema 3); the display filter is panel-local. All boolean
flags are real booleans. The publish build emits no Info/Warn diagnostics and no
correction audit events. Real errors remain ungated.

When any fix actually corrects game state, its owning script emits one Info event
with `Bug fix invoked:` in the message plus the fix id/number/name, repair type,
reason, game time, Sol, and hour.

## 7. UI text

```text
Options category: SMR Community Fixes
Panel title: SMR Community Fixes
Version selector label: Game version
Version filter option: All
Version option: 1.0.7
Selection summary: <shown> shown / <total> total / <selected> selected
Beta badge: [Beta]
Restore Rains title: Restore Rains
Restore Rains description: Restores natural and Cloud Seeding rainfall when vanilla rain scheduling becomes stalled or its saved state is stale.
Restore Disasters title: Restore Disasters
Restore Disasters description: Removes stale completed-meteor-storm state that can block vanilla cold waves, dust storms, natural rain activation, Cloud Seeding, Import Greenhouse Gases, Melt the Polar Caps, and Inner Light mirages. It does not repair rain-specific bugs; use Restore Rains for those. Vanilla Dust Devil behavior is preserved.
[Beta] Restore Dust Devils title: Restore Dust Devils
[Beta] Restore Dust Devils description: Corrects v1.0.7 Dust Devil spawn-chance handling, keeps natural scheduling tied to the surface map, and stops marker spawns after terraforming disables Dust Storms.
[Beta] Restore Asteroid Visits title: Restore Asteroid Visits
[Beta] Restore Asteroid Visits description: Prevents ordinary rockets from being mistaken for asteroid landers, avoiding an empty asteroid-rocket selection screen in v1.0.7.
[Beta] Restore Soil Overlay title: Restore Soil Overlay
[Beta] Restore Soil Overlay description: Keeps the solid soil overlay bound to the surface map, preventing v1.0.7 from using the surface SoilGrid while another map is active.
[Beta] Restore Saint Blessing title: Restore Saint Blessing
[Beta] Restore Saint Blessing description: Applies each Saint's stacking Morale bonus to the Religious colonists in that Saint's Dome, correcting v1.0.7's mismatched trait label.
[Beta] Restore SpaceY Description title: Restore SpaceY Description
[Beta] Restore SpaceY Description description: Adds SpaceY's missing +20 maximum Drone Hub command-capacity benefit to its v1.0.7 sponsor description; gameplay values are unchanged.
[Beta] Restore Jumbo Cave Reinforcements title: Restore Jumbo Cave Reinforcements
[Beta] Restore Jumbo Cave Reinforcements description: Releases Jumbo Cave Reinforcements construction sites stuck on unreachable Waste Rock in v1.0.7, but only after a drone's normal approach to that exact blocker fails.
[Beta] Restore No Disasters Cave-in Protection title: Restore No Disasters Cave-in Protection
[Beta] Restore No Disasters Cave-in Protection description: Stops v1.0.7's periodic underground marsquakes and cave-ins when the No Disasters rule is active, while preserving mystery, scripted, manual, and surface events.
[Beta] Restore Trade Rocket Protection title: Restore Trade Rocket Protection
[Beta] Restore Trade Rocket Protection description: Prevents RC Transports from interrupting v1.0.7 Universal Trade Rockets, matching the protection already applied to legacy trade and refugee rockets.
[Beta] Restore Asteroid Lander Cargo Safety title: Restore Asteroid Lander Cargo Safety
[Beta] Restore Asteroid Lander Cargo Safety description: Prevents v1.0.7 asteroid Lander payload changes from interrupting Drones or passengers while they are still using the cargo ramp.
[Beta] Restore Localized UI Text title: Restore Localized UI Text
[Beta] Restore Localized UI Text description: Uses v1.0.7's existing official translations for the overall terraforming heading and the Universal Rocket's Back to Earth action.
[Beta] Restore Track Demolition title: Restore Track Demolition
[Beta] Restore Track Demolition description: Completes v1.0.7 terminal track-element demolition and removes exact invalid Track shells already stored in existing savegames.
[Beta] Restore Clustered Lights title: Restore Clustered Lights
[Beta] Restore Clustered Lights description: Prevents v1.0.7 night lights from entering the renderer in a compressed staggered burst that can trigger the clustered-light assertion.
Select group button: Select group
Unselect group button: Unselect group
Apply button: Apply
Reset button: Reset
Back button: Back
Melt expedition line: Melt the Polar Caps: completes in <time> (40% Dust Storm chance)
Queued Melt outcome: Melt the Polar Caps: Dust Storm queued — waiting for <reason>
Forced active line: Forced Dust Storm (Melt the Polar Caps): active for <time>
```

Localized user-visible strings use stable numeric `T()` identifiers. The
technical filter labels **All** and version numbers intentionally remain raw
strings because the confirmed `XCombo` pattern uses `Translate=false` to avoid
the engine's item-selection translation assertion.

## 8. Constraints and non-goals

* Never edit the game installation, FPKs, ModTools, or generated reference files.
* Do not replace or reimplement rain gameplay.
* Do not make rain occur outside vanilla terraforming thresholds.
* Do not force Cloud Seeding while a real disaster remains active or predicted.
* Do not clear unrelated live disaster state.
* Do not add a standard Mod Options entry; the requested UI is a dedicated
  Options category and checklist panel.
* Do not hand-invent editor-managed `code_hash`, `saved`, `ModItemRef`, or
  `*.generated.lua` content.
* Do not suppress the engine-side clustered-light assertion, change renderer
  `hr` values, or replace light classes. Restore Clustered Lights may alter only
  the confirmed delayed `NightLightsOn()` call described in section 5M and
  remains default-off Beta until the controlled in-game reproduction passes.

## 9. Acceptance criteria

- [ ] **SMR Community Fixes** appears immediately below **Credits** in Options.
- [ ] Selecting it opens the dedicated modal checklist from both main-menu and
      in-game Options. The title is followed directly by the Game version
      toolbar, uses the native `MediumHeaderR` `LibelSuitRg-Regular` size-32
      font (slightly larger than the size-28 **Search:** label), retains its
      original blue-gray `PropName` color, and has no explanatory subtitle.
- [ ] The checklist begins with a real dropdown containing **All** and `1.0.7`,
      visibly displays and selects `1.0.7` on every open, and filters only the
      displayed rows. The selector must never open with a blank text field.
      Its field, popup rows, and arrow match the dark checklist palette without
      a white focused background. Only the popup row currently under the mouse
      uses the visible charcoal highlight, so moving between rows never leaves a
      second row highlighted. Keyboard focus must not synthesize rollover on the
      selected row; mouse press remains distinct. Selecting either item does not
      raise the prior `IsT(text)` Lua assertion.
- [ ] A single Mute Notifications-style toolbar contains Search, Clear, Game
      version, the selector, and the count in that order. The Clear label is
      centered inside its existing dark button. The Game version label is
      right-aligned in its reserved cell so the space after its colon matches
      the Search label-to-field spacing. Search is blank on every
      open, filters the current version's rows case-insensitively against their
      visible labels and descriptions, and updates the shown count. Clear restores
      all rows for the current version.
- [ ] All fifteen permanent numbers appear in the left column for `1.0.7`; the
      last thirteen are followed by a separate **[Beta]** badge. All right-column
      titles are unnumbered.
- [ ] Changing the version filter rebuilds the visible rows immediately, **All**
      does not change the active `1.0.7` runtime target, and reopening the panel
      resets the filter to `1.0.7`.
- [ ] Existing schema-1 settings, the removed `unsupported` profile, and unknown
      stored profiles migrate to the sole configured `1.0.7` choice.
- [ ] The left column contains the square toggle, zero-padded number, and optional
      **[Beta]** badge in that order; stable rows contain no badge. The right
      column shows the translated unnumbered title above the long explanation.
      Restore Disasters is the first row with **001** beside its toggle and title
      **Restore Disasters**; Restore Rains is second with **002** and title
      **Restore Rains**. Numbers remain stable under
      filtering and
      future catalog entries continue the three-digit sequence. The checked
      state is the sole enabled/disabled indicator. The right text column uses
      a wider `1280` maximum width, filling most of the remaining row while
      wrapping just before the panel's right edge; no text extends beyond the
      row box. Both titles
      remain valid translated values and opening the panel raises no
      `Translate == true` `SetText` assertion.
- [ ] The bug list and its rows cannot be selected. Clicking empty list space,
      labels, or descriptions never turns the whole table white or the translucent
      rows gray. Keyboard/gamepad focus uses the same dark table background and
      border as the idle state. Only each row's square checkbox changes its
      enabled/disabled state.
- [ ] On a disposable copy, remove one bug script and its two engine-required
      load-list entries. The removed bug has no row, preference initialization,
      lifecycle callback, or runtime behavior; the other bug still
      loads and retains its permanent number (for example, Restore Disasters
      remains **001** when Restore Rains is absent).
- [ ] Restore Rains defaults enabled on first use and persists its choice.
- [ ] Restore Disasters defaults enabled on first use and persists its choice.
- [ ] Restore Dust Devils, Restore Asteroid Visits, Restore Soil Overlay,
      Restore Saint Blessing, Restore SpaceY Description, and Restore Jumbo Cave
      Reinforcements, Restore No Disasters Cave-in Protection, and Restore Trade
      Rocket Protection, Restore Asteroid Lander Cargo Safety, and Restore
      Localized UI Text, and Restore Track Demolition default disabled on first
      use and install no runtime hook until Apply.
- [ ] Loading an existing v1.0.7 save with either stable fix enabled runs its guarded
      reconciliation after map state is available; no new game is required.
- [ ] Toggling either checkbox does not apply runtime behavior or persist storage
      until Apply is pressed.
- [ ] Apply commits all staged changes together, refreshes the panel baseline,
      and leaves the checklist open.
- [ ] Select group and Unselect group stage only the currently shown rows and
      update their checkbox icons without rebuilding the list. Pressing either
      group button preserves the exact current vertical scrollbar position.
      Reset clears search, restores the `1.0.7` filter, and stages every fix off -
      including the default-on ones - without changing runtime behavior until Apply.
- [ ] Escape and Back discard unapplied changes, close only the checklist, and
      return to Options.
- [ ] The toolbar shows `<shown> shown / <total> total / <selected> selected`
      and updates it for filter and staged-checkbox changes. No `xx fix(es)` text
      remains below the list. The footer shows Select group, Unselect group, Apply,
      Reset, and Back in that order; all labels are centered, the neutral buttons
      match Mute Notifications, Apply is green, and Back is red.
- [ ] The monitor-relative bug list uses a native right-side scrollbar linked through
      `VScroll`/`Target`, reserves a strip outside the row text, supports mouse-
      wheel scrolling, and auto-hides when the current rows fit in the viewport.
      Its container and list use 60% of the active desktop height, converted from
      physical pixels through the current vertical UI scale. The rendered
      viewport therefore keeps the same screen-height proportion across monitor
      resolutions and UI-scale settings and is tall enough to show five fixes at
      once when each description fits on one line.
- [ ] A natural rain attempt colliding with another disaster does not permanently
      stall future attempts.
- [ ] Cloud Seeding starts vanilla normal rain after real disasters finish.
- [ ] Loading a save with stale rain state recovers without forcing rain outside
      vanilla thresholds.
- [ ] Disabling Restore Rains restores captured vanilla functions.
- [ ] Completing a meteor storm does not leave
      `g_DisastersPredicted.DisasterMeteorStorm` set.
- [ ] After a meteor storm, cold waves, dust storms, natural rain activation,
      Cloud Seeding, Import Greenhouse Gases, Melt the Polar Caps, and Inner
      Light mirages are no longer blocked by stale meteor prediction state.
- [ ] During calm weather, Dust Devils retain their normal randomized schedule;
      a Dust Storm removes active Dust Devils and suppresses new spawns; ordinary
      scheduling resumes after it ends without catch-up or acceleration.
- [ ] Restore Disasters does not replace Restore Rains; the separate rain-loop
      deadlock, rain-thread initialization, and stale active-rain recovery remain
      owned by Restore Rains.
- [ ] Disabling Restore Disasters restores captured vanilla `MeteorsDisaster`.
- [ ] Repeated enable/disable and code reloads do not stack wrappers or duplicate
      Options categories/panels/schedulers.
- [ ] Reloading after the game refreshes the hooked globals, or while another mod
      owns an outer wrapper, produces no catalog-disable error, later-wrapper
      warning, recursion, or duplicate vanilla call. Deleting either bug script
      and its load-list entries leaves any inner persistent gate inert.
- [ ] Saving while either stable wrapper is active produces no persist error.
      Suspended rain/meteor wrapper stacks and all reachable non-global upvalues
      contain no C function such as a locally captured `table.unpack`.
- [ ] Publish defaults leave `Config.DEBUG_LOGS` false and every fix's own
      `debug` false, so ordinary play emits no Info or Warn output at all. Real
      errors always surface through `ModLog`.
- [ ] No file in `Code\` other than `SMRCommunityFixes.lua` references a function, table,
      or global defined by another file in this mod. Searching the fix files for
      the framework's names returns nothing.
- [ ] Loading the fix files with no framework present appends exactly one valid
      descriptor per fix to `_G.SMRCommunityFixesPending`; loading `SMRCommunityFixes.lua`
      afterwards adopts all of them, sorts them by number, clears the pending
      list, and applies 001/002 enabled with every beta disabled.
- [ ] After a simulated Lua reload, the previous generation of descriptors is
      quiesced exactly once each before the new generation is applied.
- [ ] Every actual stable or beta correction emits one
      searchable `Bug fix invoked:` Info event with its fix identity, repair,
      reason, game time, Sol, and hour while `DEBUG_LOGS` is enabled.
- [ ] Every fix can be enabled on an existing v1.0.7 save. Identifiable stale
      scheduler, modifier, blocker, and terminal-Track state is reconciled on
      enable/load; transient predicate/UI/action fixes govern the next affected
      call. Disabling the individual fix or the entire mod leaves no mod-owned
      saved object, timer, repair marker, or function reference, and the save
      continues under vanilla behavior. Irreversible past losses that vanilla did
      not record are never guessed or synthesized.
- [ ] Restore Track Demolition removes an existing object only when it has the
      exact invalid saved shell state (`demolishing == true`, both element arrays
      `false`). Valid existing tracks remain untouched. A new terminal demolition
      removes the emptied Track object; non-terminal shortening and splitting
      remain vanilla. Disabling restores the exact captured method when the
      module owns the hook and leaves no saved state, timer, or tracked object
      behind.
- [ ] Restore Clustered Lights changes only positive-delay `NightLightsOn()`
      calls to delay zero, leaves instant refreshes and `NightLightsOff()`
      unchanged, restores the exact captured function when disabled, and emits
      one timed correction event for each altered delayed transition.
- [ ] `metadata.lua` code order and `items.lua` entries match files on disk.
- [ ] All Lua files pass available parse checks.
- [ ] The payload deployed to the local Mods folder includes metadata, items,
      registered Code files, and the complete Images folder with no stale
      destination files; repository Markdown documentation is excluded.
- [ ] Completed changes are committed and pushed; the short commit hash is reported.

## 10. Manual in-game test steps

1. Launch v1.0.7 with only SMR Community Fixes enabled among behavior-changing test mods.
2. Open Options and confirm SMR Community Fixes is directly below Credits.
3. Open the checklist and confirm the Game version dropdown defaults to `1.0.7`
   with `1.0.7` visibly written in the field, never a blank field, and contains
   exactly **All** and `1.0.7`. Open and focus it and confirm the field, popup
   rows, and arrow remain dark and visually match the checklist. Move the pointer
   between **All** and `1.0.7` and confirm exactly one row is visibly highlighted:
   the row currently under the pointer. Confirm mouse press is distinct, the
   Clear label is centered in its button, the two label-to-field gaps match, and
   selecting both values produces no `IsT(text)` assertion.
   Confirm each fix description uses most of the available right side, wraps just
   before the border, and never draws beyond the row box.
   Click both row descriptions and empty table space, then navigate with the
   keyboard/gamepad. Confirm the table remains dark with no selected-row or
   whole-table highlight; confirm the square checkboxes still toggle normally.
   Confirm the **SMR Community Fixes** display title is slightly larger than **Search:**
   while retaining its earlier blue-gray color.
4. If persistent storage previously selected `unsupported`, reopen the checklist
   and confirm it now normalizes to `1.0.7` with all fifteen fix rows available.
5. Select **All** and confirm all catalog rows are shown without changing the
   active runtime target. Close and reopen the panel and confirm the filter
   defaults back to `1.0.7`.
6. Open the checklist; toggle Restore Rains off, press Back, reopen it, and
   confirm it is still enabled. Repeat using Escape.
7. Toggle Restore Rains off, press Apply, and confirm the panel stays open and
   shows it disabled. Close and reopen the panel and confirm it persisted.
8. Stage changes to all fifteen fixes, press Apply, and confirm they commit together.
   Confirm the first two left columns show checkbox + **001** and checkbox +
   **002**, while their right-column titles are **Restore Disasters** and
   **Restore Rains** under both filters. Confirm each beta row shows checkbox +
   its number + the separate **[Beta]** badge, for example **003 [Beta]**.
   Enter a search that shows a subset, use Select group and Unselect group, and
   confirm only those visible rows change. With enough rows to scroll, move the
   scrollbar away from the top before pressing each group button and confirm its
   position does not move. Press Reset and confirm search clears, the filter
   returns to `1.0.7`, and every checkbox is cleared, the two stable fixes
   included; the summary then reads `0 selected`. Confirm the footer order is Select group, Unselect
   group, Apply, Reset, Back; all labels are centered; the toolbar summary reads
   `14 shown / 14 total / <n> selected` and updates with staged checkbox changes;
   and no numeric fix count appears below the list.
9. Open the checklist and confirm all fifteen rows render: checkbox, number,
   `[Beta]` badge on 003-014, then the plain-text title above its explanation. No
   `Translate` assertion or missing-text row may appear, and no forecast box or
   diagnostic overlay may appear anywhere during play.
10. Toggle Restore Disasters off and press Apply; confirm vanilla behavior returns
   and the game log records no framework error. Re-enable it and press Apply.
   Confirm the toolbar summary tracks staged changes throughout.
11. Load a v1.0.7 save created before this mod was installed that contains stale
   rain or completed-meteor state. Confirm the enabled fixes reconcile it after
   loading without removing a genuinely active disaster.
12. Start a new Green Mars game, raise Atmosphere, Temperature, and Water through
   the vanilla rain thresholds, and allow natural rains to cycle.
13. Arrange for a scheduled rain attempt to overlap another predicted/active
   disaster; after that disaster, run long enough to confirm a later rain occurs.
14. Complete Cloud Seeding with no active disaster and confirm normal rainfall,
   rain FX, and beneficial soil/lake behavior occur.
15. Complete Cloud Seeding while another disaster is active; confirm rainfall
   begins after the real disaster ends rather than waiting forever.
16. Save during rain and during a rain warning, reload each save, and confirm the
   state finishes or recovers and future natural/Cloud Seeding rains remain possible.
17. With rain diagnostics enabled, confirm scheduler retry, stale-state cleanup,
    wrapper apply/restore, and Cloud Seeding pre-wait reconciliation logs. Disable
    debug flags and confirm those lines stop.
18. On a map with cold waves, dust storms, and meteor storms enabled, let a
    meteor storm complete, then run long enough to confirm cold waves and dust
    storms can be scheduled afterward.
19. During a meteor storm warning and while meteors are falling, toggle Restore
    Disasters off and on and confirm no live warning or meteor is removed.
20. After a completed meteor storm, save and reload, then confirm later disasters
    continue. With disaster diagnostics enabled, confirm one completed-storm
    cleanup log and no repeated cleanup; disable diagnostics and confirm it stops.
21. Observe Dust Devils before, during, and after a real Dust Storm. Confirm the
    storm removes active Dust Devils, none spawn during it, and the normal random
    schedule resumes afterward without an immediate catch-up burst.
22. After a completed meteor storm, exercise Cloud Seeding, Import Greenhouse
    Gases, and Melt the Polar Caps and confirm each proceeds after any genuinely
    live disaster finishes. In an Inner Light game, confirm mirages resume their
    normal polling cycle. Also confirm eligible natural rain attempts can start.
23. To reproduce the clustered-light assertion, load the affected St. Elmo's
    Fire save, let fireflies/Flower Lamps remain present, and start a Great Dust
    Storm through Melt the Polar Caps. After dismissing the assertion and closing
    the game, preserve the newest `MarsDebug` log and record whether the
    assertion occurred with Restore Clustered Lights enabled and disabled.
24. On a disposable mod copy, remove `Code/smrcf_restore_rains.lua` and its matching
    `metadata.lua` and `items.lua` entries, reload the mod, and confirm the panel
    contains the fourteen remaining fixes, **001** remains beside Restore Disasters'
    checkbox, and no load error occurs.
25. Reopen the checklist and confirm Search is blank and Game version visibly
    reads `1.0.7`. Search for text unique to Restore Rains and Restore Disasters;
    confirm the visible rows and shown count update case-insensitively. Press
    Clear and confirm all fifteen rows return. Confirm the slim right scrollbar
    appears for the fifteen-row catalog, mouse-wheel and thumb scrolling reach the
    last row, and the bar auto-hides after filtering the list down to rows that
    fit. Confirm the viewport shows five rows simultaneously when those five
    descriptions each fit on one line. Repeat at a second resolution or UI-scale
    setting and confirm the viewport remains 60% of the active desktop height.
26. On a disposable v1.0.7 game, confirm all thirteen **[Beta]** rows start
    unchecked. Enable Restore Dust Devils, use a non-100% Dust Devil preset, and
    confirm each natural opportunity performs a percentage roll followed by an
    integer spawn count only on success. Switch to another map during a cycle and
    confirm the surface preset remains in use. Cross the Dust Storm terraforming
    stop threshold and confirm marker spawns stop.
27. Enable Restore Asteroid Visits and confirm an ordinary non-lander rocket in
    `WaitLaunchOrder` or eligible `LoadAndLaunch` no longer opens an empty rocket
    selector, while a valid Universal or Lander rocket remains selectable.
28. Enable Restore Soil Overlay, show the solid soil overlay on the surface,
    switch to another map, and confirm `GetOverlayGrid()` does not expose the
    surface `SoilGrid`. Return to the surface and confirm the solid overlay still
    works. Review the log for one timed beta correction event per invoked path.
29. Place one or more Saints and Religious colonists in the same Dome. Enable
    Restore Saint Blessing and confirm each Religious colonist receives the
    documented +10 base Morale per Saint, including Saints already present when
    Apply is pressed. Move or remove a Saint and confirm stacking updates.
    Disable the fix and confirm the captured vanilla methods are restored.
30. Enable Restore SpaceY Description and inspect SpaceY in mission setup.
    Confirm its text states both four additional starting Drones and twenty
    additional maximum Drone Hub capacity, while the gameplay values remain
    +4/+20. Disable it and confirm the original description returns.
31. Load a disposable save with a Jumbo Cave Reinforcements site stuck on
    clearing unreachable Waste Rock. Enable the fix and let a drone make its
    normal approach. Confirm only the failed blocker is released and the site
    progresses. Confirm reachable Waste Rock and non-Jumbo construction sites
    retain vanilla behavior. Review the log for the timed correction event.
32. Start or load an underground colony with the No Disasters rule. Enable
    Restore No Disasters Cave-in Protection and run beyond the configured
    periodic marsquake interval; confirm no natural cave-ins occur. Confirm
    mystery/scripted cave-ins remain possible. Disable the fix and confirm only
    its suppressed vanilla map repeat is restored. Review the log for a timed
    correction event naming the underground map and whether a live repeat thread
    was removed.
33. Land a `UniversalTradeRocket` from a rival/trade event. Enable Restore Trade
    Rocket Protection and confirm RC Transport no longer offers or executes load
    or unload interaction with that rocket, while it still works with ordinary
    depots and colony rockets. Disable the fix and confirm the captured vanilla
    methods return. Review the log for a timed correction event with both object
    handles.
34. Land an asteroid Lander carrying Drones, select it before the Drones have
    left the ramp, and enable Restore Asteroid Lander Cargo Safety. Confirm the
    payload action remains unavailable until the ramp lists clear, then becomes
    available normally. Change the return payload and confirm no Drone or
    passenger is embedded in the Lander. Disable the fix and confirm the captured
    payload-eligibility method returns. Review the log for one timed correction
    event for that guarded ramp cycle.
35. In a non-English official localization, enable Restore Localized UI Text.
    Open the terraforming overview and a Universal Rocket's infopanel; confirm
    the overall terraforming heading and both Back to Earth rollover strings use
    the official translation. Disable the fix, reopen both UIs, and confirm the
    captured vanilla constructors are restored. Confirm **COLONY DATA** remains
    outside this fix rather than receiving an invented translation.
36. Build a short track that can be reduced to a terminal segment, enable
    Restore Track Demolition, and salvage its final element. Confirm the track
    and its container disappear without a `TrackBase:BuildingUpdate` error,
    while shortening and splitting longer tracks remain vanilla. Disable the
    fix and confirm the exact captured `DemolishAndSplitTrack` method returns.
    Re-enable it, invoke the terminal path again, and confirm one timed
    correction event contains the track and element handles. Load a disposable
    save containing a v1.0.7 terminal Track shell, enable the fix, and confirm the
    exact invalid shell is removed while every valid existing track remains.
    Disable the fix, save, reload, and confirm the save continues under vanilla
    behavior with no mod-owned object, timer, or repair marker.
37. Enable Restore Clustered Lights on a disposable v1.0.7 save that has
    repeatedly produced `hrClustered.cpp(987)` without mods. Exercise repeated
    day-to-night transitions at vanilla 1x, 5x, and 20x, then repeat the
    previously affected accelerated transition. Confirm night lights still
    appear, no clustered-light assertion occurs, and the log records one timed
    `atomic_night_light_turn_on` correction for each positive-delay transition.
    Disable the fix and confirm the captured `NightLightsOn()` function is
    restored and no correction event is emitted on the next transition.
38. On disposable copies of existing v1.0.7 saves, enable each applicable fix,
    let its reconciliation or next guarded interaction run, then disable that fix,
    save, and reload. Repeat once with the whole mod disabled after the repairs.
    Confirm both saves load under vanilla behavior and contain no dependency on a
    mod-owned class, object, timer, repair marker, or function. Do not expect the
    mod to recreate irreversible passengers, units, resources, or terrain whose
    pre-bug state vanilla never stored.

## 11. Phasing

```text
Phase 1 (community release): one framework file plus one self-contained file per
                        fix; dedicated SMR Community Fixes checklist with panel-local
                        version filter and staged persistent toggles; Restore
                        Rains scheduler/state/Cloud Seeding repair; Restore
                        Disasters meteor-state cleanup; and thirteen explicitly
                        labeled default-off v1.0.7 beta fixes.
Future phases:          add only independently verified v1.0.7 fixes, each as one
                        new self-contained file. Anything that is neither the
                        framework nor a single bug fix does not belong in Code\.
```
