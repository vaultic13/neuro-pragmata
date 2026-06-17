-- Hacking-grid (PuzzleSnake) lifecycle observer + AI-peer plan orchestration.
--
-- Watches the matched PuzzleSnake's edge triggers each frame and:
--   _StartTrg / re-aim     -> mark the puzzle for a (re)force
--   _GridChangeEndTrg true -> structural change -> invalidate plan, replan
--   _ResetTrg true         -> clear the puzzle's plan, narrative reset
--   _SuccessTrigger true   -> narrative success, clear the puzzle's plan
--   _FailedTrigger true    -> narrative failure, clear the puzzle's plan
--
-- Forcing: each frame a reconciliation step decides whether the puzzle the
-- player is currently aimed at needs a plan, and if so sends an actions/force
-- (at most ONE outstanding at a time). The reply is parked on the puzzle it
-- was planned for (bindings.puzzle_snake.set_plan) and dispatched only while
-- that puzzle is on screen — so plans never apply to the wrong enemy, and a
-- plan that arrives after the player ran away resumes when they return.
--
-- A plan is valid only while the puzzle's STRUCTURE (dims, goal, walls,
-- traps) is unchanged. A sticky bomb that deletes a row changes the structure
-- and invalidates the plan at whatever stage it's in (in-flight, parked, or
-- mid-execution); we discard it and re-force against the new grid.

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
-- the safe default.
local POLL_INTERVAL = 1
local _frame = 0

-- Cumulative edge hit-counters for the debug panel.
local _hit_counts = {
    start_trg       = 0,
    grid_change_end = 0,
    reset           = 0,
    success         = 0,
    failed          = 0,
    cancelled       = 0,  -- retained for the debug panel; unused under per-puzzle model
}

-- The single in-flight force. _inflight_id is the puzzle id we last forced
-- and are awaiting a plan reply for (nil = slot free). Keeping at most ONE
-- force outstanding (a) makes reply attribution unambiguous — the reply
-- belongs to _inflight_id — (b) respects the peer's one-force-at-a-time
-- model, and (c) means we never create the overlapping-force situation whose
-- handling is undefined. _inflight_since feeds a generous watchdog that
-- releases the slot only if a reply is physically lost (sidecar / socket
-- drop); it's a last resort, never hit in normal play.
local _inflight_id = nil
local _inflight_since = 0
local INFLIGHT_WATCHDOG_FRAMES = 1200   -- ~20s at 60fps

-- A pending explicit (re)start. _StartTrg fires (or aim enters a puzzle)
-- 1-2 frames before the puzzle id is readable, so we set this flag and apply
-- it in reconciliation once the current id resolves: it drops that puzzle's
-- force snapshot so the puzzle re-forces even if its grid is byte-identical
-- (the player's "try again" signal). Without this, a re-aim of an unchanged
-- grid would be suppressed — the original stuck-hack bug.
local _start_pending = false

-- Last puzzle id seen on screen, for target-switch / re-aim detection.
local _last_observed_id = nil

-- On-screen result/transition flash (overlay). Counts down per frame.
-- Tagged with the puzzle id it's ABOUT: transition flashes ("resumed",
-- "retrying") are only shown while the player is aimed at that puzzle, so a
-- target switch doesn't surface another enemy's "PUZZLE CHANGED" banner over
-- the busy state. Result flashes ("success"/"failed") stay global — they
-- describe the hack that just ended, wherever the player aims next.
local _flash_kind = nil   -- "success" | "failed" | "resumed" | "retrying" | nil
local _flash_frames = 0
local _flash_id = nil     -- puzzle the flash is about (nil = global)
local FLASH_DURATION_FRAMES = 150  -- ~2.5s at 60fps

local function _set_flash(kind, id)
    _flash_kind = kind
    _flash_frames = FLASH_DURATION_FRAMES
    _flash_id = id
end

-- Flash + narrate a structural replan, de-duplicated: the bomb can be caught
-- by both the _GridChangeEndTrg edge and tick_plan's per-tick check, so we
-- only emit the narrative once per "retrying" window.
local function _signal_retry(id)
    if _flash_kind == "retrying" and _flash_frames > 0 then
        _set_flash("retrying", id)  -- refresh duration, suppress duplicate narrative
        return
    end
    _set_flash("retrying", id)
    emit.narrative("Hacking grid changed; replanning.")
end


-- ---------------------------------------------------------------------------
-- Edge trackers
-- ---------------------------------------------------------------------------
-- Each tracker remembers the last observed value of one boolean trigger and
-- only fires its handler on false->true transitions. Skips the first
-- observation so we don't emit a spurious "started" on game launch.
--
-- IMPORTANT: read_trigger() reads from whichever puzzle the player is aimed
-- at, so a target switch changes which instance the trackers observe. The
-- trackers are RECREATED on every switch (see the frame poll) — otherwise
-- "A's trigger was false, B's happens to be true" reads as an edge and fires
-- a spurious handler (this was the bogus "PUZZLE CHANGED" banner when aiming
-- at a second enemy mid-plan).
local start_track      = emit.edge()
local gridchange_track = emit.edge()
local reset_track      = emit.edge()
local success_track    = emit.edge()
local failed_track     = emit.edge()

local function _reset_edge_trackers()
    start_track      = emit.edge()
    gridchange_track = emit.edge()
    reset_track      = emit.edge()
    success_track    = emit.edge()
    failed_track     = emit.edge()
end


