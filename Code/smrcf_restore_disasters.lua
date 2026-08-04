-- Restore Disasters - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): when a meteor storm finishes, the game forgets to clear the
--   storm's "predicted" state. That state is a shared blocker every other natural
--   event checks, so cold waves, dust storms, natural rain, Cloud Seeding, Import
--   Greenhouse Gases, Melt the Polar Caps and Inner Light mirages quietly stop
--   happening for the rest of the game. A storm that rolls zero meteors and
--   returns early leaks the same state.
-- Vanilla code:     MeteorsDisaster() in Lua/Meteors.lua
-- The repair:       after vanilla's storm function returns, clear the leftover
--   DisasterMeteorStorm prediction - but only once nothing live is left: no
--   warning notification, no predicted meteor object, no meteor still falling.
-- Left alone:       meteor frequency, warning times, targeting, damage, FX, live
--   warnings, falling meteors, and Dust Devil behavior.

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
	id = "restore_disasters",
	number = 1,
	beta = false,
	versions = { ["1.0.7"] = true },
	default_enabled = true,
	debug = false,
	label = "Restore Disasters",
	description = "Removes stale completed-meteor-storm state that can block vanilla cold waves, dust storms, natural rain activation, Cloud Seeding, Import Greenhouse Gases, Melt the Polar Caps, and Inner Light mirages. It does not repair rain-specific bugs; use Restore Rains for those. Vanilla Dust Devil behavior is preserved.",
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
local RestoreDisasters = rawget(_G, "SMRCFRestoreDisasters")
if RestoreDisasters == nil then
	RestoreDisasters = {
		enabled = false,
		active_storm_calls = 0,
		game_epoch = 0,
	}
	rawset(_G, "SMRCFRestoreDisasters", RestoreDisasters)
end

if type(RestoreDisasters.active_storm_calls) ~= "number" then
	RestoreDisasters.active_storm_calls = 0
end
if type(RestoreDisasters.game_epoch) ~= "number" then
	RestoreDisasters.game_epoch = 0
end

local METEOR_NOTIFICATION_ID = "DisasterMeteorStorm"
local RESTORED_VANILLA_PATHS = {
	"cold_wave_scheduling",
	"dust_storm_scheduling",
	"natural_rain_activation",
	"cloud_seeding",
	"import_greenhouse_gases",
	"melt_the_polar_caps",
	"inner_light_mirages",
}
-- Do not hook Dust Devils. Once dust storms can run again, vanilla's DustStorm
-- message and HasDustStorm checks provide the intended stop/pause/resume policy.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_DisasterHooks or nil

local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 2 then
	Hooks = previous_hooks
else
	-- Migrate the pre-version-28 wrapper without calling its reload teardown.
	-- The shared enabled gate makes a non-outer legacy wrapper a pass-through.
	RestoreDisasters.enabled = false
	local current = rawget(_G, "MeteorsDisaster")
	if type(previous_hooks) == "table" and
		current == previous_hooks.fixed_meteors and
		type(previous_hooks.original_meteors) == "function"
	then
		MeteorsDisaster = previous_hooks.original_meteors
	end
	Hooks = {
		protocol = 2,
		enabled = false,
		original_meteors = rawget(_G, "MeteorsDisaster"),
		fixed_meteors = false,
	}
end

if Hooks.rebase_meteors == true then
	local current = rawget(_G, "MeteorsDisaster")
	if current ~= Hooks.fixed_meteors and type(current) == "function" then
		Hooks.original_meteors = current
		Hooks.original_meteors_may_contain_wrapper = true
	end
	Hooks.rebase_meteors = false
end

Hooks.base_original_meteors = Hooks.base_original_meteors or Hooks.original_meteors
Hooks.running_meteors = type(Hooks.running_meteors) == "table" and
	Hooks.running_meteors or {}
local main_call_key = Hooks.main_call_key
if main_call_key == nil then
	main_call_key = {}
	Hooks.main_call_key = main_call_key
