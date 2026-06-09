-- Ability state context emitters.
--
-- Polls Diana's ability bindings each frame and emits context updates to
-- the AI when interesting transitions happen:
--   - Hacking gauge crossing thresholds upward       (transient)
--   - Overdrive readiness edge true/false             (narrative)
--   - Auto-Hack upgrade unlock edge                   (narrative)
--   - Scan results when a new ping set arrives        (narrative)
--
-- Each emitter is independently guarded: a missing or broken binding
-- disables only its own emit, not the whole module.

local M = {}
local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.warn("ability_state: failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local hacking   = safe_require("pragmata.bindings.hacking")
local overdrive = safe_require("pragmata.bindings.overdrive")
local scan      = safe_require("pragmata.bindings.scan")

-- --------------------------------------------------------------------
-- Trackers
-- --------------------------------------------------------------------

local GAUGE_THRESHOLDS = { 0.25, 0.5, 0.75, 1.0 }
local gauge_track             = emit.threshold(GAUGE_THRESHOLDS)
local overdrive_ready_track   = emit.edge()
local autohack_unlock_track   = emit.edge()
local scanning_track          = emit.edge()

-- Scan results are only read while a scan is genuinely in flight. Previously
-- the observer polled currentTargetUnits unconditionally and emitted whenever
-- a new ping-set appeared — which fired spuriously after every loading screen
-- (the manager keeps stale entries). Now an is_scanning() rising edge opens a
-- short window during which results are captured; outside that window we don't
-- look at the (possibly stale) list at all.
local _scan_emit_window = 0
local SCAN_EMIT_WINDOW_POLLS = 20  -- ~2s at the 6-frame poll cadence below

-- --------------------------------------------------------------------
-- Scan dedup
-- --------------------------------------------------------------------

local SCAN_DEDUP_WINDOW = 8
local _scan_recent_keys = {}
local _scan_recent_set = {}

local function scan_record_key(key)
    if _scan_recent_set[key] then return false end
    table.insert(_scan_recent_keys, key)
    _scan_recent_set[key] = true
    if #_scan_recent_keys > SCAN_DEDUP_WINDOW then
        local old = table.remove(_scan_recent_keys, 1)
        _scan_recent_set[old] = nil
    end
    return true
end

local function summarize_pings(pings)
    if type(pings) ~= "table" or #pings == 0 then return nil, nil end
    local counts, order, key_parts = {}, {}, {}
    for _, p in ipairs(pings) do
        local kind = tostring(p.icon_type or "unknown")
        if not counts[kind] then
            counts[kind] = 0
            table.insert(order, kind)
        end
        counts[kind] = counts[kind] + 1
        table.insert(key_parts, tostring(p.object_id or "?"))
    end
    table.sort(key_parts)
    table.sort(order)
    local fragments = {}
    for _, k in ipairs(order) do
        table.insert(fragments, string.format("%d %s", counts[k], k))
    end
    return table.concat(fragments, ", "), table.concat(key_parts, "|")
end

-- --------------------------------------------------------------------
-- Frame poll
-- --------------------------------------------------------------------

local POLL_INTERVAL = 6  -- ~10 Hz at 60 fps
local _frame = 0

local function safe_call(fn, ...)
    if fn == nil then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end

    if overdrive ~= nil then
        local frac = safe_call(overdrive.gauge_fraction)
        gauge_track(frac, function(bucket, threshold, prev_bucket)
            -- Only emit on upward crossings; the readiness edge below covers
            -- the drop after Overdrive fires.
            if bucket > prev_bucket then
                emit.transient(string.format("Hacking gauge: %d%%", math.floor(threshold * 100)))
            end
        end)

        local ready = safe_call(overdrive.is_ready)
        overdrive_ready_track(ready, function(now)
            if now then
                emit.narrative("Diana's Overdrive Protocol is ready.")
            else
                emit.narrative("Overdrive Protocol fired.")
            end
        end)
    end

    if hacking ~= nil then
        local unlocked = safe_call(hacking.is_auto_hack_unlocked)
        autohack_unlock_track(unlocked, function(now)
            if now then
                emit.narrative("Auto-Hack upgrade is now available.")
            end
        end)
    end

    if scan ~= nil then
        -- Open a capture window on each real scan start.
        local scanning = safe_call(scan.is_scanning)
        scanning_track(scanning, function(now)
            if now then _scan_emit_window = SCAN_EMIT_WINDOW_POLLS end
        end)

        if _scan_emit_window > 0 then
            _scan_emit_window = _scan_emit_window - 1
            local results = safe_call(scan.get_results)
            if type(results) == "table" then
                local pings = results.pings or results
                local summary, key = summarize_pings(pings)
                if summary and key and scan_record_key(key) then
                    emit.narrative("Diana scanned: " .. summary .. ".")
                end
            end
        end
    end
end)

return M
