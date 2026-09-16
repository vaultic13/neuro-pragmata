-- Shared plan bookkeeping for the puzzle families.
--
-- bindings/puzzle_snake.lua grew a set of behaviours that turned out to have
-- nothing to do with grids, and which every other puzzle family needs verbatim:
--
--   * the deferred result. The peer's tool result must say what ACTUALLY
--     happened, so the dispatcher's resolve callback is parked on the puzzle
--     RECORD (not on the plan) -- it has to survive a replan -- and fired
--     exactly once, whatever ends the hack.
--
--   * the structural snapshot. A plan is only valid while the puzzle's layout is
--     unchanged. We fingerprint the layout when the force goes out and compare
--     at dispatch time, so a plan generated against a puzzle that has since
--     changed is discarded instead of being applied to the wrong thing.
--
--   * parking. A reply can arrive after the player has looked away. The plan
--     waits on its own puzzle and resumes if the player comes back, rather than
--     being applied to whatever happens to be in front of them now.
--
--   * the one-shot event queue the observer drains to drive the overlay.
--
-- Each family calls new() once and gets its own event queue; the per-puzzle
-- state lives on the record so it is destroyed with the puzzle.

local M = {}

function M.new(opts)
    opts = opts or {}
    local P = { kind = opts.kind or "puzzle" }
    local _events = {}

    -- ----------------------------------------------------------------
    -- Events (drained by hacking_observer to drive the overlay)
    -- ----------------------------------------------------------------
    function P.push_event(kind, extra)
        local e = { kind = kind }
        if type(extra) == "table" then
            for k, v in pairs(extra) do e[k] = v end
        end
        _events[#_events + 1] = e
    end

    function P.consume_events()
        local out = _events
        _events = {}
        return out
    end

    -- ----------------------------------------------------------------
    -- Per-record plan state
    -- ----------------------------------------------------------------
    -- Park a plan on a puzzle. `steps` is whatever the family's dispatcher
    -- consumes; this module never looks inside it. `is_current` says whether the
    -- player is aimed at this puzzle right now -- if not, the plan is parked and
    -- starts when they return.
    --
    -- Returns (queued_count, parked).
    function P.set_plan(rec, steps, resolve, is_current)
        if rec == nil then return 0, false end

        -- A new plan supersedes an old one. Resolve the old deferred result
        -- rather than abandoning it: an unresolved tool call leaves the peer
        -- waiting forever.
        if rec.pending_resolve ~= nil then
            P.resolve(rec, false, "superseded by a newer plan")
        end

        rec.pending_resolve = resolve
        rec.plan = {
            queue     = steps or {},
            total     = #(steps or {}),
            executed  = 0,
            cooldown  = 0,
            parked    = not is_current,
            confirmed = false,
        }
        return rec.plan.total, rec.plan.parked
    end

    -- Fire the parked deferred result exactly once. Returns true when there
    -- actually was one -- the observer uses that to decide whether the outcome
    -- has already reached the peer as a tool result, or still needs narrating.
    function P.resolve(rec, ok, message)
        if rec == nil or rec.pending_resolve == nil then return false end
        local fn = rec.pending_resolve
        rec.pending_resolve = nil
        pcall(fn, ok and true or false, message or "")
        return true
    end

    function P.discard(rec)
        if rec == nil then return end
        rec.plan = nil
    end

    function P.has_plan(rec)
        return rec ~= nil and rec.plan ~= nil and #rec.plan.queue > 0
    end

    function P.status(rec)
        if rec == nil or rec.plan == nil then
            return { queue_size = 0, executed = 0, total = 0 }
        end
        return {
            queue_size = #rec.plan.queue,
            executed   = rec.plan.executed or 0,
            total      = rec.plan.total or 0,
            parked     = rec.plan.parked or false,
        }
    end

    -- ----------------------------------------------------------------
    -- Structural snapshot
    -- ----------------------------------------------------------------
    -- Taken just before a force goes out, so the reply and every later dispatch
    -- can be compared against the exact thing that was described to the peer.
    function P.snapshot(rec, sig)
        if rec == nil then return end
        rec.forced_sig = sig
    end

    function P.clear_snapshot(rec)
        if rec == nil then return end
        rec.forced_sig = nil
    end

    -- True when the puzzle's layout differs from what we forced against. A nil
    -- signature (couldn't read the puzzle this frame) is NOT a change: a
    -- transient read failure must not throw away a good plan.
    function P.changed(rec, sig)
        if rec == nil or rec.forced_sig == nil then return false end
        if sig == nil then return false end
        return sig ~= rec.forced_sig
    end

    -- Whether this puzzle wants a (re)force: nothing forced yet, or what we
    -- forced against no longer matches. Clearing the snapshot elsewhere is the
    -- explicit "ask again" signal (a retry on an unchanged puzzle).
    function P.needs_force(rec, sig)
        if rec == nil then return false end
        if sig == nil then return false end
        if rec.forced_sig == nil then return true end
        return sig ~= rec.forced_sig
    end

    return P
end

return M
