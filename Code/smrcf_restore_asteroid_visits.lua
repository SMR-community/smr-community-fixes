-- Restore Asteroid Visits - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): the check for "can we visit an asteroid" groups its and/or
--   conditions wrongly, so an ordinary rocket sitting in orbit counts as an
--   asteroid lander. The asteroid rocket selector then opens with nothing in it.
-- Vanilla code:     PlanetaryAsteroidVisitPossible() in Lua/PlanetaryView.lua
-- The repair:       require the Refuel, WaitLaunchOrder and LoadAndLaunch cases
--   to actually belong to a LanderRocketBase before they count.
-- Left alone:       every genuine lander and universal-rocket result, and any
--   answer another mod contributes that is not this false positive.

-- What this fix is, as data. SMRCommunityFixes.lua reads this table and needs nothing
-- else from this file.
--   id              the key the player's on/off choice is saved under - permanent
--   number          left out on purpose: the framework numbers the rows by
--                   list position, so removing a fix renumbers the rest
--   beta            true while the fix still needs testing in real games
--   versions        the game versions this repair was verified against
--   default_enabled whether a fresh install starts with it on
--   debug           this file's own diagnostics switch; false in a published build
--   label/description  plain text for the checklist row (rendered untranslated)
local FIX = {
	id = "restore_asteroid_visits",
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Asteroid Visits",
	description = "Prevents ordinary rockets from being mistaken for asteroid landers, avoiding an empty asteroid-rocket selection screen in v1.0.7.",
}

-- Renders any Lua value as one readable log fragment: strings quoted, numbers and
-- booleans plain, tables as {key=value, ...}. Nesting depth and key count are
-- capped so one unexpectedly large table cannot flood the game log.
local function describe(value, depth)
	depth = depth or 0
	local value_type = type(value)
	if value_type == "string" then return string.format("%q", value) end
	if value_type ~= "table" then return tostring(value) end
	if depth > 3 then return "<table>" end
	local parts = {}
	local count = 0
	for key, item in pairs(value) do
		count = count + 1
		if count > 20 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = tostring(key) .. "=" .. describe(item, depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- The entire logging facility for this fix, built on the game's own ModLog. INFO
-- and WARN appear only while FIX.debug is true, so a published build is silent;
-- ERROR is never gated, because a real failure must always be visible. print() is
-- the fallback when ModLog is unavailable, such as in an offline test harness.
local function log(level, message, data)
	if level ~= "ERROR" and FIX.debug ~= true then return end
	local text = "[SMR Community Fixes][" .. level .. "][" .. FIX.id .. "] " .. tostring(message)
	if data ~= nil then text = text .. " " .. describe(data) end
	local mod_log = rawget(_G, "ModLog")
	if type(mod_log) == "function" then mod_log(text) else print(text) end
end

-- Live state for this fix. It lives in a global so that a Lua reload - a Mod
-- Editor save, or the mod being reloaded in game - finds the existing table
-- instead of forgetting what is currently installed.
local RestoreAsteroidVisits = rawget(_G, "SMRCFRestoreAsteroidVisits")
if RestoreAsteroidVisits == nil then
	RestoreAsteroidVisits = { enabled = false }
	rawset(_G, "SMRCFRestoreAsteroidVisits", RestoreAsteroidVisits)
end

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_AsteroidVisitHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original = rawget(_G, "PlanetaryAsteroidVisitPossible"),
		wrapper = false,
		in_call = false,
	}
end

local current = rawget(_G, "PlanetaryAsteroidVisitPossible")
if current ~= Hooks.wrapper and type(current) == "function" then
	if current ~= Hooks.original then Hooks.original_may_contain_wrapper = true end
	Hooks.original = current
end
Hooks.base_original = Hooks.base_original or Hooks.original

if type(Hooks.wrapper) ~= "function" then
	Hooks.wrapper = function(...)
		if Hooks.in_call == true then return Hooks.base_original(...) end
		if Hooks.enabled == true and type(Hooks.impl) == "function" then
			return Hooks.impl(...)
		end
		if Hooks.original_may_contain_wrapper == true then
			return Hooks.base_original(...)
		end
		return Hooks.original(...)
	end
end
if type(shared) == "table" then
	shared.SMRCF_AsteroidVisitHooks = Hooks
end

-- Stamps a log payload with this fix's identity and the current game time. Every
-- "Bug fix invoked:" line therefore says which fix acted and when it acted, in
-- Sols and hours, which is what makes a report from a player usable.
local function correction_context(data)
	data = data or {}
	data.fix_id = FIX.id
	data.fix_number = FIX.number
	data.fix_name = FIX.label
	local game_time_fn = rawget(_G, "GameTime")
	local game_time = type(game_time_fn) == "function" and game_time_fn() or nil
	data.game_time = game_time
	local constants = rawget(_G, "const")
	local day = type(constants) == "table" and constants.DayDuration or nil
	local hour = type(constants) == "table" and constants.HourDuration or nil
	if type(game_time) == "number" and type(day) == "number" and day > 0 then
		data.sol = math.floor(game_time / day) + 1
		if type(hour) == "number" and hour > 0 then
			data.hour = math.floor((game_time % day) / hour)
		end
	end
	return data
