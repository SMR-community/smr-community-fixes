-- Restore No Disasters Cave-in Protection - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): the repeating underground marsquake skips the NoDisasters
--   game-rule check that every other natural disaster scheduler makes, so an
--   underground colony keeps suffering marsquakes and cave-ins in a game started
--   with No Disasters.
-- Vanilla code:     the underground marsquake repeat condition in Lua/Marsquake.lua
--   (compare the surface path, which does check IsGameRuleActive("NoDisasters"))
-- The repair:       apply the same rule check to that one repeat condition, and
--   stop a periodic thread that is already running - including one loaded from a
--   save made before the fix existed.
-- Left alone:       mystery, scripted, cheat/manual and surface quakes and
--   cave-ins. The No Disasters rule deliberately does not cover mystery events.

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
	id = "restore_no_disasters_cave_ins",
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore No Disasters Cave-in Protection",
	description = "Stops v1.0.7's periodic underground marsquakes and cave-ins when the No Disasters rule is active, while preserving mystery, scripted, manual, and surface events.",
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
local RestoreNoDisastersCaveIns = rawget(_G, "SMRCFRestoreNoDisastersCaveIns")
if RestoreNoDisastersCaveIns == nil then
	RestoreNoDisastersCaveIns = { enabled = false }
	rawset(_G, "SMRCFRestoreNoDisastersCaveIns", RestoreNoDisastersCaveIns)
end

local REPEAT_NAME = "UndergroundMarsquake"
local REPEAT_CONDITION = 4
local REPEAT_CLASS = 5

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

-- A table with weak keys: entries disappear once the game object used as the key
-- is collected. Per-object bookkeeping can be recorded here without keeping a
-- destroyed object alive or leaking state across a save/load.
local function weak_keys()
	return setmetatable({}, { __mode = "k" })
end

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_state = type(shared) == "table" and
	shared.SMRCF_NoDisastersCaveInsState or nil
local State
if type(previous_state) == "table" and previous_state.protocol == 2 then
	State = previous_state
	State.suppressed_maps = State.suppressed_maps or weak_keys()
	State.reported_maps = State.reported_maps or weak_keys()
else
	State = {
		protocol = 2,
		enabled = false,
		original_condition = false,
		base_original_condition = false,
		wrapper = false,
		in_condition = false,
		suppressed_maps = weak_keys(),
		reported_maps = weak_keys(),
	}
end
if type(shared) == "table" then
	shared.SMRCF_NoDisastersCaveInsState = State
end

-- The game's own record for this periodic event. PeriodicRepeatInfo is how the game
-- schedules recurring things per map; the entry holds, among other fields, the
-- condition function that decides whether the repeat applies to a given map. That
-- condition is the single thing this fix replaces.
local function repeat_info()
	local repeats = rawget(_G, "PeriodicRepeatInfo")
	return type(repeats) == "table" and repeats[REPEAT_NAME] or nil
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_condition()
	local info = repeat_info()
	if type(info) ~= "table" or info[REPEAT_CLASS] ~= "Map" then return false end
	local current = info[REPEAT_CONDITION]
	if current ~= State.wrapper and type(current) == "function" then
		State.original_condition = current
		State.base_original_condition =
			State.base_original_condition or current
	end
	return type(State.original_condition) == "function"
end

-- The one question vanilla forgot to ask here. Every other natural disaster
-- scheduler calls IsGameRuleActive("NoDisasters"); the underground marsquake repeat
-- does not, which is the whole bug.
local function no_disasters_active()
	local is_active = rawget(_G, "IsGameRuleActive")
	return type(is_active) == "function" and is_active("NoDisasters") == true
end

-- A readable name for a map, for the log only. Underground maps do not all carry the
-- same fields, so this tries id, then MapType, then Environment, and finally the raw
-- handle.
local function map_id(map)
	local mapdata = map and map.mapdata
	return mapdata and (mapdata.id or mapdata.MapType or mapdata.Environment) or
		(map and map.handle)
end

-- Reports a correction at most once per situation. Without this throttle the same
-- line would be written every frame the guarded condition holds.
local function report_suppressed(map, reason, had_thread)
	State.suppressed_maps[map] = true
	if State.reported_maps[map] == true then return end
	State.reported_maps[map] = true
	log("INFO",
		"Bug fix invoked: suppressed a periodic underground marsquake while No Disasters is active",
		correction_context({
			repair = "no_disasters_underground_marsquake_scheduler",
			reason = reason,
			map = map_id(map),
			active_thread_removed = had_thread == true,
		}))
end

-- Asks vanilla's captured condition whether the repeat applies to this map. The
-- in_condition flag keeps a nested call out of the repair; pcall only guarantees the
-- flag is lowered again and the error is re-raised unchanged.
local function call_original_condition(map)
	if State.in_condition == true then
		return State.base_original_condition(map)
	end
	State.in_condition = true
	local ok, result = pcall(State.original_condition, map)
	State.in_condition = false
	if ok ~= true then error(result) end
	return result
end

-- The repair, in one sentence: vanilla's answer, and then "no" if the No Disasters
-- rule is on. Nothing else about the schedule changes - timing, strength and location
-- all stay vanilla's business. In a game without the rule this returns exactly what
-- vanilla returned.
local function corrected_condition(map)
	local applies = call_original_condition(map)
	if State.enabled == true and applies == true and
		no_disasters_active() == true
	then
		report_suppressed(map, "repeat_condition", false)
		return false
	end
	return applies
end

if type(State.wrapper) ~= "function" then
	State.wrapper = corrected_condition
end

-- Is this game thread still running? Threads die on their own when a game ends or
-- a save is loaded, so a stored thread handle can never be trusted without asking.
local function thread_is_valid(thread)
	local is_valid = rawget(_G, "IsValidThread")
	if type(is_valid) == "function" then return is_valid(thread) == true end
	return thread ~= nil and thread ~= false
end

-- Handles the case the corrected condition alone cannot: a save where the periodic
-- thread is *already running*. The condition is only consulted when a repeat is
-- started, so an existing underground colony would keep its scheduler until the game
-- ended. Here each loaded map that the repeat applies to has its running thread
-- deleted through the game's own DeleteThread, and the entry is cleared so the game
-- does not hold a dead handle.
--
-- Only threads this fix suppressed are recorded, so disabling can restart exactly
-- those and nothing else.
local function reconcile_loaded_maps(reason)
	local maps = rawget(_G, "LoadedMaps")
	if type(maps) ~= "table" or no_disasters_active() ~= true then return true end
	local delete_thread = rawget(_G, "DeleteThread")
	if type(delete_thread) ~= "function" then
		log("ERROR",
			"Cannot suppress the active underground marsquake scheduler; DeleteThread is unavailable", {
				reason = reason,
			})
		return false
	end

	for _, map in ipairs(maps) do
		if call_original_condition(map) == true then
			local threads = map and map.RepeatThreads
			local thread = type(threads) == "table" and
				threads[REPEAT_NAME] or nil
			local had_thread = thread_is_valid(thread)
			if had_thread then
				delete_thread(thread)
				threads[REPEAT_NAME] = nil
			end
			report_suppressed(map, reason, had_thread)
		end
	end
	return true
end

-- Turn the fix on: swap the repeat's condition for the corrected one, then deal with
-- any scheduler already running in the loaded save.
--
-- Note the rollback. If the second step fails, the original condition is put straight
-- back and the fix reports failure, so the game is never left with our condition
-- installed but only half the work done.
function RestoreNoDisastersCaveIns.Apply(reason)
	if capture_condition() ~= true then
		log("ERROR",
			"Required v1.0.7 underground marsquake repeat is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	local info = repeat_info()
	State.enabled = true
	RestoreNoDisastersCaveIns.enabled = true
	info[REPEAT_CONDITION] = State.wrapper
	if reconcile_loaded_maps(reason) ~= true then
		info[REPEAT_CONDITION] = State.original_condition
		State.enabled = false
		RestoreNoDisastersCaveIns.enabled = false
		return false
	end
	log("INFO",
		"Installed No Disasters underground-marsquake scheduler gate", {
			reason = reason,
		})
	return true
end

-- Turn the fix off, and put back what was taken away. Two halves:
--   1. restore the captured condition, but only while our wrapper is still the one
--      installed, so a third-party wrapper on top is not destroyed;
--   2. restart the periodic thread through the game's own ObjRepeatRestart, but only
--      on the maps this fix actually suppressed and only where vanilla's condition
--      says the repeat belongs. A map that was already quiet stays quiet.
-- The tracking tables are then emptied, so a later enable starts from a clean slate.
function RestoreNoDisastersCaveIns.Restore(reason)
	State.enabled = false
	RestoreNoDisastersCaveIns.enabled = false
	local info = repeat_info()
	if type(info) == "table" and
		info[REPEAT_CONDITION] == State.wrapper and
		type(State.original_condition) == "function"
	then
		info[REPEAT_CONDITION] = State.original_condition
	end

	local restart = rawget(_G, "ObjRepeatRestart")
	local is_valid = rawget(_G, "IsValidThread")
	local maps = rawget(_G, "LoadedMaps")
	if type(restart) == "function" and type(maps) == "table" and
		type(State.original_condition) == "function"
	then
		for _, map in ipairs(maps) do
			if State.suppressed_maps[map] == true and
				call_original_condition(map) == true
			then
				local threads = map and map.RepeatThreads
				local thread = type(threads) == "table" and
					threads[REPEAT_NAME] or nil
				local valid
				if type(is_valid) == "function" then
					valid = is_valid(thread) == true
				else
					valid = thread ~= nil and thread ~= false
				end
				if valid ~= true then restart(map, REPEAT_NAME) end
			end
		end
	end
	State.suppressed_maps = weak_keys()
	State.reported_maps = weak_keys()
	log("INFO",
		"Restored the captured underground-marsquake repeat condition", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreNoDisastersCaveIns.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreNoDisastersCaveIns.Apply(reason) end
	return RestoreNoDisastersCaveIns.Restore(reason)
end

-- Called by the framework when a game starts or loads (see FIX.events). A new save
-- may bring its own already-running scheduler, so the reconciliation is repeated for
-- the maps that were just loaded.
function RestoreNoDisastersCaveIns.OnGameStateStarting(reason)
	State.reported_maps = weak_keys()
	if State.enabled == true then
		return reconcile_loaded_maps(reason or "GameStateStarting")
	end
	return true
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreNoDisastersCaveIns.Quiesce(reason)
	return RestoreNoDisastersCaveIns.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreNoDisastersCaveIns.SetEnabled
FIX.quiesce = RestoreNoDisastersCaveIns.Quiesce
FIX.events = {
	GameStateStarting =
		RestoreNoDisastersCaveIns.OnGameStateStarting,
}

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreNoDisastersCaveIns
