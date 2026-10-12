-- World-state context emitters.
--
-- Polls bindings each frame and emits narrative context updates on
-- transitions:
--   - Scene/area change   -> "Hugh and Diana entered a new area." (skipped
--                            while game_state_observer's named area summary
--                            is on and working)
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

-- Combat must read the same for this many polls (~2 s) before it counts as a
-- change. A flag that flickers at an encounter's edges would otherwise send
-- "Combat started." / "Combat ended." pairs the peer can only be confused by.
local COMBAT_STABLE_POLLS = 10
local _combat_seen = nil        -- last raw reading
local _combat_polls = 0         -- polls it has read that way

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end

    if scene ~= nil then
        local id = safe_call(scene.get_current_id)
        scene_track(id, function(now)
            -- When the game-state observer is announcing area changes (with
            -- the area's name and what is left there), this bare line would
            -- only duplicate it -- and a chunk change fires far more often
            -- than a map-area change does.
            local observer = package.loaded["pragmata.game_state_observer"]
            if observer and observer.covers_area_changes and observer.covers_area_changes() then
                return
            end
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
        local raw = safe_call(combat.is_in_combat)
        if raw == _combat_seen then
            _combat_polls = _combat_polls + 1
        else
            _combat_seen, _combat_polls = raw, 1
        end
        -- Unread (nil) or not yet stable: report nothing and keep the last.
        local in_combat = nil
        if raw ~= nil and _combat_polls >= COMBAT_STABLE_POLLS then in_combat = raw end
        if in_combat ~= nil then combat_track(in_combat, function(now)
            if now then
                emit.narrative("Combat started.")
            else
                emit.narrative("Combat ended.")
            end
        end) end
    end
end)

return M