end

-- Calls the vanilla availability check. Hooks.in_call is raised for the duration so
-- that if vanilla reaches this same function again, the wrapper passes it straight
-- through instead of recursing. pcall only guarantees the flag comes back down; the
-- error is re-raised unchanged, so a real vanilla failure is never swallowed.
local function call_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

-- The repair: re-run vanilla's own rocket scan, this time with the checks grouped
-- correctly, and only overrule vanilla when the difference is the known bug.
--
-- Vanilla answers "yes, an asteroid visit is possible" if any rocket is
--   * a UniversalRocketBase waiting at the colony or on Earth, or
--   * a LanderRocketBase refuelling, waiting to launch, or loading with no target.
-- Because of how those conditions are grouped, the second set is also accepted from
-- a rocket that is *not* a lander - so an ordinary rocket waiting to launch opens an
-- empty asteroid selector.
--
-- This walks the same rocket list and classifies each one:
--   valid_rocket        a rocket that genuinely qualifies (vanilla was right)
--   precedence_offender a non-lander that only matched through the bug
-- If nothing genuinely qualifies and at least one offender was found, the answer is
-- corrected to false. If anything genuinely qualifies, vanilla's answer stands - so
-- the fix never hides a real asteroid visit.
--
-- Note the early return: when vanilla already said "no", there is nothing to
-- correct. And when the game's own tables are not ready yet, vanilla's answer is
-- returned untouched rather than guessed at.
function RestoreAsteroidVisits.CorrectedPredicate(...)
	local original_result = call_original(...)
	if original_result ~= true then return original_result end

	local city = rawget(_G, "MainCity")
	local labels = city and city.labels
	local rockets = labels and labels.AllRockets
	local is_kind = rawget(_G, "IsKindOf")
	local spots = rawget(_G, "MarsScreenLandingSpots")
	if type(rockets) ~= "table" or type(is_kind) ~= "function" or
		type(spots) ~= "table"
	then
		return original_result
	end

	local valid_rocket = false
	local precedence_offender = false
	for _, rocket in ipairs(rockets) do
		if is_kind(rocket, "UniversalRocketBase") then
			if not rocket.arrival_loc and
				((rocket.command == "CmdWaitOrder" and
					rocket.departure_loc == spots.OurColony) or
				(rocket.command == "CmdOnEarth" and
					rocket.departure_loc == spots.Earth))
			then
				valid_rocket = true
				break
			end
		elseif is_kind(rocket, "LanderRocketBase") then
			if rocket.command == "Refuel" or
				rocket.command == "WaitLaunchOrder" or
				(rocket.command == "LoadAndLaunch" and not rocket.target_spot)
			then
				valid_rocket = true
				break
			end
		elseif rocket.command == "WaitLaunchOrder" or
			(rocket.command == "LoadAndLaunch" and not rocket.target_spot)
		then
			precedence_offender = true
		end
	end

	if valid_rocket ~= true and precedence_offender == true then
		log("INFO",
			"Bug fix invoked: rejected a non-lander from asteroid visit availability",
			correction_context({
				repair = "asteroid_lander_predicate",
				reason = "vanilla_boolean_precedence",
			}))
		return false
	end
	return original_result
end

-- The wrapper calls Hooks.impl only while the fix is enabled. Pointing it at the
-- repair here, instead of installing the repair as the global itself, is what makes
-- the toggle instant and the restore exact.
Hooks.impl = RestoreAsteroidVisits.CorrectedPredicate

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreAsteroidVisits.InstallHook(reason)
	local current_fn = rawget(_G, "PlanetaryAsteroidVisitPossible")
	if type(current_fn) ~= "function" then
		log("ERROR",
			"Required v1.0.7 asteroid visit API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	if current_fn ~= Hooks.original and current_fn ~= Hooks.wrapper then
		Hooks.original = current_fn
		Hooks.original_may_contain_wrapper = true
	end
	PlanetaryAsteroidVisitPossible = Hooks.wrapper
	RestoreAsteroidVisits.enabled = true
	Hooks.enabled = true
	log("INFO",
		"Installed asteroid visit predicate hook", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreAsteroidVisits.RestoreHook(reason)
	RestoreAsteroidVisits.enabled = false
	Hooks.enabled = false
	if rawget(_G, "PlanetaryAsteroidVisitPossible") == Hooks.wrapper then
		PlanetaryAsteroidVisitPossible = Hooks.original
	end
	log("INFO",
		"Restored captured asteroid visit predicate", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreAsteroidVisits.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreAsteroidVisits.InstallHook(reason) end
	return RestoreAsteroidVisits.RestoreHook(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreAsteroidVisits.Quiesce(reason)
	return RestoreAsteroidVisits.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreAsteroidVisits.SetEnabled
FIX.quiesce = RestoreAsteroidVisits.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreAsteroidVisits
