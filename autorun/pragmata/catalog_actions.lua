-- Peer actions and pushes for the catalogs: the Data Library, the Archive, the Bot Database, the Training Simulations and
-- the Earth Memories.
--
-- All five are one `catalog` value of pragmata_archive_list /
-- pragmata_archive_info (the Shelter menus are read only while open, by
-- pragmata_menu_list, but the catalogs read right closed, so for them a
-- choice makes sense):
--   archive          the pause menu's Archive (the default) / full text
--   library          found entries' titles by category / full text of up to 8
--   bot_database     collected figures, how many are left / size, description
--   simulations      available simulations, cleared or not / rules, rewards
--   earth_memories   Earth Memories (Rem Replicators): owned and placed, by group
--
-- The pair is always registered. The Archive answers anywhere; the other
-- four only in the main Shelter or while their own screen is open, and
-- refuse with that reason elsewhere. Simulations that
-- are not run from the Training tab (extra, unnamed) are left out; New Game+
-- is not a reason, every real one carries that flag. Formatting only: the
-- reads go through bindings/catalogs.lua.
--
-- Pushes: a few times a minute the found / collected / available id sets are
-- compared with the last reading. A gain is pushed as silent context only
-- while in the Shelter (switches in mod_config); outside it the baseline just
-- moves. The Archive is the exception: it is in the pause menu, so a new
-- document is pushed wherever it is found. Every push carries the exact
-- pragmata_archive_info call that reads the new entries. A gain of more than MAX_GAIN at once is a load, not an
-- unlock, and is absorbed. Not-yet-found entries are only ever counted, never named.

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local config = require("pragmata.mod_config")
local json = require("pragmata.util.json_encode")
local name_match = require("pragmata.util.name_match")

local scene = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.scene")
    if ok then scene = mod end
end

local cat = nil                 -- bindings/catalogs.lua, set by register()
local gates = nil

local function join(list, sep) return table.concat(list, sep or ", ") end

