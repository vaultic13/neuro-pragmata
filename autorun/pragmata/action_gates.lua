-- When actions are available.
--
-- Each gate is a plain predicate returning `ok, reason`, the shape
-- dispatcher.register's `available` field takes, so an action is gated with
--
--     available = gates.abilities_available
--
-- and a new rule is one more function here. The reason is what a peer that
-- calls a hidden action (racing the change) is told.
--
-- A ~5 Hz tick asks the dispatcher to sync: when the set of available actions
-- differs from the set the peer holds, it unregisters what went away and
-- re-registers the full list. Nothing is sent while the set is unchanged.
--
-- Place and menu readings can drop out for a moment (loading screens, the
-- frame a menu swaps pages). A reading of "unknown" keeps the last known
-- answer, so a loading screen does not flap the action list.

local M = {}

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local dispatcher = require("pragmata.dispatcher")
local game_state = require("pragmata.game_state")

local gui = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.gui_state")
    if ok then gui = mod else log.warn("action_gates: gui_state binding unavailable: " .. tostring(mod)) end
end

-- Tab readers for screens that hold several menus as tabs, by screen code.
-- Each returns the selected tab's key or nil when it cannot tell.
local tab_readers = {}
local cabin = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.cabin_hub")
    if ok then cabin = mod tab_readers[mod.CODE] = mod.selected_tab
    else log.warn("action_gates: cabin_hub binding unavailable: " .. tostring(mod)) end
end

local scene = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.scene")
    if ok then scene = mod end
end

local POLL_INTERVAL = 12

-- ---------------------------------------------------------------------------
-- Readings (cached per poll; the predicates run for every action on a sync)
-- ---------------------------------------------------------------------------

local _in_shelter = false
local _open = {}                -- menu key -> true while its screen is open
local _sector = nil             -- last sector hash read, for the debug panel

local function read_place()
    local area = game_state.area
    if area == nil or area.current_sector_hash == nil then return end
    local ok, h = pcall(area.current_sector_hash)
    if not ok or h == nil then return end            -- unknown: keep last
    _sector = h
    _in_shelter = (config.shelter_sector_hash ~= nil and h == config.shelter_sector_hash)
end

-- A menu rule is one screen code, or { all = {codes}, none = {codes} } for a
-- menu that shares its screen with the HUD or another menu: every `all` code
-- open and no `none` code open. A `none` entry starting with "^" is a Lua
-- pattern matched against every open code. { code = c, tab = t } is a menu
-- that is one tab of screen c (the Cabin's Stamp Club and Training). Nil when
-- the screens cannot be read.
function M.rule_matches(rule)
    if gui == nil then return nil end
    if type(rule) == "string" then return gui.is_open(rule) end
    if type(rule) ~= "table" then return nil end
    if rule.code ~= nil then
        local open = gui.is_open(rule.code)
        if open ~= true then return open end
        local reader = tab_readers[rule.code]
        if reader == nil then return nil end
        local ok, tab = pcall(reader)
        if not ok or tab == nil then return nil end     -- unknown: keep last
        return tab == rule.tab
    end
    for _, code in ipairs(rule.all or {}) do
        local v = gui.is_open(code)
        if v == nil then return nil end
        if v == false then return false end
    end
    for _, code in ipairs(rule.none or {}) do
        if code:sub(1, 1) == "^" then
            -- A Lua pattern, tested against every open screen.
            for _, open in ipairs(gui.open_codes()) do
                if open:find(code) then return false end
            end
        elseif gui.is_open(code) == true then
            return false
        end
    end
    return true
end

local function read_menus()
    if gui == nil then return end
    gui.tick()
    for key, rule in pairs(config.menu_gui or {}) do
        local v = M.rule_matches(rule)
        if v ~= nil then _open[key] = v or nil end
    end
end

-- ---------------------------------------------------------------------------
-- Gates
-- ---------------------------------------------------------------------------

function M.in_shelter() return _in_shelter end

function M.menu_is_open(key) return _open[key] == true end

-- Scan / Auto-Hack / Overdrive.
function M.abilities_available()
    if config.hide_abilities_in_shelter ~= false and _in_shelter then
        return false, "Diana's abilities are not used in the Shelter"
    end
    return true
end

-- pragmata_overdrive: the abilities gate, except that a scene stopped on its
-- Overdrive prompt always needs it (bindings/cutscene_prompt.lua).
function M.overdrive_available()
    local prompt = package.loaded["pragmata.bindings.cutscene_prompt"]
    if prompt ~= nil and config.cutscene_prompt_enabled ~= false then
        local ok, active = pcall(prompt.active)
        if ok and active ~= nil and active.button == "overdrive" then return true end
    end
    return M.abilities_available()
end

-- pragmata_purify: only while a scene waits on the filament-cleaning button.
function M.purify_available()
    local prompt = package.loaded["pragmata.bindings.cutscene_prompt"]
    if prompt ~= nil and config.cutscene_prompt_enabled ~= false then
        local ok, active = pcall(prompt.active)
        if ok and active ~= nil and active.button == "purify" then return true end
    end
    return false, "only while a scene waits for the filament-cleaning button"
end

-- The hacking answers: pragmata_enemy_hack_plan (enemies and grid puzzles) and the
-- other puzzle families' actions.
-- Something hackable is in front of the player right now. The game's opening
-- tutorial runs in the Shelter sector yet has enemies to hack (2026-10-11), so
-- "in the Shelter" alone is not "nothing to hack".
local function hack_target_present()
    local reg = package.loaded["pragmata.bindings.puzzle_registry"]
    if reg == nil or reg.active_binding == nil then return false end
    local ok, binding = pcall(reg.active_binding)
    return ok and binding ~= nil
end

function M.hacking_available()
    if config.hide_hacking_in_shelter ~= false and _in_shelter
        and not hack_target_present() then
        return false, "there is nothing to hack in the Shelter"
    end
    return true
end

-- Anywhere in the Shelter sector (the catalog actions).
function M.shelter_only()
    if _in_shelter then return true end
    return false, "only available in the Shelter"
end

-- While one Shelter menu is on screen, e.g. gates.menu_open("firmware").
function M.menu_open(key)
    return function()
        if _open[key] == true then return true end
        return false, "only available while that menu is open"
    end
end

-- Available when any of the given gates is; the first gate's reason
-- otherwise. E.g. any(shelter_only, menu_open("simulations")).
function M.any(...)
    local gates = { ... }
    return function()
        local first_reason = nil
        for _, g in ipairs(gates) do
            local ok, reason = g()
            if ok then return true end
            if first_reason == nil then first_reason = reason end
        end
        return false, first_reason
    end
end

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------

-- Hooks run just before a sync, e.g. to refresh an action's schema enum from
-- the menu that just opened. fn() takes no arguments.
local _before_sync = {}
function M.on_before_sync(fn) _before_sync[#_before_sync + 1] = fn end

local _frame = 0

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end
    -- Nothing is read while the world is loading (elevators, area loads):
    -- containers are torn down then, and the last known answers stand.
    local loaded = true
    if scene ~= nil then
        local ok_l, v = pcall(scene.is_loaded)
        loaded = not (ok_l and v == false)
    end
    if loaded then
        pcall(read_place)
        pcall(read_menus)
    end
    for _, fn in ipairs(_before_sync) do
        local ok, err = pcall(fn)
        if not ok then log.warn("action_gates: before-sync hook failed: " .. tostring(err)) end
    end
    local ok, err = pcall(dispatcher.sync)
    if not ok then log.warn("action_gates: sync failed: " .. tostring(err)) end
end)

-- For Pragmata State Debug.
function M.debug_status()
    local open = {}
    for key in pairs(_open) do open[#open + 1] = key end
    table.sort(open)
    local cabin_tab = "(binding not loaded)"
    if cabin ~= nil then
        local c = cabin.debug_status()
        cabin_tab = string.format("%s via %s (index %s, type %s = %s, title %s)",
            tostring(c.tab), tostring(c.route), tostring(c.index),
            tostring(c.tab_type_hash), tostring(c.tab_type_name), tostring(c.title))
    end
    return {
        cabin_tab = cabin_tab,
        in_shelter = _in_shelter,
        sector_hash = _sector,
        shelter_sector_hash = config.shelter_sector_hash,
        open_menus = table.concat(open, ", "),
    }
end

return M
