# Contributing a bug fix

SMR Community Fixes is maintained by the Surviving Mars: Relaunched community. Anyone can
add a fix. This file is everything you need to know to do it.

## The one rule

**A fix restores the game's intended vanilla behavior and nothing more.** It does
not change, rebalance, or add behavior, and it never modifies game installation
files. If a player turns your fix off, the game must behave exactly as it does
without this mod.

## Two kinds of file, and no others

```text
Code/SMRCommunityFixes.lua      the framework: config, logging, settings, registry, Options entry, checklist UI
Code/smrcf_restore_<fix>.lua    one bug fix, completely self-contained
```

A fix file may use the game's own globals — `ModLog`, `GameTime`, `const`,
`SharedModEnv`, `rawget`, `T`, and the vanilla functions it repairs. It must
**not** call a function or read a global defined by any other file in this mod.
That is what makes a fix reviewable on its own and unable to break the others.

The framework never names an individual bug. Anything that is neither the
framework nor a single bug fix does not belong in `Code/` — which is why
`smrcf_restore_TEMPLATE.lua` lives in `templates/`. A template inside `Code/` would
be deployed into the game as dead weight, would break the check that every
`Code/` file is registered in `metadata.lua`, and would fail the placeholder
check on the `VanillaFunctionName` and `<...>` markers it still carries.

## How a fix reaches the game

A fix appends its descriptor table to the plain global list `_G.SMRCommunityFixesPending`.
`SMRCommunityFixes.lua` adopts that list, disables any fix that disappeared since the
previous Lua load, and clears the list. You never call into the framework; you only
leave data behind for it.

The engine mod sandbox blocks `io`, `dofile`, and `dofolder` (`ModEnvBlacklist` in
`ModTools/Src/CommonLua/Classes/Mod.lua`), so the game cannot discover files on
its own. Your file must be listed in `metadata.lua` `'code'` and in `items.lua`.
Anywhere in the list works: `SMRCommunityFixes.lua` adopts the descriptors during load if it
comes after the fixes, and at `ClassesBuilt` if it comes before them.

## The descriptor

```lua
local FIX = {
    -- yours to write
    id = "restore_your_fix",          -- unique, permanent: the saved-settings key
    description = "One sentence naming the vanilla behavior this restores.",
    set_enabled = fn(enabled, reason), -- your repair; must be idempotent both ways

    -- optional: the framework fills each of these in when it is absent
    number = 15,                       -- default: the next free number
    beta = true,                       -- default: true
    versions = { ["1.0.7"] = true },   -- default: the current target version
    default_enabled = false,           -- default: false
    debug = false,                     -- default: false
    label = "Restore Your Fix",        -- default: derived from the id
    quiesce = fn(reason),              -- default: set_enabled(false, reason)
    events = { GameStateStarting = fn, DoneGame = fn, RainDisasterEnd = fn },
}
```

Those defaults are deliberately the safe ones — a fix that says nothing is beta,
off, silent, and applies only to the current target version. Pin `number`
explicitly if you want a fixed row position, which the shipped fixes all do.

`set_enabled` obeys unconditionally — the framework decides *whether* a fix runs
(master switch, game-version gate, player's checkbox), your file decides *what*
happens when it does.

## Steps

You edit Lua and nothing else. No build step, no scripts, no tooling — three Lua
files in total.

1. **Confirm the bug and find its cause in the game's own Lua source.** Invent
   nothing: every function, class, preset, and property you touch must exist in
   the installed version. Record the file you confirmed it in, in your header.
2. **Copy `templates/smrcf_restore_TEMPLATE.lua`** to
   `Code/smrcf_restore_<your_fix>.lua`. Inside your copy: set `id` to
   `restore_<your_fix>`, write the `label` and `description`, rename
   `RestoreYourFix`, `SMRCFRestoreYourFix` and `SMRCF_YourFixHooks` to your own
   names, and replace `VanillaFunctionName` with the game function you repair.
   The last two are strings, not identifiers, so a missed rename still parses and
   loads — while sharing another fix's state and captured vanilla function.
3. **Write the repair.** Capture the vanilla function, wrap it, correct only the
   exact broken condition, and delegate every other case to the captured function
   untouched. Only `id`, `description` and `set_enabled` are required — the
   framework fills in `number`, `beta`, `versions`, `default_enabled`, `debug`,
   `label` and `quiesce` when you leave them out.
4. **Make enable and disable idempotent.** Enabling twice must not double-install;
   disabling must reinstall the exact captured function; disabling twice must not
   fail. Only unwrap while your module still owns the global, so a third-party
   wrapper on top of yours is never destroyed.
5. **Log through your own `log` helper.** Diagnostics stay behind `FIX.debug`;
   `ERROR` is never gated. Emit exactly one `Bug fix invoked:` event whenever the
   fix actually corrects something, with the fix identity, repair name, reason,
   game time, Sol and hour.
6. **Register the file so you can test it.** The game only loads Lua files listed
   in `metadata.lua` `'code'`, so add these two entries locally:

   ```lua
   -- metadata.lua, anywhere in the 'code' list
   "Code/smrcf_restore_<your_fix>.lua",
   ```

   ```lua
   -- items.lua, same position in the list
   PlaceObj('ModItemCode', {
       'name', "smrcf_restore_<your_fix>",
       'CodeFileName', "Code/smrcf_restore_<your_fix>.lua",
   }),
   ```

   **You may leave these out of your pull request.** When it is merged, GitHub adds
   both entries and bumps `'version'` for you — see *What GitHub does for you*
   below.

7. **Test in game** (see below).
8. **Open a pull request** at <https://github.com/facazevedo/SMR-bug-fixes>.
   Another member of the community reviews it.

## What GitHub does for you

Two workflows in `.github/workflows/`, both driven by `tools/sync_mod.lua`:

* **On your pull request** — `check-fixes.yml` parses every Lua file and checks your
  fix. It fails only on things a person must fix: a duplicate id, a pinned number
  already taken, a template placeholder left behind, `debug = true`, a reference to
  framework internals, or a missing `description`/`set_enabled`. A fix that simply
  is not registered yet is reported as a notice, not a failure.
* **After it merges** — `register-fixes.yml` re-runs the same check, appends any
  missing `metadata.lua` and `items.lua` entries at the end of the list, bumps the
  version, and commits that itself. It never reorders what is already there.

Nothing about this requires anything installed on your machine. If you have Lua,
`lua tools/sync_mod.lua check` runs the same check locally, and
`lua tools/sync_mod.lua sync` does the same registration.

The engine mod sandbox blocks `io`, `dofile` and folder listing, so no Lua inside
the mod can discover your file or edit its own registration — that is why this is
done by CI rather than by the mod itself.

## What a reviewer checks

* The file is self-contained: searching it for `SMRCommunityFixesMod`, or for any function
  defined in `SMRCommunityFixes.lua`, returns nothing.
* It restores vanilla behavior only — no new features, no tuning, no game files
  touched.
* The repair triggers on a precise condition, not a broad "if something looks
  wrong".
* Disable reinstalls the exact captured function.
* No broad `pcall` hides a real error; errors are reported, not swallowed.
* `id`, `number`, `beta = true`, `default_enabled = false`, `debug = false`.
* The registration lines exist in both `metadata.lua` and `items.lua`.

## Testing before you submit

Parse every file, then exercise it in game:

1. Enable your fix, reproduce the bug, and confirm it is gone.
2. Disable it and confirm vanilla behavior returns.
3. Load a save made before your fix existed and confirm nothing breaks.
4. Read the newest log in
   `%APPDATA%\Surviving Mars Relaunched\logs` for Lua errors and asserts, and
   confirm your fix stays silent while `debug = false`.
5. Temporarily set `debug = true` and confirm your `Bug fix invoked:` event fires
   exactly once per correction. Set it back to `false`.

`DESCRIPTION.md` holds the full requirements for the mod, including the per-fix
behavior specifications and the manual test steps.
