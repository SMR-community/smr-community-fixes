-- TEMPLATE - copy this template to Code/smrcf_restore_<your_fix>.lua.
--
-- Start by renaming the four names below. For example: to repair the game
-- global GetOverlayGrid(), copy this file to Code/smrcf_restore_soil_overlay.lua
-- and replace every occurrence of
--
--   VanillaFunctionName    ->  GetOverlayGrid            the global you repair
--   RestoreYourFix         ->  RestoreSoilOverlay        this module's table
--   SMRCFRestoreYourFix    ->  SMRCFRestoreSoilOverlay   its _G state key
--   SMRCF_YourFixHooks     ->  SMRCF_SoilOverlayHooks    its SharedModEnv key
--
-- Ctrl+F each name on the left to find every occurrence.
--
-- Replace this whole header too, with one describing the bug you fix.
--
-- When you are done, Ctrl+F each of the four names above once more to guarantee
-- you did not miss any.
--
-- Then fill in the descriptor below. The framework fills in every OPTIONAL
-- field you leave out.
--
--   id              = "restore_soil_overlay",  REQUIRED, permanent
--   beta            = true,                    OPTIONAL, defaults true
--   versions        = { ["1.0.7"] = true },    OPTIONAL, defaults to 1.0.7
--   default_enabled = false,                   OPTIONAL, defaults false
--   debug           = false,                   OPTIONAL, defaults false
--   label           = "Restore Soil Overlay",  OPTIONAL, derived from id
--   description     = "Keeps the soil ...",    REQUIRED
--
-- At the bottom the template also wires set_enabled (REQUIRED), plus quiesce
-- and events (OPTIONAL).
--
-- SWITCHING OFF MUST BE COMPLETE. set_enabled(false) has to put the game back
-- exactly as your fix found it, with no restart. It is called when a player
-- unchecks your fix, and again when the whole mod is switched off in the Mod
-- Manager - the framework hears the game's ModUnloadLua and stands every fix
-- down, so you need no code of your own for that, only a restore that works.
-- Nothing your fix changes lives in this mod: it is all wrappers and fields
-- inside the game's own globals and classes, and none of it disappears on its
-- own. The one thing not to undo is a repair already written into the saved
-- game - that is a state the game could have reached by itself.
--
-- Rename RestoreYourFix.Corrected below accordingly, e.g. RestoreSoilOverlay.Corrected.
--
-- To test in game, list your file in metadata.lua 'code' and in items.lua. You
-- can leave both out as well: once it is merged to main, register-fixes.yml
-- runs tools/sync_mod.lua, which adds your file to metadata.lua and items.lua
-- and commits that itself.
--
-- Read next: CONTRIBUTING.md.

local FIX = {
	id = "restore_your_fix",
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Your Fix",
	description = "What this restores, in one short sentence.",
}

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

-- Diagnostics are gated by FIX.debug; real errors always reach the log.
local function log(level, message, data)
	if level ~= "ERROR" and FIX.debug ~= true then return end
	local text = "[SMR Community Fixes][" .. level .. "][" .. FIX.id .. "] " .. tostring(message)
	if data ~= nil then text = text .. " " .. describe(data) end
	local mod_log = rawget(_G, "ModLog")
	if type(mod_log) == "function" then mod_log(text) else print(text) end
end

-- Module state, kept in a global so a Lua reload does not lose it.
local RestoreYourFix = rawget(_G, "SMRCFRestoreYourFix")
if RestoreYourFix == nil then
	RestoreYourFix = {
		enabled = false,
		correction_reported = false,
	}
	rawset(_G, "SMRCFRestoreYourFix", RestoreYourFix)
end

-- The captured vanilla function and the wrapper live in SharedModEnv so they
-- survive a reload and cannot be installed twice. Replace VanillaFunctionName
-- with the real global you repair, and bump `protocol` if you change the shape
-- of this table in a later release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_YourFixHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original = rawget(_G, "VanillaFunctionName"),
		wrapper = false,
		in_call = false,
	}
end

local current = rawget(_G, "VanillaFunctionName")
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
	shared.SMRCF_YourFixHooks = Hooks
end

-- Context attached to every "Bug fix invoked:" event.
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

local function call_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

-- The repair. Delegate to vanilla, then correct only the exact broken case.
function RestoreYourFix.Corrected(...)
	local result = call_original(...)
	local is_the_broken_case = false -- replace with the precise condition
	if is_the_broken_case then
		log("INFO", "Bug fix invoked: <what was corrected>", correction_context({
			repair = "<short_repair_name>",
			reason = "<why_vanilla_was_wrong>",
		}))
		return result -- replace with the corrected value
	end
	return result
end

Hooks.impl = RestoreYourFix.Corrected

function RestoreYourFix.InstallHook(reason)
	local current_fn = rawget(_G, "VanillaFunctionName")
	if type(current_fn) ~= "function" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			reason = reason,
		})
		return false
	end
	if current_fn ~= Hooks.original and current_fn ~= Hooks.wrapper then
		Hooks.original = current_fn
		Hooks.original_may_contain_wrapper = true
	end
	-- Plain assignment, never rawset(_G, ...). Inside a mod, _G is the mod's
	-- own environment table: rawget reads fall through to the real globals, but
	-- a rawset writes only into that table, where the game never sees it. An
	-- assignment goes through ModEnvMeta.__newindex and reaches the real one.
	-- The rawset calls elsewhere in this file are for this mod's own state keys,
	-- which is the right place for them.
	VanillaFunctionName = Hooks.wrapper
	RestoreYourFix.enabled = true
	Hooks.enabled = true
	log("INFO", "Installed hook", { reason = reason })
	return true
end

function RestoreYourFix.RestoreHook(reason)
	RestoreYourFix.enabled = false
	Hooks.enabled = false
	-- Only unwrap while this module still owns the global, so a third-party
	-- wrapper installed on top of ours is never destroyed. Same rule as install:
	-- assign, do not rawset.
	if rawget(_G, "VanillaFunctionName") == Hooks.wrapper then
		VanillaFunctionName = Hooks.original
	end
	log("INFO", "Restored captured vanilla function", { reason = reason })
	return true
end

-- Called by the framework. Must be idempotent in both directions.
function RestoreYourFix.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreYourFix.InstallHook(reason) end
	return RestoreYourFix.RestoreHook(reason)
end

-- Optional: clear per-game transient state. Wire into FIX.events below.
function RestoreYourFix.ResetTransientState()
	RestoreYourFix.correction_reported = false
	return true
end

-- Called before a Lua reload replaces this descriptor, and again when the whole
-- mod is switched off. The framework hears ModUnloadLua and calls every fix's
-- quiesce, so you need no unload handler of your own - only a restore that works.
function RestoreYourFix.Quiesce(reason)
	return RestoreYourFix.SetEnabled(false, reason or "registry_reset")
end

FIX.set_enabled = RestoreYourFix.SetEnabled
FIX.quiesce = RestoreYourFix.Quiesce
FIX.events = {
	GameStateStarting = RestoreYourFix.ResetTransientState,
	DoneGame = RestoreYourFix.ResetTransientState,
}

-- Self-registration: SMRCommunityFixes.lua adopts this plain list when it loads.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreYourFix
