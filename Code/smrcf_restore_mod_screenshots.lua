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
-- FAULT 2 - WaitDownloadModScreenshots is unfinished:
--
--   Attempt to create a new global 'temp'
--   Attempt to use an undefined global 'AsyncPopsDownloadFile'
--   CommonLua/Libs/Paradox/ParadoxMods.lua(252/260)
--
-- mod_prefix, err and temp are locals of the `if thumbnailUrl then` block, but
-- the screenshot block below uses them anyway (globals / nil). Separately, the
-- screenshot loop calls AsyncPopsDownloadFile, which is not registered as a Lua
-- global at all - MarsDebug asserts on the undefined name, and the engine
-- comment above the block reads "todo: this is not working".
--
-- Fault 1 is what keeps fault 2 hidden: with ScreenshotUrls never stored, `urls`
-- is nil and the broken block never runs. Repairing only the declaration trades
-- the first assert for the second.
--
-- THE REPAIR
--
-- Declaring the field is unchanged: the field is added to the class exactly as
-- ScreenshotPaths is declared.
--
-- For the download, a mod environment cannot call AsyncWebRequest /
-- AsyncStringToFile / AsyncFileRename / io (ModEnvBlacklist), and cannot assign
-- AsyncPopsDownloadFile (blacklisted via prefixes.AsyncPops). The corrected
-- WaitDownloadModScreenshots is therefore compiled through LuaCodeToTuple with
-- no env argument, so the chunk inherits the game's _ENV where those APIs
-- exist. That replacement declares mod_prefix / err / temp at function scope
-- and downloads screenshots with the same AsyncWebRequest path the thumbnail
-- half already uses. The wrapper installed on WaitDownloadModScreenshots calls
-- that compiled function when the fix is on.
--
-- If compilation fails, ScreenshotUrls are hidden for one vanilla call so the
-- broken block never runs: thumbnail only, no assert.

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
local FIELD_OWNER = "restore_mod_screenshots"
local DOWNLOAD_FN = "WaitDownloadModScreenshots"

-- Corrected WaitDownloadModScreenshots body. Compiled into the game environment
-- via LuaCodeToTuple (see compile_fixed_download). Keep this aligned with
-- ParadoxMods.lua:213-276 aside from the scoping fix and AsyncWebRequest.
local FIXED_DOWNLOAD_SRC = [==[function(mod)
	assert(IsKindOf(mod, "ModUI_Entry"))
	if not mod.Pdx then
		return
	end
	local thumbnailUrl = mod.DisplayImagePath
	local mod_prefix, err, temp
	if thumbnailUrl then
		local path, file, ext = SplitPath(thumbnailUrl)
		local version = mod.Pdx.PreferredVersion and mod.Pdx.PreferredVersion ~= "" and ("_" .. mod.Pdx.PreferredVersion) or "_1"
		mod_prefix = PdxModsScreenshotsPath .. mod.Pdx.ModID .. version
		local file_path = mod_prefix .. ext
		if not io.exists(file_path) then
			temp = PdxModsScreenshotsPath .. "download.temp"
			temp = ConvertToOSPath(temp)
			local req_err, file_data = AsyncWebRequest({method = "GET", url = thumbnailUrl})
			err = req_err
			if not err then
				err = AsyncStringToFile(temp, file_data)
			end
			if not err then
				err = AsyncFileRename(temp, ConvertToOSPath(file_path))
				if err then
					print(string.format("Could not rename file %s", temp))
				end
			else
				print(string.format("Downloading thumbnail failed for mod %s", mod.ModID))
			end
		end
		if not err then
			mod.Thumbnail = file_path
			Msg("PdxModsThumbnailDownloaded", mod)
		end
	end

	local urls = mod.ScreenshotUrls
	if urls then
		if not mod_prefix then
			local version = mod.Pdx.PreferredVersion and mod.Pdx.PreferredVersion ~= "" and ("_" .. mod.Pdx.PreferredVersion) or "_1"
			mod_prefix = PdxModsScreenshotsPath .. mod.Pdx.ModID .. version
		end
		mod.ScreenshotPaths = {}
		temp = PdxModsScreenshotsPath .. "screenshot.temp"
		temp = ConvertToOSPath(temp)
		for i = 1, #urls do
			local url = urls[i]
			local path, file, ext = SplitPath(url)
			local file_path = mod_prefix .. "_" .. i .. ext
			err = false
			if not io.exists(file_path) then
				local req_err, file_data = AsyncWebRequest({method = "GET", url = url})
				err = req_err
				if not err then
					err = AsyncStringToFile(temp, file_data)
				end
				if not err then
					err = AsyncFileRename(temp, ConvertToOSPath(file_path))
					if err then
						print(string.format("Could not rename file %s", temp))
					end
				else
					print(string.format("Downloading screenshot failed for mod %s", mod.ModID))
				end
			end
			if not err then
				mod.ScreenshotPaths[#mod.ScreenshotPaths + 1] = file_path
			end
		end
		Msg("PopsModsScreenshotsDownloaded", mod)
	end
end]==]

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
-- declared in a later patch, or stack a second wrapper.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_ModScreenshotsHooks or nil
local Hooks
if type(previous_hooks) == "table" then
	-- Same table the installed wrapper closes over. Update it in place so a
	-- Lua reload replaces Hooks.impl without leaving a stale wrapper on the
	-- global. Drop the compiled function so a source change is picked up.
	Hooks = previous_hooks
	Hooks.protocol = 4
	Hooks.fixed = nil
	Hooks.fetched = nil
else
	Hooks = {
		protocol = 4,
		declared_by_us = false,
		enabled = false,
		original = rawget(_G, DOWNLOAD_FN),
		wrapper = false,
		in_call = false,
		fixed = false,
	}
end

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

-- Fix 016 also repairs screenshots so either option can work independently.
-- A shared ownership lease prevents one fix from removing the protected-object
-- declaration while the other still needs it.
local function screenshot_field_lease(class)
	local holder = type(shared) == "table" and shared or Hooks
	local lease = holder.SMRCF_ScreenshotUrlsFieldLease
	if type(lease) ~= "table" then
		local current = rawget(class, FIELD_NAME)
		local legacy_owned = Hooks.declared_by_us == true and current == false
		lease = {
			owners = {},
			original = legacy_owned and nil or current,
			installed = legacy_owned,
		}
		if legacy_owned and Hooks.enabled == true then
			lease.owners[FIELD_OWNER] = true
		end
		holder.SMRCF_ScreenshotUrlsFieldLease = lease
	end
	lease.owners = lease.owners or {}
	return lease
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

-- Compiles FIXED_DOWNLOAD_SRC into a function whose _ENV is the game's global
-- table. LuaCodeToTuple is game code; omitting the env argument makes load use
-- that function's own _ENV, not the mod environment.
local function compile_fixed_download()
	if type(Hooks.fixed) == "function" then return true end
	local eval = rawget(_G, "LuaCodeToTuple")
	if type(eval) ~= "function" then
		log("ERROR", "LuaCodeToTuple unavailable; cannot compile screenshot download")
		return false
	end
	local err, fn = eval(FIXED_DOWNLOAD_SRC)
	if err ~= nil or type(fn) ~= "function" then
		log("ERROR", "Failed to compile fixed WaitDownloadModScreenshots", {
			error = err ~= nil and tostring(err) or "not a function",
		})
		return false
	end
	Hooks.fixed = fn
	return true
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
	local lease = screenshot_field_lease(class)
	if next(lease.owners) == nil and lease.installed ~= true then
		lease.original = rawget(class, FIELD_NAME)
	end
	local corrected = rawget(class, FIELD_NAME) == nil
	if corrected then
		rawset(class, FIELD_NAME, false)
		lease.installed = true
	end
	lease.owners[FIELD_OWNER] = true
	Hooks.declared_by_us = false
	if RestoreModScreenshots.correction_reported ~= true then
		RestoreModScreenshots.correction_reported = true
		log("INFO", corrected and
			"Bug fix invoked: declared the missing ScreenshotUrls field" or
			"ScreenshotUrls field already available", correction_context({
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
	local holder = type(shared) == "table" and shared or Hooks
	local lease = holder.SMRCF_ScreenshotUrlsFieldLease
	if type(lease) == "table" then
		lease.owners = lease.owners or {}
		lease.owners[FIELD_OWNER] = nil
		if next(lease.owners) == nil and lease.installed == true and
			type(class) == "table" and rawget(class, FIELD_NAME) == false then
			rawset(class, FIELD_NAME, lease.original)
			lease.installed = false
			log("INFO", "Removed the declaration this fix added", { reason = reason })
		end
	end
	Hooks.declared_by_us = false
	RestoreModScreenshots.correction_reported = false
	return true
end

-- Runs the compiled replacement when available. Otherwise hides ScreenshotUrls
-- so vanilla's broken block is skipped (thumbnail still downloads).
function RestoreModScreenshots.CorrectedDownload(mod)
	local urls = mod and mod.ScreenshotUrls
	local has_urls = type(urls) == "table" and #urls > 0

	if compile_fixed_download() == true and type(Hooks.fixed) == "function" then
		local ok, failure = pcall(Hooks.fixed, mod)
		if ok ~= true then error(failure) end
		if has_urls and RestoreModScreenshots.download_reported ~= true then
			RestoreModScreenshots.download_reported = true
			log("INFO", "Bug fix invoked: ran corrected WaitDownloadModScreenshots", correction_context({
				repair = "replace_download_screenshots",
				reason = "WaitDownloadModScreenshots scoping is broken and AsyncPopsDownloadFile is not a Lua global",
				mod_id = mod.ModID,
				screenshots = #urls,
			}))
		end
		return
	end

	if not has_urls then
		return call_original(mod)
	end

	log("ERROR", "Corrected download unavailable; screenshots skipped", {
		mod_id = mod and mod.ModID,
	})
	mod.ScreenshotUrls = nil
	local ok, failure = pcall(call_original, mod)
	mod.ScreenshotUrls = urls
	if ok ~= true then error(failure) end
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
	-- Compile may fail; the wrapper still goes on so CorrectedDownload can hide
	-- ScreenshotUrls and keep vanilla from asserting.
	if compile_fixed_download() ~= true then
		log("ERROR", "Screenshot download replacement failed to compile; using no-screenshot fallback", {
			reason = reason,
		})
	end
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
