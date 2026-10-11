-- Peer-facing descriptions of the player's state.
--
-- One describe_*() per read-only action (pragmata_weapons, pragmata_health,
-- pragmata_mods, pragmata_upgrades, pragmata_inventory, pragmata_location).
-- Each returns (ok, text) exactly like an action handler, so pragmata_main
-- can return it straight through.
--
-- This module only formats: every engine read happens in bindings/, which
-- hand back plain tables. A binding that failed to load, or a read that came
-- back nil, turns into a neutral reason ("not in gameplay") -- never into an
-- empty success, which the peer would take as "you have nothing".
--
-- The observer (game_state_observer.lua) feeds one thing back in: the HP
-- actually gained the last time a repair kit was used, which is a better
-- answer than the heal figure computed from the data tables.

local M = {}

local log = require("pragmata.util.log")

local function load_binding(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.error("game_state: failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

M.vitals    = load_binding("pragmata.bindings.player_vitals")
M.loadout   = load_binding("pragmata.bindings.loadout")
M.perks     = load_binding("pragmata.bindings.perks")
M.inventory = load_binding("pragmata.bindings.inventory")
M.area      = load_binding("pragmata.bindings.area_progress")

-- Set by game_state_observer: { heal = <hp gained>, hp_max = <max at the time> }
M.observed_kit_heal = nil

local NOT_IN_GAME = "not available right now (not in gameplay, or the game has not loaded this data yet)"

-- pcall a binding read; a raised error is logged and reads as nil.
local function read(mod, fn_name)
    if mod == nil or mod[fn_name] == nil then return nil end
    local ok, v = pcall(mod[fn_name])
    if not ok then
        log.warn("game_state: " .. fn_name .. " raised: " .. tostring(v))
        return nil
    end
    return v
end

local function level_text(level, level_max)
    if level == nil then return nil end
    if level_max ~= nil and level_max > 0 then
        return string.format("Lv %d/%d", level, level_max)
    end
    return "Lv " .. tostring(level)
end

local function join(list, sep)
    return table.concat(list, sep or ", ")
end

-- ---------------------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------------------

function M.health_state()
    return read(M.vitals, "read")
end

function M.kit_heal(v)
    local obs = M.observed_kit_heal
    if obs ~= nil and obs.heal ~= nil and obs.heal > 0 then return obs.heal, true end
    if v ~= nil and v.heal_per_kit ~= nil and v.heal_per_kit > 0 then return v.heal_per_kit, false end
    return nil, false
end

function M.describe_health()
    if M.vitals == nil then return false, "health binding not loaded" end
    local v = M.health_state()
    if v == nil or v.hp == nil then return true, "Health " .. NOT_IN_GAME .. "." end

    local parts = {}
    if v.hp_max ~= nil and v.hp_max > 0 then
        parts[#parts + 1] = string.format("HP %d/%d (%d%%).",
            math.floor(v.hp + 0.5), math.floor(v.hp_max + 0.5),
            math.floor((v.hp / v.hp_max) * 100 + 0.5))
    else
        parts[#parts + 1] = string.format("HP %d.", math.floor(v.hp + 0.5))
    end

    if v.kits ~= nil then
        local kits = string.format("Repair kits: %d", v.kits)
        if v.kits_max ~= nil and v.kits_max > 0 then
            kits = kits .. string.format(" of %d carried", v.kits_max)
        end
        parts[#parts + 1] = kits .. "."
    elseif v.kits_max ~= nil then
        parts[#parts + 1] = string.format("Repair kits: count unknown (up to %d can be carried).", v.kits_max)
    end

    local heal, observed = M.kit_heal(v)
    if heal ~= nil then
        parts[#parts + 1] = string.format("Each repair kit restores about %d HP%s.",
            heal, observed and " (measured on the last use)" or "")
    end
    return true, join(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------------

local function weapon_line(w)
    local bits = { w.name }
    local tags = {}
    if w.main then tags[#tags + 1] = "main weapon" end
    if w.slot ~= nil and not w.main then tags[#tags + 1] = tostring(w.slot) .. " slot" end
    if #tags > 0 then bits[#bits + 1] = "(" .. join(tags) .. ")" end
    local lv = level_text(w.level, w.level_max)
    if lv then bits[#bits + 1] = lv end
    if w.ammo ~= nil then
        if w.ammo_max ~= nil and w.ammo_max > 0 then
            bits[#bits + 1] = string.format("ammo %d/%d", w.ammo, w.ammo_max)
        else
            bits[#bits + 1] = string.format("ammo %d", w.ammo)
        end
    end
    return join(bits, " ")
end

function M.describe_weapons()
    if M.loadout == nil then return false, "weapon binding not loaded" end
    local l = read(M.loadout, "read")
    if l == nil then return true, "Weapons " .. NOT_IN_GAME .. "." end
    if #l.weapons == 0 then return true, "No weapons are owned yet." end

    local equipped, other = {}, {}
    for _, w in ipairs(l.weapons) do
        if w.equipped or w.main then equipped[#equipped + 1] = weapon_line(w)
        else other[#other + 1] = weapon_line(w) end
    end
    local parts = {}
    if #equipped > 0 then parts[#parts + 1] = "Equipped: " .. join(equipped, "; ") .. "." end
    if #other > 0 then parts[#parts + 1] = "Also owned: " .. join(other, "; ") .. "." end
    return true, join(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Mods
-- ---------------------------------------------------------------------------

local function perk_line(e)
    local s = e.name
    local lv = level_text(e.level, e.level_max)
    if lv then s = s .. " " .. lv end
    if e.uses ~= nil then
        if e.uses_max ~= nil and e.uses_max > 0 then
            s = s .. string.format(", %d/%d uses left", e.uses, e.uses_max)
        else
            s = s .. string.format(", %d uses left", e.uses)
        end
    end
    return s
end

-- Description text as one line: markup tags out, the game's hard line breaks
-- and runs of spaces folded.
local function one_line(text)
    return (tostring(text):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Equipped mods only, one per line with what each does. Mods owned but not
-- equipped are left out on purpose: pragmata_mod_terminal_list covers them
-- at the train terminal, where they can be equipped.
local function perk_group(title, g)
    local head = title .. " equipped"
    if g.capacity ~= nil and g.capacity > 0 then
        head = head .. string.format(" (%d/%d slots)", #g.equipped, g.capacity)
    end
    if #g.equipped == 0 then return head .. ": none." end
    local lines = { head .. ":" }
    for _, e in ipairs(g.equipped) do
        -- Mods without levels read "Lv 0" with no maximum; that is noise.
        local s = "- " .. ((e.level == 0 and (e.level_max == nil or e.level_max == 0)) and e.name or perk_line(e))
        if e.description ~= nil then s = s .. ": " .. one_line(e.description) end
        lines[#lines + 1] = s
    end
    return join(lines, "\n")
end

function M.describe_mods()
    if M.perks == nil then return false, "mods binding not loaded" end
    local m = read(M.perks, "read_mods")
    if m == nil then return true, "Mods " .. NOT_IN_GAME .. "." end
    local parts = { perk_group("Mods", m.mods), perk_group("Hacking mods", m.hacking_mods) }

    -- The equipped hacking style changes what the grid's bonus nodes do, so it
    -- belongs with the hacking mods. Read through the snake binding, which
    -- already decodes it.
    local snake = package.loaded["pragmata.bindings.puzzle_snake"]
    if snake and snake.read_hacking_mode then
        local ok, mode = pcall(snake.read_hacking_mode)
        if ok and mode and mode.ok and mode.style then
            parts[#parts + 1] = "Hacking style: " .. tostring(mode.style) .. "."
        end
    end
    return true, join(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Upgrades
-- ---------------------------------------------------------------------------

function M.describe_upgrades()
    if M.perks == nil then return false, "upgrades binding not loaded" end
    local u = read(M.perks, "read_upgrades")
    if u == nil then return true, "Upgrades " .. NOT_IN_GAME .. "." end

    local parts = {}
    local fw_hack, fw_other = {}, {}
    for _, e in ipairs(u.firmware) do
        if e.hacking then fw_hack[#fw_hack + 1] = perk_line(e)
        else fw_other[#fw_other + 1] = perk_line(e) end
    end
    if #fw_other + #fw_hack == 0 then
        parts[#parts + 1] = "Firmware upgrades: none yet."
    else
        if #fw_other > 0 then parts[#parts + 1] = "Firmware upgrades (suit / weapon): " .. join(fw_other, "; ") .. "." end
        if #fw_hack > 0 then parts[#parts + 1] = "Firmware upgrades (hacking): " .. join(fw_hack, "; ") .. "." end
    end

    -- Unit Printer: weapon levels and ability levels.
    local printer = {}
    local l = read(M.loadout, "read")
    if l ~= nil then
        for _, w in ipairs(l.weapons) do
            local lv = level_text(w.level, w.level_max)
            if lv then printer[#printer + 1] = w.name .. " " .. lv end
        end
    end
    for _, e in ipairs(u.abilities) do
        local lv = level_text(e.level, e.level_max)
        if lv then printer[#printer + 1] = e.name .. " " .. lv end
    end
    if #printer > 0 then
        parts[#parts + 1] = "Unit Printer levels: " .. join(printer, "; ") .. "."
    end
    return true, join(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

-- Most distinct items listed before the rest are summarised.
local INVENTORY_LIMIT = 40

function M.describe_inventory()
    if M.inventory == nil then return false, "inventory binding not loaded" end
    local items = read(M.inventory, "read")
    if items == nil then return true, "Inventory " .. NOT_IN_GAME .. "." end
    if #items == 0 then return true, "Nothing is held." end

    -- Distinct items can share one display name (six different "Training
    -- Data"). They are merged into one entry with the total; where the game
    -- tells them apart on the item page, those headers are listed after it.
    local by_kind, order, unnamed = {}, {}, 0
    for _, it in ipairs(items) do
        if not it.named then
            unnamed = unnamed + 1
        else
            local kind = it.kind or "Other"
            local group = by_kind[kind]
            if group == nil then
                group = { names = {}, order = {} }
                by_kind[kind] = group
                order[#order + 1] = kind
            end
            local e = group.names[it.name]
            if e == nil then
                e = { name = it.name, quantity = 0, details = {}, seen = {} }
                group.names[it.name] = e
                group.order[#group.order + 1] = e
            end
            e.quantity = e.quantity + it.quantity
            if it.detail ~= nil and not e.seen[it.detail] then
                e.seen[it.detail] = true
                e.details[#e.details + 1] = it.detail
            end
        end
    end
    local parts, listed, total = {}, 0, 0
    for _, kind in ipairs(order) do
        local lines = {}
        for _, e in ipairs(by_kind[kind].order) do
            total = total + 1
            if listed < INVENTORY_LIMIT then
                local s = string.format("%s x%d", e.name, e.quantity)
                if #e.details > 0 then s = s .. " (" .. join(e.details, "; ") .. ")" end
                lines[#lines + 1] = s
                listed = listed + 1
            end
        end
        if #lines > 0 then parts[#parts + 1] = kind .. ": " .. join(lines) .. "." end
    end
    local rest = total - listed
    if rest > 0 then parts[#parts + 1] = string.format("(+%d more items)", rest) end
    if unnamed > 0 then
        parts[#parts + 1] = string.format("(+%d item(s) the game gives no name for)", unnamed)
    end
    if #parts == 0 then return true, "Only unnamed items are held." end
    return true, "Held: " .. join(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Location
-- ---------------------------------------------------------------------------

-- Shared by the action and the area-change push.
function M.location_text(a)
    local parts = {}
    -- Sector first, then the area inside it, as the map screen nests them.
    if a.sector ~= nil and a.name ~= nil then
        parts[#parts + 1] = "Current location: " .. a.sector .. ", " .. a.name .. "."
    elseif a.sector ~= nil then
        parts[#parts + 1] = "Current location: " .. a.sector .. "."
    elseif a.name ~= nil then
        parts[#parts + 1] = "Current area: " .. a.name .. "."
    elseif a.near ~= nil then
        parts[#parts + 1] = "Current area has no name on the map; the last elevator checkpoint used was "
            .. a.near .. " (it may be some way back)."
    else
        parts[#parts + 1] = "Current area has no name on the map."
    end
    if a.gather_pct ~= nil then
        parts[#parts + 1] = string.format("Map completion here: %d%%.", a.gather_pct)
    end
    if a.per_item_known and a.total ~= nil and a.total > 0 then
        local left = a.total - (a.collected or 0)
        if left <= 0 then
            parts[#parts + 1] = "Everything placed here has been collected."
        else
            local groups = {}
            for _, g in ipairs(a.remaining or {}) do
                groups[#groups + 1] = string.format("%dx %s", g.count, g.label)
            end
            parts[#parts + 1] = string.format("Still to collect (%d of %d): %s.",
                left, a.total, join(groups))
        end
    elseif a.total == 0 then
        parts[#parts + 1] = "The map lists no collectibles here."
    end
    return join(parts, " ")
end

function M.describe_location()
    if M.area == nil then return false, "location binding not loaded" end
    local a = read(M.area, "read")
    if a == nil then return true, "Location " .. NOT_IN_GAME .. "." end
    return true, M.location_text(a)
end

return M
