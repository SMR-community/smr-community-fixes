-- SMR Community Fixes - community-maintained collection of Surviving Mars: Relaunched fixes.
--
-- This is the only framework file. Every other file in Code/ is one bug fix and
-- is completely self-contained: a fix never calls a function defined here.
--
-- A fix registers itself by appending its descriptor table to the plain global
-- list _G.SMRCommunityFixesPending. This file loads last, adopts that list, disables any
-- fix that disappeared since the previous Lua load, and drives everything else:
-- settings storage, the Options category, and the checklist UI.
--
-- Descriptor contract (see templates/smrcf_TEMPLATE.lua):
--   id              string, unique, permanent - the saved-settings key
--   number          integer, unique - the row number shown in the panel. Every
--                   shipped fix leaves it out, so the rows are numbered by list
--                   position and removing a fix renumbers the ones after it.
--   beta            boolean
--   versions        { ["1.0.7"] = true }
--   default_enabled boolean
--   debug           boolean, false when published
--   label           plain string, the row title
--   description      plain string, the row explanation
--   set_enabled     function(enabled, reason) -> boolean
--   quiesce         optional function(reason) -> boolean
--   events          optional { GameStateStarting = fn, DoneGame = fn, ... }

local Mod = rawget(_G, "SMRCommunityFixesMod")
if type(Mod) ~= "table" then
	Mod = {
		booted = false,
		entries = {},
		entries_by_id = {},
		panel = {
			root = false,
			list = false,
			scrollbar = false,
			count_text = false,
			search = "",
			search_edit = false,
			version_control = false,
			version_filter = false,
			pending = false,
			checkboxes = {},
		},
		options = {
			category = false,
		},
	}
	rawset(_G, "SMRCommunityFixesMod", Mod)
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local Config = {
	MOD_ID = "SMRCF",
	ENABLE_MOD = true,
	DEFAULT_TARGET_VERSION = "1.0.7",
	ALL_VERSIONS_FILTER = "all",

	-- Publish defaults: framework diagnostics are disabled. Errors are never
	-- gated. Setting DEBUG_LOGS to true also turns on every fix's own debug
	-- flag when the registry is adopted, producing a full diagnostic build.
	DEBUG_LOGS = false,
	DEBUG_API = false,
	DEBUG_UI = false,
	DEBUG_PERSISTENCE = false,

	PANEL_LIST_HEIGHT_PER_MILLE = 600,
	PANEL_LIST_FALLBACK_HEIGHT = 640,
}
Config.TARGET_GAME_VERSION = Config.DEFAULT_TARGET_VERSION

Config.TEXT = {
	OPTIONS_CATEGORY = 981267450001,
	OPTIONS_CATEGORY_CAPS = 981267450002,
	PANEL_TITLE = 981267450003,
	BACK = 981267450009,
	SELECTION_COUNT = 981267450010,
	APPLY = 981267450011,
	VERSION_SELECTOR_LABEL = 981267450032,
	NO_FIXES_FOR_VERSION = 981267450035,
	SEARCH_LABEL = 981267450051,
	CLEAR_SEARCH = 981267450052,
	NO_MATCHING_FIXES = 981267450053,
	BETA_BADGE = 981267450077,
	SELECT_GROUP = 981267450078,
	UNSELECT_GROUP = 981267450079,
	RESET = 981267450080,
}

Config.GAME_VERSIONS = {
	{
		id = Config.DEFAULT_TARGET_VERSION,
		text = "1.0.7",
	},
}

Mod.Config = Config

local function mod_version()
	local def = rawget(_G, "CurrentModDef")
	if type(def) == "table" then return def.version end
	return nil
end

--------------------------------------------------------------------------------
-- Framework logging
--------------------------------------------------------------------------------

local DebugLog = {}
local LOG_PREFIX = "[SMR Community Fixes]"