-- ---------------------------------------------------------------------------
-- Force dispatch
-- ---------------------------------------------------------------------------
-- Per Neuro-SDK protocol, sending an actions/force prompts the AI peer to
-- pick exactly one of the listed actions. The state field carries the grid
-- render — the peer reads it to plan a route.
local function send_force(id)
    if not config.hacking_auto_force then return end

    local state = snake.get_state()
    local rendered
    if state == nil then
        rendered = "Hacking grid is active."
    else
        local ok, r = pcall(render.render, state, {
            with_legend = config.hacking_render_legend,
        })
        if ok then
            rendered = r
            log.info("hacking_observer: rendered "
                  .. tostring(state.width) .. "x" .. tostring(state.height)
                  .. " grid for puzzle " .. tostring(id))
        else
            log.error("hacking_observer: render.render() threw: " .. tostring(r))
            rendered = "Hacking grid is active. (rendering failed: "
                    .. tostring(r):sub(1, 200) .. ")"
        end
    end

    -- Snapshot the structure + cursor we're planning against BEFORE marking
    -- the slot busy, so the reply and continuous validation compare to it.
    snake.snapshot_force_target(id)
    _inflight_id = id
    _inflight_since = 0

    mailbox.send({
        command = "actions/force",
        game = GAME,
        data = {
            state = rendered,
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
    log.info("hacking_observer: forced plan request for puzzle " .. tostring(id))
end


-- Called by the pragmata_hack_plan handler when a plan reply arrives. The
-- reply belongs to the single in-flight force (_inflight_id). Parks the moves
-- on that puzzle's record; they dispatch when the player is/becomes aimed at
-- it (validity is re-checked at dispatch time). Returns (applied, info) where
-- info is the `parked` bool on success or a reason string on discard.
function M.on_plan_received(moves)
    local id = _inflight_id
    _inflight_id = nil
    _inflight_since = 0

    if id == nil then
        log.info("hacking_observer: plan reply with no in-flight force; ignoring")
        return false, "no in-flight force"
    end

    local live = snake.live_puzzle_ids()
    if not live[id] then
        log.info("hacking_observer: plan reply for puzzle " .. tostring(id)
              .. " which no longer exists; discarding")
        return false, "puzzle gone"
    end

    local queued, parked = snake.set_plan(id, moves or {})
    log.info("hacking_observer: applied plan to puzzle " .. tostring(id)
          .. " (" .. tostring(queued) .. " moves, parked=" .. tostring(parked) .. ")")
    return true, parked
end


-- ---------------------------------------------------------------------------
-- Trigger handlers
-- ---------------------------------------------------------------------------
local function on_start()
    log.info("hacking_observer: _StartTrg fired")
    emit.narrative("Hacking grid started.")
    -- The puzzle id can be unreadable for 1-2 frames after the edge; defer
    -- the snapshot clear (the "try again" signal) to reconciliation.
    _start_pending = true
end


local function on_grid_change()
    local id = snake.current_puzzle_id()
    if id == nil then return end
    -- Only replan if the STRUCTURE actually changed (sticky bomb / reset),
    -- not on a benign change edge. tick_plan's per-tick check covers the
    -- mid-execution case; this covers the idle / in-flight case.
    if not snake.struct_changed(id) then return end

    log.info("hacking_observer: grid structure changed (id=" .. tostring(id)
          .. "); invalidating plan and replanning")
    snake.discard_plan(id)
    snake.clear_force_snapshot(id)
    if _inflight_id == id then
        -- A force was out for the now-stale structure; release it so the
        -- reply (planned against the old grid) is dropped as stale and we
        -- re-force against the new one.
        _inflight_id = nil
        _inflight_since = 0
    end
    _signal_retry(id)
end


local function on_reset()
    log.info("hacking_observer: hack reset")
    local id = snake.matched_puzzle_id()
    if id ~= nil then
        snake.discard_plan(id)
        snake.clear_force_snapshot(id)
        if _inflight_id == id then _inflight_id = nil; _inflight_since = 0 end
    end
    emit.narrative("Hacking grid was reset.")
end


local function on_success()
    log.info("hacking_observer: hack succeeded")
    local id = snake.matched_puzzle_id()
    if id ~= nil then
        snake.discard_plan(id)
        snake.clear_force_snapshot(id)
        if _inflight_id == id then _inflight_id = nil; _inflight_since = 0 end
    end
    _set_flash("success")
    emit.narrative("Hack succeeded.")
end


local function on_failed()
    log.info("hacking_observer: hack failed")
    local id = snake.matched_puzzle_id()
    if id ~= nil then
        snake.discard_plan(id)
        snake.clear_force_snapshot(id)
        if _inflight_id == id then _inflight_id = nil; _inflight_since = 0 end
    end
    _set_flash("failed")
    emit.narrative("Hack failed.")
end


-- ---------------------------------------------------------------------------
-- Reconciliation: decide whether to force the current puzzle
-- ---------------------------------------------------------------------------
-- Re-derives "what does the puzzle I'm aimed at need?" from current truth
-- every frame, rather than latching on an edge that can be missed. Forces
-- exactly when the current puzzle is interactive, has no plan, nothing is in
-- flight, and its state differs from the last thing we forced it against.
local function _reconcile(cur_id)
    -- Apply a pending (re)start: drop the entered puzzle's force snapshot so
    -- it re-forces even on an unchanged grid (explicit retry).
    if _start_pending and cur_id ~= nil then
        snake.clear_force_snapshot(cur_id)
        _start_pending = false
    end

    if cur_id == nil then return end
    if not snake.is_interactive() then return end
    if snake.is_jamming() then return end        -- jammer suppresses hacking entirely
    if snake.has_plan(cur_id) then return end    -- a plan is queued / executing
    if _inflight_id == cur_id then return end     -- already waiting on this puzzle's plan
    if _inflight_id ~= nil then return end        -- busy on another puzzle (overlay shows it)
    if snake.needs_force(cur_id) then
        send_force(cur_id)
    end
end


-- ---------------------------------------------------------------------------
-- Frame poll
-- ---------------------------------------------------------------------------
re.on_frame(function()
    _frame = _frame + 1

    if _flash_frames > 0 then _flash_frames = _flash_frames - 1 end

    if (_frame % POLL_INTERVAL) ~= 0 then return end

    -- Target-switch / re-aim handling runs FIRST: the edge trackers below
    -- sample whichever puzzle is currently aimed at, so on a switch they
    -- must be re-seeded before any trigger is read — otherwise the other
    -- enemy's trigger values masquerade as edges (the bogus "PUZZLE CHANGED"
    -- on aim-switch). Entering a puzzle is also an implicit (re)start signal,
    -- in case _StartTrg doesn't re-fire on a mid-aim swap. The PREVIOUS
    -- puzzle's queue is intentionally LEFT parked so it resumes if the
    -- player returns.
    local cur_id = snake.current_puzzle_id()
    if cur_id ~= _last_observed_id then
        _reset_edge_trackers()
        if cur_id ~= nil then _start_pending = true end
        _last_observed_id = cur_id
    end

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

    -- React to dispatcher events: a parked plan resumed, or a plan was
    -- aborted because the grid structure changed under it. tick_plan only
    -- dispatches the currently-aimed puzzle, so these are about cur_id.
    for _, e in ipairs(snake.consume_plan_events()) do
        if e == "resumed" then
            _set_flash("resumed", cur_id)
        elseif e == "grid_changed" then
            _signal_retry(cur_id)
        end
    end

    -- In-flight watchdog: release the slot if the forced puzzle was destroyed
    -- or if a reply never came back within a generous window (lost message).
    if _inflight_id ~= nil then
        _inflight_since = _inflight_since + 1
        local live = snake.live_puzzle_ids()
        if not live[_inflight_id] then
            log.info("hacking_observer: in-flight puzzle " .. tostring(_inflight_id)
                  .. " gone; releasing force slot")
            _inflight_id = nil
            _inflight_since = 0
        elseif _inflight_since > INFLIGHT_WATCHDOG_FRAMES then
            log.warn("hacking_observer: in-flight force watchdog fired (no reply in "
                  .. tostring(INFLIGHT_WATCHDOG_FRAMES) .. " frames); releasing slot")
            _inflight_id = nil
            _inflight_since = 0
        end
    end

    _reconcile(cur_id)
end)


function M.debug_hit_counts()
    return _hit_counts
end


-- Status for the on-screen overlay (hacking_overlay.lua). Returns:
--   { phase = "idle"|"planning"|"busy"|"executing"|"resumed"|"retrying"
--             |"jammed"|"success"|"failed",
--     executed = <number>, total = <number> }   -- counts only when executing
-- "planning"  : a force is out for the current puzzle; waiting on the reply.
-- "busy"      : a force is out for a DIFFERENT puzzle; the current one waits.
-- "executing" : the current puzzle's plan is dispatching cell-by-cell.
-- "resumed"   : a parked plan just began running on return (brief flash).
-- "retrying"  : the grid changed (e.g. sticky bomb); replanning (brief flash).
-- "jammed"    : a jammer is suppressing hacking; planning is paused.
-- "success"/"failed": short-lived flash after the hack resolves.
function M.overlay_status()
    local cur = snake.current_puzzle_id()

    -- Result/transition flash takes priority and persists briefly. Transition
    -- flashes (resumed/retrying) are scoped to the puzzle they're about —
    -- after a target switch the new puzzle's true state (usually "busy")
    -- shows instead of another enemy's banner. Result flashes stay global.
    if _flash_frames > 0 and _flash_kind ~= nil then
        if _flash_id == nil or _flash_id == cur then
            return { phase = _flash_kind }
        end
    end

    if cur == nil or not snake.is_interactive() then
        return { phase = "idle" }
    end

    -- Jammer active: hacking is suppressed entirely; no plan will be forced
    -- until it clears.
    if snake.is_jamming() then
        return { phase = "jammed" }
    end

    -- A force is out for another enemy; the current puzzle can't be planned
    -- until it resolves (one force at a time).
    if _inflight_id ~= nil and _inflight_id ~= cur then
        return { phase = "busy" }
    end

    local ps = snake.current_plan_status()
    if ps.queue_size and ps.queue_size > 0 then
        return { phase = "executing", executed = ps.executed or 0, total = ps.total or 0 }
    end

    if _inflight_id == cur then
        return { phase = "planning" }
    end

    return { phase = "idle" }
end


return M
