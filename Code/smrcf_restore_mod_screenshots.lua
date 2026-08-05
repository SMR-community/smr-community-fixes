-- Restore Mod Screenshots
--
-- Opening a mod's page in the in-game Paradox Mods browser asserts:
--
--   Creating a new key 'ScreenshotUrls' in a protected object 'ModUI_Entry'.
--   CommonLua/PropertyObject.lua(1822): metamethod __newindex
--   CommonLua/UI/ModManager.lua(797)
--
-- Confirmed in CommonLua/UI/ModManager.lua. ModUI_Entry derives from
-- ProtectedPropertyObject, whose __newindex asserts on any key the class never
-- declared (CommonLua/PropertyObject.lua:1819-1823). The class declares
-- ScreenshotPaths at line 1229 but never ScreenshotUrls, while line 797 assigns
-- mod.ScreenshotUrls and CommonLua/Libs/Paradox/ParadoxMods.lua:249 reads it
-- back. Writer and reader agree on the name; only the declaration is missing.
-- The engine's own comment on line 786 reads "todo: this is not working".
--
-- rawset still runs after the assert, so on a build with asserts suppressed the
-- value is stored and screenshots load. Where asserts are enabled and halt, the
-- ModsUIDownloadScreenshots call on line 799 is never reached and the mod's
-- screenshots stay missing.
--
-- The repair declares the field on the class, exactly as ScreenshotPaths is
-- declared, so the assignment stops being a new key. No vanilla function is
-- wrapped and no vanilla file is touched.

local FIX = {
	id = "restore_mod_screenshots",
	number = 15,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Mod Screenshots",
	description = "Stops the error shown when opening a mod with screenshots in the Paradox Mods browser.",
}

local CLASS_NAME = "ModUI_Entry"
local FIELD_NAME = "ScreenshotUrls"

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
local RestoreModScreenshots = rawget(_G, "SMRCFRestoreModScreenshots")
if RestoreModScreenshots == nil then
	RestoreModScreenshots = {
		enabled = false,
		correction_reported = false,
	}
	rawset(_G, "SMRCFRestoreModScreenshots", RestoreModScreenshots)
end

-- Whether this module is the one that added the field. Kept in SharedModEnv so
-- a Lua reload cannot lose track and leave the field behind, or remove a field
-- the game itself declared in a later patch.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_ModScreenshotsHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		declared_by_us = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_ModScreenshotsHooks = Hooks
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

-- The repair. Declaring the field is the whole of it: __newindex accepts any key
-- for which rawget(class, key) is non-nil, and false matches how the neighbouring
-- ScreenshotPaths is declared.
function RestoreModScreenshots.DeclareField(reason)
	local class = rawget(_G, CLASS_NAME)
	if type(class) ~= "table" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			class = CLASS_NAME,
			reason = reason,
		})
		return false
	end
	if rawget(class, FIELD_NAME) ~= nil then
		-- Already declared, either by us or by a patched game. Nothing to correct.
		log("INFO", "Field already declared; nothing to do", { reason = reason })
		return true
	end
	rawset(class, FIELD_NAME, false)
	Hooks.declared_by_us = true
	if RestoreModScreenshots.correction_reported ~= true then
		RestoreModScreenshots.correction_reported = true
		log("INFO", "Bug fix invoked: declared the missing ScreenshotUrls field", correction_context({
			repair = "declare_screenshot_urls",
			reason = "ModUI_Entry assigns ScreenshotUrls without declaring it, so ProtectedPropertyObject asserts",
			class = CLASS_NAME,
			field = FIELD_NAME,
		}))
	end
	return true
end

function RestoreModScreenshots.RemoveField(reason)
	local class = rawget(_G, CLASS_NAME)
	-- Only remove what this module added, and only while it is still the value
	-- this module wrote, so a later official declaration is never undone.
	if type(class) == "table" and Hooks.declared_by_us == true
		and rawget(class, FIELD_NAME) == false then
		rawset(class, FIELD_NAME, nil)
		log("INFO", "Removed the declaration this fix added", { reason = reason })
	end
	Hooks.declared_by_us = false
	RestoreModScreenshots.correction_reported = false
	return true
end

-- Called by the framework. Must be idempotent in both directions.
function RestoreModScreenshots.SetEnabled(enabled, reason)
	enabled = enabled == true
	RestoreModScreenshots.enabled = enabled
	if enabled then return RestoreModScreenshots.DeclareField(reason) end
	return RestoreModScreenshots.RemoveField(reason)
end

-- The class may not exist yet when the registry first enables this fix, so try
-- again once a game is starting. DeclareField is idempotent, so a repeat is free.
function RestoreModScreenshots.Reapply(reason)
	if RestoreModScreenshots.enabled ~= true then return true end
	return RestoreModScreenshots.DeclareField(reason or "reapply")
end

-- Called before a Lua reload replaces this descriptor.
function RestoreModScreenshots.Quiesce(reason)
	return RestoreModScreenshots.SetEnabled(false, reason or "registry_reset")
end

FIX.set_enabled = RestoreModScreenshots.SetEnabled
FIX.quiesce = RestoreModScreenshots.Quiesce
FIX.events = {
	GameStateStarting = RestoreModScreenshots.Reapply,
}

-- Self-registration: SMRCommunityFixes.lua adopts this plain list when it loads.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreModScreenshots
