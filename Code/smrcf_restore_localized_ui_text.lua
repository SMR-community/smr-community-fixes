-- Restore Localized UI Text - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): two pieces of UI ship as raw English instead of going through
--   the game's translation records, so they stay English in every other language:
--   the OVERALL TERRAFORMING PROGRESS heading, and the Universal Rocket's
--   "Back to Earth" rollover title and text.
-- Vanilla code:     Lua/LocalizationTexts.lua and the generated XDef UI files
--   (TerraformingOverall, customUniversalRocket)
-- The repair:       rebuild those three strings through the official ids that
--   already exist in every shipped language file: 914616772802 for the heading,
--   407456913268 and 316233855405 for the rollover.
-- Left alone:       the English wording, and every other UI behavior. COLONY DATA
--   is deliberately not fixed: no reusable translation record exists for it, and
--   inventing one is not this mod's job.

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
	id = "restore_localized_ui_text",
	number = 12,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Localized UI Text",
	description = "Uses v1.0.7's existing official translations for the overall terraforming heading and the Universal Rocket's Back to Earth action.",
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

-- Wraps text in the game's own T() localization call when it is available, so
-- strings reused from the game's translation tables stay translated for every
-- language. Falls back to the plain text when T() is missing.
local function translated(id, text)
	local translate = rawget(_G, "T")
	if type(translate) == "function" then return translate(id, text) end
	return text
end

-- Live state for this fix. It lives in a global so that a Lua reload - a Mod
-- Editor save, or the mod being reloaded in game - finds the existing table
-- instead of forgetting what is currently installed.
local RestoreLocalizedUIText = rawget(_G, "SMRCFRestoreLocalizedUIText")
if RestoreLocalizedUIText == nil then
	RestoreLocalizedUIText = { enabled = false }
	rawset(_G, "SMRCFRestoreLocalizedUIText", RestoreLocalizedUIText)
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

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_LocalizedUITextHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original_rocket_init = false,
		base_rocket_init = false,
		wrapper_rocket_init = false,
		in_rocket_init = false,
		original_terraforming_init = false,
		base_terraforming_init = false,
		wrapper_terraforming_init = false,
		in_terraforming_init = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_LocalizedUITextHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_methods()
	local rocket_ui = rawget(_G, "customUniversalRocket")
	local terraforming_ui = rawget(_G, "TerraformingOverall")
	if type(rocket_ui) == "table" then
		local method = rocket_ui.Init
		if method ~= Hooks.wrapper_rocket_init and type(method) == "function" then
			Hooks.original_rocket_init = method
			Hooks.base_rocket_init = Hooks.base_rocket_init or method
		end
	end
	if type(terraforming_ui) == "table" then
		local method = terraforming_ui.Init
		if method ~= Hooks.wrapper_terraforming_init and
			type(method) == "function"
		then
			Hooks.original_terraforming_init = method
			Hooks.base_terraforming_init =
				Hooks.base_terraforming_init or method
		end
	end
	return type(Hooks.original_rocket_init) == "function" and
		type(Hooks.original_terraforming_init) == "function"
end

capture_methods()

-- This fix wraps two UI constructors, so a naming convention replaces a single
-- captured function: for "rocket_init" the captured original is
-- Hooks.original_rocket_init, the pre-wrap version Hooks.base_rocket_init, and the
-- re-entry flag Hooks.in_rocket_init. One helper then serves both.
local function call_original(method_name, ...)
	local in_key = "in_" .. method_name
	local original_key = "original_" .. method_name
	local base_key = "base_" .. method_name
	if Hooks[in_key] == true then return Hooks[base_key](...) end
	Hooks[in_key] = true
	local result = { pcall(Hooks[original_key], ...) }
	Hooks[in_key] = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

-- Walks a freshly built window tree looking for a control by its literal text. Used
-- for the terraforming heading, which has no Id to search by - the hard-coded English
-- string is the only handle the game gives us.
local function find_by_text(root, expected)
	if type(root) ~= "table" then return nil end
	if root.Text == expected then return root end
	for _, child in ipairs(root) do
		local found = find_by_text(child, expected)
		if found then return found end
	end
	return nil
end

-- The same walk, by control Id. Preferred whenever the game gives a control an Id,
-- because an Id survives translation and rewording while literal text does not.
local function find_by_id(root, expected)
	if type(root) ~= "table" then return nil end
	if root.Id == expected then return root end
	for _, child in ipairs(root) do
		local found = find_by_id(child, expected)
		if found then return found end
	end
	return nil
end

-- Re-sets the Back to Earth rollover through the game's own translation ids. Those
-- two ids already exist in every shipped language file - this fix does not add or
-- invent a translation, it only stops the UI from bypassing them. English players see
-- no change at all.
local function patch_rocket_ui(root)
	if Hooks.enabled ~= true or type(root) ~= "table" then return end
	local button = find_by_id(root, "idBackToEarth")
	if not button or type(button.SetRolloverTitle) ~= "function" or
		type(button.SetRolloverText) ~= "function"
	then
		log("ERROR",
			"Back to Earth UI control was not available for localization", nil)
		return
	end
	button:SetRolloverTitle(translated(407456913268, "Back to Earth"))
	button:SetRolloverText(translated(316233855405,
		"Send the rocket directly to Earth without any resources."))
	log("INFO",
		"Bug fix invoked: routed Back to Earth text through existing official localization entries",
		correction_context({
			repair = "back_to_earth_localization_ids",
			reason = "untranslated_xdef_ids",
			title_translation_id = 407456913268,
			description_translation_id = 316233855405,
		}))
end

-- Same idea for the terraforming heading: find the control holding the hard-coded
-- English string and re-set it through the official id 914616772802. If the control
-- cannot be found - a game patch reworded or restructured the screen - that is an
-- ungated ERROR rather than a silent no-op, so the fix cannot rot unnoticed.
local function patch_terraforming_ui(root)
	if Hooks.enabled ~= true or type(root) ~= "table" then return end
	local heading = find_by_text(root, "OVERALL TERRAFORMING PROGRESS")
	if not heading or type(heading.SetText) ~= "function" then
		log("ERROR",
			"Overall terraforming heading was not available for localization", nil)
		return
	end
	heading:SetText(translated(914616772802,
		"OVERALL TERRAFORMING PROGRESS"))
	log("INFO",
		"Bug fix invoked: routed the overall terraforming heading through its existing official localization entry",
		correction_context({
			repair = "terraforming_heading_localization_id",
			reason = "literal_xdef_text",
			translation_id = 914616772802,
		}))
end

-- Both wrappers follow the same shape: let the game build its window exactly as
-- normal, then correct the text afterwards. Patching after construction rather than
-- replacing the constructor means every other part of the screen - layout, buttons,
-- behavior - is untouched, and vanilla's return values are passed through unchanged.
if type(Hooks.wrapper_rocket_init) ~= "function" then
	Hooks.wrapper_rocket_init = function(root, ...)
		local result = { call_original("rocket_init", root, ...) }
		patch_rocket_ui(root)
		return table.unpack(result)
	end
end

if type(Hooks.wrapper_terraforming_init) ~= "function" then
	Hooks.wrapper_terraforming_init = function(root, ...)
		local result = { call_original("terraforming_init", root, ...) }
		patch_terraforming_ui(root)
		return table.unpack(result)
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreLocalizedUIText.InstallHooks(reason)
	local rocket_ui = rawget(_G, "customUniversalRocket")
	local terraforming_ui = rawget(_G, "TerraformingOverall")
	if capture_methods() ~= true or type(rocket_ui) ~= "table" or
		type(terraforming_ui) ~= "table"
	then
		log("ERROR",
			"Required v1.0.7 UI constructor API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	rocket_ui.Init = Hooks.wrapper_rocket_init
	terraforming_ui.Init = Hooks.wrapper_terraforming_init
	Hooks.enabled = true
	RestoreLocalizedUIText.enabled = true
	log("INFO",
		"Installed localized UI constructor hooks", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreLocalizedUIText.RestoreHooks(reason)
	Hooks.enabled = false
	RestoreLocalizedUIText.enabled = false
	local rocket_ui = rawget(_G, "customUniversalRocket")
	local terraforming_ui = rawget(_G, "TerraformingOverall")
	if type(rocket_ui) == "table" and
		rocket_ui.Init == Hooks.wrapper_rocket_init
	then
		rocket_ui.Init = Hooks.original_rocket_init
	end
	if type(terraforming_ui) == "table" and
		terraforming_ui.Init == Hooks.wrapper_terraforming_init
	then
		terraforming_ui.Init = Hooks.original_terraforming_init
	end
	log("INFO",
		"Restored captured UI constructors", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreLocalizedUIText.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreLocalizedUIText.InstallHooks(reason) end
	return RestoreLocalizedUIText.RestoreHooks(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreLocalizedUIText.Quiesce(reason)
	return RestoreLocalizedUIText.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreLocalizedUIText.SetEnabled
FIX.quiesce = RestoreLocalizedUIText.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreLocalizedUIText
