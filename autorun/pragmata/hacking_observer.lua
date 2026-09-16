-- Hacking-puzzle lifecycle observer + AI-peer plan orchestration.
--
-- Watches whichever hacking puzzle the player is aimed at -- the enemy grid, or
-- any of the environmental ones on switches, doors and elevators -- and:
--   started -> mark the puzzle for a (re)force
--   changed -> structural change -> invalidate plan, replan
--   reset   -> clear the puzzle's plan, narrative reset
--   success -> narrative success, clear the puzzle's plan
--   failed  -> narrative failure, clear the puzzle's plan
--
-- This file used to talk to bindings/puzzle_snake.lua by name, which is why
-- every non-enemy hack was invisible: they start, run and finish without any of
-- the code below ever looking at them. It now drives whatever
-- bindings/puzzle_registry.lua says is active, through one interface every
-- family implements. The orchestration is unchanged -- it was never
-- grid-specific -- only who it is pointed at.
--
-- Forcing: each frame a reconciliation step decides whether the puzzle the
-- player is currently aimed at needs a plan, and if so sends an actions/force
-- (at most ONE outstanding at a time, across ALL families). The reply is parked
-- on the puzzle it was planned for and dispatched only while that puzzle is on
-- screen -- so plans never apply to the wrong target, and a plan that arrives
-- after the player ran away resumes when they return.
--
-- A plan is valid only while the puzzle's STRUCTURE is unchanged. Whatever
-- changes it -- a sticky bomb deleting a grid row, a circuit board being rebuilt
-- -- invalidates the plan at whatever stage it's in (in-flight, parked, or
-- mid-execution); we discard it and re-force against the new state.

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local mailbox = require("pragmata.bridge_mailbox")
local registry = require("pragmata.bindings.puzzle_registry")
local config = require("pragmata.mod_config")

local GAME = "Pragmata"

-- Tunable: poll interval. The start edge can be cleared by the engine within a
-- handful of frames on some encounters, so polling every frame is the safe
-- default.
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

-- The single in-flight force. _inflight_id is the puzzle id we last forced and
-- are awaiting a plan reply for (nil = slot free), _inflight_kind the family it
-- belongs to. Keeping at most ONE force outstanding (a) makes reply attribution
-- unambiguous, (b) respects the peer's one-force-at-a-time model, and (c) means
-- we never create the overlapping-force situation whose handling is undefined.
-- _inflight_since feeds a generous watchdog that releases the slot only if a
-- reply is physically lost (sidecar / socket drop); it's a last resort.
local _inflight_id = nil
local _inflight_kind = nil
local _inflight_since = 0
local INFLIGHT_WATCHDOG_FRAMES = 1200   -- ~20s at 60fps

-- Has a plan reply EVER come back? A force that expires is normal once; every
-- force expiring is the signature of a sidecar that is not running, and that
-- looked identical to bad luck in the 2026-09-06 capture -- eighteen forces,
-- seven watchdog expiries, and nothing in the log naming the actual problem.
-- Said once, on the first expiry, and never again.
local _ever_replied = false
local _dead_bridge_warned = false

-- A pending explicit (re)start. The start edge fires 1-2 frames before the
-- puzzle id is readable, so we set this flag and apply it in reconciliation once
-- the current id resolves: it drops that puzzle's force snapshot so the puzzle
-- re-forces even if its state is byte-identical (the player's "try again"
-- signal). Without this, a re-aim of an unchanged puzzle would be suppressed.
local _start_pending = false

-- Last puzzle seen on screen, for target-switch / re-aim detection. Ids are
-- unique across families, but the key carries the kind too so a family swap can
-- never be mistaken for "same puzzle".
local _last_observed_key = nil

-- On-screen result/transition flash (overlay). Counts down per frame. Tagged
-- with the puzzle id it's ABOUT: transition flashes ("resumed", "retrying") are
-- only shown while the player is aimed at that puzzle, so a target switch
-- doesn't surface another target's banner. Result flashes ("success"/"failed")
-- stay global -- they describe the hack that just ended, wherever the player
-- aims next.
local _flash_kind = nil   -- "success" | "failed" | "resumed" | "retrying" | nil
local _flash_frames = 0
local _flash_id = nil     -- puzzle the flash is about (nil = global)
local FLASH_DURATION_FRAMES = 150  -- ~2.5s at 60fps

local function _set_flash(kind, id)
    _flash_kind = kind
    _flash_frames = FLASH_DURATION_FRAMES
    _flash_id = id
end


-- ---------------------------------------------------------------------------
-- Who is driving right now
-- ---------------------------------------------------------------------------
-- Returns (binding, active) for the puzzle the player is aimed at, or nil when
-- nothing hackable is in front of them -- or when the active puzzle belongs to a
-- family this build can't drive, which is reported once rather than every frame.
local _warned_kinds = {}
local function _current()
    local binding, active = registry.active_binding()
    if binding == nil then
        if active ~= nil and active.kind == nil and active.type_name ~= nil
           and not _warned_kinds[active.type_name] then
            _warned_kinds[active.type_name] = true
            log.warn("hacking_observer: unrecognised puzzle type " .. tostring(active.type_name)
                  .. "; it will be reported but cannot be played")
        end
        return nil, active
    end
    return binding, active
end

local function _key(kind, id)
    if kind == nil or id == nil then return nil end
    return kind .. "#" .. tostring(id)
end


-- Spoiler-free subject for the context lines. The grid keeps its original
-- wording so nothing about the existing enemy-hack vocabulary changes.
local function _subject(kind, is_gimmick)
    if kind == "snake" then return "Hacking grid" end
    if is_gimmick then return "Device hack" end
    local label = registry.kind_label(kind)
    return (label:gsub("^%l", string.upper))
end

local function _current_subject()
    local _, active = _current()
    if active == nil then return "Hacking grid" end
    return _subject(active.kind, active.unit_info and active.unit_info.is_gimmick)
end


-- Flash + narrate a structural replan, de-duplicated: a change can be caught by
-- both the lifecycle edge and the per-tick check, so we only emit the narrative
-- once per "retrying" window.
local function _signal_retry(id)
    if _flash_kind == "retrying" and _flash_frames > 0 then
        _set_flash("retrying", id)  -- refresh duration, suppress duplicate narrative
        return
    end
    _set_flash("retrying", id)
    emit.narrative(_current_subject() .. " changed; replanning.")
end


-- ---------------------------------------------------------------------------
-- Edge trackers
-- ---------------------------------------------------------------------------
-- Each tracker remembers the last observed value of one lifecycle boolean and
-- only fires its handler on false->true transitions. Skips the first observation
-- so we don't emit a spurious "started" on game launch.
--
-- IMPORTANT: lifecycle() reads from whichever puzzle the player is aimed at, so
-- a target switch changes which instance the trackers observe. The trackers are
-- RECREATED on every switch (see the frame poll) -- otherwise "A's trigger was
-- false, B's happens to be true" reads as an edge and fires a spurious handler.
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
-- How urgently this family's force is announced, as the wire value or nil.
--
-- The four names are the only ones the peer accepts, and it lowercases what it
-- receives, so that is what we send. Anything else -- a typo, a family with no
-- entry -- sends NO priority rather than a value that would be rejected: the
-- force still goes out, exactly as it did before this field existed.
local PRIORITY_VALUES = { low = true, medium = true, high = true, critical = true }

local _priority_warned = {}

local function force_priority(kind)
    local priorities = config.puzzle_force_priority
    if type(priorities) ~= "table" or kind == nil then return nil end
    local value = priorities[kind]
    if type(value) ~= "string" then return nil end
    local wire = value:lower()
    if not PRIORITY_VALUES[wire] then
        if not _priority_warned[kind] then
            _priority_warned[kind] = true
            log.warn("hacking_observer: mod_config.puzzle_force_priority." .. tostring(kind)
                  .. " is '" .. value .. "', which is not Low/Medium/High/Critical;"
                  .. " sending the force without a priority")
        end
        return nil
    end
    return wire
end


-- Per Neuro-SDK protocol, sending an actions/force prompts the AI peer to pick
-- exactly one of the listed actions. The state field carries the family's own
-- render -- the peer reads it to plan.
local function send_force(binding, active, id)
    if not config.hacking_auto_force then return end

    local rendered
    -- The id is passed so the render and the force-time snapshot below are
    -- provably of the same puzzle. Families that take no argument ignore it.
    local ok, r = pcall(binding.render_state, id)
    if ok and type(r) == "string" and r ~= "" then
        rendered = r
        log.info("hacking_observer: rendered " .. tostring(active.kind)
              .. " puzzle " .. tostring(id) .. " for the peer")
    else
        log.error("hacking_observer: render failed for " .. tostring(active.kind)
              .. ": " .. tostring(r))
        rendered = "A hack is active. (rendering failed: "
                .. tostring(r):sub(1, 200) .. ")"
    end

    -- Snapshot the structure we're planning against BEFORE marking the slot
    -- busy, so the reply and continuous validation compare to it.
    binding.snapshot_force_target(id)
    _inflight_id = id
    _inflight_kind = active.kind
    _inflight_since = 0

    local data = {
        -- Keep the query a one-liner: all the rules, the legend and any bonus
        -- list live in `state` (the render), so repeating them here is just
        -- bloat that dilutes the signal.
        state = rendered,
        -- A function where the wording can change at runtime (the sequence
        -- hack's group); a plain string everywhere else.
        query = type(binding.force_query) == "function" and binding.force_query()
            or binding.force_query,
        ephemeral_context = true,
        action_names = { binding.action_name },
    }
    -- A nil here leaves the key absent, so an unset or malformed setting sends
    -- the force with no priority field rather than a null one.
    data.priority = force_priority(active.kind)

    mailbox.send({
        command = "actions/force",
        game = GAME,
        data = data,
    })
    log.info("hacking_observer: forced " .. tostring(binding.action_name)
          .. " for puzzle " .. tostring(id)
          .. " (priority " .. (data.priority or "unset") .. ")")
end


-- Called by an action handler when a plan reply arrives. The reply belongs to
-- the single in-flight force, and `kind` proves it came from the action that
-- force actually listed -- a reply from a different family's action is a
-- mismatch, not a plan. Parks the payload on that puzzle's record; it dispatches
-- when the player is/becomes aimed at it (validity is re-checked at dispatch
-- time). Returns (applied, info) where info is the `parked` bool on success or a
-- reason string on discard.
function M.on_plan_received(kind, payload, resolve)
    _ever_replied = true
    local id = _inflight_id
    local in_kind = _inflight_kind
    _inflight_id = nil
    _inflight_kind = nil
    _inflight_since = 0

    if id == nil then
        log.info("hacking_observer: plan reply with no in-flight force; ignoring")
        return false, "no in-flight force"
    end
    if kind ~= nil and in_kind ~= nil and kind ~= in_kind then
        log.info("hacking_observer: plan reply for '" .. tostring(kind)
              .. "' but the force was for '" .. tostring(in_kind) .. "'; discarding")
        return false, "reply does not match the active puzzle"
    end

    local binding = registry.binding_for(in_kind)
    if binding == nil then return false, "puzzle binding unavailable" end

    local live = binding.live_puzzle_ids()
    if not live[id] then
        log.info("hacking_observer: plan reply for puzzle " .. tostring(id)
              .. " which no longer exists; discarding")
        return false, "puzzle gone"
    end

    -- `resolve` is the dispatcher's deferred-result callback. Parking it on the
    -- puzzle lets the binding report the plan's true outcome as the tool result.
    local queued, parked = binding.set_plan(id, payload or {}, resolve)
    log.info("hacking_observer: applied plan to " .. tostring(in_kind) .. " puzzle "
          .. tostring(id) .. " (" .. tostring(queued) .. " steps, parked="
          .. tostring(parked) .. ")")
    if queued == 0 then
        -- The binding refused the plan and has already resolved the peer's tool
        -- call with the reason, so there is nothing left to wait on.
        return false, "plan rejected by the puzzle"
    end
    return true, parked
end


-- ---------------------------------------------------------------------------
-- Trigger handlers
-- ---------------------------------------------------------------------------
local function on_start()
    log.info("hacking_observer: start edge fired")
    emit.narrative(_current_subject() .. " started.")
    -- The puzzle id can be unreadable for 1-2 frames after the edge; defer the
    -- snapshot clear (the "try again" signal) to reconciliation.
    _start_pending = true
end


local function on_grid_change()
    local binding = _current()
    if binding == nil then return end
    local id = binding.current_puzzle_id()
    if id == nil then return end
    -- Only replan if the STRUCTURE actually changed, not on a benign change
    -- edge. Each family's tick covers the mid-execution case; this covers the
    -- idle / in-flight case.
    if not binding.struct_changed(id) then return end

    log.info("hacking_observer: structure changed (id=" .. tostring(id)
          .. "); invalidating plan and replanning")
    binding.discard_plan(id)
    binding.clear_force_snapshot(id)
    if _inflight_id == id then
        -- A force was out for the now-stale structure; release it so the reply
        -- (planned against the old state) is dropped as stale and we re-force.
        _inflight_id = nil
        _inflight_kind = nil
        _inflight_since = 0
    end
    _signal_retry(id)
end


-- For end-of-hack triggers: resolve the puzzle's deferred result (so the outcome
-- reaches the AI as the tool result), tear down its plan/snapshot, and report
-- whether a deferred result was actually pending. When it was, the hack ended a
-- plan the AI drove, so we DON'T also narrate it as silent context -- the tool
-- result already covers it. A manual/auto hack (nothing pending) still gets the
-- narrative.
local function _end_hack(success, result_msg)
    local binding = _current()
    if binding == nil then return false end
    local id = binding.matched_puzzle_id()
    local plan_driven = false
    if id ~= nil then
        plan_driven = binding.resolve_plan(id, success, result_msg)
        binding.discard_plan(id)
        binding.clear_force_snapshot(id)
        if _inflight_id == id then
            _inflight_id = nil
            _inflight_kind = nil
            _inflight_since = 0
        end
    end
    return plan_driven
