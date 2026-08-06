-- Restore Mod Details
--
-- The v1.0.7 Paradox Mods detail page has two related presentation faults.
-- `ModsUIRetrieveModDetails` parses descriptions through HTMLParser, whose
-- anchor implementation deliberately emits inert "label [URL]" text and whose
-- unsupported tags discard their contents. The page already implements
-- OnHyperLink(OpenUrl), so the parser is leaving working UI support unused.
-- Separately, WaitDownloadModScreenshots caches thumbnails only by ModID and
-- PreferredVersion. Replacing a thumbnail without publishing a new mod version
-- therefore leaves the old image on disk in Browse All, Installed Mods, and the
-- detail page.
--
-- This fix wraps ModsUIRetrieveModDetails and the vanilla thumbnail downloader.
-- Vanilla still performs all of its normal work first. Fix-owned real-time
-- workers format the returned LongDescription with a private HTMLParser instance
-- and download the latest DisplayImagePath to unique, fix-owned AppData files.
-- List entries without a full response fetch it without storing it on the entry.
-- The vanilla screenshot cache is never edited.
--
-- AsyncWebRequest and the file APIs are unavailable in a mod environment. The
-- worker is compiled through LuaCodeToTuple without an env argument, matching
-- the game's own environment while keeping all ownership state in SharedModEnv.
-- Disable/reload cancels every worker, restores only field values still owned by
-- this fix, deletes only files this fix created, and restores the exact captured
-- function while this wrapper still owns the global.

local FIX = {
	id = "restore_mod_details",
	number = 16,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Mod Details",
	description = "Loads current thumbnails throughout the Paradox Mods browser and restores website-style description formatting with clickable links.",
}

local RETRIEVE_FN = "ModsUIRetrieveModDetails"
local DOWNLOAD_FN = "WaitDownloadModScreenshots"
local SCHEDULE_FN = "ModsUIDownloadScreenshots"
local BOLD_STYLE_ID = "SMRCFModsUIDetailsBold"

-- Runs in the game environment, not this mod's restricted environment.
local WORKER_SRC = [==[function(mod, hooks, vanilla_thread, generation,
	format_long_description, fetch_current_details)
	if vanilla_thread and IsValidThread(vanilla_thread) then
		WaitThread(vanilla_thread)
	end
	if hooks.enabled ~= true or hooks.generation ~= generation then
		return { cancelled = true }
	end

	local details = mod and mod.PdxModDetails
	local detail_error
	if mod and fetch_current_details == true then
		local mod_id = type(mod.PdxModId) == "function" and mod:PdxModId()
		if mod_id then
			detail_error, details = AsyncPdxGetModDetails({ ModID = mod_id })
		end
	end
	if type(details) ~= "table" then
		return { changed = false }, detail_error and
			("current details: " .. tostring(detail_error)) or nil
	end

	local report = {
		changed = false,
		description = false,
		thumbnail = false,
		mod_id = details.ModID,
	}
	local failures = {}

	local function format_description(input)
		local parser = HTMLParser:new({ TextColor = RGB(26, 26, 26) })
		local base_begin_tag = parser.BeginTag
		local base_end_tag = parser.EndTag
		local paragraph_mark = "\1SMRCF_PARAGRAPH\2"
		local list_open_mark = "\1SMRCF_LIST_OPEN\2"
		local list_close_mark = "\1SMRCF_LIST_CLOSE\2"
		local item_mark = "\1SMRCF_LIST_ITEM\2"
		local passthrough = {
			DIV = true, SPAN = true, SECTION = true, ARTICLE = true,
			MAIN = true, HEADER = true, FOOTER = true, FIGURE = true,
			FIGCAPTION = true, FONT = true, SMALL = true, BIG = true,
			DL = true, DT = true, DD = true, TABLE = true, THEAD = true,
			TBODY = true, TFOOT = true, TR = true, TH = true, TD = true,
			S = true, DEL = true, STRIKE = true, CODE = true, PRE = true,
		}
		local block = {
			DIV = true, SECTION = true, ARTICLE = true, MAIN = true,
			HEADER = true, FOOTER = true, FIGURE = true, FIGCAPTION = true,
			DL = true, DT = true, DD = true, TABLE = true, TR = true,
			BLOCKQUOTE = true, PRE = true,
		}
		rawset(parser, "smrcf_lists", {})

		rawset(parser, "BeginTag", function(self, tag, attributes)
			tag = tag or ""
			if tag == "UL" or tag == "OL" then
				local lists = self.smrcf_lists
				lists[#lists + 1] = { ordered = tag == "OL", count = 0 }
				return { smrcf_list = true }
			end
			if tag == "LI" then
				local lists = self.smrcf_lists
				local list = lists[#lists]
				if list then
					list.count = list.count + 1
					return {
						smrcf_item = true,
						depth = #lists,
						prefix = list.ordered and (tostring(list.count) .. ".") or "•",
					}
				end
			end
			return base_begin_tag(self, tag, attributes)
		end)

		rawset(parser, "EndTag", function(self, tag, attributes, state,
			original_inner_html, processed_html)
			tag = tag or ""
			processed_html = processed_html or ""
			if tag == "A" then
				local link = attributes and (attributes.href or attributes.HREF)
				if type(link) ~= "string" then return processed_html end
				link = link:gsub("&amp;", "&"):gsub("&#38;", "&")
				local lower = string.lower(link)
				if not lower:match("^https?://") or link:find("[<>\"']") or
					link:find("[%c]") then
					return processed_html
				end
				link = link:gsub("%s", "+")
				local label = processed_html ~= "" and processed_html or link
				return string.format(
					"<color 0 0 238><h OpenUrl %s 0 0 238 underline>%s</h></color>",
					link, label)
			end
			if tag == "EM" or tag == "I" then
				return "<color 45 45 45 255>" .. processed_html .. "</color>"
			end
			if tag == "STRONG" or tag == "B" then
				return "<style " .. hooks.bold_style_id .. ">" ..
					processed_html .. "</style>"
			end
			if tag == "U" or tag == "INS" then
				return "<underline>" .. processed_html .. "</underline>"
			end
			if tag == "P" then
				if processed_html:match("%S") then
					return processed_html .. paragraph_mark
				end
				return ""
			end
			if tag == "LI" and state and state.smrcf_item then
				local indent = string.rep("    ", state.depth or 1)
				return item_mark .. indent .. state.prefix .. "  " ..
					processed_html:gsub("^%s+", ""):gsub("%s+$", "")
			end
			if tag == "UL" or tag == "OL" then
				local lists = self.smrcf_lists
				lists[#lists] = nil
				return list_open_mark .. processed_html .. list_close_mark
			end
			if tag == "BLOCKQUOTE" then
				return "\n    " .. processed_html:gsub("\n", "\n    ") .. "\n"
			end
			if tag == "HR" then return "\n--------------------\n" end
			if tag == "SCRIPT" or tag == "STYLE" or tag == "IMG" or
				tag == "IFRAME" or tag == "OBJECT" then
				return ""
			end
			if passthrough[tag] then
				return block[tag] and ("\n" .. processed_html .. "\n") or processed_html
			end
			return base_end_tag(self, tag, attributes, state,
				original_inner_html, processed_html)
		end)

		input = tostring(input or ""):gsub("</?br%s*/?>", "<br/>")
		local output = parser:ConvertText(input)
		output = output:gsub(paragraph_mark, "\n\n")
		output = output:gsub(list_open_mark, "\n\n")
		output = output:gsub(list_close_mark, "\n\n")
		output = output:gsub(item_mark, "\n")
		output = output:gsub("\n\n\n+", "\n\n")
		return output
	end

	local raw_description = details.LongDescription
	if format_long_description == true and type(raw_description) == "string" then
		local ok, formatted = pcall(format_description, raw_description)
		if ok then
			if hooks.enabled == true and hooks.generation == generation and
				formatted ~= mod.LongDescription then
				local record = hooks.modified[mod] or {}
				local old = record.description
				local original = mod.LongDescription
				if old and original == old.installed then original = old.original end
				mod.LongDescription = formatted
				record.description = { original = original, installed = formatted }
				hooks.modified[mod] = record
				report.changed = true
				report.description = true
				mod:ObjModified()
			end
		else
			failures[#failures + 1] = "description formatting: " .. tostring(formatted)
		end
	end

	if hooks.enabled ~= true or hooks.generation ~= generation then
		return report
	end

	local url = details.DisplayImagePath
	if type(url) == "string" and url ~= "" then
		local clean_url = url:match("^[^?#]+") or url
		local ext = string.lower(clean_url:match("%.([%w]+)$") or "jpg")
		local allowed = { jpg = true, jpeg = true, png = true, bmp = true, tga = true }
		if not allowed[ext] then ext = "jpg" end
		local mod_id = tostring(details.ModID or "unknown"):gsub("[^%w_-]", "_")
		hooks.next_file = (hooks.next_file or 0) + 1
		local nonce = hooks.next_file
		local base
		repeat
			base = string.format("AppData/SMRCFModDetails_%s_%s_%s", mod_id,
				tostring(RealTime()), tostring(nonce))
			nonce = nonce + 1
		until not io.exists(base .. ".temp") and not io.exists(base .. "." .. ext)
		hooks.next_file = nonce
		local temp_path = base .. ".temp"
		local final_path = base .. "." .. ext
		hooks.owned_paths[temp_path] = true
		hooks.owned_paths[final_path] = true

		local err, data = AsyncWebRequest({
			method = "GET",
			url = url,
			headers = { ["Cache-Control"] = "no-cache", Pragma = "no-cache" },
			pstr_response = true,
		})
		if not err and hooks.enabled == true and hooks.generation == generation then
			err = AsyncStringToFile(ConvertToOSPath(temp_path), data)
		end
		if not err and hooks.enabled == true and hooks.generation == generation then
			err = AsyncFileRename(ConvertToOSPath(temp_path), ConvertToOSPath(final_path))
			if not err then hooks.owned_paths[temp_path] = nil end
		end
		if err then
			failures[#failures + 1] = "thumbnail download: " .. tostring(err)
		elseif hooks.enabled == true and hooks.generation == generation then
			local record = hooks.modified[mod] or {}
			local old = record.thumbnail
			local original = mod.Thumbnail
			if old and original == old.installed then original = old.original end
			mod.Thumbnail = final_path
			record.thumbnail = { original = original, installed = final_path }
			hooks.modified[mod] = record
			report.changed = true
			report.thumbnail = true
			local notify = rawget(_G, "Msg")
			if type(notify) == "function" then
				notify("PdxModsThumbnailDownloaded", mod)
			else
				mod:ObjModified()
			end
		end
	end

	return report, #failures > 0 and table.concat(failures, "; ") or nil
end]==]

-- Also compiled in the game environment because AsyncFileDelete is blacklisted
-- for mods. Missing files count as clean: a cancelled worker may have reserved a
-- path before it reached the write.
local CLEANUP_SRC = [==[function(paths)
	local failed = {}
	for path in pairs(paths or empty_table) do
		local err = AsyncFileDelete(ConvertToOSPath(path))
		if err and err ~= "File Not Found" and err ~= "Path Not Found" then
			failed[path] = tostring(err)
		end
	end
	return failed
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
		if count > 20 then parts[#parts + 1] = "..." break end
		parts[#parts + 1] = tostring(key) .. "=" .. describe(item, depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function log(level, message, data)
	if level ~= "ERROR" and FIX.debug ~= true then return end
	local text = "[SMR Community Fixes][" .. level .. "][" .. FIX.id .. "] " .. tostring(message)
	if data ~= nil then text = text .. " " .. describe(data) end
	local mod_log = rawget(_G, "ModLog")
	if type(mod_log) == "function" then mod_log(text) else print(text) end
end

local RestoreModDetails = rawget(_G, "SMRCFRestoreModDetails")
if RestoreModDetails == nil then
	RestoreModDetails = { enabled = false }
	rawset(_G, "SMRCFRestoreModDetails", RestoreModDetails)
end

local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_ModDetailsHooks or nil
local Hooks
if type(previous_hooks) == "table" then
	Hooks = previous_hooks
	Hooks.protocol = 2
	Hooks.worker_fn = nil
	Hooks.cleanup_fn = nil
else
	Hooks = {
		protocol = 2,
		enabled = false,
		generation = 0,
		original = rawget(_G, RETRIEVE_FN),
		wrapper = false,
		in_call = false,
		download_original = rawget(_G, DOWNLOAD_FN),
		download_wrapper = false,
		download_in_call = false,
		schedule_original = rawget(_G, SCHEDULE_FN),
		schedule_wrapper = false,
		schedule_in_call = false,
		workers = {},
		modified = setmetatable({}, { __mode = "k" }),
		owned_paths = {},
		next_file = 0,
		bold_style_id = BOLD_STYLE_ID,
		bold_style = false,
		bold_style_original = nil,
	}
end
Hooks.workers = Hooks.workers or {}
Hooks.modified = Hooks.modified or setmetatable({}, { __mode = "k" })
Hooks.owned_paths = Hooks.owned_paths or {}
Hooks.download_original = Hooks.download_original or rawget(_G, DOWNLOAD_FN)
Hooks.schedule_original = Hooks.schedule_original or rawget(_G, SCHEDULE_FN)
Hooks.bold_style_id = BOLD_STYLE_ID

local current = rawget(_G, RETRIEVE_FN)
if current ~= Hooks.wrapper and type(current) == "function" then
	if current ~= Hooks.original then Hooks.original_may_contain_wrapper = true end
	Hooks.original = current
end
Hooks.base_original = Hooks.base_original or Hooks.original

local current_download = rawget(_G, DOWNLOAD_FN)
if current_download ~= Hooks.download_wrapper and type(current_download) == "function" then
	if current_download ~= Hooks.download_original then
		Hooks.download_original_may_contain_wrapper = true
	end
	Hooks.download_original = current_download
end
Hooks.download_base_original = Hooks.download_base_original or Hooks.download_original

local current_schedule = rawget(_G, SCHEDULE_FN)
if current_schedule ~= Hooks.schedule_wrapper and type(current_schedule) == "function" then
	if current_schedule ~= Hooks.schedule_original then
		Hooks.schedule_original_may_contain_wrapper = true
	end
	Hooks.schedule_original = current_schedule
end
Hooks.schedule_base_original = Hooks.schedule_base_original or Hooks.schedule_original

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
if type(Hooks.download_wrapper) ~= "function" then
	Hooks.download_wrapper = function(...)
		if Hooks.download_in_call == true then return Hooks.download_base_original(...) end
		if Hooks.enabled == true and type(Hooks.download_impl) == "function" then
			return Hooks.download_impl(...)
		end
		if Hooks.download_original_may_contain_wrapper == true then
			return Hooks.download_base_original(...)
		end
		return Hooks.download_original(...)
	end
end
if type(Hooks.schedule_wrapper) ~= "function" then
	Hooks.schedule_wrapper = function(...)
		if Hooks.schedule_in_call == true then return Hooks.schedule_base_original(...) end
		if Hooks.enabled == true and type(Hooks.schedule_impl) == "function" then
			return Hooks.schedule_impl(...)
		end
		if Hooks.schedule_original_may_contain_wrapper == true then
			return Hooks.schedule_base_original(...)
		end
		return Hooks.schedule_original(...)
	end
end
if type(shared) == "table" then shared.SMRCF_ModDetailsHooks = Hooks end

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

local function compile_runtime()
	if type(Hooks.worker_fn) == "function" and type(Hooks.cleanup_fn) == "function" then
		return true
	end
	local eval = rawget(_G, "LuaCodeToTuple")
	if type(eval) ~= "function" then
		log("ERROR", "LuaCodeToTuple unavailable; cannot compile detail repair")
		return false
	end
	local worker_err, worker_fn = eval(WORKER_SRC)
	local cleanup_err, cleanup_fn = eval(CLEANUP_SRC)
	if worker_err ~= nil or type(worker_fn) ~= "function" or
		cleanup_err ~= nil or type(cleanup_fn) ~= "function" then
		log("ERROR", "Failed to compile mod-detail worker", {
			worker_error = worker_err,
			cleanup_error = cleanup_err,
		})
		return false
	end
	Hooks.worker_fn = worker_fn
	Hooks.cleanup_fn = cleanup_fn
	return true
end

local function clear_bold_style_cache()
	local cache = rawget(_G, "TextStyleCache")
	if type(cache) == "table" then cache[BOLD_STYLE_ID] = nil end
end

function RestoreModDetails.InstallBoldStyle()
	local styles = rawget(_G, "TextStyles")
	local text_style = rawget(_G, "TextStyle")
	if type(styles) ~= "table" or type(text_style) ~= "table" or
		type(text_style.new) ~= "function" then
		log("ERROR", "TextStyle API unavailable; cannot install rich bold text")
		return false
	end
	local current = styles[BOLD_STYLE_ID]
	if Hooks.bold_style and current == Hooks.bold_style then return true end
	if Hooks.bold_style and current ~= Hooks.bold_style then
		log("ERROR", "A later text style owns the fix's style id; leaving it unchanged", {
			style = BOLD_STYLE_ID,
		})
		return false
	end
	local base = styles.ModsUIDetailsDescription
	Hooks.bold_style_original = current
	local owned = text_style:new({
		id = BOLD_STYLE_ID,
		group = "ModsUI",
		FontName = base and base.FontName or "Noto Sans Regular",
		FontSize = base and base.FontSize or 26,
		TextColor = base and base.TextColor or RGB(26, 26, 26),
		RolloverTextColor = base and base.RolloverTextColor or RGB(26, 26, 26),
		DisabledTextColor = base and base.DisabledTextColor or RGB(26, 26, 26),
		DisabledRolloverTextColor = base and base.DisabledRolloverTextColor or RGB(26, 26, 26),
		-- Relaunched ships no bold face for its Noto UI font. A one-pixel
		-- same-color outline preserves Noto's metrics and produces real visible
		-- emphasis instead of silently falling back to the regular face.
		ShadowType = "outline",
		ShadowSize = 1,
		ShadowColor = base and base.TextColor or RGB(26, 26, 26),
		ShadowDir = point(0, 0),
	})
	Hooks.bold_style = owned
	styles[BOLD_STYLE_ID] = owned
	clear_bold_style_cache()
	return true
end

function RestoreModDetails.RestoreBoldStyle(reason)
	local styles = rawget(_G, "TextStyles")
	if type(styles) == "table" and Hooks.bold_style and
		styles[BOLD_STYLE_ID] == Hooks.bold_style then
		styles[BOLD_STYLE_ID] = Hooks.bold_style_original
		clear_bold_style_cache()
	end
	Hooks.bold_style = false
	Hooks.bold_style_original = nil
	return true
end

local function call_retrieve_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

local function call_download_original(...)
	Hooks.download_in_call = true
	local original = Hooks.download_original
	local result = { pcall(original, ...) }
	Hooks.download_in_call = false
	return result
end

local function call_schedule_original(...)
	Hooks.schedule_in_call = true
	local original = Hooks.schedule_original
	local result = { pcall(original, ...) }
	Hooks.schedule_in_call = false
	return result
end

function RestoreModDetails.CancelWorkers()
	for thread in pairs(Hooks.workers) do
		DeleteThread(thread)
		Hooks.workers[thread] = nil
	end
	Hooks.detail_worker = nil
	return true
end

function RestoreModDetails.CancelDetailWorker()
	local thread = Hooks.detail_worker
	if thread and Hooks.workers[thread] then
		DeleteThread(thread)
		Hooks.workers[thread] = nil
	end
	Hooks.detail_worker = nil
end

local function worker_finished(ok, report, failure)
	local current_thread = CurrentThread()
	Hooks.workers[current_thread] = nil
	if Hooks.detail_worker == current_thread then Hooks.detail_worker = nil end
	if ok ~= true then
		log("ERROR", "Mod-detail worker failed", { error = report })
		return
	end
	if failure then
		log("ERROR", "Could not complete every mod-detail repair", {
			error = failure,
			mod_id = report and report.mod_id,
		})
	end
	if report and report.changed == true and Hooks.enabled == true then
		log("INFO", "Bug fix invoked: refreshed Paradox Mods presentation", correction_context({
			repair = "refresh_mod_details",
			reason = "the vanilla detail page reuses a version-only thumbnail cache and drops rich HTML/link behavior",
			mod_id = report.mod_id,
			description = report.description == true,
			thumbnail = report.thumbnail == true,
		}))
	end
end

function RestoreModDetails.Corrected(mod, ...)
	RestoreModDetails.CancelDetailWorker()
	local generation = Hooks.generation
	local result = { call_retrieve_original(mod, ...) }
	local vanilla_thread = rawget(_G, "g_PopsRetrieveModDetailsThread")
	local create_thread = rawget(_G, "CreateRealTimeThread")
	if Hooks.enabled == true and mod ~= nil and type(create_thread) == "function" and
		compile_runtime() == true then
		local thread = create_thread(function(target, wait_for, token)
			local ok, report, failure = pcall(Hooks.worker_fn, target, Hooks,
				wait_for, token, true, false)
			worker_finished(ok, report, failure)
		end, mod, vanilla_thread, generation)
		Hooks.workers[thread] = true
		Hooks.detail_worker = thread
	end
	return table.unpack(result)
end

Hooks.impl = RestoreModDetails.Corrected

-- The list loader calls this before it redraws a newly materialized Browse All
-- or Installed Mods entry. Queue vanilla's normal thumbnail/screenshots first,
-- then synchronously wait for a tracked current-thumbnail worker. The entry's
-- very first populated render therefore has the current image instead of the
-- version-keyed cache image.
function RestoreModDetails.CorrectedSchedule(mod, ...)
	local result = call_schedule_original(mod, ...)
	if result[1] == true and Hooks.enabled == true and mod ~= nil and
		type(rawget(_G, "CreateRealTimeThread")) == "function" and
		compile_runtime() == true then
		local generation = Hooks.generation
		local thread = CreateRealTimeThread(function(target, token)
			local ok, report, failure = pcall(Hooks.worker_fn, target, Hooks,
				false, token, false, true)
			worker_finished(ok, report, failure)
		end, mod, generation)
		Hooks.workers[thread] = true
		WaitThread(thread)
	end
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

Hooks.schedule_impl = RestoreModDetails.CorrectedSchedule

-- Browse All and Installed Mods both pass through this queue. Let vanilla finish
-- its thumbnail and screenshot work. If the initial-list worker already owns a
-- current thumbnail, restore that exact path after vanilla replaces it with the
-- stale cache. Calls from any other path still fetch a current full response.
function RestoreModDetails.CorrectedDownload(mod, ...)
	local record = mod and Hooks.modified[mod]
	local thumbnail = record and record.thumbnail
	local owned_at_entry = thumbnail and mod.Thumbnail == thumbnail.installed
	local result = call_download_original(mod, ...)
	if result[1] == true and Hooks.enabled == true and owned_at_entry then
		local latest = Hooks.modified[mod]
		latest = latest and latest.thumbnail
		if latest and mod.Thumbnail ~= latest.installed then
			mod.Thumbnail = latest.installed
			if type(mod.ObjModified) == "function" then mod:ObjModified() end
		end
	elseif result[1] == true and Hooks.enabled == true and mod ~= nil and
		type(rawget(_G, "CreateRealTimeThread")) == "function" and
		compile_runtime() == true then
		local generation = Hooks.generation
		local thread = CreateRealTimeThread(function(target, token)
			local ok, report, failure = pcall(Hooks.worker_fn, target, Hooks,
				false, token, false, true)
			worker_finished(ok, report, failure)
		end, mod, generation)
		Hooks.workers[thread] = true
		WaitThread(thread)
	end
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

Hooks.download_impl = RestoreModDetails.CorrectedDownload

function RestoreModDetails.RestoreModifiedEntries(reason)
	local all_ok = true
	for mod, record in pairs(Hooks.modified) do
		local ok, restored_or_error = pcall(function()
			local restored = false
			if record.description and mod.LongDescription == record.description.installed then
				mod.LongDescription = record.description.original
				restored = true
			end
			if record.thumbnail and mod.Thumbnail == record.thumbnail.installed then
				mod.Thumbnail = record.thumbnail.original
				restored = true
			end
			if restored and type(mod.ObjModified) == "function" then mod:ObjModified() end
			return restored
		end)
		if ok then
			Hooks.modified[mod] = nil
		elseif not ok then
			all_ok = false
			log("ERROR", "Could not restore a modified mod entry", {
				error = restored_or_error,
				reason = reason,
			})
		end
	end
	return all_ok
end

function RestoreModDetails.CleanupOwnedFiles(reason)
	if next(Hooks.owned_paths) == nil then return true end
	if compile_runtime() ~= true then return false end
	local protected = {}
	for _, record in pairs(Hooks.modified) do
		if record.thumbnail then protected[record.thumbnail.installed] = true end
	end
	local candidates = {}
	for path in pairs(Hooks.owned_paths) do
		if not protected[path] then candidates[path] = true end
	end
	if next(candidates) == nil then return false end
	local ok, failed = pcall(Hooks.cleanup_fn, candidates)
	if ok ~= true or type(failed) ~= "table" then
		log("ERROR", "Could not clean up fix-owned thumbnail files", {
			error = ok == true and "invalid cleanup result" or failed,
			reason = reason,
		})
		return false
	end
	for path in pairs(candidates) do
		if failed[path] == nil then Hooks.owned_paths[path] = nil end
	end
	if next(failed) ~= nil then
		log("ERROR", "Some fix-owned thumbnail files could not be removed", {
			files = failed,
			reason = reason,
		})
		return false
	end
	return next(Hooks.owned_paths) == nil
end

function RestoreModDetails.InstallHook(reason)
	local current_fn = rawget(_G, RETRIEVE_FN)
	local current_download_fn = rawget(_G, DOWNLOAD_FN)
	local current_schedule_fn = rawget(_G, SCHEDULE_FN)
	if type(current_fn) ~= "function" or type(current_download_fn) ~= "function" or
		type(current_schedule_fn) ~= "function" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			fn = RETRIEVE_FN,
			download_fn = DOWNLOAD_FN,
			schedule_fn = SCHEDULE_FN,
			reason = reason,
		})
		return false
	end
	if compile_runtime() ~= true then return false end
	if RestoreModDetails.InstallBoldStyle() ~= true then return false end
	if current_fn ~= Hooks.original and current_fn ~= Hooks.wrapper then
		Hooks.original = current_fn
		Hooks.original_may_contain_wrapper = true
	end
	if current_download_fn ~= Hooks.download_original and
		current_download_fn ~= Hooks.download_wrapper then
		Hooks.download_original = current_download_fn
		Hooks.download_original_may_contain_wrapper = true
	end
	if current_schedule_fn ~= Hooks.schedule_original and
		current_schedule_fn ~= Hooks.schedule_wrapper then
		Hooks.schedule_original = current_schedule_fn
		Hooks.schedule_original_may_contain_wrapper = true
	end
	local was_enabled = Hooks.enabled == true
	ModsUIRetrieveModDetails = Hooks.wrapper
	WaitDownloadModScreenshots = Hooks.download_wrapper
	ModsUIDownloadScreenshots = Hooks.schedule_wrapper
	RestoreModDetails.enabled = true
	Hooks.enabled = true
	if not was_enabled then
		local context = rawget(_G, "g_ParadoxModsContextObj")
		if type(context) == "table" then
			if type(context.GetMods) == "function" then
				local ok, failure = pcall(context.GetMods, context)
				if not ok then log("ERROR", "Could not reload Browse All", { error = failure }) end
			end
			if type(context.GetInstalledMods) == "function" then
				local ok, failure = pcall(context.GetInstalledMods, context)
				if not ok then log("ERROR", "Could not reload Installed Mods", { error = failure }) end
			end
		end
	end
	log("INFO", "Installed mod-detail hook", { reason = reason })
	return true
end

function RestoreModDetails.RestoreHook(reason)
	RestoreModDetails.enabled = false
	Hooks.enabled = false
	Hooks.generation = (Hooks.generation or 0) + 1
	RestoreModDetails.CancelWorkers()
	local fields_ok = RestoreModDetails.RestoreModifiedEntries(reason)
	local files_ok = RestoreModDetails.CleanupOwnedFiles(reason)
	if rawget(_G, RETRIEVE_FN) == Hooks.wrapper then
		ModsUIRetrieveModDetails = Hooks.original
	end
	if rawget(_G, DOWNLOAD_FN) == Hooks.download_wrapper then
		WaitDownloadModScreenshots = Hooks.download_original
	end
	if rawget(_G, SCHEDULE_FN) == Hooks.schedule_wrapper then
		ModsUIDownloadScreenshots = Hooks.schedule_original
	end
	local style_ok = RestoreModDetails.RestoreBoldStyle(reason)
	log("INFO", "Restored captured mod-detail function and state", { reason = reason })
	return fields_ok and files_ok and style_ok
end

function RestoreModDetails.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreModDetails.InstallHook(reason) end
	return RestoreModDetails.RestoreHook(reason)
end

function RestoreModDetails.Reapply(reason)
	if RestoreModDetails.enabled ~= true then return true end
	return RestoreModDetails.InstallHook(reason or "reapply")
end

function RestoreModDetails.Quiesce(reason)
	return RestoreModDetails.SetEnabled(false, reason or "registry_reset")
end

FIX.set_enabled = RestoreModDetails.SetEnabled
FIX.quiesce = RestoreModDetails.Quiesce
FIX.events = {
	GameStateStarting = RestoreModDetails.Reapply,
}

local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreModDetails
