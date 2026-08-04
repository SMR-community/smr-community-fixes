-- Restore Dust Devils - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): three problems in Dust Devil spawning. spawn_chance is
--   multiplied into the spawn count and the fractional result is used as a
--   numeric for-loop limit, so the chance never behaves like a percentage; the
--   preset is read from whichever map the player is currently looking at, so
--   viewing a cave changes surface weather; and marker Dust Devils keep spawning
--   after terraforming has disabled Dust Storms.
-- Vanilla code:     Lua/DustDevils.lua
-- The repair:       roll spawn_chance as a real percentage, then pick a whole
--   count between count_min and count_max; always read the preset from
--   MainMap.mapdata; re-check the disabled gate before a warned marker devil
--   starts.
-- Left alone:       timing ranges, warning delay, positions, movement, the
--   major/electrostatic choice, FX, and the No Disasters rule.

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
	id = "restore_dust_devils",
	number = 3,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Dust Devils",
	description = "Corrects v1.0.7 Dust Devil spawn-chance handling, keeps natural scheduling tied to the surface map, and stops marker spawns after terraforming disables Dust Storms.",
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
local RestoreDustDevils = rawget(_G, "SMRCFRestoreDustDevils")
if RestoreDustDevils == nil then
	RestoreDustDevils = {
		enabled = false,
		scheduler_active = false,
		map_mismatch_reported = false,
		marker_disabled_reported = false,
	}
	rawset(_G, "SMRCFRestoreDustDevils", RestoreDustDevils)
end

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_DustDevilHooks or nil
local scheduler_functions = rawget(_G, "GlobalGameTimeThreadFuncs")

local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original_scheduler = type(scheduler_functions) == "table" and
			scheduler_functions.DustDevils or nil,
		original_marker = rawget(_G, "CreateDustDevilMarkerThread"),
		fixed_scheduler = false,
		fixed_marker = false,
	}
end

local current_scheduler = type(scheduler_functions) == "table" and
	scheduler_functions.DustDevils or nil
if current_scheduler ~= Hooks.fixed_scheduler and
	type(current_scheduler) == "function"
then
	if current_scheduler ~= Hooks.original_scheduler then
		Hooks.original_scheduler_may_contain_wrapper = true
	end
	Hooks.original_scheduler = current_scheduler
end

local current_marker = rawget(_G, "CreateDustDevilMarkerThread")
if current_marker ~= Hooks.fixed_marker and type(current_marker) == "function" then
	if current_marker ~= Hooks.original_marker then
		Hooks.original_marker_may_contain_wrapper = true
	end
	Hooks.original_marker = current_marker
end

Hooks.base_original_scheduler = Hooks.base_original_scheduler or
	Hooks.original_scheduler
Hooks.base_original_marker = Hooks.base_original_marker or Hooks.original_marker

if type(Hooks.fixed_scheduler) ~= "function" then
	Hooks.fixed_scheduler = function(...)
		if Hooks.enabled == true and type(Hooks.impl_scheduler) == "function" then
			return Hooks.impl_scheduler(...)
		end
		if Hooks.original_scheduler_may_contain_wrapper == true then
			return Hooks.base_original_scheduler(...)
		end
		return Hooks.original_scheduler(...)
	end
end

if type(Hooks.fixed_marker) ~= "function" then
	Hooks.fixed_marker = function(descr, marker, ...)
		if Hooks.enabled == true and type(Hooks.impl_marker) == "function" then
			return Hooks.impl_marker(descr, marker, ...)
		end
		if Hooks.original_marker_may_contain_wrapper == true then
			return Hooks.base_original_marker(descr, marker, ...)
		end
		return Hooks.original_marker(descr, marker, ...)
	end
end

if type(shared) == "table" then
	shared.SMRCF_DustDevilHooks = Hooks
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

-- Has terraforming permanently switched Dust Storms off? Once the atmosphere is thick
-- enough the game sets this, and no natural Dust Devil should follow. Vanilla checks it
-- when the scheduler starts but not again before a warned marker devil spawns, which is
-- the third part of this bug.
local function dust_storms_disabled()
	return rawget(_G, "DustStormsDisabled") == true
end

-- Is a real Dust Storm running on this map? Dust Devils are suppressed during one, so
-- this is checked both before spawning and again after the warning delay.
local function has_dust_storm(map)
	local checker = rawget(_G, "HasDustStorm")
	return type(checker) == "function" and not not checker(map)
end

-- Is this game thread still running? Threads die on their own when a game ends or
-- a save is loaded, so a stored thread handle can never be trusted without asking.
local function thread_alive(thread)
	local checker = rawget(_G, "IsValidThread")
	return type(checker) == "function" and checker(thread) == true
end

-- Reads the Dust Devil settings for the *surface* map, which is the second part of the
-- bug: vanilla reads them from whichever map is currently displayed, so opening a cave
-- view changes surface weather.
--
-- The chain is: surface map -> its map settings -> the named DustDevils preset ->
-- OverrideDisasterDescriptor, which is the game's own hook for terraforming changing a
-- disaster's numbers. A nil descriptor from that override means terraforming has
-- disabled Dust Devils, and it is reported as a distinct reason rather than an error.
--
-- The correction is logged once per game, only when the displayed map really was not the
-- surface map - that is the evidence this part of the fix did something.
function RestoreDustDevils.GetMainMapDescriptor()
	local map = main_map()
	local mapdata = map and map.mapdata
	local preset_id = mapdata and mapdata.MapSettings_DustDevils
	if preset_id == nil or preset_id == "disabled" then
		return nil, preset_id == "disabled" and "map_setting_disabled" or
			"main_map_unavailable"
	end

	local presets = rawget(_G, "Presets")
	local map_settings = type(presets) == "table" and presets.MapSettings or nil
	local dust_presets = type(map_settings) == "table" and
		map_settings.DustDevils or nil
	local original = type(dust_presets) == "table" and
		(dust_presets[preset_id] or dust_presets.DustDevils_VeryLow) or nil
	local override = rawget(_G, "OverrideDisasterDescriptor")
	if original == nil or type(override) ~= "function" then
		return nil, "descriptor_unavailable"
	end

	local current_map = rawget(_G, "CurrentMap")
	if current_map and current_map ~= map and
		RestoreDustDevils.map_mismatch_reported ~= true
	then
		RestoreDustDevils.map_mismatch_reported = true
		log_correction("read the Dust Devil preset from MainMap", {
			repair = "main_map_descriptor",
			reason = "current_map_was_not_main_map",
			preset = preset_id,
		})
	end

	local descriptor = override(original)
	if descriptor == nil then return nil, "terraforming_disabled" end
	return descriptor, nil
end

-- Recovers the descriptor a running marker thread was started with, by reading the
-- thread's own local variables through the game's GetThreadUpvalues. This is how a
-- marker keeps its exact settings when its thread is restarted after a toggle, instead
-- of being handed a freshly guessed descriptor. If the thread is gone or the API is
-- missing, the caller's fallback is used.
local function marker_descriptor(thread, fallback)
	local reader = rawget(_G, "GetThreadUpvalues")
	if thread_alive(thread) and type(reader) == "function" then
		local ok, values = pcall(reader, thread)
		if ok == true and type(values) == "table" then
			return values.descr or values.descriptor or fallback
		end
	end
	return fallback
end

-- Restarts the per-marker spawn threads. Map features that spawn Dust Devils each run
-- their own thread, so switching this fix on or off has to stop the old threads and
-- start replacements; otherwise vanilla's loop would keep running alongside the
-- corrected one. Each marker keeps its own descriptor across the restart.
function RestoreDustDevils.ResetMarkerThreads(map, fallback)
	if not map or type(map.MapForEach) ~= "function" then return 0 end
	local delete_thread = rawget(_G, "DeleteThread")
	local create_marker = rawget(_G, "CreateDustDevilMarkerThread")
	local restarted = 0
	map:MapForEach(true, "PrefabFeatureMarker", function(marker)
		if marker.FeatureType ~= "Dust Devils" then return end
		local descriptor = marker_descriptor(marker.thread, fallback)
		if marker.thread and type(delete_thread) == "function" then
			delete_thread(marker.thread)
		end
		marker.thread = false
		if descriptor and type(create_marker) == "function" then
			marker.thread = create_marker(descriptor, marker)
			restarted = restarted + 1
		end
	end)
	return restarted
end

-- The corrected marker spawn loop, running in its own game-time thread.
--
-- It follows vanilla's shape exactly - wait a randomised spawn time, wake up one warning
-- period early, roll, place, wait for the hit, start the devil - with two corrections:
--   * `random:Random(100) < marker_spawn_chance` is a real percentage roll. Vanilla
--     multiplied the chance into the count and used the fraction as a loop limit.
--   * the disabled/storm gate is re-checked after the warning sleep, just before the
--     devil starts, so terraforming that completes during the warning still stops it.
--
-- Two things to notice for your own threaded fix: `while Hooks.enabled == true` means
-- switching the fix off ends this loop at its next wake-up instead of leaving it running
-- forever, and every Sleep is a point where the game may be saved, loaded or ended - so
-- nothing is cached across one that must stay valid.
function RestoreDustDevils.MarkerLoop(descr, marker)
	local start_pos = marker:GetPos()
	local radius = marker.FeatureRadius
	local warning_time = descr.warning_time
	local map = marker:GetMap()
	while Hooks.enabled == true do
		local random = rawget(_G, "SessionRandom")
		if not random then return end
		local spawn_time = random:Random(descr.marker_spawntime,
			descr.marker_spawntime + descr.marker_spawntime_random)
		Sleep(Max(spawn_time - warning_time, 1000))
		if Hooks.enabled ~= true then return end

		local blocked = has_dust_storm(map) or dust_storms_disabled()
		if dust_storms_disabled() and
			RestoreDustDevils.marker_disabled_reported ~= true
		then
			RestoreDustDevils.marker_disabled_reported = true
			log_correction("suppressed a Dust Devil marker after terraforming disabled it", {
				repair = "marker_terraforming_gate",
				reason = "DustStormsDisabled",
			})
		elseif dust_storms_disabled() ~= true then
			RestoreDustDevils.marker_disabled_reported = false
		end

		if not blocked and
			random:Random(100) < descr.marker_spawn_chance
		then
			local get_pos = rawget(_G, "GetRandomPassableAroundOnMap")
			local pos = type(get_pos) == "function" and
				(get_pos(map, start_pos, radius) or start_pos) or start_pos
			local hit_time = Min(spawn_time, warning_time)
			local generate = rawget(_G, "GenerateDustDevilIn")
			local devil = type(generate) == "function" and
				generate(pos, map, descr, radius) or nil
			Sleep(hit_time)
			if IsValid(devil) then
				if has_dust_storm(map) or dust_storms_disabled() then
					devil:delete()
				else
					devil:Start()
				end
			end
		end
	end
end

-- Replaces the game's marker-thread creator, so a marker created at any time gets the
-- corrected loop above. CreateGameTimeThread ties the thread to game time, so it pauses
-- when the game pauses and speeds up with time compression. The thread handle is cleared
-- from the marker when the loop ends, so nothing holds a dead handle.
function RestoreDustDevils.CreateMarkerThread(descr, marker)
	local create = rawget(_G, "CreateGameTimeThread")
	if type(create) ~= "function" then return false end
	return create(function(self, descriptor)
		RestoreDustDevils.MarkerLoop(descriptor, self)
		if IsValid(self) then self.thread = false end
	end, marker, descr)
end

-- The corrected natural Dust Devil scheduler. This is the fix's centrepiece and it
-- mirrors vanilla's loop step for step, so it is worth reading as a comparison.
--
-- Outline:
--   * bail out entirely under the No Disasters rule, and wait for map generation first;
--   * fetch the surface descriptor. "disabled" in the map settings ends the thread; any
--     other unavailability just sleeps a Sol and tries again, because presets and
--     terraforming state can appear later;
--   * restart the marker threads once, so map features use the corrected loop too;
--   * wait out any active Dust Storm or terraforming shutdown, re-read the descriptor
--     afterwards (terraforming may have changed the numbers while we waited);
--   * roll the spawn chance ONCE as a percentage, and only on success pick a whole
--     count between count_min and count_max. This is the corrected line:
--         chance_passed = random:Random(100) < descr.spawn_chance
--         count         = random:Random(descr.count_min, descr.count_max)
--     Vanilla instead scaled the count by the chance and fed the fractional result to a
--     numeric for-loop, so the "chance" silently became a count multiplier;
--   * spawn that many devils, re-checking the storm and disabled gates between each, so
--     a storm starting mid-batch stops the rest.
--
-- Every wait uses Sleep, so the loop follows game speed and pausing. Hooks.enabled is
-- re-tested after each one, which is how switching the fix off ends the thread promptly
-- and vanilla's own scheduler can take back over.
function RestoreDustDevils.RunScheduler()
	local game_rule = rawget(_G, "IsGameRuleActive")
	if type(game_rule) == "function" and game_rule("NoDisasters") then return end
	if rawget(_G, "GeneratingMap") then WaitMsg("MapGenerated") end

	local map = main_map()
	if not map then return end
	local marker_threads_ready = false
	while Hooks.enabled == true do
		local descr, unavailable_reason =
			RestoreDustDevils.GetMainMapDescriptor()
		if descr == nil then
			if unavailable_reason == "map_setting_disabled" then return end
			local constants = rawget(_G, "const")
			Sleep(type(constants) == "table" and constants.DayDuration or 5000)
		else
			if marker_threads_ready ~= true then
				RestoreDustDevils.ResetMarkerThreads(map, descr)
				marker_threads_ready = true
			end

			while Hooks.enabled == true and
				(has_dust_storm(map) or dust_storms_disabled())
			do
				Sleep(5000)
			end
			if Hooks.enabled ~= true then return end

			descr, unavailable_reason =
				RestoreDustDevils.GetMainMapDescriptor()
			if descr == nil then
				local constants = rawget(_G, "const")
				Sleep(type(constants) == "table" and constants.DayDuration or 5000)
			else
				local random = rawget(_G, "SessionRandom")
				if not random then return end
				local spawn_time = random:Random(descr.spawntime,
					descr.spawntime + descr.spawntime_random)
				local warning_time = descr.warning_time
				Sleep(Max(spawn_time - warning_time, 1000))
				if Hooks.enabled ~= true then return end

				local chance_roll = random:Random(100)
				local chance_passed = chance_roll < descr.spawn_chance
				local count = chance_passed and
					random:Random(descr.count_min, descr.count_max) or 0
				log_correction("applied the Dust Devil spawn chance as a chance roll", {
					repair = "spawn_chance_roll",
					reason = "vanilla_scaled_spawn_count",
					spawn_chance = descr.spawn_chance,
					chance_roll = chance_roll,
					spawn_count = count,
				})

				for _ = 1, count do
					local hit_time = Min(spawn_time, warning_time)
					Sleep(hit_time)
					if Hooks.enabled ~= true or has_dust_storm(map) or
						dust_storms_disabled()
					then
						break
					end
					local get_pos = rawget(_G, "GetRandomPassableAwayFromBuilding")
					local pos = type(get_pos) == "function" and get_pos(map) or nil
					if not pos then break end
					local generate = rawget(_G, "GenerateDustDevilIn")
					local devil = type(generate) == "function" and
						generate(pos, map, descr) or nil
					if devil then devil:Start() end
					Sleep(random:Random(descr.spawn_delay_min,
						descr.spawn_delay_max))
				end
			end
		end
	end
end

-- Point the two gates at the corrected versions. The wrappers call these only while the
-- fix is enabled, so disabling hands both jobs straight back to vanilla.
Hooks.impl_scheduler = RestoreDustDevils.RunScheduler
Hooks.impl_marker = RestoreDustDevils.CreateMarkerThread

-- The game functions this fix needs. GlobalGameTimeThreadFuncs.DustDevils is the
-- scheduler entry the game itself starts, which is why it is replaced there rather than
-- as a plain global: that is the table the game reads when it (re)starts the thread.
local function required_apis_available()
	local funcs = rawget(_G, "GlobalGameTimeThreadFuncs")
	return type(funcs) == "table" and
		type(funcs.DustDevils) == "function" and
		type(rawget(_G, "RestartGlobalGameTimeThread")) == "function" and
		type(rawget(_G, "CreateDustDevilMarkerThread")) == "function" and
		type(rawget(_G, "OverrideDisasterDescriptor")) == "function"
end

-- Restarts the Dust Devil scheduler thread through the game's own
-- RestartGlobalGameTimeThread. Needed on both enable and disable: the thread currently
-- running holds whichever loop was installed when it started, so the switch only takes
-- effect once it is restarted. Outside a game there is no thread to restart, and that is
-- not an error.
local function restart_scheduler(reason)
	if not main_map() or not rawget(_G, "Game") then
		RestoreDustDevils.scheduler_active = false
		return true
	end
	local restart = rawget(_G, "RestartGlobalGameTimeThread")
	if type(restart) ~= "function" then return false end
	restart("DustDevils")
	RestoreDustDevils.scheduler_active = RestoreDustDevils.enabled == true
	log("INFO", "Restarted the Dust Devil scheduler", {
		reason = reason,
		enabled = RestoreDustDevils.enabled == true,
	})
	return true
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreDustDevils.InstallHooks(reason)
	if required_apis_available() ~= true then
		log("ERROR",
			"Required v1.0.7 Dust Devil APIs are unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end

	local funcs = rawget(_G, "GlobalGameTimeThreadFuncs")
	local scheduler = funcs.DustDevils
	local marker = rawget(_G, "CreateDustDevilMarkerThread")
	if RestoreDustDevils.enabled == true and Hooks.enabled == true and
		scheduler == Hooks.fixed_scheduler and marker == Hooks.fixed_marker
	then
		if RestoreDustDevils.scheduler_active == true or
			not main_map() or not rawget(_G, "Game")
		then
			return true
		end
		return restart_scheduler(reason)
	end
	if scheduler ~= Hooks.original_scheduler and
		scheduler ~= Hooks.fixed_scheduler
	then
		Hooks.original_scheduler = scheduler
		Hooks.original_scheduler_may_contain_wrapper = true
	end
	if marker ~= Hooks.original_marker and marker ~= Hooks.fixed_marker then
		Hooks.original_marker = marker
		Hooks.original_marker_may_contain_wrapper = true
	end

	funcs.DustDevils = Hooks.fixed_scheduler
	CreateDustDevilMarkerThread = Hooks.fixed_marker
	RestoreDustDevils.enabled = true
	Hooks.enabled = true
	return restart_scheduler(reason)
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreDustDevils.RestoreHooks(reason)
	local funcs = rawget(_G, "GlobalGameTimeThreadFuncs")
	local owns_scheduler = type(funcs) == "table" and
		funcs.DustDevils == Hooks.fixed_scheduler
	local owns_marker = rawget(_G, "CreateDustDevilMarkerThread") ==
		Hooks.fixed_marker
	local was_enabled = RestoreDustDevils.enabled == true or
		Hooks.enabled == true or owns_scheduler or owns_marker
	RestoreDustDevils.enabled = false
	RestoreDustDevils.scheduler_active = false
	Hooks.enabled = false

	if owns_scheduler then
		funcs.DustDevils = Hooks.original_scheduler
	end
	if owns_marker then
		CreateDustDevilMarkerThread = Hooks.original_marker
	end
	if was_enabled ~= true then return true end

	local map = main_map()
	if map and rawget(_G, "Game") then
		local delete_thread = rawget(_G, "DeleteThread")
		if type(map.MapForEach) == "function" then
			map:MapForEach(true, "PrefabFeatureMarker", function(marker)
				if marker.FeatureType == "Dust Devils" then
					if marker.thread and type(delete_thread) == "function" then
						delete_thread(marker.thread)
					end
					marker.thread = false
				end
			end)
		end
	end
	return restart_scheduler(reason)
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreDustDevils.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreDustDevils.InstallHooks(reason) end
	return RestoreDustDevils.RestoreHooks(reason)
end

-- Called when a game starts or ends (see FIX.events at the bottom). Clears
-- per-game bookkeeping such as the once-per-game log latch. Nothing here is ever
-- written into a savegame.
function RestoreDustDevils.ResetTransientState()
	RestoreDustDevils.scheduler_active = false
	RestoreDustDevils.map_mismatch_reported = false
	RestoreDustDevils.marker_disabled_reported = false
	return true
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreDustDevils.Quiesce(reason)
	return RestoreDustDevils.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreDustDevils.SetEnabled
FIX.quiesce = RestoreDustDevils.Quiesce
FIX.events = {
	GameStateStarting = RestoreDustDevils.ResetTransientState,
	DoneGame = RestoreDustDevils.ResetTransientState,
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

return RestoreDustDevils
