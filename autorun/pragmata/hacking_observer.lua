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

-- Idempotency: signature of the state text we last forced. If on_start
-- fires again for the same puzzle with the same grid layout (e.g. the
-- engine retriggers the edge after a brief flicker), we skip the duplicate
-- send instead of asking the peer to re-plan against an unchanged grid.
-- Reset whenever the puzzle ends so re-aiming the same enemy re-fires.
local _last_forced_state_hash = nil

-- Deferred-force state. _StartTrg can fire before _GridAccessor is populated;
-- in that case get_state() returns nil and we can't render the grid yet. We
-- mark "pending" and the per-frame poll retries until the grid becomes
-- readable OR the puzzle ends. ~2 seconds at 60fps is plenty for grid setup
-- to complete; if it doesn't, something is wrong and we log a warning.
local _pending_force_frames = 0
local MAX_PENDING_FORCE_FRAMES = 120

-- On-screen overlay result flash. on_success / on_failed set a short-lived
-- flash so the player sees a clear "HACK COMPLETE" / "HACK FAILED" banner
-- after Vera finishes, even though the puzzle goes inactive immediately. The
-- frame poll counts it down; M.overlay_status() reports it to the overlay.
local _flash_kind = nil           -- "success" | "failed" | nil
local _flash_frames = 0
local FLASH_DURATION_FRAMES = 150 -- ~2.5s at 60fps

-- Overlay staleness safety net. is_active() can stay true after the player
-- drops aim (the engine's _GuiHandle lingers), so the banner can't rely on it
-- alone to clear. We hide the banner if the meaningful status hasn't changed
-- for a while: a hack that's genuinely live keeps changing (moves dispatch
-- ~7Hz; a plan reply flips planning->executing), so a frozen status means the
-- hack effectively stopped (aim dropped / plan never answered).
local _ov_last_sig = nil
local _ov_stale_frames = 0
local OV_STALE_EXECUTING = 150    -- ~2.5s after the last move/no change
local OV_STALE_PLANNING  = 360    -- ~6s waiting on a plan that never comes


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

-- HackingManager.LastHackingTarget handle from the previous poll. Used to
-- detect when the player switches aim between enemies without `_StartTrg`
-- firing again on the new instance (engine may only fire it on ctor /
-- first-ever start). When this changes from non-nil → non-nil, we treat
-- it as a fresh hack start for the new enemy.
local _last_observed_target = nil


-- ---------------------------------------------------------------------------
-- Auto-force on grid start
-- ---------------------------------------------------------------------------
-- Per Neuro-SDK protocol, sending an actions/force prompts the AI peer to
-- pick exactly one of the listed actions. The state field carries the grid
-- render — the AI reads it to plan a route.

local function _state_hash(text)
    if text == nil then return "" end
    -- Cheap signature: length + first 200 chars. Enough to differentiate
    -- distinct grids without paying for a full hash.
    return tostring(#text) .. ":" .. text:sub(1, 200)
end


local function send_force(state_text)
    if not config.hacking_auto_force then return end

    -- Skip duplicate forces for an unchanged grid. The observer should
    -- emit at most one force per puzzle start, but defensive against the
    -- engine retriggering _StartTrg or our edge tracker double-firing.
    local h = _state_hash(state_text)
    if h == _last_forced_state_hash then
        log.info("hacking_observer: suppressing duplicate force (state unchanged)")
        return
    end
    _last_forced_state_hash = h

    _force_in_flight = true
    _stale_plan_expected = false
    mailbox.send({
        command = "actions/force",
        game = GAME,
        data = {
            state = state_text or "Hacking grid is active.",
            query = "Hacking grid is live. Plan moves from cursor (@) to Goal "
                 .. "(G) via pragmata_hack_plan. IMPORTANT: route through as MANY "
                 .. "bonus nodes as possible on the way -- BLUE 'O' nodes are worth "
                 .. "the most (more damage + longer-lasting hack), then YELLOW '*' "
                 .. "skill nodes (see the 'Bonus nodes' list in the state). A longer, "
                 .. "winding route that collects more bonuses is better than the "
                 .. "shortest path, as long as you still reach G and never step on an "
                 .. "X trap or revisit a ~ trail cell.",
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


-- Try to render the active puzzle's grid and emit context + force. Returns
-- true if the force was sent (or the grid rendered with a placeholder
-- fallback for a render error). Returns false if state is not yet readable
-- — caller is expected to retry on a later frame.
local function _try_emit_force_from_state()
    local state = snake.get_state()
    if state == nil then return false end

    local ok, rendered = pcall(render.render, state, {
        with_legend = config.hacking_render_legend,
    })
    if not ok then
        log.error("hacking_observer: render.render() threw: " .. tostring(rendered))
        send_force("Hacking grid is active. (rendering failed: "
                .. tostring(rendered):sub(1, 200) .. ")")
        return true
    end

    log.info("hacking_observer: rendered "
          .. tostring(state.width) .. "x" .. tostring(state.height) .. " grid")

    -- The grid travels to Vera as the force `state` (the decision prompt she
    -- plans against). We deliberately do NOT also emit it on the transient
    -- context lane: a full grid is a unique blob that won't dedup, so transient
    -- copies piled up alongside the live one in Vera's "recent game state" and
    -- polluted her planning prompt with stale grids. The short
    -- emit.narrative("Hacking grid started.") breadcrumb (in on_start) is
    -- enough for lane-aware peers/logs.
    send_force(rendered)
    return true
end


local function on_start()
    log.info("hacking_observer: _StartTrg fired")
    emit.narrative("Hacking grid started.")

    -- Reset the overlay staleness so a fresh hack always shows its banner,
    -- even if a previous hack was hidden by the staleness safety net with an
    -- identical status signature.
    _ov_last_sig = nil
    _ov_stale_frames = 0

    -- Defer ALL readiness checks (is_active, is_interactive, get_state)
    -- to the per-frame retry loop. On first aim of a fresh enemy, the
    -- engine can fire _StartTrg one or two frames before _GuiHandle is
    -- set, before _State flips to Play, and before _ActualGrid is
    -- populated — so deciding now would silently bail. The retry loop
    -- handles cancellation (puzzle never becomes active) and cooldown
    -- (active but not interactive) cleanly.
    _pending_force_frames = MAX_PENDING_FORCE_FRAMES
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


-- Common puzzle-teardown bookkeeping: drop any queued moves so they don't
-- execute against a different enemy's puzzle, clear the pending-force
-- retry, and reset the duplicate-suppression hash so a re-hack of the
-- same enemy re-fires the force cleanly. Force-in-flight tracking is
-- handled per-caller because cancellation is semantically distinct.
local function _reset_puzzle_local_state()
    snake.clear_plan()
    _pending_force_frames = 0
    _last_forced_state_hash = nil
end


local function on_success()
    log.info("hacking_observer: hack succeeded")
    _force_in_flight = false
    _stale_plan_expected = false
    _reset_puzzle_local_state()
    _flash_kind = "success"
    _flash_frames = FLASH_DURATION_FRAMES
    emit.narrative("Hack succeeded.")
end


local function on_failed()
    log.info("hacking_observer: hack failed")
    _force_in_flight = false
    _stale_plan_expected = false
    _reset_puzzle_local_state()
    _flash_kind = "failed"
    _flash_frames = FLASH_DURATION_FRAMES
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
    _reset_puzzle_local_state()
end


-- ---------------------------------------------------------------------------
-- Frame poll
-- ---------------------------------------------------------------------------

re.on_frame(function()
    _frame = _frame + 1

    -- Count down the overlay result flash every frame, independent of the
    -- poll interval below.
    if _flash_frames > 0 then _flash_frames = _flash_frames - 1 end

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
    -- success/failed trigger this same frame. With the HackingManager-
    -- discriminated get_instance(), is_active() now reflects "the player
    -- is aimed at an enemy whose puzzle hasn't ended" — dropping aim
    -- flips it false, which is what we want.
    active_track(snake.is_active(), function(now)
        if now == false
           and not snake.read_trigger("_SuccessTrigger")
           and not snake.read_trigger("_FailedTrigger") then
            _hit_counts.cancelled = _hit_counts.cancelled + 1
            on_cancelled()
        end
    end)

    -- Target switch: HackingManager.LastHackingTarget changed from one
    -- enemy to another without an intervening "no target" frame. The new
    -- puzzle's _StartTrg may not re-fire (the engine only sets it on ctor
    -- / first start), so trigger a fresh on_start ourselves. The
    -- send_force idempotency guard suppresses the duplicate if start_track
    -- also fires this same frame.
    local current_target = snake.get_active_target_handle()
    if current_target ~= _last_observed_target then
        if current_target ~= nil and _last_observed_target ~= nil then
            log.info("hacking_observer: target switched mid-aim; firing on_start for new puzzle")
            -- Old enemy's queue and pending state are stale now.
            snake.clear_plan()
            _pending_force_frames = 0
            _force_in_flight = false
            _stale_plan_expected = false
            on_start()
        end
        _last_observed_target = current_target
    end

    -- Deferred force: on first-aim of an enemy, _StartTrg fires before
    -- the puzzle is fully spun up. Each frame: check active → interactive
    -- → grid-readable, and either fire or wait. Three exit paths:
    --   1. Puzzle interactive AND grid renders → fire force, done.
    --   2. Active but not interactive (cooldown) → abort cleanly, no
    --      fallback (would just churn a no-op generation).
    --   3. Timeout without ever becoming active → log + fallback so the
    --      peer isn't left waiting silently.
    if _pending_force_frames > 0 then
        if snake.is_active() then
            if not snake.is_interactive() then
                log.info("hacking_observer: pending force dropped (puzzle active but not interactive — cooldown?)")
                _pending_force_frames = 0
            elseif _try_emit_force_from_state() then
                log.info("hacking_observer: pending force sent after retry")
                _pending_force_frames = 0
            else
                _pending_force_frames = _pending_force_frames - 1
                if _pending_force_frames == 0 then
                    log.warn("hacking_observer: pending force timed out (grid never became readable)")
                    send_force("Hacking grid is active. (state details unavailable after retry)")
                end
            end
        else
            -- Not yet active (waiting for _GuiHandle / HackingManager
            -- target update). Keep waiting; on_cancelled will clear if
            -- the player drops aim before the puzzle materializes.
            _pending_force_frames = _pending_force_frames - 1
            if _pending_force_frames == 0 then
                log.warn("hacking_observer: pending force timed out (puzzle never became active)")
            end
        end
    end
end)


function M.debug_hit_counts()
    return _hit_counts
end


-- Status for the on-screen overlay (hacking_overlay.lua). Returns:
--   { phase = "idle"|"planning"|"executing"|"success"|"failed",
--     executed = <number>, total = <number> }   -- counts only when executing
-- "planning"  : a force is out to Vera; we're waiting for her plan reply.
-- "executing" : Vera's plan is queued / being dispatched cell-by-cell (or the
--               last move is animating to the goal).
-- "success"/"failed": short-lived flash after the hack resolves.
function M.overlay_status()
    -- Result flash takes priority and persists briefly even after the puzzle
    -- goes inactive, so COMPLETE / FAILED stays visible for a beat.
    if _flash_frames > 0 and _flash_kind ~= nil then
        _ov_stale_frames = 0
        _ov_last_sig = nil
        return { phase = _flash_kind }
    end

    -- Work out the candidate phase. We gate on is_interactive() (not just
    -- is_active()): it additionally checks the puzzle's _State, which drops out
    -- of the Play state when the player cancels — catching cancels that
    -- is_active() misses because the engine's _GuiHandle lingers.
    local phase, executed, total = nil, 0, 0
    if snake.is_interactive() then
        local ps = snake.plan_status()
        if ps.queue_size and ps.queue_size > 0 then
            phase, executed, total = "executing", ps.executed or 0, ps.total or 0
        elseif ps.total and ps.total > 0 then
            -- Plan dispatched, puzzle still live (last move animating, or Vera
            -- under-planned and the cursor is parked).
            phase, executed, total = "executing", ps.total, ps.total
        elseif _force_in_flight or _pending_force_frames > 0 then
            -- Force out, no moves yet => waiting on the plan. Gating on the
            -- force flag means a manual (non-AI) hack shows no banner.
            phase = "planning"
        end
    end

    if phase == nil then
        _ov_stale_frames = 0
        _ov_last_sig = nil
        return { phase = "idle" }
    end

    -- Staleness safety net: if the meaningful status is frozen for too long,
    -- the hack has effectively stopped (aim dropped while _GuiHandle/_State
    -- linger, or a plan request that was never answered). Hide the banner.
    local sig = phase .. ":" .. tostring(executed) .. "/" .. tostring(total)
    if sig == _ov_last_sig then
        _ov_stale_frames = _ov_stale_frames + 1
    else
        _ov_stale_frames = 0
        _ov_last_sig = sig
    end
    local limit = (phase == "planning") and OV_STALE_PLANNING or OV_STALE_EXECUTING
    if _ov_stale_frames > limit then
        return { phase = "idle" }
    end

    return { phase = phase, executed = executed, total = total }
end


return M
