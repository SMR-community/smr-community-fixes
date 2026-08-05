-- Restore Mod Screenshots
--
-- Screenshots never appear for a mod in the in-game Paradox Mods browser, and
-- opening one asserts. There are two separate faults, and the first hides the
-- second, so both are repaired here.
--
-- FAULT 1 - the field is never declared:
--
--   Creating a new key 'ScreenshotUrls' in a protected object 'ModUI_Entry'.
--   CommonLua/PropertyObject.lua(1822): metamethod __newindex
--   CommonLua/UI/ModManager.lua(797)
--
-- ModUI_Entry derives from ProtectedPropertyObject, whose __newindex asserts on
-- any key the class never declared (CommonLua/PropertyObject.lua:1819-1823).
-- The class declares ScreenshotPaths at line 1229 but never ScreenshotUrls,
-- while line 797 assigns mod.ScreenshotUrls and ParadoxMods.lua:249 reads it
-- back. Writer and reader agree on the name; only the declaration is missing.
--
-- FAULT 2 - the download reads three out-of-scope locals:
--
--   Attempt to create a new global 'temp'
--   CommonLua/Libs/Paradox/ParadoxMods.lua(252): global WaitDownloadModScreenshots
--
-- In WaitDownloadModScreenshots, mod_prefix (line 222), err and temp (line 224)
-- are locals of the `if thumbnailUrl then` block. The screenshot block below it
-- uses all three anyway, so they resolve as globals: temp and err create new
-- globals, which the mod environment asserts on
-- (CommonLua/Classes/Mod.lua:1560), and mod_prefix reads back nil, so
-- `mod_prefix .. "_" .. i` at line 257 cannot build a path at all. The engine's
-- own comment above it reads "todo: this is not working".
--
-- Fault 1 is what keeps fault 2 hidden: with ScreenshotUrls never stored, `urls`
-- is nil and the broken block never runs. Repairing only the declaration - which
-- is what this fix did originally - trades the first assert for the second.
--
-- THE REPAIR
--
-- Declaring the field is unchanged: the field is added to the class exactly as
-- ScreenshotPaths is declared, so the assignment stops being a new key.
--
-- For the download, the mod environment blocks io, AsyncWebRequest,
-- AsyncStringToFile and AsyncFileRename (Mod.lua ModEnvBlacklist), so the
-- vanilla body cannot simply be rewritten here - the thumbnail half is
-- unreachable from a mod. Vanilla therefore still does the thumbnail, with the
-- URLs hidden from it for the duration of that one call so its broken block
-- cannot run, and this fix then performs the screenshot download vanilla
-- intended, using the calls a mod may make.
--
-- Two differences from what vanilla's code was reaching for, both forced by the
-- blocked calls and neither visible to a player:
--   * files download straight to their final path rather than to a temporary
--     one that is renamed, because AsyncFileRename is blocked;
--   * a file already on disk cannot be detected, because io and
--     AsyncGetFileAttribute are both blocked, so a per-session record of what
--     has been fetched stands in for vanilla's io.exists check.
--
-- Left alone: the thumbnail half, including its own shadowed `err` at line 228
-- that makes the outer `err` always nil. That is a separate fault with a
-- separate effect, and correcting it here would change thumbnail behaviour.

local FIX = {
	id = "restore_mod_screenshots",
	number = 15,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Mod Screenshots",
	description = "Shows a mod's screenshots in the Paradox Mods browser instead of two errors and no pictures.",
}

local CLASS_NAME = "ModUI_Entry"
local FIELD_NAME = "ScreenshotUrls"
local DOWNLOAD_FN = "WaitDownloadModScreenshots"

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
		download_reported = false,
	}
	rawset(_G, "SMRCFRestoreModScreenshots", RestoreModScreenshots)
end

-- Whether this module is the one that added the field, plus the captured vanilla
-- download function and this fix's wrapper. Kept in SharedModEnv so a Lua reload
-- cannot lose track and leave the field behind, remove a field the game itself
-- declared in a later patch, or stack a second wrapper. `protocol` rejects a
-- table left by an older, differently shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_ModScreenshotsHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 2 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 2,
		declared_by_us = false,
		enabled = false,
		original = rawget(_G, DOWNLOAD_FN),
		wrapper = false,
		in_call = false,
		-- What has already been fetched this session, keyed by file prefix.
		-- Stands in for vanilla's io.exists, which a mod cannot call.
		fetched = {},
	}
end
if type(Hooks.fetched) ~= "table" then Hooks.fetched = {} end

local current_download = rawget(_G, DOWNLOAD_FN)
if current_download ~= Hooks.wrapper and type(current_download) == "function" then
	if current_download ~= Hooks.original then Hooks.original_may_contain_wrapper = true end
	Hooks.original = current_download
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
	shared.SMRCF_ModScreenshotsHooks = Hooks
end

-- Calls the vanilla download. Hooks.in_call is raised for the duration so that if
-- vanilla reaches this same function again, the wrapper passes it straight through
-- instead of recursing. pcall only guarantees the flag comes back down; the error
-- is re-raised unchanged, so a real vanilla failure is never swallowed.
local function call_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
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

-- The file prefix vanilla builds at ParadoxMods.lua:222, computed here without
-- depending on the thumbnail block having run. Returns nil when the mod carries
-- nothing to build a path from, which is the caller's signal to leave it alone.
local function screenshot_prefix(mod)
	local base = rawget(_G, "PdxModsScreenshotsPath")
	local pdx = mod and mod.Pdx
	local mod_id = pdx and pdx.ModID
	if type(base) ~= "string" or mod_id == nil then return nil end
	local preferred = pdx.PreferredVersion
	local version = (preferred and preferred ~= "") and ("_" .. preferred) or "_1"
	return base .. mod_id .. version
end

-- The repair for fault 2, standing in for the screenshot half of
-- WaitDownloadModScreenshots.
--
-- Vanilla still runs, because only it can do the thumbnail - the calls that half
-- needs are blocked for mods. Its screenshot block is skipped by hiding the URLs
-- for the length of that one call, which is the whole reason this fix can leave
-- the thumbnail untouched. The URLs go back before anything else looks at the
-- mod, including when vanilla raises.
function RestoreModScreenshots.CorrectedDownload(mod)
	local urls = mod and mod.ScreenshotUrls
	if type(urls) ~= "table" or #urls == 0 then
		-- Nothing to correct: vanilla's broken block only runs when urls is set.
		return call_original(mod)
	end

	local prefix = screenshot_prefix(mod)
	local split_path = rawget(_G, "SplitPath")
	local to_os_path = rawget(_G, "ConvertToOSPath")
	local download = rawget(_G, "AsyncPopsDownloadFile")
	if prefix == nil or type(split_path) ~= "function" or
		type(to_os_path) ~= "function" or type(download) ~= "function"
	then
		log("ERROR", "Required v1.0.7 API is unavailable; screenshots left to vanilla", {
			has_prefix = prefix ~= nil,
			has_split_path = type(split_path) == "function",
			has_convert = type(to_os_path) == "function",
			has_download = type(download) == "function",
		})
		return call_original(mod)
	end

	mod.ScreenshotUrls = nil
	local ok, failure = pcall(call_original, mod)
	mod.ScreenshotUrls = urls
	if ok ~= true then error(failure) end

	local cached = Hooks.fetched[prefix]
	if type(cached) == "table" and #cached == #urls then
		mod.ScreenshotPaths = cached
	else
		local paths = {}
		for i = 1, #urls do
			local url = urls[i]
			local _, _, ext = split_path(url)
			local file_path = prefix .. "_" .. i .. (ext or "")
			local failed = download(url, to_os_path(file_path))
			if failed then
				log("ERROR", "Downloading screenshot failed", {
					mod_id = mod.ModID,
					index = i,
					error = tostring(failed),
				})
			else
				paths[#paths + 1] = file_path
			end
		end
		Hooks.fetched[prefix] = paths
		mod.ScreenshotPaths = paths
	end

	local msg = rawget(_G, "Msg")
	if type(msg) == "function" then
		msg("PopsModsScreenshotsDownloaded", mod)
	end

	if RestoreModScreenshots.download_reported ~= true then
		RestoreModScreenshots.download_reported = true
		log("INFO", "Bug fix invoked: downloaded the mod's screenshots", correction_context({
			repair = "download_screenshots",
			reason = "WaitDownloadModScreenshots uses mod_prefix, err and temp outside the block that declares them",
			mod_id = mod.ModID,
			screenshots = #urls,
		}))
	end
	return
end

Hooks.impl = RestoreModScreenshots.CorrectedDownload

-- Installs the wrapper. If something replaced the vanilla function since this
-- file loaded, that version is captured as the new original, so another mod's
-- work stays in the chain.
function RestoreModScreenshots.InstallHook(reason)
	local current_fn = rawget(_G, DOWNLOAD_FN)
	if type(current_fn) ~= "function" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			fn = DOWNLOAD_FN,
			reason = reason,
		})
		return false
	end
	if current_fn ~= Hooks.original and current_fn ~= Hooks.wrapper then
		Hooks.original = current_fn
		Hooks.original_may_contain_wrapper = true
	end
	-- Plain assignment, never rawset. Inside a mod, _G is the mod's own
	-- environment table: reads fall through to the real globals, but a rawset
	-- writes only into that table, where the game would never see it. An
	-- assignment goes through ModEnvMeta.__newindex, which writes the real one.
	WaitDownloadModScreenshots = Hooks.wrapper
	Hooks.enabled = true
	log("INFO", "Installed screenshot download hook", { reason = reason })
	return true
end

-- Turning the fix off restores the captured function, but only if the global is
-- still this fix's wrapper. If another mod wrapped ours afterwards, replacing the
-- global would destroy that mod's hook, so the wrapper stays installed and passes
-- everything straight through.
function RestoreModScreenshots.RestoreHook(reason)
	Hooks.enabled = false
	if rawget(_G, DOWNLOAD_FN) == Hooks.wrapper then
		WaitDownloadModScreenshots = Hooks.original
	end
	RestoreModScreenshots.download_reported = false
	log("INFO", "Restored captured screenshot download", { reason = reason })
	return true
end

-- Called by the framework. Must be idempotent in both directions. The field is
-- declared before the hook is installed, because the corrected download assigns
-- ScreenshotUrls and that assignment is exactly what fault 1 rejects.
function RestoreModScreenshots.SetEnabled(enabled, reason)
	enabled = enabled == true
	RestoreModScreenshots.enabled = enabled
	if enabled then
		if RestoreModScreenshots.DeclareField(reason) ~= true then return false end
		return RestoreModScreenshots.InstallHook(reason)
	end
	local restored = RestoreModScreenshots.RestoreHook(reason)
	return RestoreModScreenshots.RemoveField(reason) and restored
end

-- The class and the download function may not exist yet when the registry first
-- enables this fix, so try again once a game is starting. Both steps are
-- idempotent, so a repeat is free.
function RestoreModScreenshots.Reapply(reason)
	if RestoreModScreenshots.enabled ~= true then return true end
	reason = reason or "reapply"
	if RestoreModScreenshots.DeclareField(reason) ~= true then return false end
	return RestoreModScreenshots.InstallHook(reason)
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
