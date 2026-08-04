-- Restore Asteroid Lander Cargo Safety - one self-contained SMR Community Fixes module.
-- It uses engine globals only and never calls another file in this mod.
-- SMRCommunityFixes.lua adopts the FIX descriptor appended at the bottom.
--
-- The bug (v1.0.7): editing an asteroid Lander's payload triggers
--   ForceInterruptIncomingDrones(), which can cut off a Drone or passenger that is
--   still moving along the cargo ramp. Vanilla's own safe disconnect path waits
--   for the ramp to clear first; the payload path does not.
-- Vanilla code:     CanRequestPayload() and the cargo ramp lists in
--   Lua/Buildings/CargoTransporter.lua and the Lander rocket code
-- The repair:       make the payload action unavailable while drones_exiting,
--   drones_entering or boarding still has anyone in it - the same lists vanilla
--   waits on. The action returns the moment the ramp is clear.
-- Left alone:       nothing is moved, deleted or respawned. This fix only makes a
--   button unavailable for a few seconds; it never repairs a unit afterwards.

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
	id = "restore_asteroid_lander_cargo_safety",
	number = 11,
	beta = true,
	versions = { ["1.0.7"] = true },
	default_enabled = false,
	debug = false,
	label = "Restore Asteroid Lander Cargo Safety",
	description = "Prevents v1.0.7 asteroid Lander payload changes from interrupting Drones or passengers while they are still using the cargo ramp.",
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

local RestoreAsteroidLanderCargoSafety = rawget(_G,
	"SMRCFRestoreAsteroidLanderCargoSafety")
if RestoreAsteroidLanderCargoSafety == nil then
	RestoreAsteroidLanderCargoSafety = { enabled = false }
	rawset(_G, "SMRCFRestoreAsteroidLanderCargoSafety",
		RestoreAsteroidLanderCargoSafety)
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
	shared.SMRCF_AsteroidLanderCargoSafetyHooks or nil
local Hooks
if type(previous_hooks) == "table" and previous_hooks.protocol == 1 then
	Hooks = previous_hooks
	Hooks.reported_landers = Hooks.reported_landers or weak_keys()
else
	Hooks = {
		protocol = 1,
		enabled = false,
		original_can_request_payload = false,
		base_can_request_payload = false,
		wrapper_can_request_payload = false,
		in_can_request_payload = false,
		reported_landers = weak_keys(),
	}
end
if type(shared) == "table" then
	shared.SMRCF_AsteroidLanderCargoSafetyHooks = Hooks
end

-- Remembers the vanilla function or method exactly as it is right now, before this
-- fix touches anything. Everything else in this file calls the captured value, so
-- the repair can always be undone by putting it back.
local function capture_method()
	local lander = rawget(_G, "LanderRocketBase")
	if type(lander) ~= "table" then return false end
	local method = lander.CanRequestPayload
	if method ~= Hooks.wrapper_can_request_payload and
		type(method) == "function"
	then
		Hooks.original_can_request_payload = method
		Hooks.base_can_request_payload =
			Hooks.base_can_request_payload or method
	end
	return type(Hooks.original_can_request_payload) == "function"
end

capture_method()

-- Is anyone still on the cargo ramp? These are the game's own three tracking lists:
-- drones walking out, drones walking in, and colonists boarding. Vanilla's safe
-- disconnect path waits on exactly these, which is why this fix reuses them instead
-- of inventing its own idea of "busy".
local function ramp_in_use(lander)
	local drones_exiting = type(lander.drones_exiting) == "table" and
		#lander.drones_exiting > 0
	local drones_entering = type(lander.drones_entering) == "table" and
		#lander.drones_entering > 0
	local boarding = type(lander.boarding) == "table" and
		#lander.boarding > 0
	return drones_exiting or drones_entering or boarding
end

-- Length of a list that may not exist yet. Used only to put useful numbers in the
-- log line; never to make a decision.
local function list_count(value)
	return type(value) == "table" and #value or 0
end

-- Reports a correction at most once per situation. Without this throttle the same
-- line would be written every frame the guarded condition holds.
local function report_guard(lander)
	if Hooks.reported_landers[lander] == true then return end
	Hooks.reported_landers[lander] = true
	log("INFO",
		"Bug fix invoked: deferred asteroid Lander payload editing until all ramp units exit",
		correction_context({
			repair = "asteroid_lander_payload_ramp_guard",
			reason = "cargo_ramp_in_use",
			lander_handle = lander and lander.handle,
			lander_class = lander and lander.class,
			drones_exiting = lander and
				list_count(lander.drones_exiting) or 0,
			drones_entering = lander and
				list_count(lander.drones_entering) or 0,
			passengers_boarding = lander and
				list_count(lander.boarding) or 0,
		}))
end

