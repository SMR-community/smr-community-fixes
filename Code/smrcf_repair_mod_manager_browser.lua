-- Repair Mod Manager Browser
--
-- The v1.0.7 Paradox Mods browser presents mod details through three separate
-- faults. They are repaired together because they share one code path, and
-- repairing any one of them alone only exposes the next.
--
-- ModsUIRetrieveModDetails parses descriptions through HTMLParser, whose anchor
-- implementation deliberately emits inert "label [URL]" text and whose
-- unsupported tags discard their contents. The page already implements
-- OnHyperLink(OpenUrl), so the parser is leaving working UI support unused.
--
-- ModUI_Entry derives from ProtectedPropertyObject, whose __newindex asserts on
-- any key the class never declared (CommonLua/PropertyObject.lua:1819-1823). The
-- class declares ScreenshotPaths (CommonLua/UI/ModManager.lua:1229) but never
-- ScreenshotUrls, which line 797 assigns and ParadoxMods.lua:249 reads back. A
-- mod that has screenshots therefore asserts on the assignment, and where
-- asserts halt, the ModsUIDownloadScreenshots call on line 799 is never reached.
--
-- WaitDownloadModScreenshots caches images only by ModID and PreferredVersion.
-- Replacing an image without publishing a new mod version leaves the old
-- thumbnail on disk, and its screenshot branch calls AsyncPopsDownloadFile,
-- which is not a Lua global at all - the engine's own comment above that block
-- reads "todo: this is not working".
--
-- This fix declares the missing field, then wraps ModsUIRetrieveModDetails, the
-- vanilla thumbnail downloader, and the details dialog. Vanilla still performs
-- all of its normal work first. Fix-owned real-time workers format the returned
-- LongDescription with a private HTMLParser instance and download the latest
-- DisplayImagePath and screenshots to unique, fix-owned AppData files. Vanilla's
-- unfinished screenshot branch is therefore never needed and never repaired: its
-- URL list is hidden for the duration of the captured call.
-- List-entry updates download the current thumbnail before their first refresh,
-- while opening details prepares the complete image selector before the page is
-- spawned. Detail retrieval defers its refresh until every field is ready. Stale
-- images and raw descriptions therefore never reach the UI, and the existing
-- thumbnail-click behavior selects which image is shown at full size.
--
-- The browser is what makes that affordable. Vanilla rebuilds every visible row
-- whenever the list is shown - which is what leaving a mod page does - and resets
-- each Thumbnail to the stale cache path on the way, so a naive implementation
-- asks the network for images it already has, once per row, while the player
-- waits. Three things keep that off the screen: a row reads the image URL out of
-- the list response the game just built instead of spending a detail request of
-- its own, a recently downloaded URL is reused from disk rather than fetched
-- again, and a row refresh waits only briefly for its worker before letting it
-- finish in the background and refresh the entry itself.
--
-- AsyncWebRequest and the file APIs are unavailable in a mod environment. The
-- worker is compiled through LuaCodeToTuple without an env argument, matching
-- the game's own environment while keeping all ownership state in SharedModEnv.
-- Disable/reload cancels every worker, restores only field values still owned by
-- this fix, deletes only files this fix created, and restores the exact captured
-- function while this wrapper still owns the global.
--
-- Fallback font names are validated through UIL at every loaded text-style
-- size, including each style's current UI-scaled size, before they are exposed
-- to XText. The v1.0.7 parser probes glyphs only at size 10 even though it later
-- creates the selected face at the active style size; a face can pass that probe
-- and still return -1 at another size, which is then passed to UIL.MeasureText.

local FIX = {
	id = "repair_mod_manager_browser",
	beta = false,
	versions = { ["1.0.7"] = true },
	default_enabled = true,
	debug = false,
	label = "Repair Mod Manager Browser",
	description = "Displays each mod’s latest thumbnail and screenshots, and properly formats descriptions, including HTML/Steam markup, Unicode, emoji, and clickable links.",
}

