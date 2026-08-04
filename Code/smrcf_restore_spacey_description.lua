-- Restore SpaceY Description - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): SpaceY's sponsor description lists only part of its Drone Hub
--   benefit. The game really does grant +20 maximum command capacity as well as
--   the 4 extra starting Drones, but the text never says so, so players compare
--   sponsors on wrong information.
-- Vanilla code:     the SpaceY MissionSponsorPreset and its `effect` text
-- The repair:       swap that one description string for wording that states both
--   benefits, taken from the game's own translation record.
-- Left alone:       every gameplay value. The Effect_ModifyLabel entries that
--   actually grant the bonus are not touched - this fix is text only.

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
	id = "restore_spacey_description",
	number = 7,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore SpaceY Description",
	description = "Adds SpaceY's missing +20 maximum Drone Hub command-capacity benefit to its v1.0.7 sponsor description; gameplay values are unchanged.",
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
local RestoreSpaceYDescription = rawget(_G, "SMRCFRestoreSpaceYDescription")
if RestoreSpaceYDescription == nil then
	RestoreSpaceYDescription = { enabled = false }
	rawset(_G, "SMRCFRestoreSpaceYDescription", RestoreSpaceYDescription)
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

-- This fix edits one preset field rather than wrapping a function, so what has to
-- survive a Lua reload is the original text it replaced. That lives in
-- SharedModEnv, an engine table that is never saved and never cleared, so the
-- vanilla wording can still be restored after the mod is reloaded mid-session.
-- `protocol` rejects a table left by an older, differently shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_state = type(shared) == "table" and
	shared.SMRCF_SpaceYDescriptionState or nil
local State
if type(previous_state) == "table" and previous_state.protocol == 1 then
	State = previous_state
else
	State = {
		protocol = 1,
		enabled = false,
		original_effect = nil,
		patched_effect = false,
	}
end
if type(shared) == "table" then
	shared.SMRCF_SpaceYDescriptionState = State
end

-- Finds the SpaceY sponsor preset. Two lookups, because the live table
-- MissionSponsors only exists once the game has built its presets; before that the
-- preset is still only in Presets.MissionSponsorPreset.Default. Returning nil is
-- normal early in startup and the caller handles it.
local function spacey_preset()
	local sponsors = rawget(_G, "MissionSponsors")
	if type(sponsors) == "table" and sponsors.SpaceY then
		return sponsors.SpaceY
	end
	local presets = rawget(_G, "Presets")
	local sponsor_presets = type(presets) == "table" and
		presets.MissionSponsorPreset or nil
	local defaults = type(sponsor_presets) == "table" and
		sponsor_presets.Default or nil
	return type(defaults) == "table" and defaults.SpaceY or nil
end

-- The corrected description text, built once and remembered. It is the vanilla
-- wording with one bullet completed, and it goes through T() with this mod's own
-- text id so it can be translated later. Note it is compared by identity in
-- Restore(), which is why the same value has to be reused rather than rebuilt.
local function patched_effect()
	if State.patched_effect then return State.patched_effect end
	State.patched_effect = translated(981267450064,
		"<bullet> <em>Dragon Rocket</em> - has smaller cargo capacity (<cargo>) but is faster and requires less fuel\n<bullet> <em>Solar Array</em> - a large cluster of solar panels that have lower maintenance cost but are vulnerable to dust storms\n<bullet> Drone Hubs start with 4 additional Drones and can command 20 additional Drones\n<bullet> 50% cheaper advanced resources")
	return State.patched_effect
end

-- Tells the UI the preset changed, so an open sponsor screen redraws instead of
-- showing the old text until it is reopened. ObjModified is the game's own
-- "this object changed" signal.
local function notify_changed(preset)
	local modified = rawget(_G, "ObjModified")
	if type(modified) == "function" then modified(preset) end
end

-- Turn the fix on: remember the vanilla text, then swap in the corrected one.
--
-- The startup-order detail worth copying: presets do not exist yet during
-- code_load or ClassesBuilt. A missing preset at those two moments is normal, so it
-- is a quiet deferral that reports success - the framework calls this again later
-- and it works then. A missing preset at any later point is a real problem and is
-- logged as an ungated ERROR.
function RestoreSpaceYDescription.Apply(reason)
	local preset = spacey_preset()
	if not preset or preset.id ~= "SpaceY" then
		if reason == "code_load" or reason == "ClassesBuilt" then
			log("WARN",
				"SpaceY sponsor preset is not initialized yet; deferring fix", {
					reason = reason,
				})
			return true
		end
		log("ERROR",
			"Required v1.0.7 SpaceY sponsor preset is unavailable; fix not applied", {
				reason = reason,
			})
		return false
	end

	local replacement = patched_effect()
	if preset.effect ~= replacement then
		State.original_effect = preset.effect
		preset.effect = replacement
		notify_changed(preset)
		log("INFO",
			"Bug fix invoked: restored the missing SpaceY Drone Hub capacity text",
			correction_context({
				repair = "spacey_sponsor_effect_text",
				reason = reason,
				command_center_max_drones_bonus = 20,
				starting_drones_bonus = 4,
			}))
	end
	RestoreSpaceYDescription.enabled = true
	State.enabled = true
	log("INFO",
		"Applied SpaceY sponsor-description patch", {
			reason = reason,
		})
	return true
end

-- Turn the fix off: put the captured vanilla text back, but only if the preset
-- still holds *our* text. If something else changed the description in the
-- meantime, that value is left alone rather than overwritten with a stale string.
function RestoreSpaceYDescription.Restore(reason)
	local preset = spacey_preset()
	if preset and preset.effect == State.patched_effect and
		State.original_effect ~= nil
	then
		preset.effect = State.original_effect
		notify_changed(preset)
	end
	RestoreSpaceYDescription.enabled = false
	State.enabled = false
	log("INFO",
		"Restored captured SpaceY sponsor description", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreSpaceYDescription.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreSpaceYDescription.Apply(reason) end
	return RestoreSpaceYDescription.Restore(reason)
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreSpaceYDescription.Quiesce(reason)
	return RestoreSpaceYDescription.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreSpaceYDescription.SetEnabled
FIX.quiesce = RestoreSpaceYDescription.Quiesce

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreSpaceYDescription
