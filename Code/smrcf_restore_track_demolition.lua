-- Restore Track Demolition - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): three terminal branches of track demolition call
--   track_obj:OnDemolish() and return without the DoneObject() step the ordinary
--   demolish path performs. OnDemolish has already replaced both element arrays
--   with false, so what is left is a Track that is permanently "demolishing",
--   holds no elements, and cannot safely run its own BuildingUpdate.
-- Vanilla code:     DemolishAndSplitTrack() in Lua/Buildings/TrackElement.lua,
--   with TrackBase:OnDemolish() in Track.lua and Demolishable:DoDemolish()
-- The repair:       after vanilla returns, finish the missing destruction - but
--   only for a Track in exactly that shell state (demolishing true, elements
--   false, elements_under_construction false). Enabling the fix also sweeps a
--   loaded save for shells already stored that way.
-- Left alone:       normal shortening, splitting, construction repair, refunds and
--   station reconnection. A finished demolition is never undone on disable.

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
	id = "restore_track_demolition",
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Track Demolition",
	description = "Completes v1.0.7 terminal track-element demolition and removes exact invalid Track shells already stored in existing savegames.",
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
local RestoreTrackDemolition = rawget(_G, "SMRCFRestoreTrackDemolition")
if RestoreTrackDemolition == nil then
	RestoreTrackDemolition = { enabled = false }
	rawset(_G, "SMRCFRestoreTrackDemolition", RestoreTrackDemolition)
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
	shared.SMRCF_TrackDemolitionHooks or nil
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
	shared.SMRCF_TrackDemolitionHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_current_method()
	local element_class = rawget(_G, "TrackGridElement")
	if type(element_class) ~= "table" then return false end
	local current = element_class.DemolishAndSplitTrack
	if current ~= Hooks.wrapper and type(current) == "function" then
		if type(Hooks.original) == "function" and current ~= Hooks.original then
			Hooks.original_may_contain_wrapper = true
		end
		Hooks.original = current
	end
	Hooks.base_original = Hooks.base_original or Hooks.original
	return type(Hooks.original) == "function"
end

capture_current_method()

-- Keeps a call's return values intact, including a nil in the middle, by recording
-- how many there were. Passing results through with plain `...` would silently
-- truncate at the first nil.
local function pack_results(...)
	return { n = select("#", ...), ... }
end

-- Calls the vanilla demolition method and hands back every one of its return values
-- intact. in_wrapper keeps a nested demolition - vanilla splitting a track can
-- demolish further elements - from running the repair twice on the same call.
local function call_original(element, ...)
	local original = Hooks.original_may_contain_wrapper == true and
		Hooks.base_original or Hooks.original
	if type(original) ~= "function" then
		error("Restore Track Demolition has no captured vanilla method")
	end
	if Hooks.in_wrapper == true then return original(element, ...) end

	Hooks.in_wrapper = true
	local results = pack_results(pcall(original, element, ...))
	Hooks.in_wrapper = false
	if results[1] ~= true then error(results[2]) end
	return table.unpack(results, 2, results.n)
end

-- Is this still a real, undestroyed game object? Game code can hand back objects
-- that were deleted a moment ago, so anything held across a frame is rechecked
-- before it is used.
local function is_valid_object(object)
	if object == nil then return false end
	local is_valid = rawget(_G, "IsValid")
	return type(is_valid) ~= "function" or is_valid(object)
end

-- The exact fingerprint of the bug, and the only state this fix ever acts on:
--   demolishing == true                  vanilla started tearing the track down
--   elements == false                    OnDemolish already destroyed both arrays
--   elements_under_construction == false and replaced them with false
-- A track in any other combination is either healthy or mid-operation, and is left
-- completely alone. Keeping the test this literal is what makes the fix safe.
local function is_terminal_track_shell(track)
	return is_valid_object(track) and
		track.demolishing == true and
		track.elements == false and
		track.elements_under_construction == false
end

