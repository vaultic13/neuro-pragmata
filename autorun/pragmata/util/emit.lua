-- Context emission helpers.
--
-- Provides:
--   emit.narrative(msg)    -- discrete events (scan fired, scene changed)
--   emit.transient(msg)    -- current-state snapshots (gauge: 60%); uses an
--                             optional `lane` field that lane-aware consumers
--                             treat as replacement-style context. Pure
--                             Neuro-SDK consumers ignore the field and treat
--                             it as a normal cumulative context line.
--   emit.edge(...)         -- only fires the callback when a tracked value
--                             transitions; skips first observation
--   emit.threshold(...)    -- fires the callback when a numeric value crosses
--                             into a new bucket
--
-- The lane field is forward-compatible: lane-aware consumers respect
-- "narrative" vs "transient" lanes; anything that doesn't understand them
-- treats every line as cumulative context. The choice to use one or the
-- other is purely about whether the message represents an event vs. a
-- state snapshot.

local M = {}
local mailbox = require("pragmata.bridge_mailbox")

local GAME = "Pragmata"

local function send_context(message, lane, silent)
    if message == nil or message == "" then return end
    local data = { message = message }
    if silent ~= false then data.silent = true end
    if lane then data.lane = lane end
    mailbox.send({
        command = "context",
        game = GAME,
        data = data,
    })
end

function M.narrative(message, opts)
    opts = opts or {}
    send_context(message, "narrative", opts.silent)
end

function M.transient(message, opts)
    opts = opts or {}
    send_context(message, "transient", opts.silent)
end

-- Edge-triggered tracker. Skip first observation so we don't emit "became X"
-- on the very first poll after game launch.
--
-- Usage:
--   local track = emit.edge()
--   re.on_frame(function()
--       track(some_bool, function(now) emit.narrative("became " .. tostring(now)) end)
--   end)
function M.edge()
    local last
    local seeded = false
    return function(current, on_change)
        if not seeded then
            last = current
            seeded = true
            return
        end
        if last ~= current then
            last = current
            if on_change then on_change(current) end
        end
    end
end

-- Threshold tracker. Fires only when the value crosses into a new bucket
-- defined by an ascending threshold list. Skips first observation.
--
-- Usage:
--   local track = emit.threshold({0.25, 0.5, 0.75, 1.0})
--   re.on_frame(function()
--       track(gauge_fraction, function(bucket, threshold)
--           emit.transient(string.format("Gauge: %d%%", math.floor(threshold * 100)))
--       end)
--   end)
function M.threshold(thresholds)
    local last_bucket
    local seeded = false
    return function(value, on_cross)
        if value == nil then return end
        local bucket = 0
        for i, t in ipairs(thresholds) do
            if value >= t then bucket = i end
        end
        if not seeded then
            last_bucket = bucket
            seeded = true
            return
        end
        if bucket ~= last_bucket then
            local prev = last_bucket
            last_bucket = bucket
            if on_cross then
                on_cross(bucket, thresholds[bucket], prev)
            end
        end
    end
end

-- Throttle by minimum interval. Returns a function that only allows the
-- callback through if at least `interval_frames` have passed since last fire.
-- Useful for events that can otherwise spam per-frame.
function M.throttle(interval_frames)
    local last_fire = -math.huge
    local frame = 0
    return function(on_fire)
        frame = frame + 1
        if frame - last_fire >= interval_frames then
            last_fire = frame
            if on_fire then on_fire() end
        end
    end
end

return M
