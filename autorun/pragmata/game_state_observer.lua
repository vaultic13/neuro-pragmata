-- Proactive game-state context.
--
-- Polls the game-state bindings a few times a second and pushes silent
-- narrative context on three edges, each switchable in mod_config:
--
--   area change   -> "Entered <area>. Map completion here: 60%. Still to
--                     collect (3 of 12): 2x Upgrade Components, 1x Archive."
--   low health    -> "Hugh is down to 22% HP (88/400) with 1 repair kit left."
--                     Only on a DOWNWARD crossing of a configured fraction, so
--                     healing back up and taking the same hit again re-arms it
--                     but hovering around a threshold does not spam.
--   weapon change -> "Weapon equipped: <name>." / "Weapon unequipped: <name>."
--                     when the set of equipped weapons differs from the
--                     previous reading (a field pickup equips). Ammo is not
--                     compared.
--   hacking mods  -> "Hacking mod equipped: <name>." / "... unequipped ..."
--                     the same comparison over the equipped hacking mods;
--                     remaining uses are not compared.
--
-- It also measures what a repair kit actually heals: when the kit count drops,
-- the HP gained over the next few seconds is recorded on game_state, and the
-- health action reports that instead of the figure computed from data tables.
--
-- Polling pauses whenever the world is not loaded (menus, loading screens).
-- The area and health baselines are dropped then, so a load never reads as a
-- fall from full health. The weapon baselines are kept (see reset_baselines);
-- a save load shows up as a jump too large to be a pickup and is absorbed.

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local config = require("pragmata.mod_config")
local game_state = require("pragmata.game_state")

local scene = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.scene")
    if ok then scene = mod else log.warn("game_state_observer: scene binding unavailable") end
end

local POLL_INTERVAL = 12          -- ~5 Hz at 60 fps
local KIT_HEAL_WINDOW = 240       -- frames to watch HP after a kit is used

local _frame = 0

-- Area
local _area_id = nil
local _area_seen = false          -- the area binding has produced an id at least once

-- Health
local _hp_bucket = nil
local _last_kits = nil
local _last_hp = nil
local _kit_watch = nil            -- { hp_before, best, until_frame, hp_max }

-- Weapons