local function value_to_string(value, depth)
	depth = depth or 0
	if depth > 4 then return "<max-depth>" end
	local value_type = type(value)
	if value_type == "nil" then return "nil" end
	if value_type == "string" then return string.format("%q", value) end
	if value_type == "number" or value_type == "boolean" then return tostring(value) end
	if value_type ~= "table" then
		return "<" .. value_type .. ":" .. tostring(value) .. ">"
	end

	local parts = {}
	local count = 0
	for key, item in pairs(value) do
		count = count + 1
		if count > 20 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = tostring(key) .. "=" .. value_to_string(item, depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function should_log(scope_flag)
	if Config.DEBUG_LOGS ~= true then return false end
	if scope_flag == nil then return true end
	return Config[scope_flag] == true
end

local function emit(level, scope, message, data)
	local text = LOG_PREFIX .. "[" .. tostring(level) .. "][" ..
		tostring(scope) .. "] " .. tostring(message)
	if data ~= nil then
		text = text .. " " .. value_to_string(data, 0)
	end
	local mod_log = rawget(_G, "ModLog")
	if type(mod_log) == "function" then
		mod_log(text)
	else
		print(text)
	end
end

function DebugLog.Info(scope, message, data, scope_flag)
	if should_log(scope_flag) == true then
		emit("INFO", scope, message, data)
	end
end

function DebugLog.Warn(scope, message, data, scope_flag)
	if should_log(scope_flag) == true then
		emit("WARN", scope, message, data)
	end
end

function DebugLog.Error(scope, message, data)
	emit("ERROR", scope, message, data)
end

function DebugLog.ApiCheck(api_name, available, data)
	if should_log("DEBUG_API") ~= true then return end
	local payload = data or {}
	payload.api = api_name
	payload.available = available == true
	emit("INFO", "ApiCheck", "Checked API availability", payload)
end

local function translated(id, text)
	local translate = rawget(_G, "T")
	if type(translate) == "function" then return translate(id, text) end
	return text
end

--------------------------------------------------------------------------------
-- Settings storage
--------------------------------------------------------------------------------

local Persistence = {}
local Catalog = {}
local Panel = Mod.panel
local OptionsPatch = {}

local SETTINGS_SCHEMA = 3
local in_memory_settings = false

local function known_target_version(version)
	for _, entry in ipairs(Config.GAME_VERSIONS or {}) do
		if entry.id == version then return true end
	end
	return false
end

local function storage_table()
	return rawget(_G, "CurrentModStorageTable")
end

local function storage_writer()
	return rawget(_G, "WriteModPersistentStorageTable")
end

function Persistence.IsAvailable()
	return type(storage_table()) == "table" and type(storage_writer()) == "function"
end

function Persistence.Load(reason)
	local store = storage_table()
	if type(store) ~= "table" then
		store = type(in_memory_settings) == "table" and in_memory_settings or {}
		DebugLog.Warn("Persistence", "Per-mod storage unavailable; settings are in memory only", {
			reason = reason,
		}, "DEBUG_PERSISTENCE")
	end

	local previous_schema = tonumber(store.schema) or 0
	store.schema = SETTINGS_SCHEMA
	if store.target_version == nil and previous_schema < SETTINGS_SCHEMA then
		store.target_version = Config.DEFAULT_TARGET_VERSION
	elseif known_target_version(store.target_version) ~= true then
		store.target_version = Config.DEFAULT_TARGET_VERSION
	end
	Config.TARGET_GAME_VERSION = store.target_version
	if type(store.fixes) ~= "table" then store.fixes = {} end
	local active_fixes = {}
	for _, entry in ipairs(Mod.entries) do
		if store.fixes[entry.id] == nil then
			store.fixes[entry.id] = entry.default_enabled == true
		else
			store.fixes[entry.id] = store.fixes[entry.id] == true
		end
		active_fixes[entry.id] = store.fixes[entry.id]
	end

	in_memory_settings = store
	DebugLog.Info("Persistence", "Loaded fix settings", {
		reason = reason,
		available = Persistence.IsAvailable(),
		target_version = store.target_version,
		fixes = active_fixes,
	}, "DEBUG_PERSISTENCE")
	return store
end

-- Give every registered fix a stored value, defaulting to its own default_enabled.
--
-- Persistence.Load seeds this too, but only for the fixes registered at the moment
-- it runs. If the 'code' list puts SMRCommunityFixes.lua before the fixes, the registry is
-- still empty then, and the fixes are adopted later at ClassesBuilt. Seeding again
-- after every adoption is what makes the load order irrelevant - without it those
-- fixes would have no stored preference and would all come up disabled, including
-- the ones that are supposed to default on.
function Persistence.SeedDefaults(reason)
	local settings = Persistence.GetSettings()
	if type(settings.fixes) ~= "table" then settings.fixes = {} end
	local seeded = {}
	for _, entry in ipairs(Mod.entries) do
		if settings.fixes[entry.id] == nil then
			settings.fixes[entry.id] = entry.default_enabled == true
			seeded[entry.id] = settings.fixes[entry.id]
		end
	end
	if next(seeded) ~= nil then
		DebugLog.Info("Persistence", "Seeded defaults for newly adopted fixes", {
			reason = reason,
			seeded = seeded,
		}, "DEBUG_PERSISTENCE")
	end
	return true
end

function Persistence.GetSettings()
	if type(in_memory_settings) ~= "table" then
		return Persistence.Load("lazy_get")
	end
	return in_memory_settings
end

function Persistence.Save(reason)
	local writer = storage_writer()
	if type(writer) ~= "function" then
		DebugLog.Warn("Persistence", "Save skipped because storage writer is unavailable", {
			reason = reason,
		}, "DEBUG_PERSISTENCE")
		return false
	end

	local ok, err = pcall(writer)
	if ok ~= true or err ~= nil then
		DebugLog.Error("Persistence", "Failed to save fix settings", {
			reason = reason,
			error = err,
		})
		return false
	end
	DebugLog.Info("Persistence", "Saved fix settings", {
		reason = reason,
	}, "DEBUG_PERSISTENCE")
	return true
end

function Persistence.IsFixEnabled(fix_id)
	local settings = Persistence.GetSettings()
	return settings.fixes[fix_id] == true
end

function Persistence.GetTargetVersion()
	local settings = Persistence.GetSettings()
	return settings.target_version
end

function Persistence.SetTargetVersionValue(version)
	if known_target_version(version) ~= true then
		DebugLog.Error("Persistence", "Refused to save an unknown target version", {
			target_version = version,
		})
		return false
	end
	local settings = Persistence.GetSettings()
	settings.target_version = version
	Config.TARGET_GAME_VERSION = version
	return true
end

function Persistence.SetFixValue(fix_id, enabled)
	if type(fix_id) ~= "string" or fix_id == "" then
		DebugLog.Error("Persistence", "Refused to save a fix without an id", {
			fix_id = fix_id,
		})
		return false
	end
	local settings = Persistence.GetSettings()
	settings.fixes[fix_id] = enabled == true
	return true
end

function Persistence.SetFixEnabled(fix_id, enabled, reason)
	if Persistence.SetFixValue(fix_id, enabled) ~= true then return false end
	return Persistence.Save(reason or ("set_" .. fix_id))
end

--------------------------------------------------------------------------------
-- Fix registry
--------------------------------------------------------------------------------

-- Turns "restore_dome_filter" into "Restore Dome Filter", so a fix that does not
-- spell out a label still gets a readable row title.
local function label_from_id(fix_id)
	local words = {}
	for word in tostring(fix_id):gmatch("[^_]+") do
		words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(words, " ")
end

-- Fills in everything a fix does not have to state itself. Only three things are
-- genuinely the author's to provide: `id`, `description` and `set_enabled`. Anything
-- else missing gets the conservative default here, so a short descriptor is a valid
-- descriptor and a contributor cannot fail registration by forgetting boilerplate.
--
-- Defaults chosen so that a half-declared fix is inert rather than surprising: new
-- fixes are beta, off by default, silent, and support the current target version.
-- `taken_numbers` carries the numbers already claimed by explicitly numbered fixes,
-- so an auto-assigned number never collides with a pinned one.
local function normalize_descriptor(entry, taken_numbers)
	if type(entry) ~= "table" then return entry end
	if entry.beta == nil then entry.beta = true end
	if entry.default_enabled == nil then entry.default_enabled = false end
	if entry.debug == nil then entry.debug = false end
	if type(entry.versions) ~= "table" then
		entry.versions = { [Config.DEFAULT_TARGET_VERSION] = true }
	end
	if type(entry.label) ~= "string" or entry.label == "" then
		entry.label = label_from_id(entry.id)
	end
	if entry.number == nil then
		local candidate = 1
		while taken_numbers[candidate] ~= nil do candidate = candidate + 1 end
		entry.number = candidate
		taken_numbers[candidate] = entry.id
	end
	-- A fix that does not define quiesce still has to stand down before a reload, so
	-- the obvious implementation is supplied: switch yourself off.
	if entry.quiesce == nil and type(entry.set_enabled) == "function" then
		local set_enabled = entry.set_enabled
		entry.quiesce = function(reason)
			return set_enabled(false, reason or "registry_reset")
		end
	end
	return entry
end

-- Every field a fix descriptor must have, and of the right type. A fix that fails
-- this check is refused with one ERROR naming it, and the rest of the mod carries on
-- - a malformed contribution can annoy, but it cannot break the other fixes.
-- Everything optional has already been filled in by normalize_descriptor above.
local function valid_descriptor(entry)
	return type(entry) == "table" and
		type(entry.id) == "string" and entry.id ~= "" and
		type(entry.number) == "number" and entry.number > 0 and
		entry.number == math.floor(entry.number) and
		type(entry.beta) == "boolean" and
		type(entry.versions) == "table" and
		type(entry.label) == "string" and entry.label ~= "" and
		type(entry.description) == "string" and entry.description ~= "" and
		type(entry.set_enabled) == "function" and
		(entry.quiesce == nil or type(entry.quiesce) == "function") and
		(entry.events == nil or type(entry.events) == "table") and
		type(entry.default_enabled) == "boolean"
end

-- Take ownership of the descriptors the fix files appended while loading. Any
-- fix that was active in the previous Lua load and is not in the new list, or
-- was replaced by a freshly loaded descriptor, is disabled first so a removed
-- or reloaded module cannot leave an old hook installed.
function Catalog.AdoptPending(reason)
	local pending = rawget(_G, "SMRCommunityFixesPending")
	if type(pending) ~= "table" or #pending == 0 then return false end

	local entries = {}
	local entries_by_id = {}
	local used_numbers = {}
	-- Claim every pinned number before normalizing, so a number assigned to a fix that
	-- did not state one can never land on a number another fix pinned further down the
	-- list. `claimed` is only the reservation map; `used_numbers` below is what detects
	-- an actual collision between two fixes.
	local claimed = {}
	for _, entry in ipairs(pending) do
		if type(entry) == "table" and type(entry.number) == "number" then
			claimed[entry.number] = entry.id
		end
	end
	for _, entry in ipairs(pending) do
		normalize_descriptor(entry, claimed)
		if valid_descriptor(entry) ~= true then
			DebugLog.Error("Registry", "Refused an invalid bug fix descriptor", {
				fix_id = type(entry) == "table" and entry.id or nil,
				reason = reason,
			})
		elseif entries_by_id[entry.id] ~= nil then
			DebugLog.Error("Registry", "Refused a duplicate bug fix id", {
				fix_id = entry.id,
				reason = reason,
			})
		elseif used_numbers[entry.number] ~= nil then
			DebugLog.Error("Registry", "Refused a duplicate bug fix number", {
				fix_id = entry.id,
				number = entry.number,
				claimed_by = used_numbers[entry.number],
				reason = reason,
			})
		else
			if Config.DEBUG_LOGS == true then entry.debug = true end
			entries[#entries + 1] = entry
			entries_by_id[entry.id] = entry
			used_numbers[entry.number] = entry.id
		end
	end

	for _, previous in ipairs(Mod.entries) do
		if entries_by_id[previous.id] ~= previous then
			if type(previous.quiesce) == "function" then
				local ok, result = pcall(previous.quiesce, "registry_reset")
				if ok ~= true or result == false then
					DebugLog.Error("Registry", "Could not disable a previous bug fix", {
						fix_id = previous.id,
						error = ok == true and nil or result,
					})
				end
			else
				DebugLog.Warn("Registry", "Previous bug fix exposed no quiesce callback", {
					fix_id = previous.id,
				}, "DEBUG_UI")
			end
		end
	end

	table.sort(entries, function(a, b) return a.number < b.number end)
	Mod.entries = entries
	Mod.entries_by_id = entries_by_id
	rawset(_G, "SMRCommunityFixesPending", nil)
	DebugLog.Info("Registry", "Adopted registered bug fixes", {
		reason = reason,
		count = #entries,
	}, "DEBUG_UI")
	return true
end

function Catalog.GetEntries()
	return Mod.entries
end

function Catalog.GetVersions()
	return Config.GAME_VERSIONS or {}
end

function Catalog.IsKnownVersion(version)
	for _, entry in ipairs(Catalog.GetVersions()) do
		if entry.id == version then return true end
	end
	return false
end

local function find_entry(entry_or_id)
	if type(entry_or_id) == "table" then
		return Mod.entries_by_id[entry_or_id.id]
	end
	return Mod.entries_by_id[entry_or_id]
end

function Catalog.GetSelectedVersion()
	local version = Persistence.GetTargetVersion()
	if Catalog.IsKnownVersion(version) == true then return version end
	return Config.DEFAULT_TARGET_VERSION
end

function Catalog.IsApplicable(entry_or_id, version)
	local entry = find_entry(entry_or_id)
	version = version or Catalog.GetSelectedVersion()
	return entry ~= nil and type(entry.versions) == "table" and
		entry.versions[version] == true
end

function Catalog.GetEntriesForVersion(version)
	local entries = {}
	for _, entry in ipairs(Mod.entries) do
		if Catalog.IsApplicable(entry, version) then entries[#entries + 1] = entry end
	end
	return entries
end

function Catalog.IsEnabled(entry_or_id)
	local fix_id = type(entry_or_id) == "table" and entry_or_id.id or entry_or_id
	return Persistence.IsFixEnabled(fix_id)
end

-- Should this fix actually be running? Three things must all be true: the mod is on,
-- the player ticked it, and it declares support for the selected game version. This is
-- the only place that decision is made - fix files never ask, they are told.
function Catalog.IsRuntimeEnabled(entry_or_id, version, preference)
	local entry = find_entry(entry_or_id)
	if not entry then return false end
	if preference == nil then preference = Catalog.IsEnabled(entry) end
	return Config.ENABLE_MOD == true and preference == true and
		Catalog.IsApplicable(entry, version)
end

-- Calls one fix's set_enabled, inside pcall. This is the boundary between the framework
-- and community-contributed code: a fix that raises an error is reported by name and
-- treated as a failure, but it cannot take the mod down with it.
local function apply_fix(entry_or_id, enabled, reason)
	local entry = find_entry(entry_or_id)
	if not entry then
		DebugLog.Error("Registry", "Cannot apply an unknown bug fix", {
			fix_id = type(entry_or_id) == "table" and entry_or_id.id or entry_or_id,
			reason = reason,
		})
		return false
	end
	local ok, result = pcall(entry.set_enabled, enabled == true, reason)
	if ok ~= true then
		DebugLog.Error("Registry", "Bug fix raised an error while changing state", {
			fix_id = entry.id,
			enabled = enabled == true,
			reason = reason,
			error = result,
		})
		return false
	end
	return result == true
end

-- Passes a game message on to any fix that asked for it through FIX.events. That is how a
-- fix reacts to a game starting, ending, or a rain finishing without adding its own OnMsg
-- handler - the framework owns the message, the fix just names it.
function Catalog.Notify(event_name, reason)
	local all_ok = true
	for _, entry in ipairs(Mod.entries) do
		local events = entry.events
		local handler = type(events) == "table" and events[event_name] or nil
		if type(handler) == "function" then
			local ok, result = pcall(handler, reason)
			if ok ~= true or result == false then
				all_ok = false
				DebugLog.Error("Registry", "Bug fix event handler failed", {
					fix_id = entry.id,
					event = event_name,
					reason = reason,
					error = ok == true and nil or result,
				})
			end
		end
	end
	return all_ok
end

function Catalog.SetEnabled(entry_or_id, enabled, reason)
	local entry = find_entry(entry_or_id)
	if not entry then
		DebugLog.Error("Registry", "Cannot change an unknown bug fix", {
			fix_id = entry_or_id,
			reason = reason,
		})
		return false
	end
	local fix_id = entry.id
	enabled = enabled == true
	local previous = Persistence.IsFixEnabled(fix_id)
	local target_version = Catalog.GetSelectedVersion()
	local previous_runtime = Catalog.IsRuntimeEnabled(entry, target_version, previous)
	local desired_runtime = Catalog.IsRuntimeEnabled(entry, target_version, enabled)
	if previous == enabled then
		return apply_fix(fix_id, desired_runtime, reason)
	end
	if previous_runtime ~= desired_runtime and
		apply_fix(fix_id, desired_runtime, reason) ~= true
	then
		return false
	end
	if Persistence.SetFixEnabled(fix_id, enabled, reason) ~= true then
		local rolled_back = true
		if previous_runtime ~= desired_runtime then
			rolled_back = apply_fix(fix_id, previous_runtime,
				(reason or "toggle") .. "_persistence_rollback")
		end
		Persistence.SetFixValue(fix_id, previous)
		DebugLog.Error("Registry", "Fix applied but its setting could not be persisted", {
			fix_id = fix_id,
			enabled = enabled,
			previous = previous,
			rolled_back = rolled_back == true,
			target_version = target_version,
			reason = reason,
		})
		return false
	end
	DebugLog.Info("Registry", "Changed fix state", {
		fix_id = fix_id,
		enabled = enabled,
		runtime_enabled = desired_runtime,
		target_version = target_version,
		reason = reason,
	}, "DEBUG_UI")
	return true
end

local function rollback_runtime_changes(changes, reason)
	local runtime_ok = true
	for index = #changes, 1, -1 do
		local change = changes[index]
		if apply_fix(change.id, change.previous_runtime,
			(reason or "staged_apply") .. "_runtime_rollback") ~= true
		then
			runtime_ok = false
		end
	end
	return runtime_ok
end

local function restore_persisted_values(version, changes)
	Persistence.SetTargetVersionValue(version)
	for _, change in ipairs(changes) do
		Persistence.SetFixValue(change.id, change.previous)
	end
end

-- Applies everything the player staged in the panel, as one transaction.
--
-- The panel only ever collects intentions; nothing happens until Apply is pressed and this
-- runs. It works out which fixes actually change runtime state, applies those, then saves
-- the settings. If any single step fails, the fixes already applied are rolled back and the
-- stored values restored, so the player never ends up with half a change applied - and
-- never with settings on disk that disagree with what is running.
function Catalog.ApplyStaged(states, reason)
	if type(states) ~= "table" then
		DebugLog.Error("Registry", "Cannot apply missing staged fix states", {
			reason = reason,
		})
		return false
	end

	local target_version = states.target_version
	if Catalog.IsKnownVersion(target_version) ~= true then
		DebugLog.Error("Registry", "Staged target version is unknown", {
			target_version = target_version,
			reason = reason,
		})
		return false
	end

	local previous_version = Catalog.GetSelectedVersion()
	local preference_changes = {}
	local runtime_changes = {}
	for _, entry in ipairs(Mod.entries) do
		local desired = states[entry.id]
		if type(desired) ~= "boolean" then
			DebugLog.Error("Registry", "Staged fix state is not a boolean", {
				fix_id = entry.id,
				value_type = type(desired),
				reason = reason,
			})
			return false
		end
		local previous = Persistence.IsFixEnabled(entry.id)
		if previous ~= desired then
			preference_changes[#preference_changes + 1] = {
				id = entry.id,
				previous = previous,
				desired = desired,
			}
		end
		local previous_runtime = Catalog.IsRuntimeEnabled(
			entry, previous_version, previous)
		local desired_runtime = Catalog.IsRuntimeEnabled(
			entry, target_version, desired)
		if previous_runtime ~= desired_runtime then
			runtime_changes[#runtime_changes + 1] = {
				id = entry.id,
				previous_runtime = previous_runtime,
				desired_runtime = desired_runtime,
			}
		end
	end

	local version_changed = previous_version ~= target_version
	if #preference_changes == 0 and version_changed ~= true then
		DebugLog.Info("Registry", "No staged fix changes to apply", {
			reason = reason,
			target_version = target_version,
		}, "DEBUG_UI")
		return true
	end

	local applied = {}
	for _, change in ipairs(runtime_changes) do
		if apply_fix(change.id, change.desired_runtime,
			(reason or "staged_apply") .. "_runtime") ~= true
		then
			local rollback_changes = {}
			for _, applied_change in ipairs(applied) do
				rollback_changes[#rollback_changes + 1] = applied_change
			end
			rollback_changes[#rollback_changes + 1] = change
			rollback_runtime_changes(rollback_changes, reason)
			DebugLog.Error("Registry", "Failed to apply staged fix runtime state", {
				fix_id = change.id,
				desired = change.desired_runtime,
				target_version = target_version,
				reason = reason,
			})
			return false
		end
		applied[#applied + 1] = change
	end

	if Persistence.SetTargetVersionValue(target_version) ~= true then
		rollback_runtime_changes(applied, reason)
		return false
	end
	for _, change in ipairs(preference_changes) do
		if Persistence.SetFixValue(change.id, change.desired) ~= true then
			rollback_runtime_changes(applied, reason)
			restore_persisted_values(previous_version, preference_changes)
			DebugLog.Error("Registry", "Failed to stage fix values for persistence", {
				fix_id = change.id,
				reason = reason,
			})
			return false
		end
	end

	if Persistence.Save(reason or "apply_staged_settings") ~= true then
		local runtime_rolled_back = rollback_runtime_changes(applied, reason)
		restore_persisted_values(previous_version, preference_changes)
		local storage_rolled_back = Persistence.Save(
			(reason or "staged_apply") .. "_persistence_rollback")
		DebugLog.Error("Registry", "Failed to persist staged fix changes", {
			reason = reason,
			runtime_rolled_back = runtime_rolled_back,
			storage_rolled_back = storage_rolled_back,
		})
		return false
	end

	DebugLog.Info("Registry", "Applied staged fix changes", {
		reason = reason,
		fix_changes = #preference_changes,
		previous_version = previous_version,
		target_version = target_version,
		version_changed = version_changed,
	}, "DEBUG_UI")
	return true
end

-- Brings every registered fix into line with the saved settings. Called at each lifecycle
-- point - code load, ClassesBuilt, game start, load, mod reload - which is why every fix's
-- set_enabled has to be safe to call again with a value it already has.
function Catalog.ApplyAll(reason)
	local all_ok = true
	local target_version = Catalog.GetSelectedVersion()
	Config.TARGET_GAME_VERSION = target_version
	for _, entry in ipairs(Mod.entries) do
		local enabled = Catalog.IsRuntimeEnabled(entry, target_version)
		if apply_fix(entry.id, enabled, reason) ~= true then
			all_ok = false
		end
	end
	DebugLog.Info("Registry", "Applied version-gated fix registry", {
		reason = reason,
		target_version = target_version,
	}, "DEBUG_UI")
	return all_ok
end

-- Stands every fix down, handing the game back exactly as it was found.
--
-- Turning a single fix off already restores what that fix changed; this is for the
-- moment the whole mod goes away, which is the one case a fix cannot handle for
-- itself. Everything this mod changes lives in the game's own globals and classes,
-- so it has to be given back while there is still code here to do it.
--
-- Saved choices are deliberately not touched. quiesce reverses the runtime change
-- and nothing else, so switching the mod back on restores exactly the fixes that
-- were on before.
function Catalog.QuiesceAll(reason)
	local all_ok = true
	for _, entry in ipairs(Mod.entries) do
		if type(entry.quiesce) == "function" then
			local ok, result = pcall(entry.quiesce, reason)
			if ok ~= true or result == false then
				all_ok = false
				DebugLog.Error("Registry", "Could not stand a bug fix down", {
					fix_id = entry.id,
					reason = reason,
					error = ok == true and nil or result,
				})
			end
		end
	end
	DebugLog.Info("Registry", "Stood every bug fix down", {
		reason = reason,
		fixes = #Mod.entries,
	}, "DEBUG_UI")
	return all_ok
end

--------------------------------------------------------------------------------
-- Options category
--------------------------------------------------------------------------------

local CATEGORY_ID = "SMRCommunityFixes"

local function open_panel()
	if type(Panel.Open) ~= "function" then
		DebugLog.Error("Options", "SMR Community Fixes panel is unavailable", nil)
		return false
	end
	return Panel.Open("options_category")
end

local function find_category(categories, id)
	for index, category in ipairs(categories) do
		if category.id == id then return index, category end
	end
	return nil, nil
end

function OptionsPatch.Apply(reason)
	local categories = rawget(_G, "OptionsCategories")
	if type(categories) ~= "table" then
		DebugLog.ApiCheck("OptionsCategories", false, { reason = reason })
		return false
	end

	local existing_index, existing = find_category(categories, CATEGORY_ID)
	if existing then
		existing.display_name = translated(Config.TEXT.OPTIONS_CATEGORY, "SMR Community Fixes")
		existing.caps_name = translated(Config.TEXT.OPTIONS_CATEGORY_CAPS, "SMR COMMUNITY FIXES")
		existing.run = open_panel
		existing.no_edit = false
		existing.bf_owner = Config.MOD_ID
		table.remove(categories, existing_index)
		local credits_index = find_category(categories, "Credits")
		local insert_index = credits_index and (credits_index + 1) or (#categories + 1)
		table.insert(categories, insert_index, existing)
		Mod.options.category = existing
		DebugLog.Info("Options", "Refreshed and positioned existing SMR Community Fixes category", {
			reason = reason,
			index = insert_index,
		}, "DEBUG_UI")
		return true
	end

	local category = {
		id = CATEGORY_ID,
		display_name = translated(Config.TEXT.OPTIONS_CATEGORY, "SMR Community Fixes"),
		caps_name = translated(Config.TEXT.OPTIONS_CATEGORY_CAPS, "SMR COMMUNITY FIXES"),
		run = open_panel,
		no_edit = false,
		bf_owner = Config.MOD_ID,
	}
	local credits_index = find_category(categories, "Credits")
	local insert_index = credits_index and (credits_index + 1) or (#categories + 1)
	table.insert(categories, insert_index, category)
	Mod.options.category = category
	DebugLog.Info("Options", "Inserted SMR Community Fixes category", {
		reason = reason,
		index = insert_index,
		credits_found = credits_index ~= nil,
	}, "DEBUG_UI")
	return true
end

-- Takes the category back out, so an unloaded mod does not leave a row in Options
-- whose only action is to call code that no longer exists. bf_owner is checked
-- rather than the id alone, so a category this mod did not insert is left alone.
function OptionsPatch.Remove(reason)
	local categories = rawget(_G, "OptionsCategories")
	if type(categories) ~= "table" then return true end
	local index, category = find_category(categories, CATEGORY_ID)
	if not category or category.bf_owner ~= Config.MOD_ID then return true end
	table.remove(categories, index)
	Mod.options.category = nil
	DebugLog.Info("Options", "Removed the SMR Community Fixes category", {
		reason = reason,
		index = index,
	}, "DEBUG_UI")
	return true
end

--------------------------------------------------------------------------------
-- Checklist panel
--------------------------------------------------------------------------------

if type(Panel.search) ~= "string" then Panel.search = "" end
if type(Panel.checkboxes) ~= "table" then Panel.checkboxes = {} end

local function color(r, g, b, a)
	local rgba = rawget(_G, "RGBA")
	if type(rgba) == "function" then return rgba(r, g, b, a) end
	return nil
end

local function padding(left, top, right, bottom)
	local box_fn = rawget(_G, "box")
	if type(box_fn) == "function" then return box_fn(left, top, right, bottom) end
	return nil
end

local function list_viewport_height(desktop)
	local ratio = Config.PANEL_LIST_HEIGHT_PER_MILLE
	local fallback = Config.PANEL_LIST_FALLBACK_HEIGHT
	local mul_div_round = rawget(_G, "MulDivRound")
	local desktop_box = desktop and desktop.box
	local desktop_scale = desktop and desktop.scale
	if type(ratio) ~= "number" or ratio <= 0 or ratio > 1000 or
		type(fallback) ~= "number" or fallback <= 0 or
		type(mul_div_round) ~= "function" or not desktop_box or
		type(desktop_box.sizey) ~= "function" or not desktop_scale or
		type(desktop_scale.y) ~= "function"
	then
		DebugLog.Error("Panel", "Cannot calculate monitor-relative list height; using fallback", {
			height_per_mille = ratio,
			fallback_height = fallback,
			has_desktop_box = desktop_box ~= nil,
			has_desktop_scale = desktop_scale ~= nil,
			has_mul_div_round = type(mul_div_round) == "function",
		})
		return fallback or 600, false, false
	end

	local desktop_height = desktop_box:sizey()
	local scale_y = desktop_scale:y()
	if type(desktop_height) ~= "number" or desktop_height <= 0 or
		type(scale_y) ~= "number" or scale_y <= 0
	then
		DebugLog.Error("Panel", "Invalid desktop geometry for monitor-relative list height; using fallback", {
			desktop_height = desktop_height,
			ui_scale_y = scale_y,
			fallback_height = fallback,
		})
		return fallback, desktop_height, scale_y
	end

	-- XWindow scales MinHeight/MaxHeight by scale_y / 1000. Converting the
	-- requested screen fraction back to logical units keeps the rendered list
	-- at the same proportion of every monitor and user UI-scale setting.
	return math.max(1, mul_div_round(desktop_height, ratio, scale_y)),
		desktop_height, scale_y
end
Panel.GetListViewportHeight = list_viewport_height

local function window_valid(window)
	return window ~= nil and window ~= false and window.window_state ~= "destroying"
end

local function make_text(parent, value, style, options)
	local XText = rawget(_G, "XText")
	if not XText then return false end
	options = options or {}
	local control = XText:new({
		Translate = options.Translate ~= false,
		TextStyle = style or "PropValue",
		HAlign = options.HAlign or "left",
		VAlign = options.VAlign or "center",
		TextHAlign = options.TextHAlign or "left",
		HandleMouse = false,
		WordWrap = options.WordWrap == true,
		MinWidth = options.MinWidth,
		MaxWidth = options.MaxWidth,
		MaxHeight = options.MaxHeight,
		TextColor = options.TextColor or color(230, 230, 230, 255),
	}, parent)
	control:SetText(value or "")
	return control
end

-- Copies the current on/off state of every fix into Panel.pending. That copy is what the
-- checkboxes edit, which is the whole reason Back and Escape can discard changes: until
-- Apply runs, nothing outside this table has been touched.
local function snapshot_current_states()
	local pending = {
		target_version = Catalog.GetSelectedVersion(),
	}
	for _, entry in ipairs(Catalog.GetEntries()) do
		pending[entry.id] = Catalog.IsEnabled(entry) == true
	end
	Panel.pending = pending
	return pending
end

local function staged_target_version()
	if type(Panel.pending) ~= "table" then snapshot_current_states() end
	local version = Panel.pending.target_version
	if Catalog.IsKnownVersion(version) == true then
		return version
	end
	return Config.DEFAULT_TARGET_VERSION
end

local function version_items()
	local items = {
		{
			id = Config.ALL_VERSIONS_FILTER,
			name = "All",
		},
	}
	for _, version in ipairs(Catalog.GetVersions()) do
		items[#items + 1] = {
			id = version.id,
			name = version.text,
		}
	end
	return items
end

local function version_item_text(value)
	for _, item in ipairs(version_items()) do
		if item.id == value then return item.name end
	end
	return tostring(value or "")
end

local function selected_version_filter()
	local value = Panel.version_filter
	if value == Config.ALL_VERSIONS_FILTER then return value end
	if Catalog.IsKnownVersion(value) == true then
		return value
	end
	return Config.DEFAULT_TARGET_VERSION
end

local function visible_text(value)
	if type(value) == "string" then return value end
	for _, name in ipairs({ "_InternalTranslate", "TDevModeGetEnglishText" }) do
		local translate = rawget(_G, name)
		if type(translate) == "function" then
			local ok, text = pcall(translate, value)
			if ok == true and type(text) == "string" then return text end
		end
	end
	return ""
end

local function search_matches(entry, query)
	if query == "" then return true end
	local label = string.lower(entry.label)
	local description = string.lower(entry.description)
	local number = string.format("%03d", entry.number)
	local beta_badge = entry.beta == true and string.lower(visible_text(
		translated(Config.TEXT.BETA_BADGE, "[Beta]"))) or ""
	return string.find(number, query, 1, true) ~= nil or
		string.find(label, query, 1, true) ~= nil or
		string.find(description, query, 1, true) ~= nil or
		(beta_badge ~= "" and string.find(beta_badge, query, 1, true) ~= nil)
end

local function filtered_entries()
	local version_filter = selected_version_filter()
	local entries
	if version_filter == Config.ALL_VERSIONS_FILTER then
		entries = Catalog.GetEntries()
	else
		entries = Catalog.GetEntriesForVersion(version_filter)
	end
	local query = string.lower(Panel.search or "")
	if query == "" then return entries, version_filter end
	local result = {}
	for _, entry in ipairs(entries) do
		if search_matches(entry, query) then result[#result + 1] = entry end
	end
	return result, version_filter
end

local staged_state

local function update_count_text()
	if not window_valid(Panel.count_text) then return end
	local shown_entries = filtered_entries()
	local all_entries = Catalog.GetEntries()
	local selected = 0
	for _, entry in ipairs(all_entries) do
		if staged_state(entry) then selected = selected + 1 end
	end
	Panel.count_text:SetText(translated(Config.TEXT.SELECTION_COUNT,
		string.format("%d shown / %d total / %d selected",
			#shown_entries, #all_entries, selected)))
end

local function set_window_color(window, setter, value)
	local method = window and window[setter]
	if type(method) == "function" then method(window, value) end
end

local function apply_dark_combo_style(combo)
	if not combo or rawget(combo, "_bf_dark_style_applied") == true then
		return combo ~= nil
	end

	local stock_open_combo = combo.OpenCombo
	if type(stock_open_combo) ~= "function" then
		DebugLog.Error("Panel", "Cannot style game-version dropdown popup", {
			has_open_combo = false,
		})
		return false
	end

	local field_background = color(8, 10, 12, 255)
	local popup_background = color(18, 22, 26, 255)
	local border_color = color(70, 84, 90, 255)
	local item_highlight_background = color(54, 68, 74, 255)
	local item_pressed_background = color(85, 101, 108, 255)
	local item_highlight_border = color(100, 118, 126, 255)
	local edit = combo.idEdit
	set_window_color(edit, "SetBackground", field_background)
	set_window_color(edit, "SetFocusedBackground", field_background)
	set_window_color(edit, "SetDisabledBackground", field_background)
	set_window_color(edit, "SetSelectionBackground", field_background)
	set_window_color(edit, "SetSelectionColor", color(255, 255, 255, 255))

	combo.OpenCombo = function(self, mode)
		local popup = stock_open_combo(self, mode)
		if not popup then return popup end

		set_window_color(popup, "SetBackground", popup_background)
		set_window_color(popup, "SetFocusedBackground", popup_background)
		set_window_color(popup, "SetBorderColor", border_color)
		set_window_color(popup, "SetFocusedBorderColor", border_color)

		local container = popup.idContainer
		set_window_color(container, "SetBackground", popup_background)
		set_window_color(container, "SetFocusedBackground", popup_background)
		if container then
			for _, item in ipairs(container) do
				local set_rollover_on_focus = item.SetRolloverOnFocus
				if type(set_rollover_on_focus) == "function" then
					set_rollover_on_focus(item, false)
				else
					rawset(item, "RolloverOnFocus", false)
				end
				if type(item.SetRollover) == "function" then
					item:SetRollover(false)
				end
				set_window_color(item, "SetBackground", popup_background)
				set_window_color(item, "SetFocusedBackground", popup_background)
				set_window_color(item, "SetRolloverBackground", item_highlight_background)
				set_window_color(item, "SetPressedBackground", item_pressed_background)
				set_window_color(item, "SetDisabledBackground", popup_background)
				set_window_color(item, "SetFocusedBorderColor", border_color)
				set_window_color(item, "SetRolloverBorderColor", item_highlight_border)
				set_window_color(item, "SetPressedBorderColor", item_highlight_border)
			end
		end
		return popup
	end

	local arrow = combo.idButton
	set_window_color(arrow, "SetBackground", color(38, 46, 52, 255))
	set_window_color(arrow, "SetRolloverBackground", color(54, 68, 74, 255))
	set_window_color(arrow, "SetPressedBackground", color(85, 101, 108, 255))
	set_window_color(arrow, "SetDisabledBackground", color(28, 34, 38, 255))
	rawset(combo, "_bf_dark_style_applied", true)
	DebugLog.Info("Panel", "Styled game-version dropdown for dark panel", {
		has_edit = edit ~= nil,
		has_arrow = arrow ~= nil,
	}, "DEBUG_UI")
	return true
end

staged_state = function(entry)
	if type(Panel.pending) ~= "table" then snapshot_current_states() end
	return Panel.pending[entry.id] == true
end

local function make_button(parent, value, on_press, options)
	local XTextButton = rawget(_G, "XTextButton")
	if not XTextButton then return false end
	options = options or {}
	local control = XTextButton:new({
		Translate = true,
		TextStyle = options.TextStyle or "ActionSmall",
		Padding = options.Padding or padding(10, 4, 10, 4),
		MinWidth = options.MinWidth or 90,
		MinHeight = options.MinHeight or 32,
		MaxHeight = options.MaxHeight or 40,
		HAlign = options.HAlign or "left",
		VAlign = "center",
		Background = options.Background or color(38, 46, 52, 235),
		RolloverBackground = options.RolloverBackground or color(54, 68, 74, 235),
		PressedBackground = options.PressedBackground or color(85, 101, 108, 245),
		TextColor = color(255, 255, 255, 255),
		RolloverTextColor = color(255, 255, 255, 255),
		OnPress = function(self, gamepad)
			return on_press(self, gamepad)
		end,
	}, parent)
	control:SetText(value or "")
	if options.CenterLabel == true then
		if type(control.SetLayoutMethod) == "function" then
			control:SetLayoutMethod("Box")
		end
		if control.idLabel and type(control.idLabel.SetHAlign) == "function" then
			control.idLabel:SetHAlign("center")
		end
	end
	return control
end

-- Builds one checklist row from a descriptor, and this is the only place the UI reads a
-- fix's data. It uses six fields and nothing else: id, number, beta, label, description and
-- default_enabled. Note Translate = false on the number, label and description - they are
-- plain strings, so a fix does not have to allocate localization ids to appear here.
local function build_row(list, entry)
	local XWindow = rawget(_G, "XWindow")
	local XCheckButton = rawget(_G, "XCheckButton")
	if not XWindow or not XCheckButton then
		DebugLog.Error("Panel", "Required row UI classes are unavailable", {
			has_XWindow = XWindow ~= nil,
			has_XCheckButton = XCheckButton ~= nil,
			fix_id = entry.id,
		})
		return false
	end

	local row = XWindow:new({
		LayoutMethod = "HList",
		LayoutHSpacing = 16,
		HAlign = "stretch",
		MinHeight = 112,
		Padding = padding(12, 10, 12, 10),
		Background = color(28, 34, 38, 150),
		HandleMouse = true,
		IsSelectable = function()
			return false
		end,
		OnMouseButtonDown = function()
			return "break"
		end,
	}, list)

	local enabled = staged_state(entry)
	local toggle_cell = XWindow:new({
		LayoutMethod = "HList",
		LayoutHSpacing = 8,
		HAlign = "left",
		VAlign = "center",
		MinWidth = 200,
		MaxWidth = 200,
		MinHeight = 44,
	}, row)
	local checkbox = XCheckButton:new({
		Translate = false,
		MinWidth = 40,
		MaxWidth = 40,
		MinHeight = 44,
		HAlign = "left",
		VAlign = "center",
		TextStyle = "PropName",
		TextColor = color(255, 255, 255, 255),
		RolloverTextColor = color(255, 255, 255, 255),
		IconColor = color(255, 255, 255, 255),
		RolloverIconColor = color(255, 255, 255, 255),
		OnChange = function(self, checked)
			if type(Panel.pending) ~= "table" then snapshot_current_states() end
			Panel.pending[entry.id] = checked == true
			update_count_text()
			DebugLog.Info("Panel", "Staged fix state", {
				fix_id = entry.id,
				enabled = checked == true,
			}, "DEBUG_UI")
		end,
	}, toggle_cell)
	checkbox:SetCheck(enabled)
	checkbox:SetText("")
	Panel.checkboxes[entry.id] = checkbox
	make_text(toggle_cell, string.format("%03d", entry.number), "PropName", {
		Translate = false,
		TextColor = color(168, 183, 201, 255),
	})
	if entry.beta == true then
		make_text(toggle_cell,
			translated(Config.TEXT.BETA_BADGE, "[Beta]"), "PropName", {
				TextColor = color(168, 183, 201, 255),
			})
	end

	local text_cell = XWindow:new({
		LayoutMethod = "VList",
		LayoutVSpacing = 3,
		HAlign = "stretch",
		VAlign = "center",
		MinHeight = 92,
	}, row)
	make_text(text_cell, entry.label, "PropName", {
		Translate = false,
		TextColor = color(168, 183, 201, 255),
		WordWrap = true,
		MaxWidth = 1280,
	})
	make_text(text_cell, entry.description, "PropValue", {
		Translate = false,
		TextColor = color(180, 200, 210, 255),
		WordWrap = true,
		MaxWidth = 1280,
	})

	if row.window_state == "new" then row:Open() end
	return row
end

function Panel.IsOpen()
	return window_valid(Panel.root)
end

function Panel.Rebuild(reason)
	if not window_valid(Panel.list) then return false end
	Panel.checkboxes = {}
	if type(Panel.list.Clear) == "function" then Panel.list:Clear() end

	local target_version = staged_target_version()
	local entries, version_filter = filtered_entries()
	for _, entry in ipairs(entries) do
		build_row(Panel.list, entry)
	end
	if #entries == 0 then
		local empty_text
		if (Panel.search or "") ~= "" then
			empty_text = translated(Config.TEXT.NO_MATCHING_FIXES,
				"No bug fixes match the search.")
		else
			empty_text = translated(Config.TEXT.NO_FIXES_FOR_VERSION,
				"No fixes are applied for this version.")
		end
		make_text(Panel.list, empty_text, "PropValue", {
			HAlign = "center",
			TextColor = color(180, 200, 210, 255),
		})
	end
	update_count_text()
	Panel.list:InvalidateLayout()
	DebugLog.Info("Panel", "Rebuilt bug-fix list", {
		reason = reason,
		shown = #entries,
		total = #Catalog.GetEntries(),
		version_filter = version_filter,
		target_version = target_version,
	}, "DEBUG_UI")
	return true
end

function Panel.Close(reason)
	local root = Panel.root
	if window_valid(root) then
		if type(root.SetModal) == "function" then
			local ok, err = pcall(function() root:SetModal(false) end)
			if ok ~= true then
				DebugLog.Error("Panel", "Failed to release panel modal state", {
					reason = reason,
					error = err,
				})
			end
		end
		root:delete()
	end
	Panel.root = false
	Panel.list = false
	Panel.scrollbar = false
	Panel.count_text = false
	Panel.search = ""
	Panel.search_edit = false
	Panel.version_control = false
	Panel.version_filter = false
	Panel.pending = false
	Panel.checkboxes = {}
	DebugLog.Info("Panel", "Closed SMR Community Fixes panel", {
		reason = reason,
	}, "DEBUG_UI")
end

function Panel.Apply(reason)
	if type(Panel.pending) ~= "table" then snapshot_current_states() end
	if Catalog.ApplyStaged(Panel.pending, reason or "panel_apply") ~= true then
		return false
	end
	snapshot_current_states()
	Panel.Rebuild("apply_success")
	DebugLog.Info("Panel", "Applied staged SMR Community Fixes settings", {
		reason = reason,
	}, "DEBUG_UI")
	return true
end

function Panel.SetVisibleGroupState(enabled, reason)
	if type(Panel.pending) ~= "table" then snapshot_current_states() end
	local entries = filtered_entries()
	local target_enabled = enabled == true
	local changed_count = 0
	local list = Panel.list
	local scroll_position = window_valid(list) and
		(list.PendingOffsetY or list.OffsetY or 0) or false
	for _, entry in ipairs(entries) do
		if Panel.pending[entry.id] ~= target_enabled then
			changed_count = changed_count + 1
		end
		Panel.pending[entry.id] = target_enabled
		local checkbox = Panel.checkboxes[entry.id]
		if window_valid(checkbox) and type(checkbox.SetCheck) == "function" then
			checkbox:SetCheck(target_enabled)
		end
	end
	update_count_text()
	DebugLog.Info("Panel", "Staged visible bug-fix group", {
		reason = reason,
		enabled = target_enabled,
		visible_count = #entries,
		changed_count = changed_count,
		scroll_position = scroll_position,
	}, "DEBUG_UI")
	return true
end

function Panel.ResetStaged(reason)
	if type(Panel.pending) ~= "table" then snapshot_current_states() end
	-- Reset means "everything off", not "back to the shipped defaults": it stages
	-- every fix unchecked, including the two that default on. Like every other
	-- checkbox change it is only staged - Apply is what commits it, and Back still
	-- discards it.
	for _, entry in ipairs(Catalog.GetEntries()) do
		Panel.pending[entry.id] = false
	end
	Panel.pending.target_version = Config.DEFAULT_TARGET_VERSION
	Panel.search = ""
	Panel.version_filter = Config.DEFAULT_TARGET_VERSION

	local edit = Panel.search_edit
	if window_valid(edit) and type(edit.SetText) == "function" then
		edit:SetText("")
	end
	local combo = Panel.version_control
	if window_valid(combo) then
		if type(combo.SetValueWithText) == "function" then
			combo:SetValueWithText(Config.DEFAULT_TARGET_VERSION,
				version_item_text(Config.DEFAULT_TARGET_VERSION), true)
		elseif type(combo.SetValue) == "function" then
			combo:SetValue(Config.DEFAULT_TARGET_VERSION)
		end
	end

	Panel.Rebuild(reason or "reset_staged")
	DebugLog.Info("Panel", "Staged every bug fix off and cleared the filters", {
		reason = reason,
		target_version = Config.DEFAULT_TARGET_VERSION,
		fix_count = #Catalog.GetEntries(),
	}, "DEBUG_UI")
	return true
end

function Panel.Open(reason)
	local XWindow = rawget(_G, "XWindow")
	local XList = rawget(_G, "XList")
	local XScrollBar = rawget(_G, "XScrollBar")
	local XEdit = rawget(_G, "XEdit")
	local XCombo = rawget(_G, "XCombo")
	local terminal_global = rawget(_G, "terminal")
	local desktop = terminal_global and terminal_global.desktop or nil
	if not XWindow or not XList or not XEdit or not XCombo or not desktop then
		DebugLog.Error("Panel", "Cannot open SMR Community Fixes panel; required UI is unavailable", {
			has_XWindow = XWindow ~= nil,
			has_XList = XList ~= nil,
			has_XEdit = XEdit ~= nil,
			has_XCombo = XCombo ~= nil,
			has_desktop = desktop ~= nil,
			reason = reason,
		})
		return false
	end
	if Panel.IsOpen() then return Panel.Rebuild("already_open") end
	Panel.version_filter = Config.DEFAULT_TARGET_VERSION
	Panel.search = ""
	snapshot_current_states()
	local initial_version_filter = selected_version_filter()

	local root = XWindow:new({
		Id = "idBFPanelRoot",
		Dock = "box",
		HandleMouse = true,
		Background = color(0, 0, 0, 160),
		OnShortcut = function(self, shortcut)
			if shortcut == "Escape" or shortcut == "ButtonB" then
				Panel.Close("shortcut")
				return "break"
			end
		end,
	}, desktop)
	Panel.root = root

	local content = XWindow:new({
		HAlign = "center",
		VAlign = "center",
		MinWidth = 1500,
		MaxWidth = 1700,
		LayoutMethod = "VList",
		LayoutVSpacing = 10,
		Padding = padding(18, 18, 18, 18),
		Background = color(18, 22, 26, 250),
		BorderWidth = 1,
		BorderColor = color(70, 84, 90, 255),
		HandleMouse = true,
	}, root)

	local panel_title = make_text(content,
		translated(Config.TEXT.PANEL_TITLE, "SMR Community Fixes"), "MediumHeaderR")
	set_window_color(panel_title, "SetTextColor", color(168, 183, 201, 255))

	local search_toolbar = XWindow:new({
		LayoutMethod = "HList",
		LayoutHSpacing = 10,
		HAlign = "stretch",
		VAlign = "center",
		MinHeight = 48,
		Padding = padding(0, 4, 0, 4),
	}, content)
	make_text(search_toolbar, translated(Config.TEXT.SEARCH_LABEL, "Search:"),
		"PropValue", {
			MinWidth = 90,
			TextColor = color(255, 255, 255, 255),
		})
	Panel.search_edit = XEdit:new({
		Id = "idBFSearch",
		Translate = false,
		TextStyle = "PropValue",
		MinWidth = 300,
		MaxWidth = 340,
		Background = color(8, 10, 12, 255),
		FocusedBackground = color(12, 15, 18, 255),
		BorderWidth = 1,
		BorderColor = color(70, 84, 90, 255),
		FocusedBorderColor = color(100, 118, 126, 255),
		Padding = padding(6, 4, 6, 4),
		OnTextChanged = function(self)
			Panel.search = type(self.GetText) == "function" and
				(self:GetText() or "") or ""
			Panel.Rebuild("search_changed")
		end,
	}, search_toolbar)
	make_button(search_toolbar, translated(Config.TEXT.CLEAR_SEARCH, "Clear"), function()
		Panel.search = ""
		local edit = Panel.search_edit
		if window_valid(edit) and type(edit.SetText) == "function" then
			edit:SetText("")
		end
		Panel.Rebuild("search_cleared")
	end, { MinWidth = 90, CenterLabel = true })

	local version_toolbar = search_toolbar
	make_text(version_toolbar, translated(Config.TEXT.VERSION_SELECTOR_LABEL,
		"Game version:"), "PropValue", {
		MinWidth = 190,
		TextHAlign = "right",
		TextColor = color(255, 255, 255, 255),
	})
	Panel.version_control = XCombo:new({
		Id = "idBFGameVersion",
		Translate = false,
		ArbitraryValue = false,
		TextStyle = "PropValue",
		Padding = padding(6, 4, 1, 4),
		Background = color(8, 10, 12, 255),
		FocusedBackground = color(12, 15, 18, 255),
		BorderWidth = 1,
		BorderColor = color(70, 84, 90, 255),
		FocusedBorderColor = color(100, 118, 126, 255),
		PopupBackground = color(18, 22, 26, 255),
		ListItemTemplate = "XComboXTextListItemDark",
		AutoSelectAll = false,
		RefreshItemsOnOpen = false,
		MinWidth = 300,
		MaxWidth = 340,
		PopupMinWidth = 300,
		MinItems = 1,
		MaxItems = 10,
		Items = version_items,
		Value = initial_version_filter,
		OnValueChanged = function(self, value)
			if value ~= Config.ALL_VERSIONS_FILTER and
				Catalog.IsKnownVersion(value) ~= true
			then
				return
			end
			Panel.version_filter = value
			DebugLog.Info("Panel", "Changed game-version filter", {
				version_filter = value,
			}, "DEBUG_UI")
			Panel.Rebuild("version_filter_changed")
		end,
	}, version_toolbar)
	if type(Panel.version_control.SetValueWithText) == "function" then
		Panel.version_control:SetValueWithText(initial_version_filter,
			version_item_text(initial_version_filter), true)
	elseif type(Panel.version_control.SetValue) == "function" then
		Panel.version_control:SetValue(initial_version_filter)
	else
		DebugLog.Error("Panel", "Cannot initialize game-version dropdown value", {
			version_filter = initial_version_filter,
		})
	end
	apply_dark_combo_style(Panel.version_control)
	Panel.count_text = make_text(version_toolbar, "", "PropValue", {
		HAlign = "right",
		MinWidth = 340,
		TextColor = color(230, 230, 230, 255),
	})

	local list_height, desktop_height, ui_scale_y = list_viewport_height(desktop)
	local list_container = XWindow:new({
		HAlign = "stretch",
		VAlign = "top",
		MinHeight = list_height,
		MaxHeight = list_height,
	}, content)
	local list = XList:new({
		Id = "idBFFixList",
		Dock = "box",
		VScroll = "idBFScroll",
		MinHeight = list_height,
		MaxHeight = list_height,
		LayoutMethod = "VList",
		LayoutVSpacing = 5,
		Padding = padding(3, 3, 3, 32),
		BorderWidth = 1,
		BorderColor = color(50, 60, 66, 255),
		Background = color(12, 15, 18, 255),
		FocusedBackground = color(12, 15, 18, 255),
		FocusedBorderColor = color(50, 60, 66, 255),
		Clip = "parent & self",
		MouseScroll = true,
		WorkUnfocused = true,
		GamepadInitialSelection = false,
		ForceInitialSelection = false,
		SetFocusOnOpen = false,
		OnSelection = function(self)
			if type(self.SetSelection) == "function" then
				self:SetSelection(false, false)
			end
		end,
	}, list_container)
	Panel.list = list
	if XScrollBar then
		Panel.scrollbar = XScrollBar:new({
			Id = "idBFScroll",
			Dock = "right",
			Margins = padding(6, 2, 2, 2),
			MinWidth = 14,
			MaxWidth = 14,
			MinThumbSize = 48,
			Target = "idBFFixList",
			SnapToItems = true,
			AutoHide = true,
			Background = color(18, 22, 26, 255),
			DisabledBackground = color(18, 22, 26, 160),
			ScrollColor = color(100, 118, 126, 255),
			DisabledScrollColor = color(70, 84, 90, 160),
			BorderWidth = 1,
			BorderColor = color(50, 60, 66, 255),
		}, list_container)
		DebugLog.Info("Panel", "Created bug-fix list scrollbar", {
			target = "idBFFixList",
			list_v_scroll = "idBFScroll",
			auto_hide = true,
		}, "DEBUG_UI")
	else
		DebugLog.Warn("Panel", "XScrollBar unavailable; list remains mouse-wheel scrollable",
			nil, "DEBUG_UI")
	end

	local footer = XWindow:new({
		LayoutMethod = "HList",
		LayoutHSpacing = 8,
		HAlign = "stretch",
		VAlign = "center",
		Padding = padding(0, 6, 0, 0),
	}, content)
	make_button(footer, translated(Config.TEXT.SELECT_GROUP, "Select group"), function()
		Panel.SetVisibleGroupState(true, "select_visible_button")
	end, {
		MinWidth = 90,
		MinHeight = 30,
		MaxHeight = 36,
		CenterLabel = true,
	})
	make_button(footer, translated(Config.TEXT.UNSELECT_GROUP, "Unselect group"), function()
		Panel.SetVisibleGroupState(false, "unselect_visible_button")
	end, {
		MinWidth = 90,
		MinHeight = 30,
		MaxHeight = 36,
		CenterLabel = true,
	})
	make_button(footer, translated(Config.TEXT.APPLY, "Apply"), function()
		Panel.Apply("apply_button")
	end, {
		HAlign = "left",
		MinWidth = 90,
		MinHeight = 30,
		MaxHeight = 36,
		CenterLabel = true,
		Background = color(36, 58, 44, 235),
		RolloverBackground = color(50, 82, 61, 235),
	})
	make_button(footer, translated(Config.TEXT.RESET, "Reset"), function()
		Panel.ResetStaged("reset_button")
	end, {
		MinWidth = 90,
		MinHeight = 30,
		MaxHeight = 36,
		CenterLabel = true,
	})
	make_button(footer, translated(Config.TEXT.BACK, "Back"), function()
		Panel.Close("back_button")
	end, {
		HAlign = "left",
		MinWidth = 90,
		MinHeight = 30,
		MaxHeight = 36,
		CenterLabel = true,
		Background = color(70, 40, 40, 235),
		RolloverBackground = color(100, 56, 56, 235),
	})

	root:Open()
	if type(root.SetModal) == "function" then
		local ok, err = pcall(function() root:SetModal(true) end)
		if ok ~= true then
			DebugLog.Error("Panel", "Failed to make SMR Community Fixes panel modal", {
				reason = reason,
				error = err,
			})
		end
	end
	if type(root.SetFocus) == "function" then
		local ok = pcall(function() root:SetFocus(true) end)
		if ok ~= true then pcall(function() root:SetFocus() end) end
	end

	Panel.Rebuild("open")
	DebugLog.Info("Panel", "Opened SMR Community Fixes panel", {
		reason = reason,
		list_height = list_height,
		list_height_per_mille = Config.PANEL_LIST_HEIGHT_PER_MILLE,
		desktop_height = desktop_height,
		ui_scale_y = ui_scale_y,
	}, "DEBUG_UI")
	return true
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

Mod.Log = DebugLog
Mod.Persistence = Persistence
Mod.Registry = Catalog
Mod.OptionsPatch = OptionsPatch

local function run_step(label, fn, reason)
	local ok, result = pcall(fn, reason)
	if ok ~= true then
		DebugLog.Error("Lifecycle", "Lifecycle step raised an error", {
			step = label,
			reason = reason,
			error = result,
		})
		return false
	end
	if result == false then
		DebugLog.Error("Lifecycle", "Lifecycle step reported failure", {
			step = label,
			reason = reason,
		})
		return false
	end
	return true
end

-- One lifecycle pass: adopt any newly registered fixes, load settings the first time, make
-- sure the Options entry exists, then bring every fix into line with the saved choices.
-- Called from each of the OnMsg handlers below as well as at code load, so it must be safe
-- to run any number of times.
function Mod.Apply(reason)
	local adopted = Catalog.AdoptPending(reason)
	if Mod.booted ~= true then
		run_step("persistence_load", Persistence.Load, reason)
		Mod.booted = true
	elseif adopted == true then
		-- Fixes adopted after the first pass, which is what happens when the 'code'
		-- list loads this file before them. Their defaults are seeded now, because
		-- Persistence.Load has already run and will not run again.
		run_step("persistence_seed", Persistence.SeedDefaults, reason)
	end
	run_step("options_category", OptionsPatch.Apply, reason)
	run_step("fix_registry", Catalog.ApplyAll, reason)
	DebugLog.Info("Lifecycle", "Applied SMR Community Fixes lifecycle", {
		reason = reason,
		version = mod_version(),
		target_game_version = Config.TARGET_GAME_VERSION,
		registered_fixes = #Mod.entries,
	}, nil)
	return true
end

Mod.Apply("code_load")

function OnMsg.ClassesBuilt()
	Mod.Apply("ClassesBuilt")
end

-- Runs when a game starts or a save loads. Fixes are told first (GameStateStarting), so they
-- can clear per-game state and repair what the save contains, and the full apply pass is
-- then deferred by one frame through DelayedCall so the game has finished setting itself up.
-- If DelayedCall is unavailable the pass simply runs immediately.
local function apply_after_game_state(reason)
	Catalog.Notify("GameStateStarting", reason)
	local delayed_call = rawget(_G, "DelayedCall")
	if type(delayed_call) == "function" then
		delayed_call(0, function()
			Mod.Apply(reason .. "_deferred")
		end)
	else
		Mod.Apply(reason)
	end
end

function OnMsg.CityStart()
	apply_after_game_state("CityStart")
end

function OnMsg.LoadGame()
	apply_after_game_state("LoadGame")
end

function OnMsg.ModsReloaded()
	Mod.Apply("ModsReloaded")
end

function OnMsg.RainDisasterEnd()
	Catalog.Notify("RainDisasterEnd", "RainDisasterEnd")
end

local function close_panel(reason)
	if Panel.IsOpen() then Panel.Close(reason) end
end

function OnMsg.ChangeMap()
	close_panel("ChangeMap")
end

function OnMsg.DoneGame()
	Catalog.Notify("DoneGame", "DoneGame")
	close_panel("DoneGame")
end

-- Hands the game back before this mod's Lua is taken away.
--
-- Everything the mod changes is a wrapper or a field inside the game's own
-- globals and classes, and none of that disappears just because the mod does. Left
-- alone, a wrapper would go on being called with the code behind it unloaded, and
-- Options would keep a row that leads nowhere. So this is the last chance to undo
-- it, and it is taken.
--
-- Only the runtime change is undone. Saved choices stay exactly as they are, so
-- switching the mod back on restores the same set of fixes.
function Mod.Unload(reason)
	local ok = Catalog.QuiesceAll(reason)
	OptionsPatch.Remove(reason)
	close_panel(reason)
	DebugLog.Info("Lifecycle", "Stood down before this mod's Lua was unloaded", {
		reason = reason,
		ok = ok,
	}, nil)
	return ok
end

-- Fired by the game just before it unloads a mod that has Lua, which is what
-- happens when the mod is switched off in the Mod Manager. It names the mod, so
-- another mod being unloaded does not stand this one down.
function OnMsg.ModUnloadLua(mod_id)
	if mod_id ~= Config.MOD_ID then return end
	Mod.Unload("ModUnloadLua")
end

return Mod