end
-- Keeps a call's return values intact, including a nil in the middle, by recording
-- how many there were. Passing results through with plain `...` would silently
-- truncate at the first nil.
local function pack_values(...)
	return { n = select("#", ...), ... }
end
-- Identifies the game thread this call is running on.
--
-- Why a thread and not a simple boolean: a meteor storm runs inside a game-time
-- thread and can yield in the middle. A single "am I inside the repair" flag would
-- then still be raised when a *different* thread called in, and that thread's storm
-- would be sent down the fallback path by mistake. Keeping the guard per thread means
-- two storms in flight cannot interfere. main_call_key stands in for code that runs
-- outside any thread.
local function current_call_key()
	local current_thread = rawget(_G, "CurrentThread")
	if type(current_thread) == "function" then
		local ok, thread = pcall(current_thread)
		if ok == true and thread ~= nil and thread ~= false then return thread end
	end
	local running = type(coroutine) == "table" and coroutine.running
	local thread = type(running) == "function" and running() or nil
	return thread or main_call_key
end

-- Runs the repair, but sends a re-entrant call on the same thread to `fallback`
-- (plain vanilla) instead. That is what stops the repair calling itself when vanilla
-- triggers another storm from inside one.
--
-- The direct call is deliberate: MeteorsDisaster legitimately yields through Sleep and
-- thread waits, and wrapping it in pcall would put a C-call boundary in the middle of
-- a coroutine that is allowed to yield. Return values are packed so a nil among them
-- is not lost.
local function guarded_call(implementation, fallback, ...)
	local key = current_call_key()
	if Hooks.running_meteors[key] == true then return fallback(...) end
	Hooks.running_meteors[key] = true
	-- MeteorsDisaster may yield; keep the guard on a direct Lua call path.
	local result = pack_values(implementation(...))
	Hooks.running_meteors[key] = nil
	return table.unpack(result, 1, result.n)
end

if type(Hooks.fixed_meteors) ~= "function" then
	Hooks.fixed_meteors = function(meteors, meteors_type, pos, forced_pos, ...)
		if Hooks.enabled == true and type(Hooks.impl_meteors) == "function" then
			return guarded_call(Hooks.impl_meteors, Hooks.base_original_meteors,
				meteors, meteors_type, pos, forced_pos, ...)
		end
		if Hooks.original_meteors_may_contain_wrapper == true then
			return Hooks.base_original_meteors(meteors, meteors_type, pos, forced_pos, ...)
		end
		return Hooks.original_meteors(meteors, meteors_type, pos, forced_pos, ...)
	end
end
if type(shared) == "table" then shared.SMRCF_DisasterHooks = Hooks end

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

-- Shorthand for the one log line that matters: this fix actually corrected
-- something. Everything else it logs is optional detail.
local function log_correction(message, data)
	log("INFO", "Bug fix invoked: " .. message,
		correction_context(data))
end

-- The surface map. Several bugs in the game come from reading surface data while
-- the player happens to be looking at a cave or an asteroid, so this fix is
-- explicit about which map it means.
local function main_map()
	return rawget(_G, "MainMap")
end

-- The game's shared "a disaster is predicted" table. This is the blocker at the heart
-- of the bug: cold waves, dust storms, rain activation, Cloud Seeding, greenhouse
-- gases, Melt the Polar Caps and mirages all refuse to start while an entry for
-- another disaster is sitting in here.
local function prediction_table()
	return rawget(_G, "g_DisastersPredicted")
end

-- The actual repair: clear the leftover meteor-storm prediction.
--
-- It goes through the game's own RemoveDisasterNotifications rather than deleting the
-- table entry, so notification bookkeeping stays consistent with what vanilla would
-- have done had it cleaned up properly.
--
-- Two details worth copying into your own fix:
--   * the result is verified. If the entry is still there afterwards, that is an
--     ungated ERROR - a repair that quietly failed is worse than one that shouts.
--   * g_MeteorStorm is only reset when it is still true, which is the leak left by
--     vanilla's zero-meteor early return.
local function remove_meteor_prediction(reason, reset_storm_state)
	local map = main_map()
	local remove = rawget(_G, "RemoveDisasterNotifications")
	if not map or type(remove) ~= "function" then
		log("ERROR",
			"Cannot clear completed meteor storm state", {
				reason = reason,
				has_main_map = map ~= nil and map ~= false,
				has_remove_api = type(remove) == "function",
			})
		return false
	end

	local predictions = prediction_table()
	local had_prediction = type(predictions) == "table" and
		not not predictions[METEOR_NOTIFICATION_ID]
	remove(METEOR_NOTIFICATION_ID, map)
	local prediction_cleared = type(predictions) == "table" and
		predictions[METEOR_NOTIFICATION_ID] == nil
	if prediction_cleared ~= true then
		log("ERROR",
			"Meteor storm cleanup did not clear the shared disaster blocker", {
				reason = reason,
				had_prediction = had_prediction,
			})
		return false
	end

	local reset_active_flag = reset_storm_state == true and
		rawget(_G, "g_MeteorStorm") == true
	if reset_active_flag then g_MeteorStorm = false end

	log("INFO", "Cleared completed meteor storm state", {
		reason = reason,
		had_prediction = had_prediction,
		reset_stale_active_flag = reset_active_flag,
		restored_vanilla_paths = RESTORED_VANILLA_PATHS,
		dust_devil_behavior = "vanilla_dust_storm_exclusion",
	})
	if had_prediction == true or reset_active_flag == true then
		log_correction("cleared completed meteor-storm state that blocked disasters", {
			repair = "stale_completed_meteor_storm",
			reason = reason,
			had_prediction = had_prediction,
			reset_stale_active_flag = reset_active_flag,
			restored_vanilla_paths = RESTORED_VANILLA_PATHS,
		})
	end
	return true
end

-- Is a meteor warning still on screen? One of the three "is anything still live?"
-- questions asked before old state is cleared. Returns nil, not false, when the game
-- API is missing - the caller treats "unknown" as a reason not to touch anything.
local function has_live_meteor_notification(map)
	local find_notification = rawget(_G, "FindNotification")
	if type(find_notification) ~= "function" then return nil end
	return find_notification(METEOR_NOTIFICATION_ID, map) ~= nil
end

-- Is any meteor still predicted or still falling? Two questions in one: the game's
-- predicted-meteor list, and a count of BaseMeteor objects whose fall thread is still
-- running. Either one means the storm is genuinely alive and nothing may be cleared.
-- Returns nil when the game APIs are not available, which the caller treats as "do not
-- touch".
local function has_live_meteor_objects(map)
	local predicted = rawget(_G, "g_MeteorsPredicted")
	local is_valid = rawget(_G, "IsValid")
	if type(predicted) ~= "table" or type(is_valid) ~= "function" then
		return nil
	end
	for _, meteor in ipairs(predicted) do
		if is_valid(meteor) then return true end
	end

	local is_valid_thread = rawget(_G, "IsValidThread")
	if not map or type(map.MapCount) ~= "function" or
		type(is_valid_thread) ~= "function"
	then
		return nil
	end
	local falling = map:MapCount(true, "BaseMeteor", function(meteor)
		return meteor.fall_thread and is_valid_thread(meteor.fall_thread)
	end)
	return falling > 0
end

