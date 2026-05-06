-- Hacking-grid (PuzzleSnake) lifecycle observer.
--
-- Polls the puzzle_snake binding's edge-trigger fields each frame and emits:
--   _StartTrg true        -> render grid, send context + actions/force
--   _GridChangeEndTrg true -> re-render, re-emit context
--   _ResetTrg / _GridResetRequest -> emit narrative reset event
--   _SuccessTrigger true  -> emit narrative success
--   _FailedTrigger true   -> emit narrative failure
--
-- The actions/force step is what kicks the AI peer's planning loop without
-- requiring an explicit prompt — when a hack grid appears in-game, the
-- AI receives the rendered grid and is asked to return a plan immediately.

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local mailbox = require("pragmata.bridge_mailbox")
local snake = require("pragmata.bindings.puzzle_snake")
local render = require("pragmata.util.snake_render")
local config = require("pragmata.mod_config")

local GAME = "Pragmata"

-- Tunable: poll interval. The `_StartTrg` edge can be cleared by the engine
-- within a handful of frames on some encounters, so polling every frame is
-- the safe default. Per-poll cost is just five `inst:get_field` reads,
-- well under 1ms.
local POLL_INTERVAL = 1
local _frame = 0

-- Cumulative edge hit-counters for the debug panel. Incremented each time
-- a trigger transition fires its handler.
local _hit_counts = {
    start_trg          = 0,
    grid_change_end    = 0,
    reset              = 0,
    success            = 0,
    failed             = 0,
    cancelled          = 0,
}

-- In-flight force tracking. Set when we emit a force; cleared when the
-- corresponding action_result comes back OR when the puzzle ends (success /
-- failure / GUI drop). When a force is "in flight" but the puzzle has
-- already ended, any plan that arrives is stale and the dispatcher will
-- reject it with a no-op.
local _force_in_flight = false
local _stale_plan_expected = false  -- set when puzzle ends mid-force


-- ---------------------------------------------------------------------------
-- Edge trackers
-- ---------------------------------------------------------------------------
-- Each tracker remembers the last observed value of one boolean trigger and
-- only fires its handler on transitions. Skips the first observation so we
-- don't emit a spurious "started" on game launch.

local start_track    = emit.edge()
local gridchange_track = emit.edge()
local reset_track    = emit.edge()
local success_track  = emit.edge()
local failed_track   = emit.edge()
local active_track   = emit.edge()  -- tracks GUI-handle / is_active(); fires cancellation when drops mid-force


-- ---------------------------------------------------------------------------
-- Auto-force on grid start
-- ---------------------------------------------------------------------------
-- Per Neuro-SDK protocol, sending an actions/force prompts the AI peer to
-- pick exactly one of the listed actions. The state field carries the grid
-- render — the AI reads it to plan a route.

local function send_force(state_text)
    if not config.hacking_auto_force then return end
    _force_in_flight = true
    _stale_plan_expected = false
    mailbox.send({
        command = "actions/force",
        game = GAME,
        data = {
            state = state_text or "Hacking grid is active.",
            query = "Hacking grid is live. Plan moves from cursor (@) to "
                 .. "Goal (G) via pragmata_hack_plan. Read the state above "
                 .. "for grid layout, cursor position, and adjacency hints.",
            ephemeral_context = true,
            action_names = { "pragmata_hack_plan" },
        },
    })
end


-- Called by the action handler when a pragmata_hack_plan result is in.
-- Lets us clear the in-flight flag and check whether the plan was stale.
function M.on_plan_received()
    _force_in_flight = false
    local was_stale = _stale_plan_expected
    _stale_plan_expected = false
    return was_stale
end


local function on_start()
    local state = snake.get_state()
    if state == nil then
        log.warn("hacking_observer: _StartTrg fired but get_state() returned nil; "
              .. "emitting narrative-only event")
        emit.narrative("Hacking grid started.")
        send_force("Hacking grid is active. (state details unavailable)")
        return
    end

    -- Wrap rendering in pcall so a render bug doesn't silently abort the
    -- send_force step — we'd much rather the AI see a placeholder grid
    -- and log a loud warning than leave it with no force at all.
    local ok, rendered = pcall(render.render, state, {
        with_legend = config.hacking_render_legend,
    })
    if not ok then
        log.error("hacking_observer: render.render() threw: " .. tostring(rendered))
        emit.narrative("Hacking grid started.")
        send_force("Hacking grid is active. (rendering failed: "
                .. tostring(rendered):sub(1, 200) .. ")")
        return
    end

    log.info("hacking_observer: hack started, "
          .. tostring(state.width) .. "x" .. tostring(state.height) .. " grid")

    -- Send the rendered grid as a transient context message AND inline it
    -- in the force state. State-field-only is sufficient for the AI to
    -- plan against (and avoids context flooding), but the transient context
    -- lane gives lane-aware peers a snapshot to display in dashboards/logs.
    emit.transient("Hacking grid started:\n" .. rendered)
    send_force(rendered)
end


local function on_grid_change()
    local state = snake.get_state()
    if state == nil then return end
    local ok, rendered = pcall(render.render, state, {
        with_legend = config.hacking_render_legend,
    })
    if not ok then
        log.error("hacking_observer: render on grid-change threw: " .. tostring(rendered))
        return
    end
    log.info("hacking_observer: grid mutated mid-hack")
    emit.transient("Hacking grid changed:\n" .. rendered)
    -- We do NOT currently auto-re-force on grid change. A future revision
    -- could, once the plan-execution scheduler can abort and replan cleanly.
end


local function on_reset()
    log.info("hacking_observer: hack reset")
    emit.narrative("Hacking grid was reset.")
end


local function on_success()
    log.info("hacking_observer: hack succeeded")
    emit.narrative("Hack succeeded.")
end


local function on_failed()
    log.info("hacking_observer: hack failed")
    emit.narrative("Hack failed.")
end


-- Player stopped aiming / target moved out of range / engine cancelled the
-- puzzle without a success-or-failure trigger. Mark any in-flight plan as
-- stale so the dispatcher discards it instead of attempting (future) move
-- execution against a no-longer-present puzzle.
local function on_cancelled()
    log.info("hacking_observer: hack cancelled (GUI handle dropped without success/failed)")
    if _force_in_flight then
        _stale_plan_expected = true
        emit.narrative("Hack target lost before the plan could be executed; the next plan reply is stale.")
    else
        emit.narrative("Hack target lost.")
    end
end


-- ---------------------------------------------------------------------------
-- Frame poll
-- ---------------------------------------------------------------------------

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end

    -- Each trigger is a one-frame edge field. We can read them safely each
    -- poll; the edge-tracker only fires the handler on false→true transitions.
    start_track(snake.read_trigger("_StartTrg"), function(now)
        if now then _hit_counts.start_trg = _hit_counts.start_trg + 1; on_start() end
    end)

    gridchange_track(snake.read_trigger("_GridChangeEndTrg"), function(now)
        if now then _hit_counts.grid_change_end = _hit_counts.grid_change_end + 1; on_grid_change() end
    end)

    reset_track(snake.read_trigger("_ResetTrg"), function(now)
        if now then _hit_counts.reset = _hit_counts.reset + 1; on_reset() end
    end)

    success_track(snake.read_trigger("_SuccessTrigger"), function(now)
        if now then _hit_counts.success = _hit_counts.success + 1; on_success() end
    end)

    failed_track(snake.read_trigger("_FailedTrigger"), function(now)
        if now then _hit_counts.failed = _hit_counts.failed + 1; on_failed() end
    end)

    -- Cancellation: is_active() goes from true to false WITHOUT a
    -- success/failed trigger this same frame. Use the snake's own is_active
    -- which is "GUI handle present and no finish trigger". When the player
    -- drops aim, GUI handle vanishes and is_active() flips false.
    active_track(snake.is_active(), function(now)
        if now == false
           and not snake.read_trigger("_SuccessTrigger")
           and not snake.read_trigger("_FailedTrigger") then
            _hit_counts.cancelled = _hit_counts.cancelled + 1
            on_cancelled()
        end
    end)
end)


function M.debug_hit_counts()
    return _hit_counts
end


return M