local RETRIEVE_FN = "ModsUIRetrieveModDetails"
local DOWNLOAD_FN = "WaitDownloadModScreenshots"
local SCHEDULE_FN = "ModsUIDownloadScreenshots"
local DIALOG_MODE_FN = "ModsUISetDialogMode"
local ENTRY_UPDATE_METHOD = "UpdateEntryFromSubscribedMod"
local ENTRY_CLASS = "ModUI_Entry"
local SCREENSHOT_URLS_FIELD = "ScreenshotUrls"
local BODY_STYLE_ID = "SMRCFModsUIDetailsBody"
local BOLD_STYLE_ID = "SMRCFModsUIDetailsBold"
local DETAILS_FONT_SIZE = 20
local FALLBACK_FONT_NAMES = { "Segoe UI Emoji", "Segoe UI Symbol" }
-- How long a downloaded image may be reused for the same URL, and how long a
-- browser list refresh may block waiting for one. The wait is what keeps the
-- stale cached image from showing; past the deadline the worker finishes in the
-- background and refreshes the entry itself, so the browser never freezes.
local IMAGE_CACHE_TTL_MS = 5 * 60 * 1000
local LIST_REFRESH_WAIT_MS = 250

-- Runs in the game environment, not this mod's restricted environment.
local WORKER_SRC = [==[function(mod, hooks, vanilla_thread, generation,
	format_long_description, fetch_current_details)
	if vanilla_thread and IsValidThread(vanilla_thread) then
		WaitThread(vanilla_thread)
	end
	if hooks.enabled ~= true or hooks.generation ~= generation then
		return { cancelled = true }
	end

	-- The list responses already carry a current DisplayImagePath, so the browser
	-- paths read the entry the game just built rather than spending one
	-- AsyncPdxGetModDetails round trip per row. Only the detail page, which also
	-- needs LongDescription and the full screenshot set, asks the API itself -
	-- and only when the entry it was handed cannot supply an image at all.
	local details = mod and (mod.PdxModDetails or mod.Pdx)
	local detail_error
	local function image_url(source)
		local url = type(source) == "table" and source.DisplayImagePath or nil
		if type(url) ~= "string" or url == "" then return nil end
		return url
	end
	if mod and (fetch_current_details == true or
		(image_url(details) == nil and image_url(mod) == nil))
	then
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
		screenshots = false,
		screenshot_count = 0,
		mod_id = details.ModID,
	}
	local failures = {}

	local function same_array(left, right)
		if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
			return false
		end
		for index = 1, #left do
			if left[index] ~= right[index] then return false end
		end
		return true
	end

	-- Vanilla rebuilds its list entries constantly, and each rebuild resets
	-- Thumbnail to the stale cache path, which defeats the per-entry readiness
	-- check below and asks for the same image again. A short-lived url -> file
	-- map makes that second ask free. The window is deliberately small: the whole
	-- point of this fix is that an author can replace an image behind a URL that
	-- never changes, so the file is re-fetched once the entry goes cold.
	local function cached_download(url)
		local cache = hooks.file_cache
		local entry = type(cache) == "table" and cache[url] or nil
		if not entry then return nil end
		local age = RealTime() - (entry.time or 0)
		if age < 0 or age > (hooks.file_cache_ttl or 0) then return nil end
		if not io.exists(entry.path) then
			cache[url] = nil
			return nil
		end
		return entry.path
	end

	local function reserve_and_download(url, kind, index)
		local reused = cached_download(url)
		if reused then return reused, nil end
		local clean_url = url:match("^[^?#]+") or url
		local ext = string.lower(clean_url:match("%.([%w]+)$") or "jpg")
		local allowed = { jpg = true, jpeg = true, png = true, bmp = true, tga = true }
		if not allowed[ext] then ext = "jpg" end
		local mod_id = tostring(details.ModID or "unknown"):gsub("[^%w_-]", "_")
		hooks.next_file = (hooks.next_file or 0) + 1
		local nonce = hooks.next_file
		local base
		repeat
			base = string.format("AppData/SMRCFModDetails_%s_%s_%s_%s_%s",
				mod_id, kind, tostring(index or 0), tostring(RealTime()), tostring(nonce))
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
		if hooks.enabled ~= true or hooks.generation ~= generation then
			return nil, "cancelled"
		end
		if not err and type(hooks.file_cache) == "table" then
			hooks.file_cache[url] = { path = final_path, time = RealTime() }
		end
		return not err and final_path or nil, err
	end

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

	local url = image_url(details) or image_url(mod)
	if type(url) == "string" and url ~= "" then
		local existing = hooks.modified[mod]
		existing = existing and existing.thumbnail
		local ready = existing and existing.url == url and
			mod.Thumbnail == existing.installed and io.exists(existing.installed)
		if not ready then
			local final_path, err = reserve_and_download(url, "thumbnail", 0)
			if err then
				failures[#failures + 1] = "thumbnail download: " .. tostring(err)
			elseif final_path then
				local record = hooks.modified[mod] or {}
				local old = record.thumbnail
				local original = mod.Thumbnail
				if old and original == old.installed then original = old.original end
				mod.Thumbnail = final_path
				record.thumbnail = { original = original, installed = final_path, url = url }
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
	end

	if hooks.enabled ~= true or hooks.generation ~= generation then
		return report
	end

	-- A browser row is described by the list response, which carries an image but
	-- not always a screenshot set. Saying nothing about screenshots is not the
	-- same as saying there are none, so leave ScreenshotPaths untouched unless
	-- this response actually describes them.
	local screenshots = details.Screenshots
	if type(screenshots) ~= "table" then
		return report, #failures > 0 and table.concat(failures, "; ") or nil
	end

	local screenshot_urls = {}
	local seen_urls = {}
	do
		for index = 1, #screenshots do
			local item = screenshots[index]
			local screenshot_url = type(item) == "table" and item.Image or item
			if type(screenshot_url) == "string" and screenshot_url ~= "" and
				not seen_urls[screenshot_url] then
				seen_urls[screenshot_url] = true
				screenshot_urls[#screenshot_urls + 1] = screenshot_url
			end
		end
	end

	local record = hooks.modified[mod] or {}
	local old = record.screenshots
	local ready = old and old.installed == mod.ScreenshotPaths and
		same_array(old.urls, screenshot_urls)
	if ready then
		for index = 1, #old.installed do
			if not io.exists(old.installed[index]) then ready = false break end
		end
	end
	if not ready then
		local paths = {}
		for index = 1, #screenshot_urls do
			local path, err = reserve_and_download(screenshot_urls[index],
				"screenshot", index)
			if path then
				paths[#paths + 1] = path
			else
				failures[#failures + 1] = "screenshot " .. tostring(index) ..
					" download: " .. tostring(err)
			end
		end
		if hooks.enabled == true and hooks.generation == generation then
			local original = mod.ScreenshotPaths
			if old and original == old.installed then original = old.original end
			mod.ScreenshotPaths = paths
			record.screenshots = {
				original = original,
				installed = paths,
				urls = screenshot_urls,
			}
			hooks.modified[mod] = record
			report.changed = true
			report.screenshots = true
			report.screenshot_count = #paths
			local notify = rawget(_G, "Msg")
			if type(notify) == "function" then
				notify("PopsModsScreenshotsDownloaded", mod)
			else
				mod:ObjModified()
			end
		end
	else
		report.screenshot_count = #old.installed
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
	RestoreModDetails = { enabled = false, field_reported = false }
	rawset(_G, "SMRCFRestoreModDetails", RestoreModDetails)
end

local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and shared.SMRCF_ModDetailsHooks or nil
local Hooks
if type(previous_hooks) == "table" then
	Hooks = previous_hooks
	local previous_protocol = Hooks.protocol
	Hooks.protocol = 9
	if previous_protocol ~= Hooks.protocol then
		Hooks.fallback_fonts_validated = false
	end
	Hooks.worker_fn = nil
	Hooks.cleanup_fn = nil
else
	Hooks = {
		protocol = 9,
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
		dialog_original = rawget(_G, DIALOG_MODE_FN),
		dialog_wrapper = false,
		dialog_in_call = false,
		workers = {},
		modified = setmetatable({}, { __mode = "k" }),
		owned_paths = {},
		file_cache = {},
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
		fallback_font_sizes = false,
		fallback_fonts_validated = false,
	}
end
Hooks.workers = Hooks.workers or {}
Hooks.modified = Hooks.modified or setmetatable({}, { __mode = "k" })
Hooks.owned_paths = Hooks.owned_paths or {}
Hooks.file_cache = Hooks.file_cache or {}
Hooks.file_cache_ttl = IMAGE_CACHE_TTL_MS
Hooks.notification_gates = Hooks.notification_gates or
	setmetatable({}, { __mode = "k" })
Hooks.download_original = Hooks.download_original or rawget(_G, DOWNLOAD_FN)
Hooks.schedule_original = Hooks.schedule_original or rawget(_G, SCHEDULE_FN)
Hooks.dialog_original = Hooks.dialog_original or rawget(_G, DIALOG_MODE_FN)
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

local current_dialog = rawget(_G, DIALOG_MODE_FN)
if current_dialog ~= Hooks.dialog_wrapper and type(current_dialog) == "function" then
	if current_dialog ~= Hooks.dialog_original then
		Hooks.dialog_original_may_contain_wrapper = true
	end
	Hooks.dialog_original = current_dialog
end
Hooks.dialog_base_original = Hooks.dialog_base_original or Hooks.dialog_original

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
			if type(Hooks.font_revalidate_fn) == "function" then
				Hooks.font_revalidate_fn()
			end
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
if type(Hooks.dialog_wrapper) ~= "function" then
	Hooks.dialog_wrapper = function(...)
		if Hooks.dialog_in_call == true then return Hooks.dialog_base_original(...) end
		if Hooks.enabled == true and type(Hooks.dialog_impl) == "function" then
			return Hooks.dialog_impl(...)
		end
		if Hooks.dialog_original_may_contain_wrapper == true then
			return Hooks.dialog_base_original(...)
		end
		return Hooks.dialog_original(...)
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

-- The missing ScreenshotUrls declaration. __newindex accepts any key for which
-- rawget(class, key) is non-nil, and false matches how the neighbouring
-- ScreenshotPaths is declared. This is a class-wide change that outlives a Lua
-- reload, so what was found there is remembered in SharedModEnv rather than in
-- this chunk, and put back only while the field still holds the value written
-- here - a declaration a later patch makes official is never undone.
local function screenshot_field_state(class)
	local holder = type(shared) == "table" and shared or Hooks
	local state = holder.SMRCF_ScreenshotUrlsField
	if type(state) ~= "table" then
		state = { installed = false, original = rawget(class, SCREENSHOT_URLS_FIELD) }
		-- Earlier releases declared this field from a second fix file, either on
		-- its own or through a lease shared with this one. Adopt whichever of
		-- those recorded the original value, so a reload in the same session
		-- neither loses it nor leaves the declaration behind.
		local lease = holder.SMRCF_ScreenshotUrlsFieldLease
		local legacy = type(shared) == "table" and shared.SMRCF_ModScreenshotsHooks
		if type(lease) == "table" then
			state.installed = lease.installed == true
			state.original = lease.original
		elseif type(legacy) == "table" and legacy.declared_by_us == true and
			rawget(class, SCREENSHOT_URLS_FIELD) == false then
			state.installed = true
			state.original = nil
		end
		holder.SMRCF_ScreenshotUrlsFieldLease = nil
		holder.SMRCF_ScreenshotUrlsField = state
	end
	return state
end

function RestoreModDetails.AcquireScreenshotField(reason)
	local class = rawget(_G, ENTRY_CLASS)
	if type(class) ~= "table" then
		log("ERROR", "Required screenshot field class is unavailable", {
			class = ENTRY_CLASS,
			reason = reason,
		})
		return false
	end
	local state = screenshot_field_state(class)
	if state.installed ~= true then
		state.original = rawget(class, SCREENSHOT_URLS_FIELD)
	end
	if rawget(class, SCREENSHOT_URLS_FIELD) == nil then
		rawset(class, SCREENSHOT_URLS_FIELD, false)
		state.installed = true
		if RestoreModDetails.field_reported ~= true then
			RestoreModDetails.field_reported = true
			log("INFO", "Bug fix invoked: declared the missing ScreenshotUrls field",
				correction_context({
					repair = "declare_screenshot_urls",
					reason = "ModUI_Entry assigns ScreenshotUrls without declaring it, so ProtectedPropertyObject asserts",
					class = ENTRY_CLASS,
					field = SCREENSHOT_URLS_FIELD,
				}))
		end
	end
	return true
end

function RestoreModDetails.ReleaseScreenshotField(reason)
	local class = rawget(_G, ENTRY_CLASS)
	local holder = type(shared) == "table" and shared or Hooks
	local state = holder.SMRCF_ScreenshotUrlsField
	RestoreModDetails.field_reported = false
	if type(state) ~= "table" then return true end
	if state.installed == true and type(class) == "table" and
		rawget(class, SCREENSHOT_URLS_FIELD) == false then
		rawset(class, SCREENSHOT_URLS_FIELD, state.original)
		state.installed = false
		log("INFO", "Removed the ScreenshotUrls declaration this fix added", {
			reason = reason,
		})
	end
	return true
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

local function fallback_font_sizes(uil)
	local sizes, seen = {}, {}
	local function add(size)
		if type(size) ~= "number" or size < 1 then return end
		size = math.floor(size)
		if size < 1 or seen[size] then return end
		seen[size] = true
		sizes[#sizes + 1] = size
	end

	-- Size 10 is the parser's glyph probe. The details size is always relevant,
	-- even before this fix's two styles have been installed in TextStyles.
	add(10)
	add(DETAILS_FONT_SIZE)

	local ui_scale = 1000
	local get_ui_scale = rawget(_G, "GetUIScale")
	if type(get_ui_scale) == "function" then
		local ok, scale = pcall(get_ui_scale)
		if ok and type(scale) == "number" and scale > 0 then ui_scale = scale end
	end
	add(MulDivRound(DETAILS_FONT_SIZE, ui_scale, 1000))

	local styles = rawget(_G, "TextStyles")
	if type(styles) == "table" then
		for _, style in pairs(styles) do
			local size = type(style) == "table" and style.FontSize
			if type(size) == "number" then
				add(size)
				add(MulDivRound(size, ui_scale, 1000))
			end
		end
	end

	-- Include effective sizes already materialized at nonstandard control scales.
	local get_font_size = type(uil) == "table" and uil.GetFontSizeFromId
	local cache = rawget(_G, "TextStyleCache")
	if type(get_font_size) == "function" and type(cache) == "table" then
		for _, by_scale in pairs(cache) do
			if type(by_scale) == "table" then
				for _, metrics in pairs(by_scale) do
					local id = type(metrics) == "table" and metrics[1]
					if type(id) == "number" then
						local ok, size = pcall(get_font_size, id)
						if ok then add(size) end
					end
				end
			end
		end
	end

	table.sort(sizes)
	return sizes
end

function RestoreModDetails.InstallFallbackFonts()
	local configuration = rawget(_G, "config")
	local current = type(configuration) == "table" and configuration.FallbackFonts
	if type(current) ~= "table" then return true end
	local uil = rawget(_G, "UIL")
	local get_font_id = type(uil) == "table" and uil.GetFontID
	if type(get_font_id) ~= "function" then
		log("ERROR", "UIL.GetFontID unavailable; cannot validate fallback fonts")
		return false
	end

	local validation_sizes = fallback_font_sizes(uil)
	local original = current
	if Hooks.fallback_fonts then
		if current == Hooks.fallback_fonts and
			same_array(current, Hooks.fallback_fonts_expected)
		then
			if Hooks.fallback_fonts_validated == true and
				same_array(Hooks.fallback_font_sizes, validation_sizes)
			then
				return true
			end
			-- A previous protocol installed an unvalidated list. Rebuild it from
			-- the exact list that protocol captured instead of preserving a bad id.
			if type(Hooks.fallback_fonts_original) == "table" then
				original = Hooks.fallback_fonts_original
			end
		else
			-- A later owner changed or replaced the list. Do not overwrite it.
			return true
		end
	end

	local installed, rejected, rejected_details, seen = {}, {}, {}, {}
	local function consider(font)
		if type(font) ~= "string" or font == "" or seen[font] then return end
		seen[font] = true
		for index = 1, #validation_sizes do
			local size = validation_sizes[index]
			local ok, id = pcall(get_font_id, font, size)
			if ok ~= true or type(id) ~= "number" or id < 0 then
				rejected[#rejected + 1] = font
				rejected_details[#rejected_details + 1] =
					font .. " @ " .. tostring(size)
				return
			end
		end
		installed[#installed + 1] = font
	end
	for index = 1, #original do consider(original[index]) end
	for _, font in ipairs(FALLBACK_FONT_NAMES) do consider(font) end
	if #rejected > 0 then
		log("WARN", "Skipped unavailable fallback fonts", {
			fonts = rejected,
			failures = rejected_details,
			validated_sizes = validation_sizes,
		})
	end
	Hooks.fallback_fonts_original = original
	Hooks.fallback_fonts = installed
	Hooks.fallback_fonts_expected = table.copy(installed)
	Hooks.fallback_font_sizes = table.copy(validation_sizes)
	Hooks.fallback_fonts_validated = true
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
	Hooks.fallback_font_sizes = false
	Hooks.fallback_fonts_validated = false
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
			FontSize = DETAILS_FONT_SIZE,
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
			FontSize = DETAILS_FONT_SIZE,
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

local function call_dialog_original(...)
	Hooks.dialog_in_call = true
	local original = Hooks.dialog_original
	local result = { pcall(original, ...) }
	Hooks.dialog_in_call = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
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
			screenshots = report.screenshots == true,
			screenshot_count = report.screenshot_count,
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

local function capture_screenshot_urls(mod)
	if type(mod) ~= "table" then return end
	local record = Hooks.modified[mod] or {}
	local previous = record.screenshot_urls
	local current = rawget(mod, SCREENSHOT_URLS_FIELD)
	local original = current
	if previous and (current == previous.installed or previous.pending == true) then
		original = previous.original
	end
	record.screenshot_urls = {
		original = original,
		installed = nil,
		pending = true,
	}
	Hooks.modified[mod] = record
end

local function finish_screenshot_urls(mod)
	local record = type(mod) == "table" and Hooks.modified[mod]
	local field = record and record.screenshot_urls
	if not field or field.pending ~= true then return end
	field.installed = rawget(mod, SCREENSHOT_URLS_FIELD)
	field.pending = nil
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
	capture_screenshot_urls(mod)
	local generation = Hooks.generation
	local result = { call_retrieve_original(mod, ...) }
	local vanilla_thread = rawget(_G, "g_PopsRetrieveModDetailsThread")
	local create_thread = rawget(_G, "CreateRealTimeThread")
	if Hooks.enabled == true and mod ~= nil and type(create_thread) == "function" and
		compile_runtime() == true then
		local thread = create_thread(function(target, wait_for, token)
			local ok, report, failure = pcall(Hooks.worker_fn, target, Hooks,
				wait_for, token, true, false)
			finish_screenshot_urls(target)
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

-- The vanilla screenshot strip is conditional at template-spawn time. Prepare
-- current images before entering details so that the existing strip, including
-- its click-to-select behavior, is created in its normal place below the hero.
function RestoreModDetails.CorrectedDialogMode(win, mode, mode_param, ...)
	if mode == "details" and Hooks.enabled == true and compile_runtime() == true then
		local mod = type(mode_param) == "table" and
			(mode_param.ModEntry or mode_param) or nil
		local is_realtime = rawget(_G, "IsRealTimeThread")
		if type(mod) == "table" and type(is_realtime) == "function" and
			is_realtime() then
			local ok, report, failure = pcall(Hooks.worker_fn, mod, Hooks,
				false, Hooks.generation, true, true)
			if ok ~= true or failure then
				log("ERROR", "Could not prepare mod screenshots before opening details", {
					error = ok == true and failure or report,
					mod_id = type(mod.PdxModId) == "function" and mod:PdxModId(),
				})
			end
		end
	end
	return call_dialog_original(win, mode, mode_param, ...)
end

Hooks.dialog_impl = RestoreModDetails.CorrectedDialogMode

-- Wait a short moment for a browser-list worker, then leave it to finish on its
-- own. The wait is what stops the stale cached image being shown before the
-- current one arrives; waiting with no deadline is what made leaving a mod page
-- hang, because vanilla rebuilds every visible row and each row waited on its
-- own network round trip in turn. Past the deadline the worker still installs
-- the current image and refreshes the entry, one frame later than ideal.
local function wait_for_worker(thread, reason)
	local wait = rawget(_G, "WaitThread")
	if type(wait) ~= "function" then return false end
	wait(thread, LIST_REFRESH_WAIT_MS)
	local is_valid = rawget(_G, "IsValidThread")
	local finished = type(is_valid) ~= "function" or is_valid(thread) ~= true
	if finished ~= true then
		log("INFO", "Left an image worker running rather than blocking the browser", {
			reason = reason,
			wait_ms = LIST_REFRESH_WAIT_MS,
		})
	end
	return finished
end

-- Queue vanilla's normal thumbnail/screenshots work. If an entry-update path
-- could not synchronously install the current thumbnail, wait briefly for a
-- tracked current-thumbnail worker before returning.
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
				false, token, false, false)
			worker_finished(ok, report, failure)
		end, mod, generation)
		Hooks.workers[thread] = true
		wait_for_worker(thread, "schedule")
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
	-- This fix downloads current screenshots itself. Hide the URL list only for
	-- the captured vanilla call so its broken AsyncPopsDownloadFile branch cannot
	-- overwrite the ready selector or abort the shared download queue.
	local screenshot_urls = type(mod) == "table" and
		rawget(mod, SCREENSHOT_URLS_FIELD) or nil
	if screenshot_urls ~= nil then rawset(mod, SCREENSHOT_URLS_FIELD, nil) end
	local result = call_download_original(mod, ...)
	if screenshot_urls ~= nil and type(mod) == "table" and
		rawget(mod, SCREENSHOT_URLS_FIELD) == nil then
		rawset(mod, SCREENSHOT_URLS_FIELD, screenshot_urls)
	end
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
				false, token, false, false)
			worker_finished(ok, report, failure)
		end, mod, generation)
		Hooks.workers[thread] = true
		wait_for_worker(thread, "download")
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
			if record.screenshots and
				mod.ScreenshotPaths == record.screenshots.installed then
				mod.ScreenshotPaths = record.screenshots.original
				restored = true
			end
			if record.screenshot_urls and
				rawget(mod, SCREENSHOT_URLS_FIELD) ==
					record.screenshot_urls.installed then
				rawset(mod, SCREENSHOT_URLS_FIELD,
					record.screenshot_urls.original)
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
		if record.screenshots then
			for _, path in ipairs(record.screenshots.installed or empty_table) do
				protected[path] = true
			end
		end
	end
	local candidates = {}
	for path in pairs(Hooks.owned_paths) do
		if not protected[path] then candidates[path] = true end
	end
	if next(candidates) == nil then return false end
	local ok, failed = pcall(Hooks.cleanup_fn, candidates)
	if ok ~= true or type(failed) ~= "table" then
		log("ERROR", "Could not clean up fix-owned image files", {
			error = ok == true and "invalid cleanup result" or failed,
			reason = reason,
		})
		return false
	end
	for path in pairs(candidates) do
		if failed[path] == nil then Hooks.owned_paths[path] = nil end
	end
	if next(failed) ~= nil then
		log("ERROR", "Some fix-owned image files could not be removed", {
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
	local current_dialog_fn = rawget(_G, DIALOG_MODE_FN)
	local current_entry_class = rawget(_G, "ModUI_Entry")
	local current_entry_update_fn = type(current_entry_class) == "table" and
		current_entry_class[ENTRY_UPDATE_METHOD]
	if type(current_fn) ~= "function" or type(current_download_fn) ~= "function" or
		type(current_schedule_fn) ~= "function" or
		type(current_dialog_fn) ~= "function" or
		type(current_entry_update_fn) ~= "function" then
		log("ERROR", "Required v1.0.7 API is unavailable; fix not installed", {
			fn = RETRIEVE_FN,
			download_fn = DOWNLOAD_FN,
			schedule_fn = SCHEDULE_FN,
			dialog_fn = DIALOG_MODE_FN,
			entry_update = ENTRY_UPDATE_METHOD,
			reason = reason,
		})
		return false
	end
	if RestoreModDetails.AcquireScreenshotField(reason) ~= true then return false end
	if compile_runtime() ~= true then
		RestoreModDetails.ReleaseScreenshotField("compile_failed")
		return false
	end
	if RestoreModDetails.InstallFallbackFonts() ~= true then
		RestoreModDetails.ReleaseScreenshotField("font_install_failed")
		return false
	end
	Hooks.font_revalidate_fn = RestoreModDetails.InstallFallbackFonts
	if RestoreModDetails.InstallBoldStyle() ~= true then
		RestoreModDetails.RestoreFallbackFonts("style_install_failed")
		RestoreModDetails.ReleaseScreenshotField("style_install_failed")
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
	if current_dialog_fn ~= Hooks.dialog_original and
		current_dialog_fn ~= Hooks.dialog_wrapper then
		Hooks.dialog_original = current_dialog_fn
		Hooks.dialog_original_may_contain_wrapper = true
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
	ModsUISetDialogMode = Hooks.dialog_wrapper
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
	-- The cached files have just been deleted, so the map must go with them.
	Hooks.file_cache = {}
	if rawget(_G, RETRIEVE_FN) == Hooks.wrapper then
		ModsUIRetrieveModDetails = Hooks.original
	end
	if rawget(_G, DOWNLOAD_FN) == Hooks.download_wrapper then
		WaitDownloadModScreenshots = Hooks.download_original
	end
	if rawget(_G, SCHEDULE_FN) == Hooks.schedule_wrapper then
		ModsUIDownloadScreenshots = Hooks.schedule_original
	end
	if rawget(_G, DIALOG_MODE_FN) == Hooks.dialog_wrapper then
		ModsUISetDialogMode = Hooks.dialog_original
	end
	local current_entry_class = rawget(_G, "ModUI_Entry")
	if type(current_entry_class) == "table" and
		current_entry_class[ENTRY_UPDATE_METHOD] == Hooks.entry_update_wrapper then
		current_entry_class[ENTRY_UPDATE_METHOD] = Hooks.entry_update_original
	end
	local style_ok = RestoreModDetails.RestoreBoldStyle(reason)
	local fallback_ok = RestoreModDetails.RestoreFallbackFonts(reason)
	local screenshot_field_ok = RestoreModDetails.ReleaseScreenshotField(reason)
	log("INFO", "Restored captured mod-detail function and state", { reason = reason })
	return fields_ok and gates_ok and files_ok and style_ok and fallback_ok and
		screenshot_field_ok
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
