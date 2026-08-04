-- Restore Soil Overlay - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): the solid soil overlay keeps drawing the surface map's soil
--   data even when an underground map is the active one, because the boolean
--   grouping in the overlay lookup forgets to require the surface map.
-- Vanilla code:     GetOverlayGrid() in Lua/GameOverlays.lua
-- The repair:       reject exactly that combination - solid soil overlay showing,
--   active map is not the surface map, grid returned is the surface SoilGrid - and
--   return false, which is what vanilla does for a grid it has no data for.
-- Left alone:       the surface SoilGrid itself, and the water, custom-supply and
--   electricity overlays.

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
	id = "restore_soil_overlay",
	number = 5,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Soil Overlay",
	description = "Keeps the solid soil overlay bound to the surface map, preventing v1.0.7 from using the surface SoilGrid while another map is active.",
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
local RestoreSoilOverlay = rawget(_G, "SMRCFRestoreSoilOverlay")
if RestoreSoilOverlay == nil then
	RestoreSoilOverlay = {
		enabled = false,
		correction_reported = false,
	}
	rawset(_G, "SMRCFRestoreSoilOverlay", RestoreSoilOverlay)
end

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_SoilOverlayHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original = rawget(_G, "GetOverlayGrid"),
		wrapper = false,
		in_call = false,
	}
end

local current = rawget(_G, "GetOverlayGrid")
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
	shared.SMRCF_SoilOverlayHooks = Hooks
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

-- Calls the vanilla function this fix wrapped. Hooks.in_call is raised for the
-- duration so that if vanilla reaches GetOverlayGrid again, the wrapper passes it
-- straight through instead of recursing into the repair. pcall is used only to
-- guarantee the flag is lowered again; the error is re-raised unchanged so a real
-- vanilla failure still surfaces instead of being swallowed.
local function call_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

-- The repair itself.
--
-- The bug: vanilla's GetOverlayGrid() decides which terrain grid the overlay
-- draws. Because of Lua operator precedence in the vanilla expression, the solid
-- soil overlay keeps resolving to the surface map's SoilGrid even while a
-- different map (an underground cave) is the active one, so the overlay paints
-- surface soil data over an unrelated map.
--
-- The repair: let vanilla answer first, then reject only that exact combination -
-- the solid soil overlay is showing, the active map is not the surface map, and
-- the grid vanilla returned is literally the surface SoilGrid. Returning false
-- makes the overlay draw nothing, which is what vanilla does for a grid it has no
-- data for. Every other overlay, map and grid falls through untouched.
--
-- correction_reported keeps this to one log line per game rather than one per
-- frame, since the overlay is queried continuously while it is open.
function RestoreSoilOverlay.Corrected(...)
	local grid = call_original(...)
	local current_map = rawget(_G, "CurrentMap")
	local surface_map = rawget(_G, "MainMap")
	local soil_grid = rawget(_G, "SoilGrid")
	if rawget(_G, "show_overlay") == "soil_solid" and
		current_map and surface_map and current_map ~= surface_map and
		grid == soil_grid
	then
		if RestoreSoilOverlay.correction_reported ~= true then
			RestoreSoilOverlay.correction_reported = true
			log("INFO",
				"Bug fix invoked: blocked the surface SoilGrid on another map",
				correction_context({
					repair = "solid_soil_map_gate",
					reason = "vanilla_boolean_precedence",
				}))
		end
		return false
	end
	return grid
end

-- The wrapper calls Hooks.impl only while the fix is enabled. Pointing it at the
-- repair here, rather than installing the repair as the global, is what lets the
-- toggle be instant and exact.
Hooks.impl = RestoreSoilOverlay.Corrected

-- Turn the fix on. Refuses to install if the vanilla global is missing, which is
-- how a future game patch that renames it shows up as one clear error instead of a
-- crash. If something else replaced the global since this file loaded, that
-- function is captured as the new original so the other mod's behavior is kept in
-- the chain rather than discarded.
function RestoreSoilOverlay.InstallHook(reason)
	local current_fn = rawget(_G, "GetOverlayGrid")
	if type(current_fn) ~= "function" then
		log("ERROR",
			"Required v1.0.7 overlay API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	if current_fn ~= Hooks.original and current_fn ~= Hooks.wrapper then
		Hooks.original = current_fn
		Hooks.original_may_contain_wrapper = true
	end
	GetOverlayGrid = Hooks.wrapper
	RestoreSoilOverlay.enabled = true
	Hooks.enabled = true
	log("INFO", "Installed soil overlay grid hook", {
		reason = reason,
	})
	return true
end

-- Turn the fix off and put vanilla back exactly. The global is only unwrapped
-- while this fix still owns it: if a third-party mod wrapped our wrapper
-- afterwards, replacing the global would destroy that mod's hook, so instead the
-- wrapper stays installed and simply passes everything through.
function RestoreSoilOverlay.RestoreHook(reason)
	RestoreSoilOverlay.enabled = false
	Hooks.enabled = false
	if rawget(_G, "GetOverlayGrid") == Hooks.wrapper then
		GetOverlayGrid = Hooks.original
	end
	log("INFO", "Restored captured overlay grid function", {
		reason = reason,
	})
	return true
end

-- The single entry point the framework uses. It obeys unconditionally: whether
-- the fix *should* run - the player's checkbox, the game-version gate - has
-- already been decided by SMRCommunityFixes.lua. Safe to call repeatedly with the same
-- value.
function RestoreSoilOverlay.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreSoilOverlay.InstallHook(reason) end
	return RestoreSoilOverlay.RestoreHook(reason)
end

-- Called by the framework when a game starts or ends (see FIX.events). Clears the
-- once-per-game log latch so the next game reports its own correction. Nothing
-- here is saved into the savegame.
function RestoreSoilOverlay.ResetTransientState()
	RestoreSoilOverlay.correction_reported = false
	return true
end

-- Called by the framework immediately before a Lua reload replaces this
-- descriptor, and if this file is deleted from the mod. Standing down here is what
-- guarantees a removed or reloaded fix leaves no hook behind.
function RestoreSoilOverlay.Quiesce(reason)
	return RestoreSoilOverlay.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreSoilOverlay.SetEnabled
FIX.quiesce = RestoreSoilOverlay.Quiesce
FIX.events = {
	GameStateStarting = RestoreSoilOverlay.ResetTransientState,
	DoneGame = RestoreSoilOverlay.ResetTransientState,
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

return RestoreSoilOverlay
