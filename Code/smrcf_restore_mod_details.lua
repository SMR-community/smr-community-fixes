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
-- List-entry updates download the current thumbnail before their first refresh,
-- and detail retrieval defers its refresh until formatting finishes. The stale
-- cached image and raw description therefore never reach the UI. The vanilla
-- screenshot cache is never edited.
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
	description = "Shows only current thumbnails and already-formatted HTML/Steam descriptions with Unicode, emoji, and clickable links.",
}

local RETRIEVE_FN = "ModsUIRetrieveModDetails"
local DOWNLOAD_FN = "WaitDownloadModScreenshots"
local SCHEDULE_FN = "ModsUIDownloadScreenshots"
local ENTRY_UPDATE_METHOD = "UpdateEntryFromSubscribedMod"
local BODY_STYLE_ID = "SMRCFModsUIDetailsBody"
local BOLD_STYLE_ID = "SMRCFModsUIDetailsBold"
local FALLBACK_FONT_NAMES = { "Segoe UI Emoji", "Segoe UI Symbol" }

-- Runs in the game environment, not this mod's restricted environment.
local WORKER_SRC = [==[function(mod, hooks, vanilla_thread, generation,
	format_long_description, fetch_current_details)
	if vanilla_thread and IsValidThread(vanilla_thread) then
		WaitThread(vanilla_thread)
	end
	if hooks.enabled ~= true or hooks.generation ~= generation then
		return { cancelled = true }
	end

	local details = mod and (mod.PdxModDetails or mod.Pdx)
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
		local function encode_utf8(codepoint)
			if not codepoint or codepoint < 0 or codepoint > 0x10ffff or
				(codepoint >= 0xd800 and codepoint <= 0xdfff) then
				return nil
			end
			if codepoint <= 0x7f then return string.char(codepoint) end
			if codepoint <= 0x7ff then
				return string.char(0xc0 + math.floor(codepoint / 0x40),
					0x80 + codepoint % 0x40)
			end
			if codepoint <= 0xffff then
				return string.char(0xe0 + math.floor(codepoint / 0x1000),
					0x80 + math.floor(codepoint / 0x40) % 0x40,
					0x80 + codepoint % 0x40)
			end
			return string.char(0xf0 + math.floor(codepoint / 0x40000),
				0x80 + math.floor(codepoint / 0x1000) % 0x40,
				0x80 + math.floor(codepoint / 0x40) % 0x40,
				0x80 + codepoint % 0x40)
		end

		local function decode_numeric_entities(text)
			text = text:gsub("&#[xX]([%x]+);", function(hex)
				return encode_utf8(tonumber(hex, 16)) or ("&#x" .. hex .. ";")
			end)
			return text:gsub("&#([%d]+);", function(decimal)
				return encode_utf8(tonumber(decimal, 10)) or ("&#" .. decimal .. ";")
			end)
		end

		input = decode_numeric_entities(tostring(input or ""))
		local known_steam_tags = {
			b = true, i = true, u = true, s = true, strike = true,
			h1 = true, h2 = true, h3 = true, list = true, olist = true,
			url = true, quote = true, code = true, noparse = true,
			hr = true, img = true, table = true, tr = true, th = true, td = true,
		}
		input = input:gsub("%[(/?)([%a%d]+)([^%]]*)%]", function(slash, name, rest)
			local lower = string.lower(name)
			if known_steam_tags[lower] then
				return "[" .. slash .. lower .. rest .. "]"
			end
		end)
		input = input:gsub("%[s%]", "[strike]"):gsub("%[/s%]", "[/strike]")
		input = input:gsub("%[url%](https?://.-)%[/url%]", function(link)
			return "[url=" .. link .. "]" .. link .. "[/url]"
		end)
		local is_steam = input:match("%[/?[bui]%]") or
			input:match("%[/?h[123]%]") or input:match("%[/?list%]") or
			input:match("%[/?olist%]") or input:match("%[url=") or
			input:match("%[/?quote[^%]]*%]") or input:match("%[/?strike%]") or
			input:match("%[/?code%]") or input:match("%[/?table%]") or
			input:match("%[hr%]") or input:match("%[%*%]")

		if is_steam and type(SteamParser) == "table" then
			local h1_open, h1_close = "\3SMRCF_H1_OPEN\4", "\3SMRCF_H1_CLOSE\4"
			local h2_open, h2_close = "\3SMRCF_H2_OPEN\4", "\3SMRCF_H2_CLOSE\4"
			local h3_open, h3_close = "\3SMRCF_H3_OPEN\4", "\3SMRCF_H3_CLOSE\4"
			local bullet_mark = "\3SMRCF_BULLET\4"
			local number_mark = "\3SMRCF_NUMBER_"
			input = input:gsub("%[h1%]", "\n\n" .. h1_open)
				:gsub("%[/h1%]", h1_close .. "\n\n")
				:gsub("%[h2%]", "\n\n" .. h2_open)
				:gsub("%[/h2%]", h2_close .. "\n\n")
				:gsub("%[h3%]", "\n\n" .. h3_open)
				:gsub("%[/h3%]", h3_close .. "\n\n")
			input = input:gsub("%[olist%](.-)%[/olist%]", function(list)
				local count = 0
				list = list:gsub("%[%*%]", function()
					count = count + 1
					return "\n" .. number_mark .. tostring(count) .. "\4"
				end)
				return "\n" .. list .. "\n"
			end)
			input = input:gsub("%[/?list%]", "\n")
				:gsub("%[%*%]", "\n" .. bullet_mark)
			local steam = SteamParser:new({
				AllowUrl = true,
				NormalTextStyle = hooks.body_style_id,
				BoldTextStyle = hooks.bold_style_id,
				ItalicTextStyle = hooks.body_style_id,
				Heading1TextStyle = hooks.bold_style_id,
				Heading2TextStyle = hooks.bold_style_id,
				Heading3TextStyle = hooks.bold_style_id,
				CodeTextStyle = hooks.body_style_id,
				QuoteTextStyle = hooks.body_style_id,
				HyperlinkTextStyle = "ModsUIDescriptionLink",
			})
			local output = steam:ConvertText(input)
			output = output:gsub(h1_open, "<scale 1200><style " .. hooks.bold_style_id .. ">")
				:gsub(h1_close, "</style><scale 1000>")
				:gsub(h2_open, "<scale 1100><style " .. hooks.bold_style_id .. ">")
				:gsub(h2_close, "</style><scale 1000>")
				:gsub(h3_open, "<style " .. hooks.bold_style_id .. ">")
				:gsub(h3_close, "</style>")
				:gsub(bullet_mark, "    •  ")
			output = output:gsub(number_mark .. "(%d+)\4", "    %1.  ")
			local hyperlink_stack = {}
			output = output:gsub("<[^>]+>", function(tag)
				if tag == "</h>" then
					local safe = table.remove(hyperlink_stack)
					return safe and "</h>" or ""
				end
				if not tag:match("^<h%s+") then return tag end
				local link = tag:match("^<h%s+(.+)>$") or ""
				local lower = string.lower(link)
				local safe = lower:match("^https?://") and not link:find("[<>\"']") and
					not link:find("[%c]")
				hyperlink_stack[#hyperlink_stack + 1] = safe == true
				if not safe then return "" end
				return "<h OpenUrl " .. link:gsub("%s", "+") .. ">"
			end)
			output = output:gsub("\n\n\n+", "\n\n")
			return "<fallback_font><style " .. hooks.body_style_id .. ">" ..
				output .. "</style></fallback_font>"
		end

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

		input = input:gsub("</?br%s*/?>", "<br/>")
		local output = parser:ConvertText(input)
		output = output:gsub(paragraph_mark, "\n\n")
		output = output:gsub(list_open_mark, "\n\n")
		output = output:gsub(list_close_mark, "\n\n")
		output = output:gsub(item_mark, "\n")
		output = output:gsub("\n\n\n+", "\n\n")
		return "<fallback_font><style " .. hooks.body_style_id .. ">" ..
			output .. "</style></fallback_font>"
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
	Hooks.protocol = 4
	Hooks.worker_fn = nil
	Hooks.cleanup_fn = nil
else
	Hooks = {
		protocol = 4,
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
		body_style_id = BODY_STYLE_ID,
		body_style = false,
		body_style_original = nil,
		bold_style_id = BOLD_STYLE_ID,
		bold_style = false,
		bold_style_original = nil,
		entry_update_original = false,
		entry_update_wrapper = false,
		entry_update_in_call = false,
		notification_gates = setmetatable({}, { __mode = "k" }),
		fallback_fonts = false,
		fallback_fonts_original = nil,
		fallback_fonts_expected = false,
	}
end
Hooks.workers = Hooks.workers or {}
Hooks.modified = Hooks.modified or setmetatable({}, { __mode = "k" })
Hooks.owned_paths = Hooks.owned_paths or {}
Hooks.notification_gates = Hooks.notification_gates or
	setmetatable({}, { __mode = "k" })
Hooks.download_original = Hooks.download_original or rawget(_G, DOWNLOAD_FN)
Hooks.schedule_original = Hooks.schedule_original or rawget(_G, SCHEDULE_FN)
Hooks.body_style_id = BODY_STYLE_ID
Hooks.bold_style_id = BOLD_STYLE_ID

local entry_class = rawget(_G, "ModUI_Entry")
local current_entry_update = type(entry_class) == "table" and
	entry_class[ENTRY_UPDATE_METHOD]
Hooks.entry_update_original = Hooks.entry_update_original or current_entry_update
Hooks.entry_update_base_original = Hooks.entry_update_base_original or
	Hooks.entry_update_original

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

if current_entry_update ~= Hooks.entry_update_wrapper and
	type(current_entry_update) == "function" then
	if current_entry_update ~= Hooks.entry_update_original then
		Hooks.entry_update_original_may_contain_wrapper = true
	end
	Hooks.entry_update_original = current_entry_update
end

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
if type(Hooks.entry_update_wrapper) ~= "function" then
	Hooks.entry_update_wrapper = function(...)
		if Hooks.entry_update_in_call == true then
			return Hooks.entry_update_base_original(...)
		end
		if Hooks.enabled == true and type(Hooks.entry_update_impl) == "function" then
			return Hooks.entry_update_impl(...)
		end
		if Hooks.entry_update_original_may_contain_wrapper == true then
			return Hooks.entry_update_base_original(...)
		end
		return Hooks.entry_update_original(...)
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
	if type(cache) == "table" then
		cache[BODY_STYLE_ID] = nil
		cache[BOLD_STYLE_ID] = nil
	end
end

local function same_array(left, right)
	if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
		return false
	end
	for index = 1, #left do
		if left[index] ~= right[index] then return false end
	end
	return true
end

function RestoreModDetails.InstallFallbackFonts()
	local configuration = rawget(_G, "config")
	local current = type(configuration) == "table" and configuration.FallbackFonts
	if type(current) ~= "table" then return true end
	if Hooks.fallback_fonts then
		if current == Hooks.fallback_fonts and
			same_array(current, Hooks.fallback_fonts_expected) then
			return true
		end
		-- A later owner changed or replaced the list. Do not overwrite it.
		return true
	end
	local installed = {}
	for index = 1, #current do installed[#installed + 1] = current[index] end
	for _, font in ipairs(FALLBACK_FONT_NAMES) do
		if not table.find(installed, font) then installed[#installed + 1] = font end
	end
	Hooks.fallback_fonts_original = current
	Hooks.fallback_fonts = installed
	Hooks.fallback_fonts_expected = table.copy(installed)
	configuration.FallbackFonts = installed
	return true
end

function RestoreModDetails.RestoreFallbackFonts(reason)
	local configuration = rawget(_G, "config")
	if type(configuration) == "table" and
		configuration.FallbackFonts == Hooks.fallback_fonts and
		same_array(configuration.FallbackFonts, Hooks.fallback_fonts_expected) then
		configuration.FallbackFonts = Hooks.fallback_fonts_original
	end
	Hooks.fallback_fonts = false
	Hooks.fallback_fonts_original = nil
	Hooks.fallback_fonts_expected = false
	return true
end

function RestoreModDetails.InstallBoldStyle()
	local styles = rawget(_G, "TextStyles")
	local text_style = rawget(_G, "TextStyle")
	if type(styles) ~= "table" or type(text_style) ~= "table" or
		type(text_style.new) ~= "function" then
		log("ERROR", "TextStyle API unavailable; cannot install rich bold text")
		return false
	end
	local body_current = styles[BODY_STYLE_ID]
	local bold_current = styles[BOLD_STYLE_ID]
	if Hooks.body_style and body_current ~= Hooks.body_style then
		if body_current == nil then
			-- LoadTextStyles rebuilt the global map during Mods Reload.
			Hooks.body_style = false
			Hooks.body_style_original = nil
		else
			log("ERROR", "A later text style owns the fix's body style id; leaving it unchanged", {
				style = BODY_STYLE_ID,
			})
			return false
		end
	end
	if Hooks.bold_style and bold_current ~= Hooks.bold_style then
		if bold_current == nil then
			Hooks.bold_style = false
			Hooks.bold_style_original = nil
		else
			log("ERROR", "A later text style owns the fix's style id; leaving it unchanged", {
				style = BOLD_STYLE_ID,
			})
			return false
		end
	end
	local base = styles.ModsUIDetailsDescription
	if not Hooks.body_style then
		Hooks.body_style_original = body_current
		Hooks.body_style = text_style:new({
			id = BODY_STYLE_ID,
			group = "ModsUI",
			FontName = base and base.FontName or "Noto Sans Regular",
			FontSize = 20,
			TextColor = base and base.TextColor or RGB(26, 26, 26),
			RolloverTextColor = base and base.RolloverTextColor or RGB(26, 26, 26),
			DisabledTextColor = base and base.DisabledTextColor or RGB(26, 26, 26),
			DisabledRolloverTextColor = base and base.DisabledRolloverTextColor or RGB(26, 26, 26),
			ShadowType = base and base.ShadowType or "shadow",
			ShadowSize = base and base.ShadowSize or 0,
			ShadowColor = base and base.ShadowColor or 0,
			ShadowDir = base and base.ShadowDir or point(1, 1),
		})
	end
	if not Hooks.bold_style then
		Hooks.bold_style_original = bold_current
		Hooks.bold_style = text_style:new({
			id = BOLD_STYLE_ID,
			group = "ModsUI",
			FontName = base and base.FontName or "Noto Sans Regular",
			FontSize = 20,
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
	end
	styles[BODY_STYLE_ID] = Hooks.body_style
	styles[BOLD_STYLE_ID] = Hooks.bold_style
	clear_bold_style_cache()
	return true
end

function RestoreModDetails.RestoreBoldStyle(reason)
	local styles = rawget(_G, "TextStyles")
	local restored = false
	if type(styles) == "table" and Hooks.body_style and
		styles[BODY_STYLE_ID] == Hooks.body_style then
		styles[BODY_STYLE_ID] = Hooks.body_style_original
		restored = true
	end
	if type(styles) == "table" and Hooks.bold_style and
		styles[BOLD_STYLE_ID] == Hooks.bold_style then
		styles[BOLD_STYLE_ID] = Hooks.bold_style_original
		restored = true
	end
	if restored then clear_bold_style_cache() end
	Hooks.body_style = false
	Hooks.body_style_original = nil
	Hooks.bold_style = false
	Hooks.bold_style_original = nil
	return true
end

local function begin_notification_gate(mod)
	if type(mod) ~= "table" then return nil end
	local gate = Hooks.notification_gates[mod]
	if gate then
		gate.depth = (gate.depth or 1) + 1
		return gate
	end
	gate = {
		depth = 1,
		dirty = false,
		original = rawget(mod, "ObjModified"),
	}
	gate.wrapper = function(target, ...)
		local active = Hooks.notification_gates[target]
		if active == gate and Hooks.enabled == true then
			active.dirty = true
			return
		end
		if type(gate.original) == "function" then
			return gate.original(target, ...)
		end
		local class = rawget(_G, "ModUI_Entry")
		local method = type(class) == "table" and class.ObjModified
		if type(method) == "function" and method ~= gate.wrapper then
			return method(target, ...)
		end
	end
	Hooks.notification_gates[mod] = gate
	rawset(mod, "ObjModified", gate.wrapper)
	return gate
end

local function release_notification_gate(mod, notify, force)
	local gate = type(mod) == "table" and Hooks.notification_gates[mod]
	if not gate then return true end
	if force ~= true and (gate.depth or 1) > 1 then
		gate.depth = gate.depth - 1
		return true
	end
	Hooks.notification_gates[mod] = nil
	if rawget(mod, "ObjModified") == gate.wrapper then
		rawset(mod, "ObjModified", gate.original)
	end
	if notify == true or gate.dirty == true then
		local current = mod.ObjModified
		if type(current) == "function" and current ~= gate.wrapper then
			local ok, failure = pcall(current, mod)
			if not ok then
				log("ERROR", "Could not release a deferred mod-entry refresh", {
					error = failure,
				})
				return false
			end
		end
	end
	return true
end

function RestoreModDetails.ReleaseNotificationGates(notify)
	local mods = {}
	for mod in pairs(Hooks.notification_gates) do mods[#mods + 1] = mod end
	local all_ok = true
	for _, mod in ipairs(mods) do
		if release_notification_gate(mod, notify, true) ~= true then all_ok = false end
	end
	return all_ok
end

local function call_retrieve_original(...)
	Hooks.in_call = true
	local original = Hooks.original
	local result = { pcall(original, ...) }
	Hooks.in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

local function call_entry_update_original(...)
	Hooks.entry_update_in_call = true
	local original = Hooks.entry_update_original
	local result = { pcall(original, ...) }
	Hooks.entry_update_in_call = false
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
	Hooks.detail_worker_mod = nil
	return true
end

function RestoreModDetails.CancelDetailWorker()
	local thread = Hooks.detail_worker
	if thread and Hooks.workers[thread] then
		DeleteThread(thread)
		Hooks.workers[thread] = nil
	end
	if Hooks.detail_worker_mod then
		release_notification_gate(Hooks.detail_worker_mod, true, true)
	end
	Hooks.detail_worker = nil
	Hooks.detail_worker_mod = nil
end

local function worker_finished(ok, report, failure)
	local current_thread = CurrentThread()
	Hooks.workers[current_thread] = nil
	if Hooks.detail_worker == current_thread then
		Hooks.detail_worker = nil
		Hooks.detail_worker_mod = nil
	end
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

local function hide_stale_thumbnail(mod)
	local record = Hooks.modified[mod] or {}
	local previous = record.thumbnail
	local current = mod.Thumbnail
	local original = current
	if previous and (current == previous.installed or previous.pending == true) then
		original = previous.original
	end
	mod.Thumbnail = nil
	record.thumbnail = {
		original = original,
		installed = nil,
		pending = true,
	}
	Hooks.modified[mod] = record
end

function RestoreModDetails.CorrectedEntryUpdate(mod, ...)
	local result = { call_entry_update_original(mod, ...) }
	if Hooks.enabled == true and type(mod) == "table" and
		(mod.PdxModDetails or mod.Pdx) then
		hide_stale_thumbnail(mod)
		local is_realtime = rawget(_G, "IsRealTimeThread")
		if type(is_realtime) == "function" and is_realtime() and
			compile_runtime() == true then
			local ok, report, failure = pcall(Hooks.worker_fn, mod, Hooks,
				false, Hooks.generation, false, true)
			if ok ~= true or failure then
				log("ERROR", "Could not refresh a thumbnail before its first render", {
					error = ok == true and failure or report,
					mod_id = type(mod.PdxModId) == "function" and mod:PdxModId(),
				})
			end
		end
	end
	return table.unpack(result)
end

Hooks.entry_update_impl = RestoreModDetails.CorrectedEntryUpdate

function RestoreModDetails.Corrected(mod, ...)
	RestoreModDetails.CancelDetailWorker()
	begin_notification_gate(mod)
	local generation = Hooks.generation
	local result = { call_retrieve_original(mod, ...) }
	local vanilla_thread = rawget(_G, "g_PopsRetrieveModDetailsThread")
	local create_thread = rawget(_G, "CreateRealTimeThread")
	if Hooks.enabled == true and mod ~= nil and type(create_thread) == "function" and
		compile_runtime() == true then
		local thread = create_thread(function(target, wait_for, token)
			local ok, report, failure = pcall(Hooks.worker_fn, target, Hooks,
				wait_for, token, true, false)
			release_notification_gate(target, true, true)
			worker_finished(ok, report, failure)
		end, mod, vanilla_thread, generation)
		Hooks.workers[thread] = true
		Hooks.detail_worker = thread
		Hooks.detail_worker_mod = mod
	else
		release_notification_gate(mod, true, true)
	end
	return table.unpack(result)
end

Hooks.impl = RestoreModDetails.Corrected

-- Queue vanilla's normal thumbnail/screenshots work. If an entry-update path
-- could not synchronously install the current thumbnail, wait for a tracked
-- current-thumbnail worker before returning.
function RestoreModDetails.CorrectedSchedule(mod, ...)
	local result = call_schedule_original(mod, ...)
	local record = mod and Hooks.modified[mod]
	local thumbnail = record and record.thumbnail
	local ready = thumbnail and thumbnail.installed and
		mod.Thumbnail == thumbnail.installed
	if result[1] == true and not ready and Hooks.enabled == true and mod ~= nil and
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
	begin_notification_gate(mod)
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
	release_notification_gate(mod, true)
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
	local current_entry_class = rawget(_G, "ModUI_Entry")
	local current_entry_update_fn = type(current_entry_class) == "table" and
		current_entry_class[ENTRY_UPDATE_METHOD]
	if type(current_fn) ~= "function" or type(current_download_fn) ~= "function" or
		type(current_schedule_fn) ~= "function" or
		type(current_entry_update_fn) ~= "function" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			fn = RETRIEVE_FN,
			download_fn = DOWNLOAD_FN,
			schedule_fn = SCHEDULE_FN,
			entry_update = ENTRY_UPDATE_METHOD,
			reason = reason,
		})
		return false
	end
	if compile_runtime() ~= true then return false end
	if RestoreModDetails.InstallFallbackFonts() ~= true then return false end
	if RestoreModDetails.InstallBoldStyle() ~= true then
		RestoreModDetails.RestoreFallbackFonts("style_install_failed")
		return false
	end
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
	if current_entry_update_fn ~= Hooks.entry_update_original and
		current_entry_update_fn ~= Hooks.entry_update_wrapper then
		Hooks.entry_update_original = current_entry_update_fn
		Hooks.entry_update_original_may_contain_wrapper = true
	end
	local was_enabled = Hooks.enabled == true
	ModsUIRetrieveModDetails = Hooks.wrapper
	WaitDownloadModScreenshots = Hooks.download_wrapper
	ModsUIDownloadScreenshots = Hooks.schedule_wrapper
	current_entry_class[ENTRY_UPDATE_METHOD] = Hooks.entry_update_wrapper
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
	local gates_ok = RestoreModDetails.ReleaseNotificationGates(true)
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
	local current_entry_class = rawget(_G, "ModUI_Entry")
	if type(current_entry_class) == "table" and
		current_entry_class[ENTRY_UPDATE_METHOD] == Hooks.entry_update_wrapper then
		current_entry_class[ENTRY_UPDATE_METHOD] = Hooks.entry_update_original
	end
	local style_ok = RestoreModDetails.RestoreBoldStyle(reason)
	local fallback_ok = RestoreModDetails.RestoreFallbackFonts(reason)
	log("INFO", "Restored captured mod-detail function and state", { reason = reason })
	return fields_ok and gates_ok and files_ok and style_ok and fallback_ok
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