-- Finishes the destruction vanilla started, by running the DoneObject() step its
-- terminal branches skip. That is the same call the ordinary demolish path makes, so
-- the object is torn down exactly the way the game tears one down.
--
-- The three empty tables need explaining. OnDemolish already destroyed the real
-- collections and left `false` in their place, but TrackBase:Done walks them again
-- during DoneObject and would error on a boolean. Empty tables let that duplicate
-- cleanup pass over nothing. They are handed over only for the DoneObject call.
--
-- If DoneObject fails, the shell's previous field values are put back before the
-- error is re-raised, so a failure leaves the object as it was rather than
-- half-modified.
function RestoreTrackDemolition.CompleteTerminalCleanup(track, element, mass_delete,
	repair_reason)
	if is_terminal_track_shell(track) ~= true then return false end
	local done_object = rawget(_G, "DoneObject")
	if type(done_object) ~= "function" then
		log("ERROR",
			"Cannot finish terminal track demolition; DoneObject is unavailable", {
				track_handle = track and track.handle,
				element_handle = element and element.handle,
			})
		return false
	end

	local track_handle = track.handle
	local track_class = track.class
	local element_handle = element and element.handle
	local element_class = element and element.class
	local assigned_vehicles = track.assigned_vehicles

	-- TrackBase:OnDemolish has already destroyed these collections and replaced
	-- them with false. TrackBase:Done iterates them again, so provide empty
	-- collections only for the final DoneObject call.
	track.assigned_vehicles = {}
	track.elements = {}
	track.elements_under_construction = {}
	local result = pack_results(pcall(done_object, track))
	if result[1] ~= true then
		if is_valid_object(track) then
			track.assigned_vehicles = assigned_vehicles
			track.elements = false
			track.elements_under_construction = false
		end
		log("ERROR",
			"Terminal track object cleanup failed", {
				track_handle = track_handle,
				element_handle = element_handle,
				error = result[2],
			})
		error(result[2])
	end

	log("INFO",
		"Bug fix invoked: completed deletion of an emptied terminal track object",
		correction_context({
			repair = "terminal_track_object_cleanup",
			reason = repair_reason or (mass_delete == true and
				"mass_track_element_demolition" or
				"terminal_track_element_demolition"),
			track_handle = track_handle,
			track_class = track_class,
			element_handle = element_handle,
			element_class = element_class,
		}))
	return true
end

-- Finds shells that a save already contains, because a player may have created them
-- before this fix existed. Two ways of walking the maps: AllMapsForEach if the game
-- provides it, otherwise each entry in LoadedMaps.
--
-- Note that matches are collected into a list and deleted afterwards, by the caller.
-- Deleting objects while iterating the map would mutate the collection being walked.
local function collect_terminal_track_shells()
	local shells = {}
	local function collect(track)
		if is_terminal_track_shell(track) == true then
			shells[#shells + 1] = track
		end
	end

	local all_maps_for_each = rawget(_G, "AllMapsForEach")
	if type(all_maps_for_each) == "function" then
		all_maps_for_each("map", "TrackBase", collect)
		return shells
	end

	local loaded_maps = rawget(_G, "LoadedMaps")
	if type(loaded_maps) == "table" then
		for _, map in ipairs(loaded_maps) do
			if map and type(map.MapForEach) == "function" then
				map:MapForEach(true, "TrackBase", collect)
			end
		end
	end
	return shells
end

-- Repairs an existing save. The framework calls this when a game starts or loads
-- (see FIX.events), so a save that already contains dead track shells is cleaned up
-- rather than only being protected from new ones. It does nothing while the fix is
-- off, and it repairs only the exact shell state - never a general track sweep.
function RestoreTrackDemolition.ReconcileExisting(reason)
	if RestoreTrackDemolition.enabled ~= true or Hooks.enabled ~= true then
		return true
	end
	local shells = collect_terminal_track_shells()
	for _, track in ipairs(shells) do
		if RestoreTrackDemolition.CompleteTerminalCleanup(track, nil, false,
			"existing_save_terminal_track_shell") ~= true
		then
			return false
		end
	end
	log("INFO",
		"Reconciled existing terminal track shells", {
			reason = reason,
			repaired = #shells,
		})
	return true
end

if type(Hooks.wrapper) ~= "function" then
	Hooks.wrapper = function(element, mass_delete, ...)
		local track = element and element.track_obj
		local results = pack_results(
			call_original(element, mass_delete, ...))
		if Hooks.enabled == true then
			RestoreTrackDemolition.CompleteTerminalCleanup(
				track, element, mass_delete)
		end
		return table.unpack(results, 1, results.n)
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreTrackDemolition.InstallHook(reason)
	local element_class = rawget(_G, "TrackGridElement")
	if capture_current_method() ~= true or type(element_class) ~= "table" then
		log("ERROR",
			"Required v1.0.7 track demolition API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	element_class.DemolishAndSplitTrack = Hooks.wrapper
	Hooks.enabled = true
	RestoreTrackDemolition.enabled = true
	log("INFO",
		"Installed terminal track-object cleanup hook", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreTrackDemolition.RestoreHook(reason)
	Hooks.enabled = false
	RestoreTrackDemolition.enabled = false
	local element_class = rawget(_G, "TrackGridElement")
	if type(element_class) == "table" and
		element_class.DemolishAndSplitTrack == Hooks.wrapper
	then
		element_class.DemolishAndSplitTrack = Hooks.original
	end
	log("INFO",
		"Restored captured track demolition method", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreTrackDemolition.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then
		if RestoreTrackDemolition.InstallHook(reason) ~= true then return false end
		return RestoreTrackDemolition.ReconcileExisting(reason)
	end
	return RestoreTrackDemolition.RestoreHook(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreTrackDemolition.Quiesce(reason)
	return RestoreTrackDemolition.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreTrackDemolition.SetEnabled
FIX.quiesce = RestoreTrackDemolition.Quiesce
FIX.events = {
	GameStateStarting = RestoreTrackDemolition.ReconcileExisting,
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

return RestoreTrackDemolition
