-- Restore Rains - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): rain scheduling can deadlock. The activation step gives up
--   when another disaster is active or predicted, but the scheduler loop keeps
--   waiting for a rain that will now never start, so natural rain and Cloud
--   Seeding never fire again. Saved games can also carry "rain in progress" state
--   for a rain that already ended.
-- Vanilla code:     RainsDisasterLoop(), RainProcedure() and WaitCurrentDisaster()
--   in Lua/TerraformingDisasters.lua
-- The repair:       replace those three with versions that retry once the blocker
--   clears, and clear saved rain state only when it can be proven stale.
-- Left alone:       rain amounts, thresholds, timings, notifications, soil and
--   vegetation effects, toxic pools, FX, and the Cloud Seeding outcome.
--
-- This is the largest fix in the mod because rain runs across several game-time
-- threads. Read RunScheduler-style loops with that in mind: the code has to keep
-- working when the game is saved, loaded or paused in the middle of one.

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
	id = "restore_rains",
	beta = false,
	versions = { ["1.0.7"] = true },
	default_enabled = true,
	debug = false,
	label = "Restore Rains",
	description = "Restores natural and Cloud Seeding rainfall when vanilla rain scheduling becomes stalled or its saved state is stale.",
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
local RestoreRains = rawget(_G, "SMRCFRestoreRains")
if RestoreRains == nil then
	RestoreRains = {
		enabled = false,
		pending_rebuild = false,
		rebuild_in_progress = false,
		scheduler_modes = {},
		next_attempt_times = {},
		next_start_times = {},
	}
	rawset(_G, "SMRCFRestoreRains", RestoreRains)
end

if type(RestoreRains.next_attempt_times) ~= "table" then
	RestoreRains.next_attempt_times = {}
end
if type(RestoreRains.next_start_times) ~= "table" then
	RestoreRains.next_start_times = {}
end

local RAIN_TYPES = { "toxic", "normal" }
local PREDICTION_IDS = {
	"DisasterColdWave",
	"DisasterDustStorm",
	"DisasterMeteorStorm",
	"DisasterToxicRains",
}

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_RainHooks or nil

-- Assigns one of the three rain globals. It is written as an if-chain rather than
-- `_G[name] = value` on purpose: mod code runs in a sandboxed environment where
-- creating globals dynamically is refused, so each global this fix may replace is
-- named explicitly here.
local function set_global_hook(name, value)
	if name == "RainsDisasterLoop" then
		RainsDisasterLoop = value
	elseif name == "RainProcedure" then
		RainProcedure = value
	elseif name == "WaitCurrentDisaster" then
		WaitCurrentDisaster = value
	end
end

local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 2 then
	Hooks = previous_hooks
else
	-- Migrate the pre-version-28 wrappers. Disable their shared gate first, then
	-- unwrap them only when they are still the outermost function. If the game
	-- has already refreshed its Lua globals there is nothing left to unwrap.
	RestoreRains.enabled = false
	for _, spec in ipairs({
		{ "RainsDisasterLoop", "fixed_loop", "original_loop" },
		{ "RainProcedure", "fixed_procedure", "original_procedure" },
		{ "WaitCurrentDisaster", "fixed_wait", "original_wait" },
	}) do
		local current = rawget(_G, spec[1])
		local wrapper = type(previous_hooks) == "table" and previous_hooks[spec[2]]
		local original = type(previous_hooks) == "table" and previous_hooks[spec[3]]
		if current == wrapper and type(original) == "function" then
			set_global_hook(spec[1], original)
		end
	end
	Hooks = {
		protocol = 2,
		enabled = false,
		original_loop = rawget(_G, "RainsDisasterLoop"),
		original_procedure = rawget(_G, "RainProcedure"),
		original_wait = rawget(_G, "WaitCurrentDisaster"),
		fixed_loop = false,
		fixed_procedure = false,
		fixed_wait = false,
	}
end

-- Re-captures a vanilla function after the game has rebuilt its Lua globals.
--
-- When the game reloads its scripts, the global no longer points at our wrapper - it
-- points at a brand new vanilla function, and the one we captured earlier is stale. A
-- "rebase" flag is set when that is suspected, and this re-reads the current value as the
-- new original. The `_may_contain_wrapper` marker records that the captured value might
-- itself be someone else's wrapper, so later calls use the pre-wrap version and do not
-- walk the same chain twice.
local function rebase_after_global_refresh(name, wrapper_key, original_key, pending_key)
	if Hooks[pending_key] ~= true then return end
	local current = rawget(_G, name)
	if current ~= Hooks[wrapper_key] and type(current) == "function" then
		Hooks[original_key] = current
		Hooks[original_key .. "_may_contain_wrapper"] = true
	end
	Hooks[pending_key] = false
end

rebase_after_global_refresh("RainsDisasterLoop", "fixed_loop", "original_loop",
	"rebase_loop")
rebase_after_global_refresh("RainProcedure", "fixed_procedure", "original_procedure",
	"rebase_procedure")
rebase_after_global_refresh("WaitCurrentDisaster", "fixed_wait", "original_wait",
	"rebase_wait")

Hooks.base_original_loop = Hooks.base_original_loop or Hooks.original_loop
Hooks.base_original_procedure = Hooks.base_original_procedure or Hooks.original_procedure
Hooks.base_original_wait = Hooks.base_original_wait or Hooks.original_wait
Hooks.running_loop = type(Hooks.running_loop) == "table" and Hooks.running_loop or {}
Hooks.running_procedure = type(Hooks.running_procedure) == "table" and
	Hooks.running_procedure or {}
Hooks.running_wait = type(Hooks.running_wait) == "table" and Hooks.running_wait or {}

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
-- Identifies the game thread this call is running on. Rain code runs in several
-- game-time threads at once, so the re-entry guard below has to be per thread: a single
-- boolean would look "busy" to an unrelated thread and send its rain down the wrong path.
-- main_call_key stands in for code running outside any thread.
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

-- Runs one of the corrected rain functions, sending a re-entrant call on the same thread
-- to plain vanilla instead. `running` is the per-thread table for that particular
-- function, so the loop, the procedure and the wait each have their own guard.
local function guarded_call(running, implementation, fallback, ...)
	local key = current_call_key()
	if running[key] == true then return fallback(...) end
	running[key] = true
	-- Keep this a direct Lua call: rain functions legitimately yield through
	-- Sleep/WaitThread, so a protected C-call boundary is not safe on every
	-- game Lua runtime.
	local result = pack_values(implementation(...))
	running[key] = nil
	return table.unpack(result, 1, result.n)
end

if type(Hooks.fixed_loop) ~= "function" then
	Hooks.fixed_loop = function(settings)
		if Hooks.enabled == true and type(Hooks.impl_loop) == "function" then
			return guarded_call(Hooks.running_loop, Hooks.impl_loop,
				Hooks.base_original_loop, settings)
		end
		if Hooks.original_loop_may_contain_wrapper == true then
			return Hooks.base_original_loop(settings)
		end
		return Hooks.original_loop(settings)
	end
end
if type(Hooks.fixed_procedure) ~= "function" then
	Hooks.fixed_procedure = function(settings, ...)
		if Hooks.enabled == true and type(Hooks.impl_procedure) == "function" then
			return guarded_call(Hooks.running_procedure, Hooks.impl_procedure,
				Hooks.base_original_procedure, settings, ...)
		end
		if Hooks.original_procedure_may_contain_wrapper == true then
			return Hooks.base_original_procedure(settings, ...)
		end
		return Hooks.original_procedure(settings, ...)
	end
end
if type(Hooks.fixed_wait) ~= "function" then
	Hooks.fixed_wait = function(...)
		if Hooks.enabled == true and type(Hooks.impl_wait) == "function" then
			return guarded_call(Hooks.running_wait, Hooks.impl_wait,
				Hooks.base_original_wait, ...)
		end
		if Hooks.original_wait_may_contain_wrapper == true then
			return Hooks.base_original_wait(...)
		end
		return Hooks.original_wait(...)
	end
end
if type(shared) == "table" then shared.SMRCF_RainHooks = Hooks end

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

-- Is this game thread still running? Threads die on their own when a game ends or
-- a save is loaded, so a stored thread handle can never be trusted without asking.
local function is_thread_alive(thread)
	local is_valid_thread = rawget(_G, "IsValidThread")
	if type(is_valid_thread) ~= "function" then return nil end
	return thread ~= nil and thread ~= false and is_valid_thread(thread) == true
end

-- The game's own rain bookkeeping table, one entry per rain type. It is normally created
-- by vanilla; recreating it when it is missing is itself one of this fix's repairs,
-- because a save that lost it can never schedule rain again.
local function rain_threads()
	local threads = rawget(_G, "RainsDisasterThreads")
	if type(threads) ~= "table" then
		threads = {}
		RainsDisasterThreads = threads
		log("WARN", "Created missing vanilla rain thread table", nil)
		log_correction("recreated the missing vanilla rain state table", {
			repair = "missing_rain_thread_table",
		})
	end
	return threads
end

-- Makes sure the entry for one rain type ("normal" or "toxic") exists and has every
-- field the rain code expects.
--
-- Note that missing fields are filled with `false`, never nil. The game's rain code tests
-- these fields directly, and a nil where a false is expected is exactly the kind of gap
-- that leaves a scheduler waiting forever.
function RestoreRains.EnsureRainType(rain_type, settings, reason)
	rain_type = rain_type == "toxic" and "toxic" or "normal"
	local threads = rain_threads()
	local data = threads[rain_type]
	if type(data) ~= "table" then
		data = {
			id = settings and (settings.id or settings.Id) or false,
			last_id = false,
			activation_thread = false,
			main_thread = false,
			soil_thread = false,
			duration = false,
		}
		threads[rain_type] = data
		log("WARN", "Initialized missing rain type state", {
			rain_type = rain_type,
			reason = reason,
		})
	end
	if data.activation_thread == nil then data.activation_thread = false end
	if data.main_thread == nil then data.main_thread = false end
	if data.soil_thread == nil then data.soil_thread = false end
	if data.duration == nil then data.duration = false end
	return data
end

-- Clears "a disaster is predicted" entries that no longer have a notification behind
-- them. Rain refuses to start while any of these is set, so a leftover entry silently
-- stops rain forever.
--
-- The proof is the important part: an entry is only removed when the game's own
-- FindNotification says there is no matching notification on the map. An entry with a live
-- notification is a real prediction and is left alone.
local function clear_stale_predictions(reason)
	local predictions = rawget(_G, "g_DisastersPredicted")
	local find_notification = rawget(_G, "FindNotification")
	local main_map = rawget(_G, "MainMap")
	if type(predictions) ~= "table" or type(find_notification) ~= "function" or not main_map then
		return 0
	end

	local cleared = 0
	local cleared_ids = {}
	for _, notification_id in ipairs(PREDICTION_IDS) do
		if predictions[notification_id] then
			local notification = find_notification(notification_id, main_map)
			if not notification then
				predictions[notification_id] = nil
				cleared = cleared + 1
				cleared_ids[#cleared_ids + 1] = notification_id
				log("WARN", "Cleared proven-stale disaster prediction", {
					notification_id = notification_id,
					reason = reason,
				})
			end
		end
	end
	if cleared > 0 then
		log_correction("cleared stale disaster predictions that blocked rain", {
			repair = "stale_disaster_predictions",
			reason = reason,
			cleared_count = cleared,
			notification_ids = cleared_ids,
		})
	end
	return cleared
end

-- Resets one rain type's per-rain fields to "no rain running". Kept separate because it is
-- the fallback used when vanilla's own cleanup cannot be called.
local function clear_inactive_thread_fields(data)
	data.main_thread = false
	data.soil_thread = false
	data.last_id = false
	data.duration = false
end

-- Ends a rain the save still thinks is falling, but whose threads are gone.
--
-- It tries the game's own FinishRainProcedure first, so soil, vegetation, FX and
-- notifications are all wound down the way vanilla winds them down. Only if that is
-- unavailable or fails does it fall back to resetting the state fields directly - a
-- cruder cleanup, and it says so in the log.
--
-- Returns nil when the map is not loaded yet: not a failure, just "ask again later".
local function finish_stale_active_rain(rain_type, data, reason)
	if not rawget(_G, "MainMap") or not rawget(_G, "MainCity") then
		log("INFO", "Stale active-rain cleanup deferred until map state exists", {
			rain_type = rain_type,
			reason = reason,
		})
		return nil
	end
	local finish = rawget(_G, "FinishRainProcedure")
	if type(finish) == "function" then
		local ok, err = pcall(finish, rain_type)
		if ok == true then
			log("WARN", "Finished stale active rain state through vanilla cleanup", {
				rain_type = rain_type,
				reason = reason,
			})
			log_correction("finished stale active rain through vanilla cleanup", {
				repair = "stale_active_rain",
				rain_type = rain_type,
				reason = reason,
				cleanup = "FinishRainProcedure",
			})
			return true
		end
		log("ERROR", "Vanilla stale-rain cleanup failed", {
			rain_type = rain_type,
			reason = reason,
			error = err,
		})
	else
		log("ERROR", "FinishRainProcedure is unavailable during stale-rain cleanup", {
			rain_type = rain_type,
			reason = reason,
		})
	end

	clear_inactive_thread_fields(data)
	g_RainDisaster = false
	log_correction("cleared stale active rain with the safe fallback", {
		repair = "stale_active_rain",
		rain_type = rain_type,
		reason = reason,
		cleanup = "fallback_state_reset",
	})
	return false
end

-- Repairs rain state in a save, and the ordering matters, so read it as a checklist:
--   1. clear predictions that no longer have a notification (they block everything else);
--   2. for each rain type, make sure its entry exists and its fields are filled;
--   3. if the save says this rain is falling but its main thread is dead, end it properly;
--   4. if a rain is not the active one but still holds thread fields, clear them;
--   5. clear a dead soil thread the same way;
--   6. finally, clear g_RainDisaster if it names something that is not a real rain type.
--
-- Every step demands evidence that the state is dead - a thread that is gone, a
-- notification that does not exist - before touching anything. A living rain is never
-- interrupted, which is why this can safely run on every load.
function RestoreRains.ReconcileState(reason)
	if RestoreRains.enabled ~= true then return true end
	local is_valid_thread = rawget(_G, "IsValidThread")
	if type(is_valid_thread) ~= "function" then
		log("ERROR", "IsValidThread is unavailable; state reconciliation aborted", {
			reason = reason,
		})
		return false
	end

	clear_stale_predictions(reason)
	local active_rain = rawget(_G, "g_RainDisaster")
	local threads = rain_threads()
	for _, rain_type in ipairs(RAIN_TYPES) do
		local data = RestoreRains.EnsureRainType(rain_type, nil, reason)
		if active_rain == rain_type and is_thread_alive(data.main_thread) ~= true then
			local finished = finish_stale_active_rain(rain_type, data, reason)
			if finished ~= nil then
				active_rain = rawget(_G, "g_RainDisaster")
			end
		elseif data.main_thread and is_thread_alive(data.main_thread) ~= true then
			clear_inactive_thread_fields(data)
			log("WARN", "Cleared dead inactive rain thread state", {
				rain_type = rain_type,
				reason = reason,
			})
			log_correction("cleared dead inactive rain thread state", {
				repair = "dead_inactive_rain_thread",
				rain_type = rain_type,
				reason = reason,
			})
		end
		if data.soil_thread and is_thread_alive(data.soil_thread) ~= true then
			data.soil_thread = false
			log_correction("cleared a dead rain soil thread", {
				repair = "dead_rain_soil_thread",
				rain_type = rain_type,
				reason = reason,
			})
		end
	end

	active_rain = rawget(_G, "g_RainDisaster")
	if active_rain and active_rain ~= "toxic" and active_rain ~= "normal" then
		log("WARN", "Cleared invalid active rain type", {
			active_rain = active_rain,
			reason = reason,
		})
		g_RainDisaster = false
		log_correction("cleared an invalid active-rain marker", {
			repair = "invalid_active_rain_type",
			active_rain = active_rain,
			reason = reason,
		})
	end
	return type(threads) == "table"
end

-- The corrected rain scheduler, and the fix for the deadlock.
--
-- Vanilla's loop waits for the rain it just requested to finish. When activation declines
-- - another disaster is active or predicted - no rain ever runs, so nothing ever finishes,
-- and the loop waits forever. The colony never sees natural rain again.
--
-- This version keeps looping instead: schedule an attempt, sleep, reconcile stale state,
-- run vanilla's own RainsDisasterActivation in a thread, wait for that thread, then go
-- round again. Whether the attempt produced rain or was declined, the next attempt is
-- still scheduled.
--
-- Points worth copying:
--   * activation itself is vanilla's function, called unchanged. Only the surrounding
--     loop is different, so rain amounts and effects stay vanilla's.
--   * next_attempt_times / next_start_times are recorded for the log, so a player report
--     can show when rain was due.
--   * invalid settings, or a missing activation function, hand control back to
--     Hooks.original_loop rather than improvising.
--   * `while RestoreRains.enabled == true` plus the final call to the original loop means
--     switching the fix off returns the scheduler to vanilla cleanly, mid-game.
Hooks.impl_loop = function(settings)
	local rain_type = settings and settings.type == "toxic" and "toxic" or "normal"
	while RestoreRains.enabled == true do
		local spawn_time = settings and settings.spawntime
		local spawn_random = settings and settings.spawntime_random
		if type(spawn_time) ~= "number" or type(spawn_random) ~= "number" then
			log("ERROR", "Rain scheduler received invalid settings", {
				settings = settings,
			})
			return Hooks.original_loop(settings)
		end

		local delay = spawn_time + AsyncRand(spawn_random)
		local next_attempt_time = GameTime() + delay
		RestoreRains.next_attempt_times[rain_type] = next_attempt_time
		RestoreRains.next_start_times[rain_type] = false
		log("INFO", "Scheduled natural rain attempt", {
			rain_type = rain_type,
			delay = delay,
			next_attempt_time = next_attempt_time,
		})
		Sleep(delay)
		RestoreRains.next_attempt_times[rain_type] = false
		if RestoreRains.enabled ~= true then break end

		RestoreRains.ReconcileState("before_natural_attempt")
		local activation = rawget(_G, "RainsDisasterActivation")
		if type(activation) ~= "function" then
			log("ERROR", "RainsDisasterActivation is unavailable", nil)
			return Hooks.original_loop(settings)
		end

		local active_before = type(rawget(_G, "IsDisasterActive")) == "function" and
			IsDisasterActive() or false
		local predicted_before = type(rawget(_G, "IsDisasterPredicted")) == "function" and
			IsDisasterPredicted() or false
		if not active_before and not predicted_before then
			local warning_time = type(rawget(_G, "GetDisasterWarningTime")) == "function" and
				GetDisasterWarningTime() or 0
			RestoreRains.next_start_times[rain_type] = GameTime() + warning_time
		end
		local activation_thread = CreateGameTimeThread(activation, settings)
		WaitThread(activation_thread)
		RestoreRains.next_start_times[rain_type] = false
		log("INFO", "Rain activation thread finished; scheduler will continue", {
			rain_type = settings.type or "normal",
			settings_id = settings.id or settings.Id,
			was_blocked_by_active_disaster = not not active_before,
			was_blocked_by_prediction = predicted_before or false,
		})
		if RestoreRains.enabled == true then
			log_correction("kept the natural rain scheduler running after an activation attempt", {
				repair = "continued_natural_rain_scheduler",
				rain_type = settings.type or "normal",
				settings_id = settings.id or settings.Id,
				was_blocked_by_active_disaster = not not active_before,
				was_blocked_by_prediction = predicted_before or false,
			})
		end
	end
	RestoreRains.next_attempt_times[rain_type] = false
	RestoreRains.next_start_times[rain_type] = false
	return Hooks.original_loop(settings)
end

-- The second hook, and the smallest: make sure this rain type's bookkeeping entry exists
-- and is complete just before vanilla starts the rain, then hand straight over to vanilla.
-- Nothing about how the rain behaves is changed here - the entry is prepared so vanilla's
-- own code does not trip over a missing field.
Hooks.impl_procedure = function(settings, ...)
	if RestoreRains.enabled == true then
		if type(settings) ~= "table" then
			log("ERROR", "RainProcedure received missing settings", {
				settings = settings,
			})
		else
			local rain_type = settings.type == "toxic" and "toxic" or "normal"
			RestoreRains.next_start_times[rain_type] = false
			RestoreRains.EnsureRainType(settings.type or "normal", settings,
				"before_rain_procedure")
		end
	end
	return Hooks.original_procedure(settings, ...)
end

-- The third hook: "wait until no disaster is active or predicted".
--
-- Vanilla waits on a message that a stale prediction may never deliver, so the wait can
-- outlive the disaster it was waiting for. This version polls once per game hour and
-- reconciles stale state as it goes, so a leftover prediction is cleared and the wait ends.
-- It returns as soon as nothing is active or predicted - the same condition vanilla was
-- waiting for.
--
-- Cloud Seeding and similar projects sit in this wait, which is why fixing it is what makes
-- them start again after a disaster.
Hooks.impl_wait = function(...)
	while RestoreRains.enabled == true do
		RestoreRains.ReconcileState("wait_current_disaster_poll")
		local predicted = IsDisasterPredicted()
		local active = IsDisasterActive()
		if not predicted and not active then return end
		Sleep(const.HourDuration)
	end
	return Hooks.original_wait(...)
end

-- Every game function this fix needs, checked before anything is installed and recorded in
-- the log. This fix replaces three globals and drives game-time threads, so it has the
-- longest list in the mod - and if any single entry is missing it installs nothing at all
-- rather than running half a repair.
local function required_hooks_available()
	local available = type(Hooks.original_loop) == "function" and
		type(Hooks.original_procedure) == "function" and
		type(Hooks.original_wait) == "function" and
		type(rawget(_G, "RainsDisasterActivation")) == "function" and
		type(rawget(_G, "IsDisasterPredicted")) == "function" and
		type(rawget(_G, "IsDisasterActive")) == "function" and
		type(rawget(_G, "WaitThread")) == "function" and
		type(rawget(_G, "CreateGameTimeThread")) == "function" and
		type(rawget(_G, "IsValidThread")) == "function" and
		type(rawget(_G, "DeleteThread")) == "function" and
		type(rawget(_G, "Sleep")) == "function" and
		type(rawget(_G, "AsyncRand")) == "function" and
		type(rawget(_G, "const")) == "table" and
		type(const.HourDuration) == "number"
	log_api("Restore Rains hook set", available, {
		has_loop = type(Hooks.original_loop) == "function",
		has_procedure = type(Hooks.original_procedure) == "function",
		has_wait = type(Hooks.original_wait) == "function",
		has_activation = type(rawget(_G, "RainsDisasterActivation")) == "function",
		has_IsDisasterPredicted = type(rawget(_G, "IsDisasterPredicted")) == "function",
		has_IsDisasterActive = type(rawget(_G, "IsDisasterActive")) == "function",
		has_WaitThread = type(rawget(_G, "WaitThread")) == "function",
		has_CreateGameTimeThread = type(rawget(_G, "CreateGameTimeThread")) == "function",
		has_IsValidThread = type(rawget(_G, "IsValidThread")) == "function",
		has_DeleteThread = type(rawget(_G, "DeleteThread")) == "function",
		has_Sleep = type(rawget(_G, "Sleep")) == "function",
		has_AsyncRand = type(rawget(_G, "AsyncRand")) == "function",
		has_HourDuration = type(rawget(_G, "const")) == "table" and
			type(const.HourDuration) == "number",
	})
	return available
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreRains.InstallHooks(reason)
	if required_hooks_available() ~= true then
		log("ERROR", "Required v1.0.7 rain APIs are unavailable; fix not installed", {
			reason = reason,
		})
		return false
	end

	local function install_one(name, wrapper_key, original_key, pending_key)
		local current = rawget(_G, name)
		if type(current) ~= "function" then return false end
		if current ~= Hooks[wrapper_key] and current ~= Hooks[original_key] then
			-- The game refreshes these globals before it reloads mod code. Capture
			-- that refreshed function as the new downstream link instead of
			-- stacking a second SMR Community Fixes wrapper around the previous one.
			Hooks[original_key] = current
			Hooks[original_key .. "_may_contain_wrapper"] = true
			log("INFO", "Rebased stable hook after a Lua global refresh", {
				function_name = name,
				reason = reason,
			})
		end
		set_global_hook(name, Hooks[wrapper_key])
		Hooks[pending_key] = false
		return true
	end

	if install_one("RainsDisasterLoop", "fixed_loop", "original_loop",
		"rebase_loop") ~= true or
		install_one("RainProcedure", "fixed_procedure", "original_procedure",
			"rebase_procedure") ~= true or
		install_one("WaitCurrentDisaster", "fixed_wait", "original_wait",
			"rebase_wait") ~= true
	then
		log("ERROR", "A required rain hook disappeared during installation", {
			reason = reason,
		})
		return false
	end

	RestoreRains.enabled = true
	Hooks.enabled = true
	log("INFO", "Installed rain repair hooks", {
		reason = reason,
	})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreRains.RestoreHooks(reason)
	-- Disable the persistent wrapper gate before touching any global. If another
	-- system owns the outer function, the wrapper can safely remain in that
	-- chain as a pass-through until this module is loaded again or deleted.
	RestoreRains.enabled = false
	Hooks.enabled = false
	local function restore_one(name, wrapper_key, original_key, pending_key)
		local current = rawget(_G, name)
		local wrapper = Hooks[wrapper_key]
		local original = Hooks[original_key]
		if current == wrapper then
			set_global_hook(name, original)
			Hooks[pending_key] = false
			return
		end
		if current ~= original then
			Hooks[pending_key] = true
			log("INFO", "Disabled an inner hook gate while preserving the outer function", {
				function_name = name,
				reason = reason,
			})
		end
	end

	restore_one("RainsDisasterLoop", "fixed_loop", "original_loop", "rebase_loop")
	restore_one("RainProcedure", "fixed_procedure", "original_procedure",
		"rebase_procedure")
	restore_one("WaitCurrentDisaster", "fixed_wait", "original_wait", "rebase_wait")
	log("INFO", "Restored vanilla rain functions", {
		reason = reason,
		restored = true,
	})
	return true
end

-- Is rain actually falling right now? Used to postpone a scheduler rebuild: restarting
-- schedulers during a rain would cut it short, so the rebuild waits until it ends.
local function any_live_rain_main_thread()
	for _, rain_type in ipairs(RAIN_TYPES) do
		local data = RestoreRains.EnsureRainType(rain_type, nil, "live_main_check")
		if is_thread_alive(data.main_thread) == true then return true, rain_type end
	end
	return false, nil
end

-- Swaps the running rain schedulers between vanilla and corrected mode.
--
-- Replacing the global functions is not enough on its own: a scheduler thread that is
-- already running holds whichever loop it started with, so it has to be stopped and
-- restarted for a toggle to take effect. That is what this does, and it is the most
-- delicate function in the mod. Read the guards:
--   * rebuild_in_progress stops the rebuild from re-entering itself;
--   * no map or no UpdateRainsThreads means "too early", so it defers instead of failing;
--   * a rain currently falling defers the rebuild (pending_rebuild) rather than cutting it
--     short - OnRainEnded picks it up afterwards;
--   * scheduler_modes remembers which mode each live thread was started in, so a rebuild
--     that would change nothing is skipped entirely (`already_owned`);
--   * restarting goes through vanilla's own UpdateRainsThreads, so the threads the game
--     ends up with are the ones the game would have created itself.
--
-- The pcall around UpdateRainsThreads is one of the few here: it is a vanilla call whose
-- failure must not leave rebuild_in_progress stuck true, and the error is reported.
function RestoreRains.RebuildSchedulers(reason, force)
	if RestoreRains.rebuild_in_progress == true then return true end
	local main_map = rawget(_G, "MainMap")
	local update = rawget(_G, "UpdateRainsThreads")
	if not main_map or type(update) ~= "function" then
		log("INFO", "Scheduler rebuild deferred until game state exists", {
			reason = reason,
			has_main_map = main_map ~= nil and main_map ~= false,
			has_update = type(update) == "function",
		})
		return true
	end

	if RestoreRains.enabled == true then RestoreRains.ReconcileState(reason) end
	local live_main, live_type = any_live_rain_main_thread()
	if live_main == true then
		RestoreRains.pending_rebuild = true
		log("INFO", "Scheduler rebuild deferred until active rain ends", {
			reason = reason,
			rain_type = live_type,
		})
		return true
	end

	local desired_mode = RestoreRains.enabled == true and
		"fixed" or "vanilla"
	local already_owned = true
	local has_live_scheduler = false
	for _, rain_type in ipairs(RAIN_TYPES) do
		local data = RestoreRains.EnsureRainType(rain_type, nil, reason)
		local activation_thread = data.activation_thread
		if is_thread_alive(activation_thread) == true then
			has_live_scheduler = true
			if RestoreRains.scheduler_modes[activation_thread] ~= desired_mode then
				already_owned = false
			end
		end
	end
	if has_live_scheduler ~= true then already_owned = false end
	if force ~= true and already_owned == true then return true end

	RestoreRains.rebuild_in_progress = true
	local deleted_schedulers = 0
	for _, rain_type in ipairs(RAIN_TYPES) do
		local data = RestoreRains.EnsureRainType(rain_type, nil, reason)
		local activation_thread = data.activation_thread
		if is_thread_alive(activation_thread) == true then
			DeleteThread(activation_thread)
			deleted_schedulers = deleted_schedulers + 1
		end
		data.activation_thread = false
		RestoreRains.next_attempt_times[rain_type] = false
		RestoreRains.next_start_times[rain_type] = false
	end

	local ok, err = pcall(update, false)
	if ok ~= true then
		RestoreRains.rebuild_in_progress = false
		log("ERROR", "Vanilla UpdateRainsThreads failed during scheduler rebuild", {
			reason = reason,
			error = err,
		})
		return false
	end

	RestoreRains.scheduler_modes = {}
	local current_threads = rain_threads()
	local started_schedulers = 0
	for _, rain_type in ipairs(RAIN_TYPES) do
		local data = current_threads[rain_type]
		if type(data) == "table" and is_thread_alive(data.activation_thread) == true then
			RestoreRains.scheduler_modes[data.activation_thread] = desired_mode
			started_schedulers = started_schedulers + 1
		end
	end
	RestoreRains.pending_rebuild = false
	RestoreRains.rebuild_in_progress = false
	log("INFO", "Rebuilt eligible vanilla rain schedulers", {
		reason = reason,
		mode = desired_mode,
	})
	if desired_mode == "fixed" and
		(deleted_schedulers > 0 or started_schedulers > 0)
	then
		log_correction("rebuilt the natural rain schedulers in continued mode", {
			repair = "rebuilt_natural_rain_schedulers",
			reason = reason,
			deleted_schedulers = deleted_schedulers,
			started_schedulers = started_schedulers,
		})
	end
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreRains.SetEnabled(enabled, reason)
	enabled = enabled == true
	local mode_changed = RestoreRains.enabled ~= enabled
	local hooks_ok
	if enabled then
		hooks_ok = RestoreRains.InstallHooks(reason)
		if hooks_ok == true then RestoreRains.ReconcileState(reason) end
	else
		hooks_ok = RestoreRains.RestoreHooks(reason)
	end
	if hooks_ok ~= true then return false end
	return RestoreRains.RebuildSchedulers(reason, mode_changed)
end

-- The framework calls this on the game's RainDisasterEnd message (see FIX.events). It is
-- the other half of the deferral above: a rebuild that was postponed because rain was
-- falling happens now that the rain has ended.
function RestoreRains.OnRainEnded(reason)
	if RestoreRains.pending_rebuild == true then
		return RestoreRains.RebuildSchedulers(reason or "rain_ended", true)
	end
	return true
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreRains.Quiesce(reason)
	return RestoreRains.SetEnabled(false, reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreRains.SetEnabled
FIX.quiesce = RestoreRains.Quiesce
FIX.events = {
	RainDisasterEnd = RestoreRains.OnRainEnded,
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

return RestoreRains