local function clean(text)
    return (tostring(text):gsub("<[^>]*>", ""):gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read(fn_name, ...)
    if cat == nil or cat[fn_name] == nil then return nil end
    local ok, v = pcall(cat[fn_name], ...)
    if not ok then
        log.warn("catalog_actions: " .. fn_name .. " raised: " .. tostring(v))
        return nil
    end
    return v
end

local UNREADABLE = "That catalog could not be read just now."

-- ---------------------------------------------------------------------------
-- Data Library (Shelter terminal) and Archive (pause menu)
-- ---------------------------------------------------------------------------
--
-- The same narrative data, split by category: the binding's library() /
-- archive() take the terminal's or the pause menu's categories.

local NARRATIVE_TITLE = { library = "Data Library", archive = "Archive" }

local function entry_title(e) return e.title and clean(e.title) or "an untitled entry" end

local function narrative_entries(lib)
    local out = {}
    for _, c in ipairs(lib.categories) do
        for _, e in ipairs(c.entries) do
            e.name = entry_title(e)
            out[#out + 1] = e
        end
    end
    return out
end

local function narrative_list(menu)
    local lib = read(menu, false)
    if lib == nil then return false, UNREADABLE end
    local found, total = 0, 0
    for _, c in ipairs(lib.categories) do found, total = found + c.found, total + c.total end
    local lines = { string.format("%s: %d of %d entries found.", NARRATIVE_TITLE[menu], found, total) }
    for _, c in ipairs(lib.categories) do
        lines[#lines + 1] = string.format("%s (%d of %d):", c.name and clean(c.name) or "Unnamed category", c.found, c.total)
        if #c.entries == 0 then lines[#lines + 1] = "- nothing found yet" end
        for _, e in ipairs(c.entries) do
            lines[#lines + 1] = "- " .. entry_title(e) .. (e.group and (" [" .. clean(e.group) .. "]") or "")
        end
    end
    return true, join(lines, "\n")
end

local function narrative_detail(e)
    local where = {}
    if e.category then where[#where + 1] = clean(e.category) end
    if e.group then where[#where + 1] = clean(e.group) end
    local lines = { string.format("'%s'%s:", entry_title(e), #where > 0 and (" (" .. join(where) .. ")") or "") }
    local body = e.body and clean(e.body) or nil
    if body then lines[#lines + 1] = body end
    -- A one-page entry's page is its body again; it is not repeated.
    for i, p in ipairs(e.pages or {}) do
        local page = clean(p)
        if page ~= body then lines[#lines + 1] = string.format("[page %d] %s", i, page) end
    end
    if not e.body and #(e.pages or {}) == 0 then lines[#lines + 1] = "(its text could not be read)" end
    return join(lines, "\n")
end

local function narrative_info(menu, args)
    local lib = read(menu, true)
    if lib == nil then return false, UNREADABLE end
    return name_match.info_reply(narrative_entries(lib), args, narrative_detail, "\n\n")
end

local function library_list() return narrative_list("library") end
local function library_info(args) return narrative_info("library", args) end
local function archive_list() return narrative_list("archive") end
local function archive_info(args) return narrative_info("archive", args) end

-- ---------------------------------------------------------------------------
-- Bot Database
-- ---------------------------------------------------------------------------

local function figure_name(e) return e.name and clean(e.name) or "an unnamed figure" end

local function owned_figures(db)
    local out = {}
    for _, e in ipairs(db.entries) do
        if e.owned == true then
            e.name = figure_name(e)
            out[#out + 1] = e
        end
    end
    return out
end

local function bot_database_list()
    local db = read("bot_database")
    if db == nil then return false, UNREADABLE end
    local owned = owned_figures(db)
    local names = {}
    for _, e in ipairs(owned) do names[#names + 1] = e.name end
    local lines = { string.format("Bot Database: %d of %d figures collected.", #owned, #db.entries) }
    lines[#lines + 1] = "Collected: " .. (#names > 0 and join(names, "; ") or "none") .. "."
    return true, join(lines, "\n")
end

local function bot_database_detail(e)
    local s = e.name
    if e.length then s = s .. " (" .. clean(e.length) .. ")" end
    if e.description then s = s .. ": " .. clean(e.description) end
    return s
end

local function bot_database_info(args)
    local db = read("bot_database")
    if db == nil then return false, UNREADABLE end
    return name_match.info_reply(owned_figures(db), args, bot_database_detail)
end

-- ---------------------------------------------------------------------------
-- Training Simulations
-- ---------------------------------------------------------------------------

local function sim_name(e) return e.name and clean(e.name) or "an unnamed simulation" end

local function available_sims(s)
    local out = {}
    for _, e in ipairs(s.entries) do
        if e.available and e.skip == nil then
            e.name = sim_name(e)
            out[#out + 1] = e
        end
    end
    return out
end

local function sim_line(e)
    local s = e.name
    local tags = {}
    if e.category then tags[#tags + 1] = clean(e.category) end
    if e.extra == true then tags[#tags + 1] = "extra" end
    if #tags > 0 then s = s .. " (" .. join(tags) .. ")" end
    if e.cleared == true then s = s .. " - cleared"
    elseif e.cleared == false then s = s .. " - not cleared yet" end
    return s
end

local function simulations_list()
    local s = read("simulations")
    if s == nil then return false, UNREADABLE end
    local avail = available_sims(s)
    local cleared = 0
    for _, e in ipairs(avail) do if e.cleared == true then cleared = cleared + 1 end end
    local lines = { string.format("Training Simulations: %d available, %d of them cleared.", #avail, cleared) }
    for _, e in ipairs(avail) do lines[#lines + 1] = "- " .. sim_line(e) end
    local locked = 0
    for _, e in ipairs(s.entries) do
        if not e.available and e.skip == nil then locked = locked + 1 end
    end
    if locked > 0 then lines[#lines + 1] = string.format("%d more not unlocked yet.", locked) end
    return true, join(lines, "\n")
end

local function sim_detail(e)
    local lines = { sim_line(e) }
    if e.description then lines[#lines + 1] = "  " .. clean(e.description) end
    local sc = e.screen
    if sc == nil then
        lines[#lines + 1] = "  Rewards and rules are shown once the Training Simulations tab has been opened."
        return join(lines, "\n")
    end
    if sc.time_limit and sc.time_limit > 0 then
        lines[#lines + 1] = string.format("  Time limit: %d seconds.", math.floor(sc.time_limit + 0.5))
    end
    for _, rule in ipairs(sc.rules or {}) do lines[#lines + 1] = "  Rule: " .. clean(rule) end
    for _, rw in ipairs(sc.rewards or {}) do
        local s = "  Reward"
        if rw.title then s = s .. " for '" .. clean(rw.title) .. "'" end
        if rw.item then s = s .. ": " .. (rw.count and rw.count > 1 and (rw.count .. "x ") or "") .. clean(rw.item) end
        if rw.done == true then s = s .. " - earned" elseif rw.done == false then s = s .. " - not earned yet" end
        lines[#lines + 1] = s
    end
    return join(lines, "\n")
end

local function simulations_info(args)
    local s = read("simulations")
    if s == nil then return false, UNREADABLE end
    return name_match.info_reply(available_sims(s), args, sim_detail)
end

-- ---------------------------------------------------------------------------
-- Earth Memories (Rem Replicators)
-- ---------------------------------------------------------------------------

local function memory_name(e) return e.name and clean(e.name) or "an unnamed Earth Memory" end

local function memory_state(e)
    if e.placed then return "placed in the Shelter" end
    return "owned, not placed yet"
end

local function owned_memories(m)
    local out = {}
    for _, g in ipairs(m.groups) do
        for _, e in ipairs(g.entries) do
            if e.owned then
                e.name = memory_name(e)
                e.group_index = g.index
                out[#out + 1] = e
            end
        end
    end
    return out
end

local function earth_memories_list()
    local m = read("earth_memories", false)
    if m == nil then return false, UNREADABLE end
    local owned, placed, total = 0, 0, 0
    for _, g in ipairs(m.groups) do owned, placed, total = owned + g.owned, placed + g.placed, total + g.total end
    local lines = { string.format("Earth Memories: %d of %d owned, %d of them placed in the Shelter.", owned, total, placed) }
    for _, g in ipairs(m.groups) do
        lines[#lines + 1] = string.format("Group %d (%d of %d owned, %d placed):", g.index, g.owned, g.total, g.placed)
        local any = false
        for _, e in ipairs(g.entries) do
            if e.owned then
                any = true
                lines[#lines + 1] = "- " .. memory_name(e) .. " - " .. memory_state(e)
            end
        end
        if not any then lines[#lines + 1] = "- none owned yet" end
    end
    if not m.grouped then lines[#lines + 1] = "(Groups are read from Diana in the Shelter; not available right now.)" end
    return true, join(lines, "\n")
end

-- The game's description ends with a paragraph of its own, "This can be
-- given to Diana in the Shelter." Once the memory is placed that is no longer
-- true, so the last paragraph is dropped (by position, not by its wording,
-- so it works in every language).
local function without_last_paragraph(text)
    local cut = nil
    local from = 1
    while true do
        local s, e = text:find("\r?\n[ \t]*\r?\n", from)
        if s == nil then break end
        cut, from = s, e + 1
    end
    if cut == nil then return text end
    return text:sub(1, cut - 1)
end

local function earth_memory_detail(e)
    local s = string.format("%s (group %s) - %s", e.name, tostring(e.group_index), memory_state(e))
    local d = e.description
    if d and e.placed then d = without_last_paragraph(d) end
    if d then s = s .. ": " .. clean(d) end
    return s
end

local function earth_memories_info(args)
    local m = read("earth_memories", true)
    if m == nil then return false, UNREADABLE end
    return name_match.info_reply(owned_memories(m), args, earth_memory_detail)
end

-- ---------------------------------------------------------------------------
-- New-entry pushes
-- ---------------------------------------------------------------------------

local POLL_INTERVAL = 120         -- ~2 s at 60 fps
local MAX_GAIN = 6                -- more at once is a load, not an unlock
local _frame = 0

local function event(text)
    log.info("catalog_actions: " .. text)
end

-- One tracker per catalog.
--   ids()        -> { [id] = true-ish } or nil
--   names(added) -> list of display strings for the added ids
--   message      -> prefix of the pushed line
--   switch       -> mod_config field that turns the push on
--   allow_empty  -> an empty set is a real reading (nothing placed yet)
--   anywhere     -> push outside the Shelter too
--   compose(added) -> names, message: replaces names + message when the
--                   pushed line needs more than a list of names
--   catalog      -> the pragmata_archive_info `catalog` value; with it,
--                   names() also returns the entries' titles exactly as the
--                   list gives them, and the line ends with the call that
--                   reads them
local function read_call(catalog, titles)
    local call = json.encode({ catalog = catalog, names = titles, __keyorder = { "catalog", "names" } })
    return "Read " .. ((#titles == 1) and "it" or "them") .. " with pragmata_archive_info " .. call .. "."
end

local function tracker(t)
    local last, pending = nil, nil
    t.reset = function() last, pending = nil, nil end
    t.poll = function()
        local ok, ids = pcall(t.ids)
        if not ok or ids == nil then return end
        local n, list = 0, {}
        for id in pairs(ids) do n = n + 1 list[#list + 1] = id end
        if n == 0 and not t.allow_empty then return end   -- unread or mid-load
        table.sort(list)
        local key = table.concat(list, ",")
        if last ~= nil and last.key == key then pending = nil return end
        if last ~= nil and pending ~= key then pending = key return end
        pending = nil
        local previous = last
        last = { key = key, set = ids }
        if previous == nil then
            event(string.format("%s baseline: %d", t.label, n))
            return
        end
        local added = {}
        for id in pairs(ids) do
            if not previous.set[id] then added[#added + 1] = id end
        end
        if #added == 0 then return end
        if #added > MAX_GAIN then
            event(string.format("%s +%d at once: taken as a load, not announced", t.label, #added))
            return
        end
        local names, message, titles = nil, nil, nil
        if t.compose ~= nil then
            local okc, n2, m2 = pcall(t.compose, added)
            if okc then names, message = n2, m2 end
        else
            local okn, n2, t2 = pcall(t.names, added)
            if okn then names, titles = n2, t2 end
        end
        if names == nil or #names == 0 then names, message, titles = { #added .. " new" }, nil, nil end
        if message == nil then
            message = t.message .. join(names, "; ") .. "."
            if t.catalog ~= nil and titles ~= nil and #titles > 0 then
                message = message .. " " .. read_call(t.catalog, titles)
            end
        end
        local may_push = t.anywhere or (gates ~= nil and gates.in_shelter())
        event(string.format("%s gained: %s%s", t.label, join(names, "; "),
            may_push and "" or " (outside the Shelter: not pushed)"))
        if not may_push or config[t.switch] ~= true then return end
        emit.narrative(message)
    end
    return t
end

local library_tracker = tracker({
    label = "Data Library", switch = "catalog_push_library", allow_empty = true,
    catalog = "library",
    message = "New Data Library entry: ",
    ids = function() return read("library_ids") end,
    names = function(added)
        local want = {}
        for _, id in ipairs(added) do want[id] = true end
        local lib = read("library", false)
        local out, titles = {}, {}
        for _, c in ipairs(lib and lib.categories or {}) do
            for _, e in ipairs(c.entries) do
                if want[e.id] then
                    out[#out + 1] = string.format("'%s'%s", entry_title(e),
                        c.name and (" in " .. clean(c.name)) or "")
                    titles[#titles + 1] = entry_title(e)
                end
            end
        end
        return out, titles
    end,
})

-- The Archive: anywhere, with where to find each new document and the call
-- that reads it. The titles are entry_title()'s, exactly as
-- pragmata_archive_list shows them, so the suggested call resolves.
local archive_tracker = tracker({
    label = "Archive", switch = "catalog_push_archive", anywhere = true,
    -- An empty Archive is a real reading (archive_ids is nil while unread),
    -- so the very first document found is announced, not taken as baseline.
    allow_empty = true,
    ids = function() return read("archive_ids") end,
    compose = function(added)
        local want = {}
        for _, id in ipairs(added) do want[id] = true end
        local lib = read("archive", false)
        local names, parts, titles = {}, {}, {}
        for _, c in ipairs(lib and lib.categories or {}) do
            for _, e in ipairs(c.entries) do
                if want[e.id] then
                    local title = entry_title(e)
                    local where = c.name and clean(c.name) or "an unnamed category"
                    names[#names + 1] = string.format("'%s' in %s", title, where)
                    parts[#parts + 1] = names[#names]
                    titles[#titles + 1] = title
                end
            end
        end
        if #titles == 0 then return nil, nil end
        local call = json.encode({ names = titles })
        local head = (#titles == 1) and "New Archive entry: " or "New Archive entries: "
        return names, head .. join(parts, "; ") .. ". Read "
            .. ((#titles == 1) and "it" or "them") .. " with pragmata_archive_info " .. call .. "."
    end,
})

local bot_tracker = tracker({
    label = "Bot Database", switch = "catalog_push_bot_database", catalog = "bot_database",
    message = "New Bot Database figure: ",
    ids = function() return read("bot_database_ids") end,
    names = function(added)
        local want = {}
        for _, id in ipairs(added) do want[id] = true end
        local db = read("bot_database")
        local out = {}
        for _, e in ipairs(db and db.entries or {}) do
            if want[e.id] then out[#out + 1] = figure_name(e) end
        end
        return out, out
    end,
})

local sim_tracker = tracker({
    label = "Training Simulations", switch = "catalog_push_simulations", catalog = "simulations",
    message = "New Training Simulation available: ",
    ids = function() return read("simulation_ids") end,
    names = function(added)
        local want = {}
        for _, id in ipairs(added) do want[id] = true end
        local s = read("simulations")
        local out = {}
        for _, e in ipairs(s and s.entries or {}) do
            if want[e.id] then out[#out + 1] = sim_name(e) end
        end
        return out, out
    end,
})

local function memory_names(added)
    local want = {}
    for _, id in ipairs(added) do want[id] = true end
    local m = read("earth_memories", false)
    local out = {}
    for _, g in ipairs(m and m.groups or {}) do
        for _, e in ipairs(g.entries) do
            if want[e.id] then out[#out + 1] = memory_name(e) end
        end
    end
    return out, out
end

local memory_tracker = tracker({
    label = "Earth Memories owned", switch = "catalog_push_earth_memories", catalog = "earth_memories",
    message = "New Earth Memory: ",
    ids = function() return read("earth_owned_ids") end,
    names = memory_names,
})

-- Placing happens only in the Shelter, with Diana's cutscene.
local placed_tracker = tracker({
    label = "Earth Memories placed", switch = "catalog_push_earth_memories", catalog = "earth_memories",
    message = "Earth Memory placed in the Shelter: ",
    allow_empty = true,
    ids = function() return read("earth_placed_ids") end,
    names = memory_names,
})

local TRACKERS = { library_tracker, archive_tracker, bot_tracker, sim_tracker, memory_tracker, placed_tracker }

local _unloaded = false

local function poll()
    if scene ~= nil then
        local ok, loaded = pcall(scene.is_loaded)
        if ok and loaded == false then
            if not _unloaded then
                event("world not loaded: baselines dropped")
                for _, t in ipairs(TRACKERS) do t.reset() end
                if cat and cat.forget_screens then pcall(cat.forget_screens) end
            end
            _unloaded = true
            return
        end
    end
    _unloaded = false
    if cat.tick_screens then pcall(cat.tick_screens) end
    for _, t in ipairs(TRACKERS) do
        local ok, err = pcall(t.poll)
        if not ok then log.warn("catalog_actions: " .. t.label .. " poll failed: " .. tostring(err)) end
    end
end

-- The mod menu's "Rescan archive and catalogs": forget what was read and read
-- everything again. The next reading is a fresh baseline, so nothing already
-- found is announced as new.
function M.rescan()
    for _, t in ipairs(TRACKERS) do t.reset() end
    if cat and cat.forget_screens then pcall(cat.forget_screens) end
    log.info("catalog_actions: rescan requested from the mod menu")
end

-- ---------------------------------------------------------------------------
-- pragmata_archive_list / pragmata_archive_info (called once from
-- pragmata_main.lua at startup)
-- ---------------------------------------------------------------------------
--
-- Always registered: the Archive is in the pause menu and readable anywhere.
-- The `catalog` argument picks one of the Shelter's catalogs instead; each
-- of those has a gate (the main Shelter, or its own screen open), and a call
-- it does not pass is refused with the gate's reason.

local function unavailable() return false, "the catalog reader failed to load" end

-- In add() order: the order the enum and the refusals list them.
local CATALOGS = {}
local CATALOG_ORDER = {}

local function add_catalog(c)
    CATALOGS[c.key] = c
    CATALOG_ORDER[#CATALOG_ORDER + 1] = c.key
end

local function catalog_lines()
    local parts = {}
    for _, k in ipairs(CATALOG_ORDER) do parts[#parts + 1] = k .. " = " .. CATALOGS[k].about end
    return table.concat(parts, "; ")
end

-- The catalog for args.catalog (archive when absent), or nil + a refusal.
local function pick(args)
    local key = type(args) == "table" and args.catalog or nil
    if key == nil or key == "" then key = "archive" end
    local c = type(key) == "string" and CATALOGS[key] or nil
    if c == nil then
        return nil, "Unknown catalog '" .. tostring(key) .. "'. Use one of: "
            .. table.concat(CATALOG_ORDER, ", ") .. " (or leave it out for the Archive)."
    end
    if c.gate ~= nil then
        local ok, avail, reason = pcall(c.gate)
        if ok and avail == false then
            return nil, (c.label:gsub("^%l", string.upper)) .. " cannot be read right now"
                .. (reason and (": " .. reason) or "")
                .. ". It can be read anywhere in the main Shelter, or while its own screen is open."
        end
    end
    return c
end

local function guarded(c, fn, ...)
    if cat == nil then return unavailable() end
    local ok, success, message = pcall(fn, ...)
    if not ok then
        return false, (c.label:gsub("^%l", string.upper)) .. " could not be read: " .. tostring(success)
    end
    return success, message
end

function M.register(dispatcher, gates_mod, binding)
    cat, gates = binding, gates_mod
    local function where(key) return gates.any(gates.shelter_only, gates.menu_open(key)) end

    add_catalog({ key = "archive", label = "the Archive", list = archive_list, info = archive_info,
                  about = "the pause menu's documents, records and Help notes (the default; works anywhere)" })
    add_catalog({ key = "library", label = "the Data Library", list = library_list, info = library_info,
                  gate = where("library"),
                  about = "the Shelter terminal's found entries by category" })
    add_catalog({ key = "bot_database", label = "the Bot Database", list = bot_database_list,
                  info = bot_database_info, gate = where("bot_database"),
                  about = "figures collected; info gives size and description" })
    add_catalog({ key = "simulations", label = "the Training Simulations", list = simulations_list,
                  info = simulations_info, gate = where("simulations"),
                  about = "available simulations, cleared or not; info gives rules and rewards" })
    add_catalog({ key = "earth_memories", label = "the Earth Memories", list = earth_memories_list,
                  info = earth_memories_info, gate = where("replicator"),
                  about = "Rem Replicator items owned and placed, by group" })

    local catalog_prop = {
        type = "string", ["enum"] = CATALOG_ORDER,
        description = "Which to read: " .. catalog_lines()
            .. ". All but archive only in the main Shelter. Leave it out for the Archive.",
    }
    local info_schema = name_match.schema("entries of that catalog")
    info_schema.properties.catalog = catalog_prop
    info_schema.properties.__keyorder = { "catalog", "names" }

    dispatcher.register("pragmata_archive_list", {
        description = "List the Archive (the pause menu's documents, records and Help notes) or, "
            .. "with `catalog`, one of the Shelter's catalogs: every entry found or collected so "
            .. "far, with counts. The Archive works anywhere; the Shelter's catalogs in the main "
            .. "Shelter. Read-only.",
        short = "List the Archive, or one of the Shelter's catalogs with `catalog`. Read-only.",
        schema = { type = "object", properties = { catalog = catalog_prop } },
        handler = function(args)
            local c, why = pick(args)
            if c == nil then return false, why end
            return guarded(c, c.list)
        end,
    })
    dispatcher.register("pragmata_archive_info", {
        description = "The full text or details of up to 8 entries of the Archive or, with "
            .. "`catalog`, one of the Shelter's catalogs, by the names pragmata_archive_list "
            .. "gives for it. Same availability as pragmata_archive_list. Read-only.",
        short = "Details for up to 8 Archive or catalog entries, by name. Read-only.",
        schema = info_schema,
        handler = function(args)
            local c, why = pick(args)
            if c == nil then return false, why end
            return guarded(c, c.info, args)
        end,
    })

    re.on_frame(function()
        _frame = _frame + 1
        if (_frame % POLL_INTERVAL) ~= 0 or cat == nil then return end
        local ok, err = pcall(poll)
        if not ok then log.warn("catalog_actions: poll failed: " .. tostring(err)) end
    end)
end

return M