-- Repairs a save that already carries the stale state, and the most important thing
-- about it is how careful it is not to clear a real storm.
--
-- Read it as a chain of proofs. State is only cleared once every one of these holds:
--   * something stale is actually present (prediction entry or g_MeteorStorm),
--   * no wrapped storm call is currently in flight,
--   * no meteor warning notification is on screen,
--   * no meteor is predicted or still falling.
-- Anything unknown - a game API missing, a question that cannot be answered - ends in
-- "leave it alone" rather than a guess. That asymmetry is deliberate: wrongly clearing
-- a live storm would delete a warning the player is reacting to, while wrongly keeping
-- stale state only means the fix repairs it on the next pass.
function RestoreDisasters.ReconcileState(reason)
	if RestoreDisasters.enabled ~= true then
		return true
	end

	local map = main_map()
	if not map then
		log("INFO",
			"Meteor storm reconciliation deferred until map state exists", {
				reason = reason,
			})
		return true
	end

	local predictions = prediction_table()
	if type(predictions) ~= "table" then
		log("ERROR",
			"Disaster prediction table is unavailable during reconciliation", {
				reason = reason,
			})
		return false
	end

	local predicted = predictions[METEOR_NOTIFICATION_ID] == true
	local storm_flag = rawget(_G, "g_MeteorStorm") == true
	if predicted ~= true and storm_flag ~= true then return true end
	if RestoreDisasters.active_storm_calls > 0 then
		log("INFO", "Preserved active wrapped meteor storm", {
			reason = reason,
			active_storm_calls = RestoreDisasters.active_storm_calls,
		})
		return true
	end

	local live_notification = has_live_meteor_notification(map)
	if live_notification == nil then
		log("ERROR",
			"FindNotification is unavailable during reconciliation", {
				reason = reason,
			})
		return false
	end
	if live_notification == true then
		log("INFO", "Preserved live meteor storm state", {
			reason = reason,
			proof = "notification",
		})
		return true
	end

	if storm_flag == true then
		local live_objects = has_live_meteor_objects(map)
		if live_objects == nil then
			log("WARN",
				"Could not prove saved meteor storm state is stale", {
					reason = reason,
				})
			return true
		end
		if live_objects == true then
			log("INFO", "Preserved active meteor objects", {
				reason = reason,
				proof = "predicted_or_falling_meteor",
			})
			return true
		end
	end

	log("WARN", "Repairing stale meteor storm state", {
		reason = reason,
		predicted = predicted,
		storm_flag = storm_flag,
	})
	return remove_meteor_prediction(reason, storm_flag)
end

-- The repair for new storms: let vanilla's storm run to completion, then clean up
-- after it.
--
-- Three details carry the weight here:
--   * active_storm_calls counts storms in flight, so overlapping storms only clean up
--     once the last one has returned;
--   * game_epoch is compared before and after. If the player quit to the menu or
--     loaded a save while the storm was running, this is a different game and the
--     counter from the old one must not be touched;
--   * only meteors_type == "storm" is treated this way. Single meteor impacts do not
--     set the shared blocker and are left completely alone.
Hooks.impl_meteors = function(meteors, meteors_type, pos, forced_pos, ...)
	local is_storm = meteors_type == "storm"
	local call_epoch = RestoreDisasters.game_epoch
	if is_storm then
		RestoreDisasters.active_storm_calls =
			RestoreDisasters.active_storm_calls + 1
	end
	local result = Hooks.original_meteors(meteors, meteors_type, pos, forced_pos, ...)
	local same_game = call_epoch == RestoreDisasters.game_epoch
	if is_storm and same_game then
		RestoreDisasters.active_storm_calls =
			math.max(RestoreDisasters.active_storm_calls - 1, 0)
	end
	if RestoreDisasters.enabled == true and is_storm and
		same_game and RestoreDisasters.active_storm_calls == 0
	then
		remove_meteor_prediction("meteor_storm_returned", true)
	end
	return result
end

-- Called when a game starts or ends (see FIX.events). Bumping game_epoch invalidates
-- any storm call still suspended from the previous game, so when such a call finally
-- returns it recognises that it belongs to a game that no longer exists and does not
-- clean up state in the new one.
function RestoreDisasters.ResetTransientState(reason)
	RestoreDisasters.game_epoch = RestoreDisasters.game_epoch + 1
	RestoreDisasters.active_storm_calls = 0
	log("INFO", "Reset transient meteor hook state", {
		reason = reason,
		game_epoch = RestoreDisasters.game_epoch,
	})
	return true
end

-- Checks the game functions this fix needs before installing anything, and logs the
-- result. Two groups:
--   * the ones the repair itself calls - without these it refuses to install;
--   * the "consumers", the vanilla systems that were blocked by the stale state.
--     Those are only recorded, not required. They are what a log reader needs to see
--     in order to trust that clearing the blocker actually unblocks something.
local function required_apis_available()
	local available = type(Hooks.original_meteors) == "function" and
		type(rawget(_G, "RemoveDisasterNotifications")) == "function" and
		type(rawget(_G, "FindNotification")) == "function"
	log_api("Restore Disasters hook set", available, {
		has_MeteorsDisaster = type(Hooks.original_meteors) == "function",
		has_RemoveDisasterNotifications =
			type(rawget(_G, "RemoveDisasterNotifications")) == "function",
		has_FindNotification = type(rawget(_G, "FindNotification")) == "function",
	})
	local consumers = {
		has_IsDisasterPredicted =
			type(rawget(_G, "IsDisasterPredicted")) == "function",
		has_WaitCurrentDisaster =
			type(rawget(_G, "WaitCurrentDisaster")) == "function",
		has_RainsDisasterActivation =
			type(rawget(_G, "RainsDisasterActivation")) == "function",
		has_HasDustStorm = type(rawget(_G, "HasDustStorm")) == "function",
		has_StopDustDevils = type(rawget(_G, "StopDustDevils")) == "function",
		has_DreamStartMirages =
			type(rawget(_G, "Dream_StartMirages")) == "function",
	}
	local consumers_available = true
	for _, present in pairs(consumers) do
		if present ~= true then consumers_available = false end
	end
	log_api("Restore Disasters vanilla consumers", consumers_available,
		consumers)
	return available
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreDisasters.InstallHook(reason)
	if required_apis_available() ~= true then
		log("ERROR",
			"Required v1.0.7 meteor APIs are unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end

	local current = rawget(_G, "MeteorsDisaster")
	if current ~= Hooks.original_meteors and current ~= Hooks.fixed_meteors then
		if type(current) ~= "function" then
			log("ERROR",
				"MeteorsDisaster disappeared during hook installation", {
					reason = reason,
				})
			return false
		end
		Hooks.original_meteors = current
		Hooks.original_meteors_may_contain_wrapper = true
		log("INFO",
			"Rebased stable hook after a Lua global refresh", {
				reason = reason,
			})
	end
	MeteorsDisaster = Hooks.fixed_meteors
	Hooks.rebase_meteors = false
	RestoreDisasters.enabled = true
	Hooks.enabled = true
	log("INFO", "Installed meteor storm cleanup hook", {
		reason = reason,
	})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreDisasters.RestoreHook(reason)
	RestoreDisasters.enabled = false
	Hooks.enabled = false
	local current = rawget(_G, "MeteorsDisaster")
	if current == Hooks.fixed_meteors then
		MeteorsDisaster = Hooks.original_meteors
	elseif current ~= Hooks.original_meteors then
		Hooks.rebase_meteors = true
		log("INFO",
			"Disabled an inner hook gate while preserving the outer function", {
				reason = reason,
			})
	end
	log("INFO", "Restored captured meteor disaster function", {
		reason = reason,
	})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreDisasters.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then
		if RestoreDisasters.InstallHook(reason) ~= true then return false end
		return RestoreDisasters.ReconcileState(reason)
	end
	return RestoreDisasters.RestoreHook(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreDisasters.Quiesce(reason)
	return RestoreDisasters.SetEnabled(false, reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreDisasters.SetEnabled
FIX.quiesce = RestoreDisasters.Quiesce
FIX.events = {
	GameStateStarting = RestoreDisasters.ResetTransientState,
	DoneGame = RestoreDisasters.ResetTransientState,
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

return RestoreDisasters