local function thresholds()
    local t = config.state_low_health_thresholds or { 0.5, 0.25 }
    local sorted = {}
    for _, v in ipairs(t) do
        if type(v) == "number" and v > 0 and v < 1 then sorted[#sorted + 1] = v end
    end
    table.sort(sorted, function(a, b) return a > b end)   -- 0.5, 0.25, ...
    return sorted
end

-- 0 = above every threshold; k = below the k-th (descending) threshold.
local function bucket_of(ratio, ts)
    local b = 0
    for i, t in ipairs(ts) do
        if ratio < t then b = i end
    end
    return b
end

-- The weapon baseline is NOT dropped here: a load is caught instead by the
-- size guard in poll_weapons (more than MAX_EQUIP_CHANGES at once), and an
-- empty mid-load reading is skipped.
local function reset_baselines()
    _area_id = nil
    _hp_bucket = nil
    _last_kits, _last_hp, _kit_watch = nil, nil, nil
end

-- True once the area push is known to work, so world_state can drop its
-- generic "entered a new area" line instead of doubling up.
function M.covers_area_changes()
    return config.state_push_area_summary == true and _area_seen
end

-- ---------------------------------------------------------------------------
-- Pollers
-- ---------------------------------------------------------------------------

local function poll_area()
    if game_state.area == nil then return end
    -- Sector + area, both from the loaded scene: a walk into a new place is an
    -- edge even though the checkpoint (elevator-only) has not changed.
    local ok, id = pcall(game_state.area.current_location_key)
    if not ok or id == nil then return end
    _area_seen = true
    if _area_id == nil then _area_id = id return end   -- baseline
    if id == _area_id then return end
    _area_id = id
    if config.state_push_area_summary ~= true then return end
    local ok_r, a = pcall(game_state.area.read)
    if ok_r and a ~= nil then
        emit.narrative("Hugh and Diana entered a new area. " .. game_state.location_text(a))
    else
        emit.narrative("Hugh and Diana entered a new area.")
    end
end

local function poll_health()
    local v = game_state.health_state()
    if v == nil or v.hp == nil then return end

    -- Kit heal measurement.
    if _kit_watch ~= nil then
        if v.hp > _kit_watch.best then _kit_watch.best = v.hp end
        if _frame >= _kit_watch.until_frame then
            local gained = math.floor(_kit_watch.best - _kit_watch.hp_before + 0.5)
            -- A gain that hits the cap only proves "at least this much".
            local capped = v.hp_max ~= nil and _kit_watch.best >= v.hp_max - 0.5
            if gained > 0 and not capped then
                game_state.observed_kit_heal = { heal = gained, hp_max = v.hp_max }
                log.info("game_state_observer: repair kit healed " .. tostring(gained) .. " HP")
            end
            _kit_watch = nil
        end
    end
    if v.kits ~= nil and _last_kits ~= nil and v.kits < _last_kits and _last_hp ~= nil then
        _kit_watch = { hp_before = _last_hp, best = v.hp, until_frame = _frame + KIT_HEAL_WINDOW }
    end
    _last_kits, _last_hp = v.kits, v.hp

    -- Low-health push.
    if v.hp_max == nil or v.hp_max <= 0 or v.hp <= 0 then return end
    local ratio = v.hp / v.hp_max
    local ts = thresholds()
    local b = bucket_of(ratio, ts)
    local prev = _hp_bucket
    _hp_bucket = b
    if prev == nil or b <= prev then return end          -- baseline, or healing
    if config.state_push_low_health ~= true then return end

    local kits = ""
    if v.kits ~= nil then
        kits = string.format(" with %d repair kit%s left", v.kits, v.kits == 1 and "" or "s")
    end
    emit.narrative(string.format("Hugh is down to %d%% HP (%d/%d)%s.",
        math.floor(ratio * 100 + 0.5), math.floor(v.hp + 0.5),
        math.floor(v.hp_max + 0.5), kits))
end

local WEAPON_EVENTS_MAX = 16

-- For Pragmata State Debug: what the weapon check saw, newest first.
M.weapon_events = {}

local function weapon_event(text)
    table.insert(M.weapon_events, 1, { frame = _frame, text = text })
    while #M.weapon_events > WEAPON_EVENTS_MAX do table.remove(M.weapon_events) end
end

-- Diff one sorted id list against its last reading. Returns the added ids,
-- or nil for "nothing to announce" (unchanged, baseline, only losses, or a
-- jump too large to be a pickup). `label` names the list in the event log.
-- Live readout for the debug panel: what the last poll of each equip list
-- read, so "no change seen" can be told apart from "nothing read at all".
M.weapon_live = { frame = nil, equipped = "not read yet", hacking = "not read yet" }

-- Most changes one poll may make and still be believed. A pickup or a swap is
-- one item in, maybe one out; a larger jump is a save load or a bad read.
local MAX_EQUIP_CHANGES = 2

-- An equip tracker compares the set of equipped ids (no ammo, no uses left)
-- with the last accepted reading and announces each id that became equipped
-- or stopped being equipped.
--   read()      -> sorted id list, or nil
--   name(id)    -> display name
--   label       -> "Weapon" / "Hacking mod" (message and log prefix)
--   live_key    -> field of M.weapon_live for the debug readout
--   switch      -> mod_config field that turns the push on
-- An empty reading is skipped when allow_empty is false: it is what a load
-- looks like mid-way (the main weapon is always equipped in play). Hacking
-- mods can legitimately all be unequipped, so they allow it.
local function equip_tracker(t)
    local last, pending = nil, nil
    t.reset = function() last, pending = nil, nil end
    t.poll = function()
        local ok, ids = pcall(t.read)
        M.weapon_live.frame = _frame
        if not ok or ids == nil or (#ids == 0 and not t.allow_empty) then
            M.weapon_live[t.live_key] = (ok and ids ~= nil) and "nothing read"
                or (ok and "unavailable" or ("error: " .. tostring(ids)))
            return
        end
        M.weapon_live[t.live_key] = #ids > 0 and table.concat(ids, ", ") or "(none)"

        local key = table.concat(ids, ",")
        if last ~= nil and last.key == key then pending = nil return end
        -- A change counts only once two polls in a row agree on it (~0.4 s),
        -- so a one-poll glitch mid-transition is never announced.
        if last ~= nil and pending ~= key then pending = key return end
        pending = nil
        local now = {}
        for _, id in ipairs(ids) do now[id] = true end
        local previous = last
        last = { key = key, set = now }
        if previous == nil then
            weapon_event(string.format("%s baseline: %d equipped", t.label, #ids))
            return
        end

        local added, removed = {}, {}
        for id in pairs(now) do
            if not previous.set[id] then added[#added + 1] = id end
        end
        for id in pairs(previous.set) do
            if not now[id] then removed[#removed + 1] = id end
        end
        if #added > MAX_EQUIP_CHANGES or #removed > MAX_EQUIP_CHANGES then
            weapon_event(string.format("%s +%d / -%d at once: taken as a load, not announced",
                t.label, #added, #removed))
            return
        end

        local function names(list)
            local out = {}
            for _, id in ipairs(list) do out[#out + 1] = t.name(id) end
            table.sort(out)
            return table.concat(out, ", ")
        end
        if #added > 0 then weapon_event(t.label .. " equipped: " .. names(added)) end
        if #removed > 0 then weapon_event(t.label .. " unequipped: " .. names(removed)) end
        if config[t.switch] ~= true then return end
        if #added > 0 then emit.narrative(t.label .. " equipped: " .. names(added) .. ".") end
        if #removed > 0 then emit.narrative(t.label .. " unequipped: " .. names(removed) .. ".") end
    end
    return t
end

-- Weapons. Round-5 test: a field pickup leaves the owned list alone (it moves
-- at checkpoints) but changes what is equipped.
local weapons = equip_tracker({
    label = "Weapon", live_key = "equipped", switch = "state_push_new_weapon",
    read = function()
        local lo = game_state.loadout
        if lo == nil or lo.equipped_ids == nil then return nil end
        return lo.equipped_ids()
    end,
    name = function(id) return game_state.loadout.weapon_name(id) end,
})

-- Hacking mods (Freeze, Multishot, ...). Uses left are not compared.
local hacking_mods = equip_tracker({
    label = "Hacking mod", live_key = "hacking", switch = "state_push_hacking_mods",
    allow_empty = true,
    read = function()
        local pk = game_state.perks
        if pk == nil or pk.equipped_hacking_ids == nil then return nil end
        return pk.equipped_hacking_ids()
    end,
    name = function(id) return game_state.perks.perk_name(id) end,
})

local function poll_weapons()
    weapons.poll()
    hacking_mods.poll()
end

local _unloaded = false

-- A poller that raises is logged (once per distinct message) instead of
-- vanishing into a bare pcall; a silently failing poll looks exactly like
-- "nothing changed".
local _last_error = {}
local function run(name, fn)
    local ok, err = pcall(fn)
    if ok then return end
    err = tostring(err)
    if _last_error[name] ~= err then
        _last_error[name] = err
        log.warn("game_state_observer: " .. name .. " poll failed: " .. err)
        if name == "weapons" then weapon_event("poll failed: " .. err) end
    end
end

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % POLL_INTERVAL) ~= 0 then return end

    if scene ~= nil then
        local ok, loaded = pcall(scene.is_loaded)
        if ok and loaded == false then
            if not _unloaded then weapon_event("world not loaded: polling paused") end
            _unloaded = true
            reset_baselines()
            return
        end
    end
    if _unloaded then weapon_event("world loaded: polling resumed") end
    _unloaded = false

    run("area", poll_area)
    run("health", poll_health)
    run("weapons", poll_weapons)
end)

return M
