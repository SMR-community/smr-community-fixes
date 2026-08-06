-- Restore Trade Rocket Protection - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): RC Transports are deliberately not allowed to interrupt trade
--   and refugee rockets, but the newer UniversalTradeRocket class was left out of
--   that exclusion, so a transport can interrupt one and cancel the trade.
-- Vanilla code:     the RC Transport interaction checks in Lua/Units/RCTransport.lua
-- The repair:       extend the exclusion the legacy rockets already have to
--   UniversalTradeRocket, blocking both the eligibility test and a direct
--   interaction command.
-- Left alone:       RC Transport interaction with storages, colony rockets and
--   every other target.

-- What this fix is, as data. SMRCommunityFixes.lua reads this table and needs nothing
-- else from this file.
--   id              the key the player's on/off choice is saved under - permanent
--   number          left out on purpose: the framework numbers the rows by
--                   list position, so removing a fix renumbers the rest
--   beta            true while the fix still needs testing in real games
--   versions        the game versions this repair was verified against
--   default_enabled whether a fresh install starts with it on
--   debug           this file's own diagnostics switch; false in a published build
--   label/description  plain text for the checklist row (rendered untranslated)
local FIX = {
	id = "restore_trade_rocket_protection",
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Trade Rocket Protection",
	description = "Prevents RC Transports from interrupting v1.0.7 Universal Trade Rockets, matching the protection already applied to legacy trade and refugee rockets.",
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

local RestoreTradeRocketProtection = rawget(_G,
	"SMRCFRestoreTradeRocketProtection")
if RestoreTradeRocketProtection == nil then
	RestoreTradeRocketProtection = { enabled = false }
	rawset(_G, "SMRCFRestoreTradeRocketProtection",
		RestoreTradeRocketProtection)
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

-- A table with weak keys: entries disappear once the game object used as the key
-- is collected. Per-object bookkeeping can be recorded here without keeping a
-- destroyed object alive or leaking state across a save/load.
local function weak_keys()
	return setmetatable({}, { __mode = "k" })
end

-- The captured vanilla function(s) and this fix's wrapper live in SharedModEnv,
-- an engine table that is never saved and never cleared. The wrapper is installed
-- once and left in place; enabling and disabling only flip Hooks.enabled. That is
-- what makes a reload safe: it can neither stack two wrappers nor lose the
-- original function. `protocol` rejects a table left by an older, differently
-- shaped release.
local shared = rawget(_G, "SharedModEnv")
local previous_hooks = type(shared) == "table" and
	shared.SMRCF_TradeRocketProtectionHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 2 then
	Hooks = previous_hooks
	Hooks.reported_targets = Hooks.reported_targets or weak_keys()
else
	Hooks = {
		protocol = 2,
		enabled = false,
		original_can_interact = false,
		original_interact = false,
		base_can_interact = false,
		base_interact = false,
		wrapper_can_interact = false,
		wrapper_interact = false,
		in_can_interact = false,
		in_interact = false,
		reported_targets = weak_keys(),
	}
end
if type(shared) == "table" then
	shared.SMRCF_TradeRocketProtectionHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_methods()
	local transport = rawget(_G, "RCTransport")
	if type(transport) ~= "table" then return false end
	local can_interact = transport.CanInteractWithObject
	local interact = transport.InteractWithObject
	if can_interact ~= Hooks.wrapper_can_interact and
		type(can_interact) == "function"
	then
		Hooks.original_can_interact = can_interact
		Hooks.base_can_interact = Hooks.base_can_interact or can_interact
	end
	if interact ~= Hooks.wrapper_interact and type(interact) == "function" then
		Hooks.original_interact = interact
		Hooks.base_interact = Hooks.base_interact or interact
	end
	return type(Hooks.original_can_interact) == "function" and
		type(Hooks.original_interact) == "function"
end

capture_methods()

-- The entire test this fix adds: is the thing the transport is about to interact
-- with a UniversalTradeRocket? IsKindOf is the game's own class test, so subclasses
-- are covered too. Legacy trade and refugee rockets are already excluded by vanilla
-- and are not mentioned here.
local function is_protected_trade_rocket(object)
	local is_kind_of = rawget(_G, "IsKindOf")
	return type(is_kind_of) == "function" and
		is_kind_of(object, "UniversalTradeRocket") == true
end

-- Reports a correction at most once per situation. Without this throttle the same
-- line would be written every frame the guarded condition holds.
local function report_blocked(transport, rocket, interaction_mode, operation)
	if Hooks.reported_targets[rocket] == true and
		operation == "eligibility_check"
	then
		return
	end
	Hooks.reported_targets[rocket] = true
	log("INFO",
		"Bug fix invoked: blocked an RC Transport interaction with a Universal Trade Rocket",
		correction_context({
			repair = "universal_trade_rocket_rc_transport_guard",
			reason = operation,
			transport_handle = transport and transport.handle,
			rocket_handle = rocket and rocket.handle,
			rocket_class = rocket and rocket.class,
			interaction_mode = interaction_mode,
		}))
end

-- This fix wraps two methods, so instead of one captured function there is a small
-- naming convention: for method "can_interact" the captured original lives in
-- Hooks.original_can_interact, the pre-wrap version in Hooks.base_can_interact, and
-- the re-entry flag in Hooks.in_can_interact. One helper then serves both methods.
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

-- Two hooks are needed, not one. This first one answers "may the transport interact
-- with that?" and is what greys the option out. Blocking only here would still leave
-- a direct command able to reach the rocket, which is why the second wrapper below
-- guards the command itself.
--
-- Unlike most fixes here, the guard runs *before* vanilla: once the target is a
-- Universal Trade Rocket the answer is false regardless of what vanilla would say.
if type(Hooks.wrapper_can_interact) ~= "function" then
	Hooks.wrapper_can_interact = function(transport, object, interaction_mode)
		if Hooks.enabled == true and is_protected_trade_rocket(object) then
			report_blocked(transport, object, interaction_mode,
				"eligibility_check")
			return false
		end
		return call_original("can_interact",
			transport, object, interaction_mode)
	end
end

if type(Hooks.wrapper_interact) ~= "function" then
	Hooks.wrapper_interact = function(transport, object, interaction_mode)
		if Hooks.enabled == true and is_protected_trade_rocket(object) then
			report_blocked(transport, object, interaction_mode,
				"interaction_command")
			return false
		end
		return call_original("interact", transport, object, interaction_mode)
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreTradeRocketProtection.InstallHooks(reason)
	if capture_methods() ~= true or
		type(rawget(_G, "IsKindOf")) ~= "function" or
		type(rawget(_G, "UniversalTradeRocket")) ~= "table"
	then
		log("ERROR",
			"Required v1.0.7 RC Transport or Universal Trade Rocket API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	local transport = rawget(_G, "RCTransport")
	transport.CanInteractWithObject = Hooks.wrapper_can_interact
	transport.InteractWithObject = Hooks.wrapper_interact
	Hooks.enabled = true
	RestoreTradeRocketProtection.enabled = true
	log("INFO",
		"Installed Universal Trade Rocket RC Transport guards", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreTradeRocketProtection.RestoreHooks(reason)
	Hooks.enabled = false
	RestoreTradeRocketProtection.enabled = false
	local transport = rawget(_G, "RCTransport")
	if type(transport) == "table" then
		if transport.CanInteractWithObject == Hooks.wrapper_can_interact then
			transport.CanInteractWithObject = Hooks.original_can_interact
		end
		if transport.InteractWithObject == Hooks.wrapper_interact then
			transport.InteractWithObject = Hooks.original_interact
		end
	end
	Hooks.reported_targets = weak_keys()
	log("INFO",
		"Restored captured RC Transport interaction methods", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreTradeRocketProtection.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then return RestoreTradeRocketProtection.InstallHooks(reason) end
	return RestoreTradeRocketProtection.RestoreHooks(reason)
end

-- Called when a game starts or ends (see FIX.events at the bottom). Clears
-- per-game bookkeeping such as the once-per-game log latch. Nothing here is ever
-- written into a savegame.
function RestoreTradeRocketProtection.ResetTransientState()
	Hooks.reported_targets = weak_keys()
	return true
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreTradeRocketProtection.Quiesce(reason)
	return RestoreTradeRocketProtection.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreTradeRocketProtection.SetEnabled
FIX.quiesce = RestoreTradeRocketProtection.Quiesce
FIX.events = {
	GameStateStarting =
		RestoreTradeRocketProtection.ResetTransientState,
	DoneGame = RestoreTradeRocketProtection.ResetTransientState,
}

-- Self-registration. This fix never calls into SMRCommunityFixes.lua: it only appends its
-- descriptor to a plain global list. SMRCommunityFixes.lua loads last, adopts the list,
-- and from then on drives this fix through set_enabled/quiesce.
local pending = rawget(_G, "SMRCommunityFixesPending")
if type(pending) ~= "table" then
	pending = {}
	rawset(_G, "SMRCommunityFixesPending", pending)
end
pending[#pending + 1] = FIX

return RestoreTradeRocketProtection