-- Calls the vanilla CanRequestPayload for this lander. The in_can_request_payload
-- flag keeps a re-entrant call - vanilla, or another mod, asking the same question
-- from inside this one - out of the repair. pcall is only here to make sure the flag
-- comes back down; the error is re-raised unchanged.
local function call_original(lander, ...)
	if Hooks.in_can_request_payload == true then
		return Hooks.base_can_request_payload(lander, ...)
	end
	Hooks.in_can_request_payload = true
	local result = {
		pcall(Hooks.original_can_request_payload, lander, ...)
	}
	Hooks.in_can_request_payload = false
	if result[1] ~= true then error(result[2]) end
	return table.unpack(result, 2)
end

-- The wrapper, and the whole repair lives here: vanilla decides first, and its "no"
-- is always respected. A "yes" is downgraded to false only while the ramp is still
-- in use, which makes the payload button unavailable for those few seconds instead
-- of interrupting a unit mid-walk.
--
-- The last check clears the report latch once the ramp empties, so a later ramp
-- cycle on the same lander is reported again rather than staying silent forever.
if type(Hooks.wrapper_can_request_payload) ~= "function" then
	Hooks.wrapper_can_request_payload = function(lander, ...)
		local allowed = call_original(lander, ...)
		if Hooks.enabled == true and allowed and ramp_in_use(lander) then
			report_guard(lander)
			return false
		end
		if Hooks.reported_landers[lander] and not ramp_in_use(lander) then
			Hooks.reported_landers[lander] = nil
		end
		return allowed
	end
end

-- Turn the fix on. If something replaced the vanilla function since this file
-- loaded, that version is captured as the new original, so another mod's work
-- stays in the chain. If a function this fix needs is missing entirely it refuses
-- and logs one ERROR - that is how a future game patch shows up as a clear message
-- instead of a crash.
function RestoreAsteroidLanderCargoSafety.InstallHooks(reason)
	local lander = rawget(_G, "LanderRocketBase")
	if capture_method() ~= true or type(lander) ~= "table" then
		log("ERROR",
			"Required v1.0.7 asteroid Lander payload API is unavailable; fix not installed", {
				reason = reason,
			})
		return false
	end
	lander.CanRequestPayload = Hooks.wrapper_can_request_payload
	Hooks.enabled = true
	RestoreAsteroidLanderCargoSafety.enabled = true
	log("INFO",
		"Installed asteroid Lander cargo-ramp guard", {
			reason = reason,
		})
	return true
end

-- Turn the fix off and hand vanilla back exactly as it was. Note the ownership
-- check: the global is only unwrapped while this fix is still the outermost
-- wrapper. If another mod wrapped ours afterwards, replacing the global would
-- destroy that mod's hook, so instead the wrapper stays installed and passes
-- everything straight through.
function RestoreAsteroidLanderCargoSafety.RestoreHooks(reason)
	Hooks.enabled = false
	RestoreAsteroidLanderCargoSafety.enabled = false
	local lander = rawget(_G, "LanderRocketBase")
	if type(lander) == "table" and
		lander.CanRequestPayload == Hooks.wrapper_can_request_payload
	then
		lander.CanRequestPayload = Hooks.original_can_request_payload
	end
	Hooks.reported_landers = weak_keys()
	log("INFO",
		"Restored captured asteroid Lander payload method", {
			reason = reason,
		})
	return true
end

-- The one entry point the framework uses. It obeys unconditionally: whether the
-- fix *should* run - the player's checkbox, the game-version gate, the master
-- switch - was already decided by SMRCommunityFixes.lua. Calling it twice with the same
-- value is safe.
function RestoreAsteroidLanderCargoSafety.SetEnabled(enabled, reason)
	enabled = enabled == true
	if enabled then
		return RestoreAsteroidLanderCargoSafety.InstallHooks(reason)
	end
	return RestoreAsteroidLanderCargoSafety.RestoreHooks(reason)
end

-- Called when a game starts or ends (see FIX.events at the bottom). Clears
-- per-game bookkeeping such as the once-per-game log latch. Nothing here is ever
-- written into a savegame.
function RestoreAsteroidLanderCargoSafety.ResetTransientState()
	Hooks.reported_landers = weak_keys()
	return true
end

-- Called by the framework just before a Lua reload replaces this descriptor, and
-- if this file is deleted from the mod. Standing down here is what guarantees a
-- removed or reloaded fix never leaves a live hook behind.
function RestoreAsteroidLanderCargoSafety.Quiesce(reason)
	return RestoreAsteroidLanderCargoSafety.SetEnabled(false,
		reason or "registry_reset")
end

-- Wire the descriptor to this file's own functions. The framework calls
-- set_enabled when the player applies a change, quiesce before a reload replaces
-- this descriptor, and an events entry when the matching game message fires.
FIX.set_enabled = RestoreAsteroidLanderCargoSafety.SetEnabled
FIX.quiesce = RestoreAsteroidLanderCargoSafety.Quiesce
FIX.events = {
	GameStateStarting =
		RestoreAsteroidLanderCargoSafety.ResetTransientState,
	DoneGame =
		RestoreAsteroidLanderCargoSafety.ResetTransientState,
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

return RestoreAsteroidLanderCargoSafety
