# SMR Community Fixes

Community-maintained bug fixes for **Surviving Mars: Relaunched**.

Each fix repairs one confirmed vanilla bug and nothing else. Every fix is
independent and individually toggleable, so you can run only the ones you want.
Turn a fix off and the game behaves exactly as it does without this mod.

Fixes are grouped by game version. Each fix belongs to the version it was
confirmed on, and you pick the version at the top of the panel. Today that list
is **v1.0.7**; when the game updates, the new version gets its own list.

<img width="1920" height="1067" alt="screenshot_01" src="https://github.com/user-attachments/assets/c7664c82-5c35-4906-8df5-8b215a2437f0" />

## Using it

Open the checklist from:

```text
Main Menu -> Options -> SMR Community Fixes
```

The panel lists every fix with a checkbox, its row number, and a `[Beta]`
badge where the fix is still being tested. Changes stay staged until you press
**Apply**; **Back** and **Escape** discard them. Your choices persist between
sessions.

Restore Disasters and Restore Rains repair eligible stale state in **existing
savegames** as well as new games, so you do not need to start over. No fix invents history the game
never saved.

## The fixes

`[Beta]` means the fix still needs testing in real games, so it ships **off** by
default. The four stable fixes ship **on**.

| # | Fix | Status | What it repairs |
|--:|-----|--------|-----------------|
| 001 | Restore Disasters | Stable, on | Clears stale completed-meteor-storm state that can block cold waves, dust storms, natural rain, Cloud Seeding, Import Greenhouse Gases, Melt the Polar Caps, and Inner Light mirages. |
| 002 | Restore Rains | Stable, on | Restarts natural and Cloud Seeding rainfall when rain scheduling stalls or its saved state goes stale. |
| 003 | Restore No Disasters Cave-in Protection | Stable, on | Stops periodic underground marsquakes and cave-ins while the No Disasters rule is active, preserving mystery, scripted, manual, and surface events. |
| 004 | Repair Mod Manager Browser | Stable, on | Displays each mod’s latest thumbnail and screenshots, and properly formats descriptions, including HTML/Steam markup, Unicode, emoji, and clickable links. |
| 005 | Restore Dust Devils | Beta | Corrects Dust Devil spawn-chance handling, keeps natural scheduling tied to the surface map, and stops spawns once terraforming disables Dust Storms. |
| 006 | Restore Asteroid Visits | Beta | Stops ordinary rockets being mistaken for asteroid landers, which opened an empty asteroid-rocket selection screen. |
| 007 | Restore Soil Overlay | Beta | Keeps the solid soil overlay bound to the surface map instead of drawing surface soil data on another map. |
| 008 | Restore Saint Blessing | Beta | Applies each Saint's stacking Morale bonus to the Religious colonists in that Saint's Dome, correcting a mismatched trait label. |
| 009 | Restore SpaceY Description | Beta | Adds SpaceY's missing +20 maximum Drone Hub capacity to its sponsor description. Gameplay values are unchanged. |
| 010 | Restore Jumbo Cave Reinforcements | Beta | Releases construction sites stuck on unreachable Waste Rock, but only after a drone's normal approach to that exact blocker fails. |
| 011 | Restore Trade Rocket Protection | Beta | Stops RC Transports interrupting Universal Trade Rockets, matching the protection legacy trade and refugee rockets already had. |
| 012 | Restore Asteroid Lander Cargo Safety | Beta | Blocks asteroid Lander payload changes while Drones or passengers are still using the cargo ramp. |
| 013 | Restore Localized UI Text | Beta | Uses the game's existing official translations for the terraforming heading and the Universal Rocket's Back to Earth action. |
| 014 | Restore Track Demolition | Beta | Completes terminal track-element demolition and removes invalid Track remnants already stored in existing savegames. |
| 015 | Restore Clustered Lights | Beta | Stops night lights entering the renderer in a compressed staggered burst that can trigger the clustered-light assertion. |

The number is just the row's position in the list, so the list always runs from
001 with no gaps. Remove a fix and everything below it moves up a number; only
the fix's name and its saved on/off choice stay put.

