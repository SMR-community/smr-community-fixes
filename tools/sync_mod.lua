--[[
SMR Community Fixes registration tool, in Lua.

    lua tools/sync_mod.lua check
        Inspect every Code/smrcf_restore_*.lua and report two kinds of finding:
          PROBLEM  something only a person can fix - a duplicate id, a pinned
                   number already in use, a template placeholder left behind,
                   debug left true, a reference to framework internals, or a
                   missing description / set_enabled. Exit code 1.
          NOTICE   registration drift - a fix that is not in metadata.lua 'code'
                   or items.lua yet. Exit code 0, because `sync` fixes this
                   deterministically once the pull request is merged.

    lua tools/sync_mod.lua sync
        Rewrite the metadata.lua 'code' list and items.lua from the files on
        disk. The existing order is kept as-is and a new fix is appended at the
        end of the list; nothing is ever reordered, including Code/SMRCommunityFixes.lua.
        Bumps the integer 'version' if the payload changed - pass --bump to bump
        anyway.

Nobody has to run this. Contributors edit Lua by hand; GitHub runs `check` on a
pull request and `sync` after a merge (see .github/workflows/). A maintainer with
Lua installed can run it locally too.

Standard Lua only - no external modules. Directory listing goes through io.popen
because standard Lua has no readdir; `ls -1` on Linux and macOS, `dir /b` on
Windows.
]]

local REPO = (arg[0] or ""):gsub("[/\\]?tools[/\\]sync_mod%.lua$", "")
if REPO == "" then REPO = "." end

local CODE_DIR = REPO .. "/Code"
local METADATA = REPO .. "/metadata.lua"
local ITEMS = REPO .. "/items.lua"
local FRAMEWORK = "Code/SMRCommunityFixes.lua"

-- Deliberately empty: `sync` rewrites this list, so anything it inserts would come
-- back after every run. The explanation lives in CONTRIBUTING.md instead.
local CODE_LIST_COMMENT = ""

-- Framework internals. A fix that names any of these is not self-contained.
-- Framework internals. A fix that names any of these is not self-contained.
local FORBIDDEN = {
	"SMRCommunityFixesMod",
}

-- Left in the template for the author to replace.
local PLACEHOLDERS = {
	"VanillaFunctionName",
	"<what goes wrong>",
	"What this restores, in one short sentence.",
	"<short_repair_name>",
	"<what was corrected>",
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function read(path)
	local handle, err = io.open(path, "rb")
	if not handle then error("cannot read " .. path .. ": " .. tostring(err), 0) end
	local text = handle:read("a")
	handle:close()
	return text
end

local function write(path, text)
	local handle, err = io.open(path, "wb")
	if not handle then error("cannot write " .. path .. ": " .. tostring(err), 0) end
	handle:write(text)
	handle:close()
end

local function exists(path)
	local handle = io.open(path, "rb")
	if handle then handle:close() return true end
	return false
end

local function is_windows()
	return package.config:sub(1, 1) == "\\"
end

local function fix_files()
	local command = is_windows()
		and ('dir /b "' .. CODE_DIR:gsub("/", "\\") .. '"')
		or ("ls -1 '" .. CODE_DIR .. "'")
	local pipe = assert(io.popen(command, "r"))
	local names = {}
	for line in pipe:lines() do
		local name = line:gsub("%s+$", "")
		if name:match("^smrcf_restore_.+%.lua$") then names[#names + 1] = name end
	end
	pipe:close()
	table.sort(names)
	return names
end

-- The 'code' block in metadata.lua: its entries and the exact span it occupies.
local function code_block(meta)
	local from, to = meta:find("'code',%s*{.-\n\t}")
	if not from then error("metadata.lua: could not find the 'code' list", 0) end
	local entries = {}
	for path in meta:sub(from, to):gmatch('"([^"]+)"') do
		entries[#entries + 1] = path
	end
	return entries, from, to
end

local function item_entries(items)
	local entries = {}
	for path in items:gmatch("'CodeFileName',%s*\"([^\"]+)\"") do
		entries[#entries + 1] = path
	end
	return entries
end

local function same_list(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then return true end
	end
	return false
end

-- The list keeps the order it already has, and a new fix is appended at the end.
-- Nothing is ever moved: SMRCommunityFixes.lua stays exactly where the maintainer put it,
-- first or last or anywhere else. Position does not affect behaviour - the framework
-- adopts the descriptors already registered when it loads, and picks up anything
-- registered after it at ClassesBuilt, seeding defaults for those late arrivals.
local function desired_order(existing, on_disk)
	local ordered, seen = {}, {}
	for _, entry in ipairs(existing) do
		local name = entry:match("[^/]+$")
		-- Drop an entry whose file is gone; keep the framework, which is not in the
		-- fix list this walks.
		if entry == FRAMEWORK or contains(on_disk, name) then
			ordered[#ordered + 1] = "Code/" .. name
			seen[name] = true
		end
	end
	for _, name in ipairs(on_disk) do
		if not seen[name] then ordered[#ordered + 1] = "Code/" .. name end
	end
	if not seen["SMRCommunityFixes.lua"] then ordered[#ordered + 1] = FRAMEWORK end
	return ordered
end

--------------------------------------------------------------------------------
-- descriptor reading
--------------------------------------------------------------------------------

local function descriptor(path)
	local src = read(path)
	local function field(name, pattern)
		return src:match("\n\t" .. name .. " = " .. pattern .. ",")
	end
	local found_forbidden, found_placeholders = {}, {}
	for _, token in ipairs(FORBIDDEN) do
		if src:find(token, 1, true) then found_forbidden[#found_forbidden + 1] = token end
	end
	for _, token in ipairs(PLACEHOLDERS) do
		if src:find(token, 1, true) then
			found_placeholders[#found_placeholders + 1] = token
		end
	end
	return {
		id = field("id", '"([^"]*)"'),
		number = tonumber(field("number", "(%d+)")),
		label = field("label", '"([^"]*)"'),
		description = field("description", '"([^"]*)"'),
		debug = field("debug", "(%a+)"),
		has_registration = src:find("pending[#pending + 1] = FIX", 1, true) ~= nil,
		has_set_enabled = src:find("FIX.set_enabled", 1, true) ~= nil,
		forbidden = found_forbidden,
		placeholders = found_placeholders,
	}
end

--------------------------------------------------------------------------------
-- writing
--------------------------------------------------------------------------------

local function write_code_list(entries)
	local meta = read(METADATA)
	local _, from, to = code_block(meta)
	local lines = { "'code', {" }
	if CODE_LIST_COMMENT ~= "" then lines[#lines + 1] = CODE_LIST_COMMENT end
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = '\t\t"' .. entry .. '",'
	end
	lines[#lines + 1] = "\t}"
	write(METADATA, meta:sub(1, from - 1) .. table.concat(lines, "\n") .. meta:sub(to + 1))
end

local function write_items(entries)
	local parts = { "return {" }
	for _, entry in ipairs(entries) do
		local name = entry:match("([^/]+)%.lua$")
		parts[#parts + 1] = "\tPlaceObj('ModItemCode', {"
		parts[#parts + 1] = "\t\t'name', \"" .. name .. "\","
		parts[#parts + 1] = "\t\t'CodeFileName', \"" .. entry .. "\","
		parts[#parts + 1] = "\t}),"
	end
	parts[#parts + 1] = "}"
	write(ITEMS, table.concat(parts, "\n") .. "\n")
end

local function bump_version()
	local meta = read(METADATA)
	local old = meta:match("\n\t'version', (%d+),")
	if not old then error("metadata.lua: could not find 'version'", 0) end
	local new = tonumber(old) + 1
	write(METADATA, (meta:gsub("\n\t'version', %d+,",
		"\n\t'version', " .. new .. ",", 1)))
	return tonumber(old), new
end

--------------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------------

local function cmd_check()
	local problems, notices = {}, {}
	local on_disk = fix_files()
	local listed = code_block(read(METADATA))
	local items = item_entries(read(ITEMS))
	local expected = desired_order(listed, on_disk)

	if not same_list(listed, expected) then
		notices[#notices + 1] =
			"metadata.lua 'code' is not in sync - `sync` will fix this on merge"
	end
	if not same_list(items, listed) then
		notices[#notices + 1] =
			"items.lua does not match metadata.lua - `sync` will fix this on merge"
	end
	for _, entry in ipairs(listed) do
		if not exists(REPO .. "/" .. entry) then
			problems[#problems + 1] = "listed but missing on disk: " .. entry
		end
	end
	if not contains(listed, FRAMEWORK) then
		problems[#problems + 1] = FRAMEWORK ..
			" is missing from the 'code' list - without it no fix is ever adopted"
	end

	local ids, numbers = {}, {}
	for _, name in ipairs(on_disk) do
		local d = descriptor(CODE_DIR .. "/" .. name)
		local function problem(text) problems[#problems + 1] = name .. ": " .. text end

		if not d.id or d.id == "" then
			problem("no id in the FIX descriptor")
		elseif ids[d.id] then
			problem("id '" .. d.id .. "' is already used by " .. ids[d.id])
		else
			ids[d.id] = name
		end

		if d.number then
			if numbers[d.number] then
				problem(("pinned number %d is already used by %s")
					:format(d.number, numbers[d.number]))
			else
				numbers[d.number] = name
			end
		end

		if not d.description or d.description == "" then
			problem("no description in the FIX descriptor")
		end
		if not d.has_set_enabled then
			problem("FIX.set_enabled is never assigned")
		end
		if not d.has_registration then
			problem("missing the registration block (pending[#pending + 1] = FIX)")
		end
		if d.debug == "true" then
			problem("debug is true; set it to false before submitting")
		end
		if #d.forbidden > 0 then
			problem("references framework internals (" ..
				table.concat(d.forbidden, ", ") .. ") - a fix must be self-contained")
		end
		if #d.placeholders > 0 then
			problem("still contains template placeholders: " ..
				table.concat(d.placeholders, ", "))
		end
		if not contains(listed, "Code/" .. name) then
			notices[#notices + 1] = name ..
				" is not registered yet - it will be added automatically on merge"
		end
	end

	print(("%d fix files, %d code entries, %d items entries")
		:format(#on_disk, #listed, #items))
	for _, notice in ipairs(notices) do print("  NOTICE   " .. notice) end
	for _, problem in ipairs(problems) do print("  PROBLEM  " .. problem) end

	if #problems > 0 then
		print("")
		print(("%d problem(s) need a person. Nothing here is fixed automatically.")
			:format(#problems))
		os.exit(1)
	end
	print(#notices > 0 and "OK - no problems; registration will be completed on merge"
		or "OK - everything is registered and consistent")
end

local function cmd_sync(force_bump)
	local listed = code_block(read(METADATA))
	local entries = desired_order(listed, fix_files())
	local changed = not same_list(entries, listed)
	write_code_list(entries)
	write_items(entries)
	print(("code list: %d entries%s")
		:format(#entries, changed and " (changed)" or ""))
	if changed or force_bump then
		local old, new = bump_version()
		print(("version  %d -> %d"):format(old, new))
	else
		print("version  unchanged (pass --bump to force)")
	end
end

local command = arg[1]
if command == "check" then
	cmd_check()
elseif command == "sync" then
	cmd_sync(arg[2] == "--bump")
else
	print("usage: lua tools/sync_mod.lua check | sync [--bump]")
	os.exit(2)
end