end


-- Frame of the last outcome we reported, from any source. The player-level
-- backstop below uses it to avoid double-reporting a hack the per-puzzle edge
-- already caught.
local _last_outcome_frame = -1000
local OUTCOME_DEDUPE_FRAMES = 60   -- ~1s at 60fps


local function on_reset()
    log.info("hacking_observer: hack reset")
    local subject = _current_subject()
    local plan_driven = _end_hack(false,
        "The hack reset to the start; none of the planned moves counted.")
    if not plan_driven then
        emit.narrative(subject .. " was reset.")
    end
end


local function on_success()
    log.info("hacking_observer: hack succeeded")
    _last_outcome_frame = _frame
    local plan_driven = _end_hack(true, "The hack is complete.")
    _set_flash("success")
    if not plan_driven then
        emit.narrative("Hack succeeded.")
    end
end


local function on_failed()
    log.info("hacking_observer: hack failed")
    _last_outcome_frame = _frame
    local plan_driven = _end_hack(false, "The hack failed.")
    _set_flash("failed")
    if not plan_driven then
        emit.narrative("Hack failed.")
    end
end


-- ---------------------------------------------------------------------------
-- Player-level outcome backstop
-- ---------------------------------------------------------------------------
-- Everything above reads the puzzle the player is AIMED AT. That is the right
-- source when there is one, but it has a blind spot the capture in
-- data/pragmata_mailbox made obvious: of nine hacks that started, only three
-- were ever seen to end. A hack that finishes while the player has already
-- looked at something else is simply never observed.
--
-- app.player.PuzzleStatus carries PuzzleSuccess / PuzzleFailed on the PLAYER,
-- not on a puzzle instance, so it fires wherever the aim happens to be and for
-- every family. bindings/player_status.lua already reflects it; nothing had ever
-- read it. It is used only to make sure the peer HEARS about an outcome -- the
-- per-puzzle path stays in charge of resolving deferred tool results, because
-- resolving a plan on a puzzle nobody is looking at would be guesswork.
--
-- Its own edge tracking is kept local rather than going through
-- player_status.edges(), which shares one observation baseline with the debug
-- panel and the probe tools: two consumers of that would eat each other's
-- transitions.
local player_status = nil
local success_flag_track = emit.edge()
local failed_flag_track  = emit.edge()

local function _poll_player_outcome()
    if player_status == nil then
        local ok, mod = pcall(require, "pragmata.bindings.player_status")
        if not ok then return end
        player_status = mod
        pcall(player_status.want_handles)
    end

    local container = player_status.container()
    if container == nil then return end

    local function report(what)
        if _frame - _last_outcome_frame <= OUTCOME_DEDUPE_FRAMES then return end
        _last_outcome_frame = _frame
        _hit_counts.backstop = (_hit_counts.backstop or 0) + 1
        log.info("hacking_observer: outcome seen on the player status (" .. what
              .. ") with no puzzle edge; reporting it")
        emit.narrative(what == "success" and "Hack succeeded." or "Hack failed.")
        _set_flash(what == "success" and "success" or "failed")
    end

    success_flag_track(
        player_status.has("app.player.PuzzleStatus", "PuzzleSuccess", container) == true,
        function(now) if now then report("success") end end)

    failed_flag_track(
        player_status.has("app.player.PuzzleStatus", "PuzzleFailed", container) == true,
        function(now) if now then report("failed") end end)
end


-- ---------------------------------------------------------------------------
-- Reconciliation: decide whether to force the current puzzle
-- ---------------------------------------------------------------------------
-- Re-derives "what does the puzzle I'm aimed at need?" from current truth every
-- frame, rather than latching on an edge that can be missed. Forces exactly when
-- the current puzzle is interactive, has no plan, nothing is in flight, and its
-- state differs from the last thing we forced it against.
local function _reconcile(binding, active, cur_id)
    -- Apply a pending (re)start: drop the entered puzzle's force snapshot so it
    -- re-forces even on an unchanged puzzle (explicit retry).
    if _start_pending and binding ~= nil and cur_id ~= nil then
        binding.clear_force_snapshot(cur_id)
        _start_pending = false
    end

    if binding == nil or cur_id == nil then return end
    if not binding.is_interactive() then return end
    if registry.is_jamming() then return end        -- jammer suppresses hacking entirely
    if registry.is_game_paused() then return end    -- don't force while the game is paused
    if binding.has_plan(cur_id) then return end     -- a plan is queued / executing
    -- A family may need a moment before it can describe its puzzle honestly --
    -- the circuit binding measures which button turns which connector first,
    -- because the peer answers in those names. Families without the method are
    -- never blocked.
    if binding.force_blocked ~= nil then
        -- A family may also hand back a reason. It is said to the peer once, so
        -- a stretch with no force reads as a decision rather than as the mod
        -- having stopped: the circuit binding does not ask a question when its
        -- board has nothing to answer.
        local blocked, reason = binding.force_blocked(cur_id)
        if blocked then
            if type(reason) == "string" then emit.narrative(reason, { silent = true }) end
            return
        end
    end
    if _inflight_id == cur_id then return end        -- already waiting on this puzzle's plan
    if _inflight_id ~= nil then return end           -- busy on another puzzle
    if binding.needs_force(cur_id) then
        send_force(binding, active, cur_id)
    end
end


-- ---------------------------------------------------------------------------
-- Frame poll
-- ---------------------------------------------------------------------------
re.on_frame(function()
    _frame = _frame + 1

    if _flash_frames > 0 then _flash_frames = _flash_frames - 1 end

    if (_frame % POLL_INTERVAL) ~= 0 then return end

    -- The registry memoises "what is active" for the frame; every consumer below
    -- and every family tick shares that one resolution.
    registry.tick()

    local binding, active = _current()
    local cur_id = binding and binding.current_puzzle_id() or nil
    local cur_key = _key(active and active.kind or nil, cur_id)

    -- Target-switch / re-aim handling runs FIRST: the edge trackers below sample
    -- whichever puzzle is currently aimed at, so on a switch they must be
    -- re-seeded before any trigger is read -- otherwise the other target's
    -- trigger values masquerade as edges. Entering a puzzle is also an implicit
    -- (re)start signal, in case the start edge doesn't re-fire on a mid-aim
    -- swap. The PREVIOUS puzzle's plan is intentionally LEFT parked so it
    -- resumes if the player returns.
    if cur_key ~= _last_observed_key then
        _reset_edge_trackers()
        if cur_key ~= nil then _start_pending = true end
        _last_observed_key = cur_key
    end

    local life = binding and binding.lifecycle()
        or { started = false, changed = false, reset = false, success = false, failed = false }

    start_track(life.started, function(now)
        if now then _hit_counts.start_trg = _hit_counts.start_trg + 1; on_start() end
    end)

    gridchange_track(life.changed, function(now)
        if now then _hit_counts.grid_change_end = _hit_counts.grid_change_end + 1; on_grid_change() end
    end)

    reset_track(life.reset, function(now)
        if now then _hit_counts.reset = _hit_counts.reset + 1; on_reset() end
    end)

    success_track(life.success, function(now)
        if now then _hit_counts.success = _hit_counts.success + 1; on_success() end
    end)

    failed_track(life.failed, function(now)
        if now then _hit_counts.failed = _hit_counts.failed + 1; on_failed() end
    end)

    -- Runs whether or not a puzzle is aimed at -- that is the entire point.
    pcall(_poll_player_outcome)

    -- React to dispatcher events from EVERY loaded family, not just the active
    -- one: a plan can abort on a puzzle the player has already turned away from,
    -- and its event still has to be drained or it queues up forever.
    for _, entry in ipairs(registry.loaded_bindings()) do
        for _, e in ipairs(entry.mod.consume_plan_events()) do
            local kind = (type(e) == "table") and e.kind or e
            if kind == "resumed" then
                _set_flash("resumed", cur_id)
            elseif kind == "succeeded" then
                -- The dispatcher detected completion itself. on_success usually
                -- drives this flash off the lifecycle edge, but flash here too
                -- in case a post-completion reset swaps the matched instance
                -- before that edge is caught.
                _set_flash("success")
            elseif kind == "grid_changed" then
                -- The puzzle's STRUCTURE actually changed. The binding already
                -- reported the replan to the AI as the tool result; here we only
                -- drive the overlay (no silent narrative).
                _set_flash("retrying", cur_id)
            elseif kind == "settling" or kind == "move_failed" then
                -- A planned step didn't land where expected -- the puzzle did
                -- NOT change. So this gets its own "rerouting" banner, NOT the
                -- misleading "PUZZLE CHANGED". The accurate outcome still
                -- reaches the AI as the TOOL RESULT, so we deliberately do NOT
                -- narrate it as silent context here.
                _set_flash("rerouting", cur_id)
            end
        end
    end

    -- In-flight watchdog: release the slot if the forced puzzle was destroyed or
    -- if a reply never came back within a generous window (lost message).
    if _inflight_id ~= nil then
        _inflight_since = _inflight_since + 1
        local owner = registry.binding_for(_inflight_kind)
        local live = owner and owner.live_puzzle_ids() or {}
        if not live[_inflight_id] then
            log.info("hacking_observer: in-flight puzzle " .. tostring(_inflight_id)
                  .. " gone; releasing force slot")
            _inflight_id = nil
            _inflight_kind = nil
            _inflight_since = 0
        elseif _inflight_since > INFLIGHT_WATCHDOG_FRAMES then
            log.warn("hacking_observer: in-flight force watchdog fired (no reply in "
                  .. tostring(INFLIGHT_WATCHDOG_FRAMES) .. " frames); releasing slot")
            if not _ever_replied and not _dead_bridge_warned then
                _dead_bridge_warned = true
                log.warn("hacking_observer: no reply has EVER come back from the bridge. "
                      .. "Every force will expire like this until something is listening -- "
                      .. "check that sidecar/pragmata_mailbox.py is running and connected "
                      .. "to the peer.")
            end
            _inflight_id = nil
            _inflight_kind = nil
            _inflight_since = 0
        end
    end

    _reconcile(binding, active, cur_id)
end)