## How it is built

```text
Code/SMRCommunityFixes.lua      the framework: config, logging, settings, registry, Options entry, checklist UI
Code/smrcf_<fix>.lua            one bug fix, completely self-contained
templates/                      the starting point for a new fix (not shipped in the mod)
tools/sync_mod.lua              registration and consistency checks used by CI
tools/publish/pdx_client.py     uploads to Paradox Mods; standard library only
tools/publish/PDX_API_NOTES.md  how that undocumented API works
```

Every fix is a standalone module: it uses the game's own globals and the vanilla
functions it repairs, and never calls into another file in this mod. It
registers itself by appending a descriptor to a plain global list, which the
framework adopts on load. That is what makes each fix reviewable on its own and
unable to break the others, and why deleting a fix's file removes its row and
its behaviour without touching anything else.

## Contributing

Anyone can add a fix, and adding one is a Lua-only job — no build step and no
tooling. Start from `templates/smrcf_TEMPLATE.lua`; its header walks you
through the whole process.

The repository has no single owner: everyone in the **SMR-community**
organisation can push to `main`, and there is no required review. Ask for an
invite at <smrcommunitymods@gmail.com> or open an issue.

**[CONTRIBUTING.md](CONTRIBUTING.md)** is the full guide: the one rule a fix must
obey, the descriptor contract, what a reviewer checks, and how to test in game.
**[DESCRIPTION.md](DESCRIPTION.md)** holds the complete requirements, the per-fix
behaviour specifications, and the manual test steps.

Three things then happen automatically:

* **Push a fix to a branch** → it is registered in `metadata.lua` and
  `items.lua` and the mod version is bumped, on that branch. Pull afterwards.
* **Open a pull request** → every Lua file is parsed, and your fix is checked
  for a duplicate id, a taken number, leftover template placeholders,
  diagnostics left on, and references to framework internals.
* **Merge it** → the same registration runs on `main`, as a safety net.

## Publishing

Players get the mod from Paradox Mods, and that page is updated from GitHub —
nobody needs the game installed to publish.

Merging does not publish. Pushing a version tag does:

```
git tag v4
git push origin v4
```

That packs `metadata.lua`, `items.lua`, `Code/` and `Images/` and uploads them.
So several fixes can land first and ship together as one release, when someone
decides it is ready.

Anyone who can push can tag, and no Paradox account is needed — CI holds the
credential, and nobody has to be logged in anywhere. A tag is the one action
here that reaches players. Before uploading, it re-runs the fix check and
refuses the tag unless the mod version has moved since the last release. You can
rehearse from the **Actions** tab with dry run on, which sends nothing but still
reports whether a tag would succeed.

Either way you find out what happened. A successful tag cuts a
[release](../../releases) naming the published version and carrying the exact
payload that was uploaded. A failed one opens an issue saying which step failed
and what the server said — and closes it once a later tag succeeds.

*Publishing to Paradox Mods* in [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## Reporting a bug in the game

A fix has to point at a confirmed cause in the game's own Lua source — no
guessing. If you have found a reproducible vanilla bug but not its cause, open an
issue describing how to reproduce it and which version you saw it on.

**Attach a savegame if you can.** Finding a cause means reproducing the bug, and
a save that already shows it turns hours of guesswork into minutes.

Saves live in the game's data folder, under `saves`:

```text
Windows   %APPDATA%\Surviving Mars Relaunched
```

Most are **too big to attach** — GitHub caps attachments at 25 MB, and a `.sav`
is already compressed, so zipping it barely helps. So:

* **Upload it anywhere and paste the link** — Drive, Dropbox, MEGA, whatever you
  already use. This is the normal way; nobody minds.
* **Under 25 MB?** Put it in a `.zip` and drag it onto the issue. GitHub refuses
  a bare `.sav`, but accepts a zip.
* **No file host?** Split the zip into parts below 25 MB, rename each part to end
  in `.zip`, and attach them all. Ugly, but it needs no account anywhere.

Also useful, in order: the newest log from `logs` in that same folder, the list
of other mods you had enabled, and a screenshot if the bug is visible.
