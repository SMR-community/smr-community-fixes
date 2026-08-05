-- Restore Clustered Lights - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): night lights are switched on through a thread that staggers
--   them over game time. When game time is compressed - high speed, or a forced
--   Dust Storm during Melt the Polar Caps - they reach the renderer in one burst
--   and the engine can trip its own assertion:
--     s_pLightsData->m_LightsIndexData.empty() == s_pLightsData->m_ClusterLights.empty()
--   The user has seen this with no mods installed, so it is an engine defect, not
--   a mod conflict.
-- Vanilla code:     NightLightsOn(map, total_delay) in Lua/NightLightObjects.lua
-- The repair:       for a delayed turn-on only, call the captured function once
--   with a delay of zero, so eligible lights enter the renderer in a single Lua
--   update instead of a compressed staggered burst. Instant refreshes
--   (total_delay == 0) are passed through untouched.
-- Left alone:       light classes, ownership, the light limit, colors, intensity,
--   shadows, renderer hr values, and NightLightsOff(). The assertion itself is not
--   suppressed - if it still fires, the log still shows it.
--
-- This one is still beta: it is reasoned from the vanilla source but has not been
-- proven to stop the assertion in a controlled in-game test.

-- What this fix is, as data. SMRCommunityFixes.lua reads this table and needs nothing
-- else from this file.
--   id              the key the player's on/off choice is saved under - permanent
--   number          the row number shown in the checklist - permanent, never reused
--   beta            true while the fix still needs testing in real games
--   versions        the game versions this repair was verified against
--   default_enabled whether a fresh install starts with it on
--   debug           this file's own diagnostics switch; false in a published build
--   label/description  plain text for the checklist row (rendered untranslated)
local FIX = {
	id = "restore_clustered_lights",
	number = 14,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Clustered Lights",
	description = "Prevents v1.0.7 night lights from entering the renderer in a compressed staggered burst that can trigger the clustered-light assertion.",
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

-- Records whether a game API this fix depends on was actually found. This is what
-- tells you, from a log alone, that a game patch renamed or removed the function
-- being wrapped rather than that the repair logic misbehaved.
local function log_api(api_name, available, data)
	local payload = data or {}
	payload.api = api_name
	payload.available = available == true
	log("INFO", "Checked API availability", payload)
end

-- Live state for this fix. It lives in a global so that a Lua reload - a Mod
-- Editor save, or the mod being reloaded in game - finds the existing table
-- instead of forgetting what is currently installed.
local RestoreClusteredLights = rawget(_G, "SMRCFRestoreClusteredLights")
if RestoreClusteredLights == nil then
	RestoreClusteredLights = { enabled = false }
	rawset(_G, "SMRCFRestoreClusteredLights", RestoreClusteredLights)
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

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_ClusteredLightsHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original = false,
		base_original = false,
		wrapper = false,
		in_wrapper = false,
		original_may_contain_wrapper = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_ClusteredLightsHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_current_function()
	local current = rawget(_G, "NightLightsOn")
	if current ~= Hooks.wrapper and type(current) == "function" then
		if type(Hooks.original) == "function" and current ~= Hooks.original then
			Hooks.original_may_contain_wrapper = true
		end
		Hooks.original = current
	end
	Hooks.base_original = Hooks.base_original or Hooks.original
	return type(Hooks.original) == "function"
end

capture_current_function()

-- Calls the vanilla NightLightsOn. Hooks.in_wrapper stops the repair from being
-- applied twice to one transition: the repair calls vanilla again with a different
-- delay, and without this flag that second call would re-enter the wrapper. A
-- missing captured function is a hard error rather than a silent no-op, because
-- there is no safe way to fake turning the lights on.
local function call_original(map, total_delay, ...)
	local original = Hooks.original_may_contain_wrapper == true and
		Hooks.base_original or Hooks.original
	if type(original) ~= "function" then
		error("Restore Clustered Lights has no captured vanilla NightLightsOn")
	end
	if Hooks.in_wrapper == true then return original(map, total_delay, ...) end

	Hooks.in_wrapper = true
	local ok, result = pcall(original, map, total_delay, ...)
	Hooks.in_wrapper = false
	if ok ~= true then error(result) end
	return result
end

-- The repair, and it is deliberately tiny: hand vanilla a delay of zero.
--
-- total_delay is how long vanilla spreads the night-light turn-on over. With a
-- positive delay it starts a game-time thread that adds lights in batches; under
-- compressed game time those batches land almost together and the engine's light
-- clustering can trip its own assertion. Delay zero takes vanilla's own synchronous
-- branch, so the same lights are added in a single Lua update.
--
-- Only a positive delay is changed. total_delay == 0 - the ordinary refresh - is
-- passed through untouched, and the log line is emitted only when a delay was
-- actually replaced, so the log shows exactly how often this fix acted.
function RestoreClusteredLights.ApplyAtomicTurnOn(map, total_delay, ...)
	local requested_delay = total_delay
	local applied_delay = total_delay
	if type(total_delay) == "number" and total_delay > 0 then
		applied_delay = 0
	end

	local result = call_original(map, applied_delay, ...)
	if applied_delay ~= requested_delay then
		log("INFO",
			"Bug fix invoked: applied a night-light attachment transition atomically",
			correction_context({
				repair = "atomic_night_light_turn_on",
				reason = "clustered_light_membership_race",
				requested_delay = requested_delay,
				applied_delay = applied_delay,
			}))
	end
	return result
end

-- The wrapper calls Hooks.impl only while the fix is enabled, so switching the fix
-- off restores vanilla's staggered behavior immediately and exactly.
Hooks.impl = RestoreClusteredLights.ApplyAtomicTurnOn

if type(Hooks.wrapper) ~= "function" then
	Hooks.wrapper = function(map, total_delay, ...)
		if Hooks.in_wrapper == true then
			return Hooks.base_original(map, total_delay, ...)
		end
		if Hooks.enabled == true and type(Hooks.impl) == "function" then
			return Hooks.impl(map, total_delay, ...)
		end
		local original = Hooks.original_may_contain_wrapper == true and
			Hooks.base_original or Hooks.original
		return original(map, total_delay, ...)
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreClusteredLights.InstallHook(reason)
	if capture_current_function() ~= true then
		log("ERROR",
			"Required v1.0.7 NightLightsOn API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	-- Plain assignment, never rawset. Inside a mod, _G is the mod's own
	-- environment table: reads fall through to the real globals, but a rawset
	-- writes only into that table, where the game would never see it. An
	-- assignment goes through ModEnvMeta.__newindex, which writes the real one.
	NightLightsOn = Hooks.wrapper
	Hooks.enabled = true
	RestoreClusteredLights.enabled = true
	log_api("NightLightsOn", true, {
		fix_id = FIX.id,
		reason = reason,
	})
	log("INFO",
		"Installed atomic night-light transition hook", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreClusteredLights.RestoreHook(reason)
	Hooks.enabled = false
	RestoreClusteredLights.enabled = false
	if rawget(_G, "NightLightsOn") == Hooks.wrapper then
		NightLightsOn = Hooks.original
	end
	log("INFO",
		"Restored captured night-light transition function", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreClusteredLights.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreClusteredLights.InstallHook(reason) end
	return RestoreClusteredLights.RestoreHook(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreClusteredLights.Quiesce(reason)
	return RestoreClusteredLights.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreClusteredLights.SetEnabled
FIX.quiesce = RestoreClusteredLights.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreClusteredLights
