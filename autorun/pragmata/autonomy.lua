-- Autonomy nudges.
--
-- When `mod_config.autonomy_nudges` is true and combat is active, emits a
-- transient hint to the AI listing currently-available abilities. The
-- transient lane means each new hint replaces the prior one, so this never
-- accumulates in conversation context.
--
-- When the toggle is false, this module is a no-op.
--
-- Throttled to once per `autonomy_nudge_interval_frames` to avoid spam.

local M = {}
local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local config = require("pragmata.mod_config")

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.warn("autonomy: failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local combat    = safe_require("pragmata.bindings.combat")
local overdrive = safe_require("pragmata.bindings.overdrive")
local hacking   = safe_require("pragmata.bindings.hacking")

local function safe_call(fn)
    if fn == nil then return false end
    local ok, result = pcall(fn)
    if not ok then return false end
    return result
end

local _frame = 0
local _last_nudge_frame = -math.huge
local POLL_INTERVAL = 30  -- ~2 Hz at 60 fps; nudge cadence is the real throttle

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end
    if not config.autonomy_nudges then return end
    if combat == nil then return end

    if not safe_call(combat.is_in_combat) then return end

    local interval = config.autonomy_nudge_interval_frames or 1800
    if _frame - _last_nudge_frame < interval then return end

    local hints = {}
    if overdrive ~= nil and safe_call(overdrive.is_ready) then
        table.insert(hints, "Overdrive Protocol is ready")
    end
    if hacking ~= nil and safe_call(hacking.is_auto_hack_unlocked) then
        table.insert(hints, "Auto-Hack is available")
    end

    if #hints == 0 then return end

    _last_nudge_frame = _frame
    emit.transient(
        "Combat is active. Available now: " ..
        table.concat(hints, "; ") ..
        ". Consider using these abilities if it would help Hugh."
    )
end)

return M
