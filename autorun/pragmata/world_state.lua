-- World-state context emitters.
--
-- Polls Phase 2 bindings each frame and emits narrative context updates on
-- transitions:
--   - Scene/area change   -> "Hugh and Diana entered a new area."
--   - Checkpoint change   -> "Checkpoint reached."
--   - Combat start/end    -> "Combat started." / "Combat ended."
--
-- All public API surfaces are opaque (UInt32 hashes / booleans), so no scene
-- or checkpoint names ever flow through here. Save/load (`checkpoint.is_saving`)
-- is intentionally NOT emitted — it conflates save and load events with no
-- clean way to disambiguate, and the narrative value is low.

local M = {}
local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.warn("world_state: failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local scene      = safe_require("pragmata.bindings.scene")
local checkpoint = safe_require("pragmata.bindings.checkpoint")
local combat     = safe_require("pragmata.bindings.combat")

local scene_track       = emit.edge()
local checkpoint_track  = emit.edge()
local combat_track      = emit.edge()

local function safe_call(fn)
    if fn == nil then return nil end
    local ok, result = pcall(fn)
    if not ok then return nil end
    return result
end

local POLL_INTERVAL = 12  -- ~5 Hz at 60 fps; world-state changes are slow
local _frame = 0

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end

    if scene ~= nil then
        local id = safe_call(scene.get_current_id)
        scene_track(id, function(now)
            if now ~= nil then
                emit.narrative("Hugh and Diana entered a new area.")
            end
        end)
    end

    if checkpoint ~= nil then
        local id = safe_call(checkpoint.get_last_id)
        checkpoint_track(id, function(now)
            if now ~= nil then
                emit.narrative("Checkpoint reached.")
            end
        end)
    end

    if combat ~= nil then
        local in_combat = safe_call(combat.is_in_combat)
        combat_track(in_combat, function(now)
            if now then
                emit.narrative("Combat started.")
            else
                emit.narrative("Combat ended.")
            end
        end)
    end
end)

return M
