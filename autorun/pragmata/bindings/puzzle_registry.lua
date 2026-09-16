-- Generic hacking-puzzle discovery, shared across every puzzle family.
--
-- The game has five hacking minigames and they all derive from one base type.
-- Only the enemy one (the cursor-routing grid, bindings/puzzle_snake.lua) was
-- ever bound, which is why environmental hacks -- switches, doors, elevators --
-- were completely invisible to the mod: they start, run and finish without a
-- single observer noticing.
--
-- This module is the part that is the SAME for all five:
--
--   * resolving which puzzle the player is currently aimed at, without hooks:
--       HackingManager.LastHackingTarget  -> a PuzzleUnit (the "socket")
--         -> PuzzleUnit.get_MyPuzzle()    -> the live puzzle instance
--         -> walk its type's parent chain -> which FAMILY it belongs to
--     Walking the parent chain is what makes the level-specific reskins and the
--     timer/advanced variants resolve to their family instead of falling through
--     as unknown.
--
--   * reading the fields the base type declares. Those sit at the same place on
--     every family, so they are the one lifecycle signal that works everywhere.
--
--   * minting stable ids and keeping per-instance records, so a family binding
--     doesn't have to reimplement instance bookkeeping.
--
-- Deliberately NOT done here: hooking the base type's success/onFailed/start
-- methods. They are virtuals that most concrete puzzles override, so a hook on
-- the base implementation would only ever see the families that DON'T override
-- them. Fields are polled instead; they don't lie.
--
-- Everything this module returns is neutral: ids, kind strings, booleans. No
-- engine object or type name leaves it except through debug_status().

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")

local M = {}

-- --------------------------------------------------------------------
-- Families
-- --------------------------------------------------------------------
-- Keyed by the type each family's chain terminates at. A puzzle's own type is
-- matched first, then each parent in turn, so:
--   app.AdvancedPuzzleCircuit -> PuzzleCircuitWithTimer -> PuzzleCircuit  = circuit
--   app.PuzzleButtonTimingNoRotate -> PuzzleButtonTiming                  = buttons
--   app.ch14100PuzzleSnake -> PuzzleSnake                                 = snake
local FAMILY_BY_TYPE = {
    ["app.PuzzleSnake"]           = "snake",
    ["app.PuzzleCircuit"]         = "circuit",
    ["app.PuzzleButtonTiming"]    = "buttons",
    ["app.PuzzleSlidePipe"]       = "slide",
    ["app.PuzzleThroughThePath"]  = "path",
}

-- Module path per family. All of these are loaded at boot by M.preload() and
-- through pcall, so a family whose binding is broken or whose types are missing
-- on this build costs nothing but a log line -- the others keep working.
local MODULE_BY_KIND = {
    snake   = "pragmata.bindings.puzzle_snake",
    circuit = "pragmata.bindings.puzzle_circuit",
    buttons = "pragmata.bindings.puzzle_buttons",
    slide   = "pragmata.bindings.puzzle_slide",
    path    = "pragmata.bindings.puzzle_path",
}

M.KINDS = { "snake", "circuit", "buttons", "slide", "path" }

-- Human-readable, spoiler-free names for the peer-facing context lines.
local KIND_LABEL = {
    snake   = "hacking grid",
    circuit = "circuit hack",
    buttons = "sequence hack",
    slide   = "pipe hack",
    path    = "path hack",
}

function M.kind_label(kind)
    return KIND_LABEL[kind] or "hack"
end


-- --------------------------------------------------------------------
-- Small reflection helpers
-- --------------------------------------------------------------------
local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function td(name)
    return safe(function() return sdk.find_type_definition(name) end)
end

local function method(t, sig)
    if t == nil then return nil end
    return safe(function() return t:get_method(sig) end)
end

-- Managed enums arrive as a wrapper or a plain number depending on the field
-- and the REFramework build; normalise both to a Lua number.
local function to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    return safe(function() return value:get_field("value__") end)
end
M.to_int = to_int

-- Read an enum type's members as { NAME = value }. This reads the constants the
-- GAME declares rather than hardcoding numbers, so a patch that renumbers an
-- enum degrades to "unknown member" instead of "confidently wrong". Cached.
local _enum_cache = {}
function M.enum_values(type_name)
    if _enum_cache[type_name] ~= nil then return _enum_cache[type_name] end
    local result = {}
    local t = td(type_name)
    if t ~= nil then
        for _, field in ipairs(safe(function() return t:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            local is_static = safe(function() return field:is_static() end)
            if is_static == true and type(name) == "string" and name ~= "value__" then
                local v = to_int(safe(function() return field:get_data(nil) end))
                if type(v) == "number" then result[name] = v end
            end
        end
    end
    -- An empty result is not cached: it means the type or its constants did not
    -- resolve on this call, and latching that would turn one early lookup into
    -- "every member unknown" for the rest of the session.
    if next(result) ~= nil then _enum_cache[type_name] = result end
    return result
end

-- Test whether one power-of-two bit is set.
--
-- Arithmetic rather than Lua 5.3+ `&`, and floor rather than `//`: REFramework's
-- Lua version varies across builds, so those are a SYNTAX error that would stop
-- this whole file from loading. Project-wide rule, same as
-- bindings/player_status.lua and bindings/puzzle_snake.lua.
-- Exact below 2^53; the largest app.puzzle.Status flag is 2^50, so there is no
-- precision loss. A negative mask means bit 63 came back signed -- no flag lives
-- up there, and reasoning about its low bits is not portable, so it reads false.
function M.has_bit(mask, bit)
    if type(mask) ~= "number" or type(bit) ~= "number" then return false end
    if bit <= 0 or mask <= 0 then return false end
    return (mask % (bit * 2)) >= bit
end

-- Liveness probe. A destroyed managed object throws on any reflection call, so
-- asking for its type is the cheapest "are you still there".
function M.is_alive(obj)
    if obj == nil then return false end
    return pcall(function() return obj:get_type_definition() end)
end

function M.type_name(obj)
    if obj == nil then return nil end
    return safe(function() return obj:get_type_definition():get_full_name() end)
end


-- --------------------------------------------------------------------
-- Init
-- --------------------------------------------------------------------
local _sdk = { inited = false }
local _init_report = {}

local function ensure_init()
    if _sdk.inited then return _sdk.base_td ~= nil end
    _sdk.inited = true

    _sdk.base_td        = td("app.PuzzleBase")
    _sdk.unit_td        = td("app.PuzzleUnit")
    _sdk.driver_td      = td("app.PuzzleDriver")
    _sdk.hacking_mgr_td = td("app.HackingManager")
    _sdk.pause_mgr_td   = td("app.PauseManager")

    _sdk.m_unit_get_puzzle  = method(_sdk.unit_td, "get_MyPuzzle()")
        or method(_sdk.unit_td, "get_MyPuzzle")
    _sdk.m_unit_is_gimmick  = method(_sdk.unit_td, "get_IsGimmick()")
        or method(_sdk.unit_td, "get_IsGimmick")
    _sdk.m_unit_is_enemy    = method(_sdk.unit_td, "get_IsEnemy()")
        or method(_sdk.unit_td, "get_IsEnemy")
    _sdk.m_base_get_state   = method(_sdk.base_td, "get_State()")
        or method(_sdk.base_td, "get_State")
    _sdk.m_get_is_jamming   = method(_sdk.hacking_mgr_td, "get_IsJamming()")
    _sdk.m_is_paused        = method(_sdk.pause_mgr_td, "isPaused()")
    _sdk.m_driver_current   = method(_sdk.driver_td, "get_CurrentPuzzle()")
        or method(_sdk.driver_td, "get_CurrentPuzzle")

    -- Enum constants, read from the game.
    _sdk.state_values  = M.enum_values("app.PuzzleBase.PuzzleState")
    _sdk.status_values = M.enum_values("app.puzzle.Status")
    _sdk.unit_types    = M.enum_values("app.PuzzleUnit.Type")

    _init_report = {
        base_td       = _sdk.base_td ~= nil,
        unit_td       = _sdk.unit_td ~= nil,
        driver_td     = _sdk.driver_td ~= nil,
        hacking_mgr   = _sdk.hacking_mgr_td ~= nil,
        get_my_puzzle = _sdk.m_unit_get_puzzle ~= nil,
        state_play    = _sdk.state_values.Play,
        state_stop    = _sdk.state_values.Stop,
        status_success = _sdk.status_values.Success,
        status_failed  = _sdk.status_values.Failed,
    }

    if _sdk.base_td == nil then
        log.warn("puzzle_registry: app.PuzzleBase type def not found; generic puzzle support disabled")
        return false
    end
    log.info("puzzle_registry: initialised (Play=" .. tostring(_sdk.state_values.Play)
          .. " Stop=" .. tostring(_sdk.state_values.Stop) .. ")")
    return true
end

function M.ready()
    return ensure_init()
end


-- --------------------------------------------------------------------
-- The HackingManager singleton
-- --------------------------------------------------------------------
local _hacking_mgr = nil
local function get_hacking_manager()
    if _hacking_mgr ~= nil then
        if M.is_alive(_hacking_mgr) then return _hacking_mgr end
        _hacking_mgr = nil
    end
    _hacking_mgr = safe(function()
        return sdk.get_managed_singleton("app.HackingManager")
    end)
    return _hacking_mgr
end


-- The PuzzleUnit the engine currently considers the hacking target. Note we do
-- NOT gate on <IsTargetedEnemy>: it means something narrower than "aimed at",
-- and for an environmental gimmick it is false by definition.
function M.target_unit()
    local mgr = get_hacking_manager()
    if mgr == nil then return nil end
    return safe(function() return mgr:get_field("<LastHackingTarget>k__BackingField") end)
end


-- Which family does this puzzle instance belong to? Walks the parent chain, so
-- subclasses resolve to the family they extend.
function M.kind_of(inst)
    if inst == nil then return nil end
    local t = safe(function() return inst:get_type_definition() end)
    local guard = 0
    while t ~= nil and guard < 16 do
        guard = guard + 1
        local name = safe(function() return t:get_full_name() end)
        if type(name) == "string" then
            local kind = FAMILY_BY_TYPE[name]
            if kind ~= nil then return kind end
        end
        t = safe(function() return t:get_parent_type() end)
    end
    return nil
end


-- --------------------------------------------------------------------
-- Base-type field reads (identical on every family)
-- --------------------------------------------------------------------
local function read_bool(inst, field, default)
    if inst == nil then return default end
    local v = safe(function() return inst:get_field(field) end)
    if v == nil then return default end
    return v == true
end
M.read_bool = read_bool

-- Snapshot of everything app.PuzzleBase declares that we care about. Returns a
-- plain table; `playing` is the normalised form of the PuzzleState enum.
function M.base_state(inst)
    if not ensure_init() or inst == nil then return nil end

    -- get_State() first, the raw field as the fallback. Same reasoning as
    -- unit_info: the accessor is the type's declared surface.
    local state_raw = nil
    if _sdk.m_base_get_state ~= nil then
        state_raw = to_int(safe(function() return _sdk.m_base_get_state:call(inst) end))
    end
    if state_raw == nil then
        state_raw = to_int(safe(function() return inst:get_field("_State") end))
    end
    local playing = nil
    local play_v = _sdk.state_values.Play
    local stop_v = _sdk.state_values.Stop
    if state_raw ~= nil and play_v ~= nil then
        if state_raw == play_v then playing = true
        elseif stop_v ~= nil and state_raw == stop_v then playing = false end
    end

    local open_status  = to_int(safe(function() return inst:get_field("_OpenStatus") end)) or 0
    local close_status = to_int(safe(function() return inst:get_field("_CloseStatus") end)) or 0

    -- The two status words are tested separately rather than OR'd together:
    -- combining them would need a bitwise operator, which this codebase does not
    -- use (see has_bit above).
    local sv = _sdk.status_values
    local function flag(bit)
        if bit == nil then return false end
        return M.has_bit(open_status, bit) or M.has_bit(close_status, bit)
    end

    return {
        state_raw       = state_raw,
        playing         = playing,
        open_status     = open_status,
        close_status    = close_status,
        status_success  = flag(sv.Success),
        status_failed   = flag(sv.Failed),
        status_open     = flag(sv.Open),
        status_close    = flag(sv.Close),
        status_jamming  = flag(sv.Jamming),
        init_trg        = read_bool(inst, "_InitTrg", false),
        failed_to_finish = read_bool(inst, "_FailedToFinish", false),
    }
end


-- The input state the puzzle families keep for themselves, for the debug panel.
--
-- Every family that reads directions carries the same four one-frame trigger
-- flags and the same four previous-frame flags, at the same names, so one reader
-- covers all of them. They matter because on mouse + keyboard the puzzle writes
-- these from the movement vector and then reads them back WITHOUT asking the
-- input layer anything -- so a direction flickering true here while the probe
-- reports "never asked about" is the whole diagnosis in one readout.
--
-- Which branch is actually in force is bindings/puzzle_mouse_mode.lua's to
-- answer, deliberately: it owns the hook on that call, and only it can ask
-- without its own question polluting the counter that says whether the ENGINE
-- reached the hook.
function M.input_debug_state(inst)
    if not ensure_init() or inst == nil then return nil end
    if not M.is_alive(inst) then return nil end

    -- nil rather than false for an absent field: a family that does not declare
    -- these must read as "no such thing", not as "not pressed".
    local function flag(name)
        local v = safe(function() return inst:get_field(name) end)
        if v == nil then return nil end
        return v == true
    end

    return {
        trg = {
            up    = flag("_TrgUp"),
            down  = flag("_TrgDown"),
            left  = flag("_TrgLeft"),
            right = flag("_TrgRight"),
        },
        prev = {
            up    = flag("_PrevUp"),
            down  = flag("_PrevDown"),
            left  = flag("_PrevLeft"),
            right = flag("_PrevRight"),
        },
    }
end


-- The socket the puzzle hangs off, and what kind of thing it is attached to.
function M.unit_info(unit)
    if not ensure_init() or unit == nil then return nil end

    -- Prefer the engine's own getters over the compiler-generated backing-field
    -- names: the getters are part of the type's surface, the backing fields are
    -- an implementation detail that a rebuild can rename.
    local function flag(getter, field)
        if getter ~= nil then
            local v = safe(function() return getter:call(unit) end)
            if v ~= nil then return v == true end
        end
        return read_bool(unit, field, false)
    end

    local is_gimmick = flag(_sdk.m_unit_is_gimmick, "<IsGimmick>k__BackingField")
    local is_enemy   = flag(_sdk.m_unit_is_enemy, "<IsEnemy>k__BackingField")
    local ttype      = to_int(safe(function() return unit:get_field("_TrailTargetType") end))
    if not is_gimmick and not is_enemy and ttype ~= nil then
        -- Fall back to the Type enum when the convenience flags are unset.
        local prop = _sdk.unit_types.Prop
        local enemy = _sdk.unit_types.Enemy
        if prop ~= nil and ttype == prop then is_gimmick = true end
        if enemy ~= nil and ttype == enemy then is_enemy = true end
    end
    return {
        is_gimmick = is_gimmick,
        is_enemy   = is_enemy,
        playable   = read_bool(unit, "_IsPlayablePuzzle", true),
        enabled    = read_bool(unit, "_Enabled", true),
        object_id  = to_int(safe(function() return unit:get_field("<ObjectID>k__BackingField") end)),
    }
end


-- Whole-game conditions that suppress hacking regardless of family.
function M.is_jamming()
    if not ensure_init() then return false end
    local mgr = get_hacking_manager()
    if mgr == nil or _sdk.m_get_is_jamming == nil then return false end
    local v = safe(function() return _sdk.m_get_is_jamming:call(mgr) end)
    return v == true
end

function M.is_game_paused()
    if not ensure_init() or _sdk.m_is_paused == nil then return false end
    local mgr = safe(function() return sdk.get_managed_singleton("app.PauseManager") end)
    if mgr == nil then return false end
    local v = safe(function() return _sdk.m_is_paused:call(mgr) end)
    return v == true
end


-- --------------------------------------------------------------------
-- Active puzzle
-- --------------------------------------------------------------------
-- Resolved once per frame and memoised, because every consumer (observer,
-- overlay, debug panel, each family's tick) asks for it.
local _active_cache = { frame = -1, value = nil }
local _frame = 0

function M.tick()
    _frame = _frame + 1
end

-- Returns { kind, inst, unit, unit_info, type_name } or nil.
function M.active_raw()
    if _active_cache.frame == _frame then return _active_cache.value end
    _active_cache.frame = _frame
    _active_cache.value = nil

    if not ensure_init() then return nil end

    local unit = M.target_unit()
    if unit == nil or not M.is_alive(unit) then return nil end

    local inst = nil
    if _sdk.m_unit_get_puzzle ~= nil then
        inst = safe(function() return _sdk.m_unit_get_puzzle:call(unit) end)
    end
    if inst == nil then
        inst = safe(function() return unit:get_field("_MyPuzzle") end)
    end
    if inst == nil or not M.is_alive(inst) then return nil end

    local kind = M.kind_of(inst)
    _active_cache.value = {
        kind      = kind,
        inst      = inst,
        unit      = unit,
        unit_info = M.unit_info(unit),
        type_name = M.type_name(inst),
    }
    return _active_cache.value
end


-- --------------------------------------------------------------------
-- Family bindings
-- --------------------------------------------------------------------
local _loaded = {}
local _load_failed = {}

-- Load one family, honouring the config gate. The outcome is latched either
-- way, so a family that is switched off or whose binding is broken costs one
-- log line rather than one per frame.
local function load_kind(kind)
    if kind == nil then return nil end
    if _loaded[kind] ~= nil then return _loaded[kind] end
    if _load_failed[kind] then return nil end

    -- Config gate. Snake is never gated -- it predates this table and turning it
    -- off would silently remove shipped behaviour.
    if kind ~= "snake" then
        local kinds = config.puzzle_kinds or {}
        if kinds[kind] == false then
            _load_failed[kind] = true
            log.info("puzzle_registry: family '" .. kind .. "' disabled by mod_config.puzzle_kinds")
            return nil
        end
    end

    local path = MODULE_BY_KIND[kind]
    if path == nil then
        _load_failed[kind] = true
        return nil
    end
    local ok, mod = pcall(require, path)
    if not ok or type(mod) ~= "table" then
        _load_failed[kind] = true
        log.error("puzzle_registry: failed to load " .. path .. ": " .. tostring(mod))
        return nil
    end
    _loaded[kind] = mod
    log.info("puzzle_registry: loaded family binding '" .. kind .. "'")
    return mod
end


-- Load every family up front. This is not an optimisation: it is the only time
-- `require` works at all.
--
-- REFramework's module search path contains reframework/autorun/ ONLY while it
-- is loading scripts at startup. A require first reached at runtime fails with
-- "module not found" against a path list that does not include this directory.
-- These bindings used to load on first sighting of a puzzle, which meant they
-- never loaded: the 2026-09-06 capture has circuit and buttons failing exactly
-- that way, minutes after boot, with both files sitting on disk. Everything
-- else in the mod happened to be reached at boot, which is why nothing had hit
-- this before -- and why the observer's runtime require of player_status looks
-- like a counter-example when it is only a package.loaded cache hit.
--
-- Snake is deliberately not listed: pragmata_main requires it directly, so it
-- is already loaded before anything here runs.
--
-- Called once from pragmata_main AFTER this module has finished loading, so
-- each family's own require of the registry is a completed-module cache hit
-- rather than a cycle.
function M.preload()
    for _, kind in ipairs(M.KINDS) do
        if kind ~= "snake" then load_kind(kind) end
    end
end


-- Snake is required directly by pragmata_main and hacking_debug already; this
-- just gives every family the same accessor. After preload() this is a table
-- lookup; the load path stays reachable for a family asked about before boot
-- finished, and would come back to life if a future REFramework fixed the path.
function M.binding_for(kind)
    return load_kind(kind)
end


-- The binding that should be driving right now, or nil when nothing hackable is
-- aimed at (or the active puzzle is a family we don't support on this build).
function M.active_binding()
    local a = M.active_raw()
    if a == nil or a.kind == nil then return nil end
    return M.binding_for(a.kind), a
end


-- Every family binding that is loaded, for the per-frame tick loop. preload()
-- fills this at boot, so it holds every family this install has enabled --
-- plus snake once the player has aimed at one.
function M.loaded_bindings()
    local list = {}
    for kind, mod in pairs(_loaded) do
        list[#list + 1] = { kind = kind, mod = mod }
    end
    return list
end


-- --------------------------------------------------------------------
-- Id minting + per-instance records
-- --------------------------------------------------------------------
-- Ids are unique across ALL families, so the observer can hold one in-flight id
-- without also tracking which family it came from.
local _next_id = 0
function M.next_id()
    _next_id = _next_id + 1
    return _next_id
end


-- A record store shared by the family bindings. Keeps one record per live puzzle
-- instance, deduped by object identity, with dead instances swept on access.
-- `on_dead(rec)` lets a family resolve a dangling deferred result rather than
-- leaving the peer waiting on a tool call that can never complete.
function M.make_store(on_dead)
    local store = { records = {} }

    function store.sweep()
        local kept = {}
        for _, rec in ipairs(store.records) do
            if M.is_alive(rec.inst) then
                kept[#kept + 1] = rec
            elseif on_dead then
                pcall(on_dead, rec)
            end
        end
        store.records = kept
    end

    function store.track(inst, unit)
        if inst == nil then return nil end
        store.sweep()
        for _, rec in ipairs(store.records) do
            if rec.inst == inst then
                rec.unit = unit or rec.unit
                return rec
            end
        end
        local rec = { id = M.next_id(), inst = inst, unit = unit }
        store.records[#store.records + 1] = rec
        return rec
    end

    function store.by_id(id)
        for _, rec in ipairs(store.records) do
            if rec.id == id then return rec end
        end
        return nil
    end

    function store.live_ids()
        store.sweep()
        local set = {}
        for _, rec in ipairs(store.records) do set[rec.id] = true end
        return set
    end

    return store
end


-- --------------------------------------------------------------------
-- Diagnostics
-- --------------------------------------------------------------------
function M.debug_status()
    ensure_init()
    local a = M.active_raw()
    local loaded = {}
    for kind in pairs(_loaded) do loaded[#loaded + 1] = kind end
    return {
        init         = _init_report,
        active_kind  = a and a.kind or nil,
        active_type  = a and a.type_name or nil,
        is_gimmick   = a and a.unit_info and a.unit_info.is_gimmick or false,
        is_enemy     = a and a.unit_info and a.unit_info.is_enemy or false,
        base         = a and M.base_state(a.inst) or nil,
        loaded_kinds = loaded,
        jamming      = M.is_jamming(),
        paused       = M.is_game_paused(),
    }
end


-- Enumerate every live puzzle the engine knows about, regardless of aim. Used by
-- the debug panel to confirm kind resolution while walking around, and by the
-- observer's cross-check that a completion wasn't missed.
function M.enumerate_live()
    if not ensure_init() then return {} end
    local mgr = get_hacking_manager()
    if mgr == nil then return {} end

    local drivers = safe(function() return mgr:get_field("_PuzzleDriverList") end)
    if drivers == nil then return {} end

    local count = safe(function() return drivers:get_field("_size") end)
    local items = safe(function() return drivers:get_field("_items") end)
    if count == nil or items == nil then return {} end

    local out = {}
    for i = 0, count - 1 do
        local driver = safe(function() return items[i] end)
        if driver ~= nil and _sdk.m_driver_current ~= nil then
            local puzzle = safe(function() return _sdk.m_driver_current:call(driver) end)
            if puzzle ~= nil and M.is_alive(puzzle) then
                out[#out + 1] = {
                    kind      = M.kind_of(puzzle),
                    type_name = M.type_name(puzzle),
                    playing   = (M.base_state(puzzle) or {}).playing,
                }
            end
        end
    end
    return out
end


return M
