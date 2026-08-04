-- Restore Jumbo Cave Reinforcements - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): a Jumbo Cave Reinforcements site can be blocked by a Waste
--   Rock pile that no drone is able to reach. The site then waits forever, because
--   the blocker is never cleared and the site is never retested.
-- Vanilla code:     the Waste Rock approach path in Lua/WasteRock.lua and
--   OnWasteRockObstructorCleared() in Lua/Buildings/ConstructionSite.lua
-- The repair:       let vanilla's approach run first and only act after it fails,
--   and only when that exact blocker belongs to a JumboCaveReinforcementStructure
--   site. The pile is then removed through the normal object-destruction path, so
--   vanilla's own "obstructor cleared" logic retests the site.
-- Left alone:       Waste Rock a drone can reach, and every other construction
--   class.

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
	id = "restore_jumbo_cave",
	number = 8,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Jumbo Cave Reinforcements",
	description = "Releases Jumbo Cave Reinforcements construction sites stuck on unreachable Waste Rock in v1.0.7, but only after a drone's normal approach to that exact blocker fails.",
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
local RestoreJumboCave = rawget(_G, "SMRCFRestoreJumboCave")
if RestoreJumboCave == nil then
	RestoreJumboCave = { enabled = false }
	rawset(_G, "SMRCFRestoreJumboCave", RestoreJumboCave)
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
	shared.SMRCF_JumboCaveHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original = false,
		wrapper = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_JumboCaveHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_current_method()
	local rock_class = rawget(_G, "WasteRockObstructor")
	if type(rock_class) ~= "table" then return false end
	local current = rock_class.DroneApproach
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

-- Calls the vanilla approach method. If another mod wrapped the method after we
-- captured it, `original` may itself be that mod's wrapper; base_original is the
-- version captured before anyone wrapped anything, and using it avoids calling the
-- same chain twice.
local function call_original(...)
	local fn = Hooks.original_may_contain_wrapper == true and
		Hooks.base_original or Hooks.original
	return fn(...)
end

-- Is this still a real, undestroyed game object? Game code can hand back objects
-- that were deleted a moment ago, so anything held across a frame is rechecked
-- before it is used.
local function is_valid_object(object)
	local is_valid = rawget(_G, "IsValid")
	return type(is_valid) ~= "function" or is_valid(object)
end

-- Is this Waste Rock pile blocking a Jumbo Cave Reinforcements site? A pile can
-- block several construction sites at once, so every parent is checked, and only a
-- JumboCaveReinforcementStructure counts. This narrowness is the point: it is what
-- keeps the fix from deleting Waste Rock that is merely inconvenient elsewhere.
local function jumbo_site_for_rock(rock)
	local parents = rock and rock.parent_construction
	if type(parents) ~= "table" then return nil end
	for _, site in ipairs(parents) do
		if is_valid_object(site) and
			site.building_class == "JumboCaveReinforcementStructure"
		then
			return site
		end
	end
	return nil
end

-- Removes the blocker, using the game's own DoneObject() so the pile is destroyed
-- exactly as vanilla destroys it - that is what makes the game's
-- OnWasteRockObstructorCleared logic run and retest the site.
--
-- Everything worth reporting (handles, entity, remaining work) is read *before*
-- the object is destroyed, because afterwards those fields are gone.
function RestoreJumboCave.RemoveUnreachableBlocker(rock, drone, site)
	if not is_valid_object(rock) or not is_valid_object(site) then return false end
	local done_object = rawget(_G, "DoneObject")
	if type(done_object) ~= "function" then
		log("ERROR",
			"Cannot remove the unreachable Jumbo Cave blocker; DoneObject is unavailable", {
				site_handle = site and site.handle,
				rock_handle = rock and rock.handle,
			})
		return false
	end

	local entity = type(rock.GetEntity) == "function" and rock:GetEntity() or nil
	local work_request = rock.work_req
	local remaining = work_request and
		type(work_request.GetActualAmount) == "function" and
		work_request:GetActualAmount() or nil
	local rock_handle = rock.handle
	local site_handle = site.handle
	local drone_handle = drone and drone.handle
	done_object(rock)
	log("INFO",
		"Bug fix invoked: removed an unreachable Jumbo Cave Waste Rock blocker",
		correction_context({
			repair = "jumbo_cave_unreachable_waste_rock",
			reason = "drone_approach_failed",
			site_handle = site_handle,
			rock_handle = rock_handle,
			drone_handle = drone_handle,
			rock_entity = entity,
			work_remaining = remaining,
		}))
	return true
end

-- The wrapper. Read the order carefully, because it is the whole safety argument:
-- vanilla runs first and its answer is returned unchanged. Only when vanilla itself
-- reports failure (result == false), the fix is on, and the pile belongs to a Jumbo
-- Cave site, is the blocker removed. A pile a drone can reach never reaches this
-- code path.
if type(Hooks.wrapper) ~= "function" then
	Hooks.wrapper = function(rock, drone, resource)
		local result = call_original(rock, drone, resource)
		if Hooks.enabled == true and result == false and
			is_valid_object(rock)
		then
			local site = jumbo_site_for_rock(rock)
			if site then
				RestoreJumboCave.RemoveUnreachableBlocker(rock, drone, site)
			end
		end
		return result
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreJumboCave.InstallHook(reason)
	if capture_current_method() ~= true then
		log("ERROR",
			"Required v1.0.7 Waste Rock API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	local rock_class = rawget(_G, "WasteRockObstructor")
	rock_class.DroneApproach = Hooks.wrapper
	RestoreJumboCave.enabled = true
	Hooks.enabled = true
	log("INFO",
		"Installed targeted Jumbo Cave Waste Rock approach hook", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreJumboCave.RestoreHook(reason)
	RestoreJumboCave.enabled = false
	Hooks.enabled = false
	local rock_class = rawget(_G, "WasteRockObstructor")
	if type(rock_class) == "table" and
		rock_class.DroneApproach == Hooks.wrapper
	then
		rock_class.DroneApproach = Hooks.original
	end
	log("INFO",
		"Restored captured Waste Rock approach method", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreJumboCave.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreJumboCave.InstallHook(reason) end
	return RestoreJumboCave.RestoreHook(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreJumboCave.Quiesce(reason)
	return RestoreJumboCave.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreJumboCave.SetEnabled
FIX.quiesce = RestoreJumboCave.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreJumboCave
