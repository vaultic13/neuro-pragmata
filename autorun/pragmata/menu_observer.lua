-- Tells the peer when a menu it can read opens or closes.
--
-- pragmata_menu_list reads only the menu on screen (menu_actions.lua), so
-- the peer needs to know when there is one. Each open or close of a menu in
-- mod_config.menu_push_keys is one silent context line:
--
--   The Unit Printer is open on the Weapon tab. Read it with pragmata_menu_list.
--   The Unit Printer closed.
--
-- Source: action_gates' open readings, checked on every gate poll (~5 Hz,
-- action_gates.on_before_sync). An edge counts only after
-- mod_config.menu_push_debounce_polls polls in the new state, so the frame a
-- menu swaps pages, or the Cabin hub rebuilding, does not flap. Switching the
-- Cabin hub between its Stamp Club and Training tabs is a real close (Training
-- is not one of these menus).
--
-- Nothing is pushed while the world is loading, and the first reading after a
-- load is a baseline, not an edge: a save loaded with a menu open is not news.
--
-- Neutral: no engine names; the labels and the open note (the printer's tab)
-- come from the menu modules through menu_actions.

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local config = require("pragmata.mod_config")

local _poll = 0
local _state = {}       -- key -> { stable = bool|nil, candidate = bool|nil, count }
local _was_loaded = true

local function event(text)
    log.info("menu_observer: " .. text)
end

local function capitalised(s) return (tostring(s):gsub("^%l", string.upper)) end

local function open_line(entry)
    local note = nil
    if entry.open_note ~= nil then
        local ok, v = pcall(entry.open_note)
        if ok and type(v) == "string" and v ~= "" then note = v end
    end
    return string.format("%s is open%s. Read it with pragmata_menu_list.",
        capitalised(entry.label or entry.key), note and (" " .. note) or "")
end

local function close_line(entry)
    return capitalised(entry.label or entry.key) .. " closed."
end

local function poll(gates, menu_actions)
    _poll = _poll + 1
    if not gates.world_loaded() then
        if _was_loaded then _state = {} end      -- next reading is a baseline
        _was_loaded = false
        return
    end
    _was_loaded = true
    local need = math.max(1, tonumber(config.menu_push_debounce_polls) or 2)
    for _, key in ipairs(config.menu_push_keys or {}) do
        local entry = menu_actions.entry(key)
        if entry ~= nil then
            local now = gates.menu_is_open(entry.open_key) == true
            local s = _state[key]
            if s == nil then
                _state[key] = { stable = now, count = 0 }
            elseif now == s.stable then
                s.candidate, s.count = nil, 0
            else
                if s.candidate == now then s.count = s.count + 1
                else s.candidate, s.count = now, 1 end
                if s.count >= need then
                    s.stable, s.candidate, s.count = now, nil, 0
                    local line = now and open_line(entry) or close_line(entry)
                    local on = config.menu_push_open_close ~= false
                    event(line .. (on and "" or "  (push off: not sent)"))
                    if on then emit.narrative(line) end
                end
            end
        end
    end
end

-- Called once from pragmata_main.lua, after the menu modules have added
-- their entries.
function M.register(gates, menu_actions)
    gates.on_before_sync(function()
        local ok, err = pcall(poll, gates, menu_actions)
        if not ok then log.warn("menu_observer: poll failed: " .. tostring(err)) end
    end)
end

return M
