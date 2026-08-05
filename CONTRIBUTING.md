# Contributing a bug fix

Anyone can add a fix. It is a Lua-only job: no build step, no tooling, one new
file.

Found a bug but not its cause? Don't write a fix — [open an
issue](../../issues/new?template=bug_report.yml) instead. A save that reproduces
it is worth more than a guess at the cause.

## The one rule

**A fix restores the game's intended vanilla behavior and nothing more.** No new
features, no rebalancing, no touching game installation files. Turn the fix off
and the game must behave exactly as it does without this mod.

## Quick start

1. **Confirm the bug in the game's own Lua source.** Invent nothing — every
   function, class, preset and property you touch must exist in the installed
   version. Note the source file you confirmed it in, in your header.
2. **Copy `templates/smrcf_restore_TEMPLATE.lua`** to
   `Code/smrcf_restore_<your_fix>.lua`. Its header lists the four names to
   rename; do all four, then Ctrl+F each one again. Two of them are strings, so
   a missed rename still loads — while silently sharing another fix's state.
3. **Write the repair.** Capture the vanilla function, wrap it, correct only the
   exact broken condition, and pass every other case to the captured function
   untouched.
4. **Test in game** (see below).
5. **Open a pull request** at
   <https://github.com/SMR-community/smr-community-fixes>. Another community
   member reviews it.

## Who can push

This repository has no single owner. Everyone in the **SMR-community**
organisation has push access to `main`, and `main` has no branch protection and
no required review — nobody has to approve your work.

Not a member yet? Ask for an invite at <smrcommunitymods@gmail.com> or open an
issue. Members are added as equals, not as guests.

Branch and pull request is still the **default** flow, because a second pair of
eyes catches the things in *What a reviewer checks* below, and because the
branch workflow registers your fix for you. Pushing straight to `main` is
allowed when you are confident — registration then happens on `main` instead.

## Where files go

```text
Code/SMRCommunityFixes.lua      the framework: config, logging, settings, registry, Options entry, checklist UI
Code/smrcf_restore_<fix>.lua    one bug fix, completely self-contained
```

Nothing else belongs in `Code/`. The template lives in `templates/` because a
file in `Code/` ships into the game and must be registered in `metadata.lua`.

Your fix may use the game's globals — `ModLog`, `GameTime`, `const`,
`SharedModEnv`, `rawget`, `T`, and the vanilla functions it repairs. It must
**never** call a function or read a global defined by another file in this mod.
That is what keeps each fix reviewable on its own and unable to break the others.

## The descriptor

Your file appends a descriptor to the global list `_G.SMRCommunityFixesPending`.
The framework adopts that list on load — you never call into the framework.

```lua
local FIX = {
    -- required
    id = "restore_your_fix",           -- unique and permanent: the saved-settings key
    description = "One sentence naming the vanilla behavior this restores.",
    set_enabled = fn(enabled, reason),  -- your repair; idempotent both ways

    -- optional: the framework fills in any you omit
    number = 15,                        -- default: next free number
    beta = true,                        -- default: true
    versions = { ["1.0.7"] = true },    -- default: current target version
    default_enabled = false,            -- default: false
    debug = false,                      -- default: false
    label = "Restore Your Fix",         -- default: derived from the id
    quiesce = fn(reason),               -- default: set_enabled(false, reason)
    events = { GameStateStarting = fn, DoneGame = fn },
}
```

The defaults are the safe ones: a fix that says nothing is beta, off, silent and
scoped to the current target version. Pin `number` if you want a fixed row
position, as all shipped fixes do.

`set_enabled` obeys unconditionally. The framework decides *whether* a fix runs
(master switch, version gate, player's checkbox); your file decides *what*
happens when it does.

## Game versions

Fixes are separated by game version. Each one belongs to the version it was
actually confirmed on — that is what `versions` declares — and the player picks
a version at the top of the panel to see that version's list. A fix is never
applied to a version nobody verified it against, because the next game patch may
well have fixed the bug, and a repair running on top of that is a new bug.

Omit `versions` and your fix is scoped to the current target version, which is
right for anything confirmed today.

When the game updates, the new version gets its own list:

1. Add it to `Config.GAME_VERSIONS` in `Code/SMRCommunityFixes.lua` — the
   catalog is data-driven, so nothing else in the UI changes.
2. Re-confirm each fix against the new build, and add the version to the
   `versions` table of every fix that still applies:

   ```lua
   versions = { ["1.0.7"] = true, ["1.0.8"] = true },
   ```

A fix Paradox has fixed upstream simply stops listing the new version. It keeps
working for players still on the old one.

## What your fix must get right

* **Idempotent both ways.** Enabling twice must not double-install. Disabling
  must reinstall the exact captured function, and disabling twice must not fail.
* **Unwrap only while you still own the global**, so a third-party wrapper
  installed on top of yours is never destroyed.
* **Log through your own `log` helper.** Diagnostics stay behind `FIX.debug`;
  `ERROR` is never gated. Emit exactly one `Bug fix invoked:` event per actual
  correction, with the fix identity, repair name, reason, game time, Sol and hour.
* **No broad `pcall` swallowing real errors.**

## Registration is automatic

The game only loads files listed in `metadata.lua` `'code'` and `items.lua`.
**You never write those entries.** Push your branch and CI adds them for you:

* **When you push your branch** — `register-on-branch.yml` appends both entries,
  bumps the version, and commits that to your branch. **`git pull` before you
  commit again**, or your next push is rejected as out of date.
* **On your PR** — `check-fixes.yml` parses every Lua file and fails only on
  things a person must fix: duplicate id, taken number, leftover template
  placeholder, `debug = true`, a reference to framework internals, or a missing
  `description`/`set_enabled`.
* **After merge** — `register-fixes.yml` runs the same registration on `main`,
  covering anything the branch run missed. It never reorders existing entries.

Every fix appends to the end of the same two lists, so if another fix merges
while yours is open, your pull request will conflict on `metadata.lua` and
`items.lua`. Resolve it the lazy way: rebase on `main`, keep **main's** copy of
both files, and push. The branch workflow re-runs and appends your fix again.

Working from a **fork**? GitHub disables workflows on a new fork until you
enable them once on your fork's **Actions** tab. Until you do, no branch
registration runs — the after-merge workflow still catches it, but your fix
won't load in game from your own checkout until the entries exist.

To add them yourself instead — needed if you want to test **before** pushing —
either run `lua tools/sync_mod.lua sync` (any Lua 5.4), or add these by hand:

```lua
-- metadata.lua, anywhere in the 'code' list
"Code/smrcf_restore_<your_fix>.lua",
```

```lua
-- items.lua, same position
PlaceObj('ModItemCode', {
    'name', "smrcf_restore_<your_fix>",
    'CodeFileName', "Code/smrcf_restore_<your_fix>.lua",
}),
```

CI does this rather than the mod itself because the engine sandbox blocks `io`,
`dofile` and folder listing, so no Lua in the mod can discover or register files.

## Publishing to Paradox Mods

The mod page is updated from GitHub, not from the game's Mod Editor. Publishing
needs no game installed anywhere — it runs on a hosted Linux runner and talks to
Paradox over HTTP. Merging does not publish. Pushing a version tag does:

```
git tag v3
git push origin v3
```

[`publish.yml`](.github/workflows/publish.yml) then checks the payload, refuses
the tag if `'version'` has not moved since the last one, packs `metadata.lua`,
`items.lua`, `Code\` and `Images\`, and uploads that to Paradox Mods.

The tag is only the trigger — the version players see is the integer in
`metadata.lua`, which CI bumps for you. So several fixes can merge, and you
publish them together when you choose.

The mod page's own wording — its title, short description and long description —
is read back from Paradox and republished unchanged, because the service demands
all three on every version and would otherwise blank them. Edit that text on the
mod page itself; this repository only ships code, images and the changelog entry
(which comes from `'last_changes'` in `metadata.lua`, and cannot be empty).

The cover image and the screenshots do come from here: `Images\` holds both, and
`publish.yml` names which is which. Add a screenshot by putting it in `Images\`,
declaring it in `metadata.lua` as `'screenshot2'` and so on, and passing it with
another `--screenshot` in the workflow.

To rehearse, run the workflow from the **Actions** tab with **dry run** on: it
packs the payload and checks the secret, and sends nothing.

### What you get back

**You are told either way.** Both outcomes write a per-step table to the run
summary:

| Step | Result | Status | Time |
|---|---|---|---|
| `renew` | ✅ | 200 | 658 ms |
| `mod_details` | ✅ | 200 | 198 ms |
| `presign` | ✅ | 200 | 172 ms |
| `upload_thumbnail` | ✅ | 200 | 418 ms |
| `upload_content` | ❌ | 504 | 20019 ms |

**If it published**, you get a [release](../../releases) for the tag: the mod
version in the title, a link to the mod page, the commits since the last
release, and `SMRCF.zip` — the exact payload uploaded — attached to it.

**If it failed**, you get an issue titled `Publishing v3 failed`, saying which
step broke, the HTTP status, the server's own message, who tagged and a link to
the run. Tagging again comments on that same issue rather than opening another,
and it closes itself once a tag succeeds.

The exit code says what state things are in:

| | |
|---|---|
| `0` | published |
| `1` | failed; nothing was uploaded |
| `2` | `PDX_REFRESH` missing, or no changelog entry to publish |
| `5` | payload uploaded but never published — not live, re-tagging replaces it |

Network errors, timeouts and 5xx retry four times with backoff before any of
that. A 4xx never retries: it means the request itself was wrong, and repeating
it only wastes the upload.

If a run fails at `renew` with a 401, the refresh token has expired. Log in once
in the game, read `refreshToken` from
`%LOCALAPPDATA%\PDX\SDK\surviving_mars_relaunched\account.json`, and replace the
secret with `gh secret set PDX_REFRESH`. The value is prompted for, so it never
reaches your shell history.

Anyone who can push can tag. A tag is the one irreversible action here — it
reaches every subscriber's game.

## Test before you submit

1. Enable your fix, reproduce the bug, confirm it is gone.
2. Disable it, confirm vanilla behavior returns.
3. Load a save made before your fix existed, confirm nothing breaks.
4. Check the newest log in the game data folder's `logs` — `%APPDATA%\Surviving
   Mars Relaunched` on Windows, `~/Library/Application Support/...` on macOS,
   `~/.local/share/...` on Linux — for Lua errors and asserts, and confirm your
   fix stays silent while `debug = false`.
5. Temporarily set `debug = true`, confirm `Bug fix invoked:` fires exactly once
   per correction, then set it back to `false`.

## What a reviewer checks

* Self-contained: searching your file for `SMRCommunityFixesMod`, or any
  function defined in `SMRCommunityFixes.lua`, returns nothing.
* Restores vanilla behavior only.
* Triggers on a precise condition, not a broad "if something looks wrong".
* Disable reinstalls the exact captured function; errors are reported, not
  swallowed.
* `id` and `number` set; `beta = true`, `default_enabled = false`, `debug = false`.

`DESCRIPTION.md` holds the full mod requirements, the per-fix behavior
specifications and the manual test steps.