function M.debug_hit_counts()
    return _hit_counts
end


function M.inflight()
    return { id = _inflight_id, kind = _inflight_kind, frames = _inflight_since }
end


-- Status for the on-screen overlay (hacking_overlay.lua). Returns:
--   { phase = "idle"|"planning"|"busy"|"executing"|"resumed"|"retrying"
--             |"rerouting"|"jammed"|"paused"|"success"|"failed",
--     executed = <number>, total = <number> }   -- counts only when executing
-- "planning"  : a force is out for the current puzzle; waiting on the reply.
-- "busy"      : a force is out for a DIFFERENT puzzle; the current one waits.
-- "executing" : the current puzzle's plan is dispatching step by step.
-- "resumed"   : a parked plan just began running on return (brief flash).
-- "retrying"  : the puzzle's STRUCTURE changed; replanning (flash).
-- "rerouting" : a planned step didn't land; replanning (brief flash).
-- "jammed"    : a jammer is suppressing hacking; planning is paused.
-- "paused"    : the GAME is paused mid-hack; we hold off forcing/dispatch until
--               it resumes.
-- "success"/"failed": short-lived flash after the hack resolves.
--
-- The vocabulary is unchanged from when this only covered the enemy grid, so
-- hacking_overlay.lua needs no knowledge of which family is driving.
function M.overlay_status()
    local binding = _current()
    local cur = binding and binding.current_puzzle_id() or nil

    -- Result/transition flash takes priority and persists briefly. Transition
    -- flashes (resumed/retrying) are scoped to the puzzle they're about -- after
    -- a target switch the new puzzle's true state shows instead of another
    -- target's banner. Result flashes stay global.
    if _flash_frames > 0 and _flash_kind ~= nil then
        if _flash_id == nil or _flash_id == cur then
            return { phase = _flash_kind }
        end
    end

    if binding == nil or cur == nil or not binding.is_interactive() then
        return { phase = "idle" }
    end

    -- Game paused mid-hack: nothing is progressing. Only surface it when there's
    -- actually a hack to pause -- a plan queued/executing or a force in flight --
    -- so a plain pause while merely aiming doesn't pop the banner.
    if registry.is_game_paused()
        and (binding.has_plan(cur) or _inflight_id ~= nil) then
        return { phase = "paused" }
    end

    -- Jammer active: hacking is suppressed entirely; no plan will be forced
    -- until it clears.
    if registry.is_jamming() then
        return { phase = "jammed" }
    end

    -- A force is out for another target; the current puzzle can't be planned
    -- until it resolves (one force at a time).
    if _inflight_id ~= nil and _inflight_id ~= cur then
        return { phase = "busy" }
    end

    local ps = binding.current_plan_status()
    if ps.queue_size and ps.queue_size > 0 then
        return { phase = "executing", executed = ps.executed or 0, total = ps.total or 0 }
    end

    if _inflight_id == cur then
        return { phase = "planning" }
    end

    return { phase = "idle" }
end


return M
