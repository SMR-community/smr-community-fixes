-- Restore Saint Blessing - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): a Saint's dome Morale bonus is applied to the label
--   "Religious", but colonists are actually gathered under the label the game's
--   own GetTraitLabel("Religious") returns. The names do not match, so the bonus
--   reaches nobody.
-- Vanilla code:     GetTraitLabel() in Lua/Traits.lua, plus the Saint trait preset
-- The repair:       point only the Saint modifier at the real label. When the fix
--   is switched on it also reconciles Saints who already live in domes, so the
--   bonus is not limited to Saints who move in later.
-- Left alone:       every non-Saint trait modifier, and the documented +10 Morale
--   per Saint and its stacking.

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
	id = "restore_saint_blessing",
	number = 6,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Saint Blessing",
	description = "Applies each Saint's stacking Morale bonus to the Religious colonists in that Saint's Dome, correcting v1.0.7's mismatched trait label.",
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

-- Live state for this fix. It lives in a global so that a Lua reload - a Mod
-- Editor save, or the mod being reloaded in game - finds the existing table
-- instead of forgetting what is currently installed.
local RestoreSaintBlessing = rawget(_G, "SMRCFRestoreSaintBlessing")
if RestoreSaintBlessing == nil then
	RestoreSaintBlessing = { enabled = false }
	rawset(_G, "SMRCFRestoreSaintBlessing", RestoreSaintBlessing)
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
	shared.SMRCF_SaintBlessingHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original_add = false,
		original_remove = false,
		wrapper_add = false,
		wrapper_remove = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_SaintBlessingHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_current_methods()
	local trait_class = rawget(_G, "TraitPreset")
	if type(trait_class) ~= "table" then return false end

	local current_add = trait_class.AddDomeColonistsModifier
	if current_add ~= Hooks.wrapper_add and type(current_add) == "function" then
		if type(Hooks.original_add) == "function" and
			current_add ~= Hooks.original_add
		then
			Hooks.original_add_may_contain_wrapper = true
		end
		Hooks.original_add = current_add
	end
	local current_remove = trait_class.RemoveDomeColonistsModifier
	if current_remove ~= Hooks.wrapper_remove and
		type(current_remove) == "function"
	then
		if type(Hooks.original_remove) == "function" and
			current_remove ~= Hooks.original_remove
		then
			Hooks.original_remove_may_contain_wrapper = true
		end
		Hooks.original_remove = current_remove
	end
	Hooks.base_original_add = Hooks.base_original_add or Hooks.original_add
	Hooks.base_original_remove = Hooks.base_original_remove or Hooks.original_remove
	return type(Hooks.original_add) == "function" and
		type(Hooks.original_remove) == "function"
end

capture_current_methods()

-- This fix wraps two methods - the one that applies a trait's dome modifier and the
-- one that removes it - so there are two small "call vanilla" helpers. Each prefers
-- the version captured before any wrapping when another mod has since wrapped ours,
-- so the same chain is not walked twice.
local function original_add(...)
	local fn = Hooks.original_add_may_contain_wrapper == true and
		Hooks.base_original_add or Hooks.original_add
	return fn(...)
end

local function original_remove(...)
	local fn = Hooks.original_remove_may_contain_wrapper == true and
		Hooks.base_original_remove or Hooks.original_remove
	return fn(...)
end

-- The label colonists are *actually* collected under. This is the heart of the bug:
-- the Saint modifier names the label "Religious", but the game groups colonists under
-- whatever GetTraitLabel("Religious") returns. Asking the game rather than assuming
-- is what makes the modifier reach real colonists.
local function religious_label()
	local get_trait_label = rawget(_G, "GetTraitLabel")
	return type(get_trait_label) == "function" and
		get_trait_label("Religious") or false
end

-- Narrows the repair to one modifier: the Saint trait targeting "Religious", and
-- only while the fix is on. Every other trait modifier passes through untouched,
-- which is why enabling this fix cannot disturb unrelated colonist bonuses.
local function is_saint_modifier(trait, target_trait)
	return Hooks.enabled == true and trait and trait.id == "Saint" and
		target_trait == "Religious"
end

-- The repair: pass the corrected label to vanilla instead of the broken one. Vanilla
-- still does all the work of creating and applying the modifier - only the label it
-- is pointed at changes. If the game cannot tell us the real label, the original
-- value is used, so the worst case is vanilla's own behavior.
if type(Hooks.wrapper_add) ~= "function" then
	Hooks.wrapper_add = function(trait, unit, target_trait)
		if is_saint_modifier(trait, target_trait) then
			local fixed_label = religious_label()
			if fixed_label then
				local result = original_add(trait, unit, fixed_label)
				if unit and unit.dome then
					log("INFO",
						"Bug fix invoked: applied the Saint modifier to Religious colonists",
						correction_context({
							repair = "saint_trait_label",
							reason = "vanilla_trait_label_mismatch",
							colonist_handle = unit.handle,
							dome_handle = unit.dome.handle,
							target_label = fixed_label,
						}))
				end
				return result
			end
		end
		return original_add(trait, unit, target_trait)
	end
end

-- Removal has to use the same corrected label, or the modifier this fix applied
-- would never be taken away again when a Saint leaves a dome.
if type(Hooks.wrapper_remove) ~= "function" then
	Hooks.wrapper_remove = function(trait, unit, target_trait)
		if is_saint_modifier(trait, target_trait) then
			target_trait = religious_label() or target_trait
		end
		return original_remove(trait, unit, target_trait)
	end
end

-- Visits every Saint who already lives in a dome, across all cities. Colonists are
-- read from the game's own `Colonist` label rather than searched for, and each one is
-- rechecked with IsValid because a label list can still hold a colonist that died a
-- moment ago.
local function each_existing_saint(callback)
	local cities = rawget(_G, "Cities")
	local is_valid = rawget(_G, "IsValid")
	if type(cities) ~= "table" then return 0 end

	local count = 0
	for _, city in ipairs(cities) do
		local labels = city and city.labels
		local colonists = labels and labels.Colonist
		if type(colonists) == "table" then
			for _, colonist in ipairs(colonists) do
				local valid = type(is_valid) ~= "function" or is_valid(colonist)
				if valid and colonist.dome and colonist.traits and
					colonist.traits.Saint
				then
					callback(colonist)
					count = count + 1
				end
			end
		end
	end
	return count
end

-- The Saint trait definition itself, needed because reconciling an existing game
-- means removing and re-adding the modifier that this preset owns.
local function saint_preset()
	local presets = rawget(_G, "TraitPresets")
	return type(presets) == "table" and presets.Saint or nil
end

-- Fixes Saints who are already in domes, in both directions.
--
-- Without this, switching the fix on would only help Saints who move into a dome
-- afterwards, because the broken modifier was applied long ago. Enabling removes the
-- modifier under the wrong label and re-adds it under the right one; disabling does
-- exactly the reverse, which is what lets the fix be turned off cleanly mid-game.
-- Both directions go through vanilla's own add/remove methods.
function RestoreSaintBlessing.ReconcileExisting(enable, reason)
	local saint = saint_preset()
	local fixed_label = religious_label()
	if not saint or not fixed_label then return 0 end

	local count = each_existing_saint(function(colonist)
		if enable == true then
			original_remove(saint, colonist, "Religious")
			original_add(saint, colonist, fixed_label)
		else
			original_remove(saint, colonist, fixed_label)
			original_add(saint, colonist, "Religious")
		end
	end)
	if enable == true and count > 0 then
		log("INFO",
			"Bug fix invoked: reconciled existing Saint dome modifiers",
			correction_context({
				repair = "existing_saint_modifiers",
				reason = reason,
				saints_reconciled = count,
				target_label = fixed_label,
			}))
	end
	return count
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreSaintBlessing.InstallHooks(reason)
	if capture_current_methods() ~= true or not religious_label() then
		log("ERROR",
			"Required v1.0.7 trait APIs are unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end

	local trait_class = rawget(_G, "TraitPreset")
	trait_class.AddDomeColonistsModifier = Hooks.wrapper_add
	trait_class.RemoveDomeColonistsModifier = Hooks.wrapper_remove
	RestoreSaintBlessing.enabled = true
	Hooks.enabled = true
	RestoreSaintBlessing.ReconcileExisting(true, reason)
	log("INFO",
		"Installed Saint dome-modifier hooks", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreSaintBlessing.RestoreHooks(reason)
	local was_enabled = RestoreSaintBlessing.enabled == true or
		Hooks.enabled == true
	RestoreSaintBlessing.enabled = false
	Hooks.enabled = false
	if was_enabled then
		RestoreSaintBlessing.ReconcileExisting(false, reason)
	end

	local trait_class = rawget(_G, "TraitPreset")
	if type(trait_class) == "table" then
		if trait_class.AddDomeColonistsModifier == Hooks.wrapper_add then
			trait_class.AddDomeColonistsModifier = Hooks.original_add
		end
		if trait_class.RemoveDomeColonistsModifier == Hooks.wrapper_remove then
			trait_class.RemoveDomeColonistsModifier = Hooks.original_remove
		end
	end
	log("INFO",
		"Restored captured Saint modifier methods", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreSaintBlessing.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreSaintBlessing.InstallHooks(reason) end
	return RestoreSaintBlessing.RestoreHooks(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreSaintBlessing.Quiesce(reason)
	return RestoreSaintBlessing.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreSaintBlessing.SetEnabled
FIX.quiesce = RestoreSaintBlessing.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreSaintBlessing
