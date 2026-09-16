-- Binding for the sliding-tile pipe hack (app.PuzzleSlidePipe).
--
-- A board of pipe tiles with one empty space. Sliding a tile into the gap moves
-- the gap the other way; the hack completes when an unbroken pipe runs from the
-- source to the goal. The engine calls the gap's travel direction the input
-- direction (Board.moveInput / moveEmpty both take one), so that is the
-- vocabulary used with the peer too.
--
-- UNVERIFIED. This family has never been seen in a capture and everything here
-- is written against the type dump: the board reader, the meaning of the _Pipe
-- bitmask, and above all whether the direction commands drive it at all. It is
-- gated behind mod_config.puzzle_kinds.slide, which ships OFF. Turn it on, check
-- the Puzzle Debug panel's peer view against a real one, and only then trust it.

local log = require("pragmata.util.log")
local registry = require("pragmata.bindings.puzzle_registry")
local input = require("pragmata.bindings.puzzle_input")
local plan_lib = require("pragmata.bindings.puzzle_plan")
local render = require("pragmata.util.puzzle_render")

local M = {}

M.kind = "slide"
M.action_name = "pragmata_hack_slide"
M.force_query = "A pipe hack is live. Call pragmata_hack_slide with the "
             .. "directions the empty space should travel."

local P = plan_lib.new({ kind = "slide" })

local store = registry.make_store(function(rec)
    P.resolve(rec, false, "the hack ended before the slides finished")
end)


local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Fixed-arity call helpers. Varargs would need table.unpack, which is Lua 5.2+;
-- REFramework's Lua version varies across builds and this codebase sticks to
-- what loads everywhere.
local function call0(m, obj)
    if m == nil or obj == nil then return nil end
    return safe(function() return m:call(obj) end)
end

local function call2(m, obj, a, b)
    if m == nil or obj == nil then return nil end
    return safe(function() return m:call(obj, a, b) end)
end

-- Arithmetic power-of-two test; see bindings/player_status.lua for why this
-- codebase avoids Lua 5.3+ bitwise operators entirely.
local function is_power_of_two(v)
    if type(v) ~= "number" or v <= 0 then return false end
    local n = math.floor(v)
    if n ~= v then return false end
    while n > 1 do
        if n % 2 ~= 0 then return false end
        n = n / 2
    end
    return n == 1
end


-- --------------------------------------------------------------------
-- Type resolution
-- --------------------------------------------------------------------
local _sdk = { inited = false }

local function ensure_init()
    if _sdk.inited then return _sdk.board_td ~= nil end
    _sdk.inited = true

    local function td(name) return safe(function() return sdk.find_type_definition(name) end) end
    local function method(t, sig)
        if t == nil then return nil end
        return safe(function() return t:get_method(sig) end)
    end

    _sdk.board_td = td("app.PuzzleSlidePipe.Board")
    _sdk.grid_td  = td("app.PuzzleSlidePipe.Grid")

    _sdk.m_len_x   = method(_sdk.board_td, "get_LengthX()") or method(_sdk.board_td, "get_LengthX")
    _sdk.m_len_y   = method(_sdk.board_td, "get_LengthY()") or method(_sdk.board_td, "get_LengthY")
    _sdk.m_item    = method(_sdk.board_td, "get_Item(System.Int32, System.Int32)")
    _sdk.m_empty   = method(_sdk.board_td, "get_EmptyPosition()") or method(_sdk.board_td, "get_EmptyPosition")
    _sdk.m_complete = method(_sdk.board_td, "isComplete()") or method(_sdk.board_td, "isComplete")

    if _sdk.board_td == nil then
        log.warn("puzzle_slide: app.PuzzleSlidePipe.Board not found; binding disabled")
        return false
    end
    return true
end


-- The _Pipe field is a raw bitmask of which sides a tile opens onto. The dump
-- gives no dedicated enum for it, so the Direction constants are used as the
-- bits -- they are the only Up/Down/Left/Right set this type declares. If they
-- turn out not to be powers of two the decode yields nothing and the renderer
-- falls back to a neutral glyph, which is the safe failure.
local _pipe_bits = nil
local function decode_pipe(value)
    local v = registry.to_int(value)
    if v == nil then return {} end
    if _pipe_bits == nil then
        _pipe_bits = {}
        for name, bit in pairs(registry.enum_values("app.PuzzleSlidePipe.Direction")) do
            if bit ~= nil and bit > 0 and is_power_of_two(bit) then
                _pipe_bits[#_pipe_bits + 1] = { name = name:lower(), bit = bit }
            end
        end
        table.sort(_pipe_bits, function(a, b) return a.bit < b.bit end)
    end
    local out = {}
    for _, e in ipairs(_pipe_bits) do
        if registry.has_bit(v, e.bit) then out[#out + 1] = e.name end
    end
    return out
end


local function read_int2(v)
    if v == nil then return nil end
    local x = safe(function() return v.x end) or safe(function() return v:get_field("x") end)
    local y = safe(function() return v.y end) or safe(function() return v:get_field("y") end)
    if x == nil or y == nil then return nil end
    return { x = x, y = y }
end


-- --------------------------------------------------------------------
-- Current puzzle
-- --------------------------------------------------------------------
local function current_record()
    local active = registry.active_raw()
    if active == nil or active.kind ~= M.kind then return nil, active end
    return store.track(active.inst, active.unit), active
end

function M.current_puzzle_id()
    local rec = current_record()
    return rec and rec.id or nil
end

M.matched_puzzle_id = M.current_puzzle_id

function M.live_puzzle_ids()
    return store.live_ids()
end


-- --------------------------------------------------------------------
-- State
-- --------------------------------------------------------------------
local function read_state(rec)
    if rec == nil or not ensure_init() then return nil end
    local inst = rec.inst
    if not registry.is_alive(inst) then return nil end

    local board = safe(function() return inst:get_field("_Board") end)
    if board == nil then return nil end

    local w = call0(_sdk.m_len_x, board)
    local h = call0(_sdk.m_len_y, board)
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return nil end

    local cells = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local cell = call2(_sdk.m_item, board, x, y)
            if cell ~= nil then
                cells[#cells + 1] = {
                    x = x, y = y,
                    openings  = decode_pipe(safe(function() return cell:get_field("_Pipe") end)),
                    raw_pipe  = registry.to_int(safe(function() return cell:get_field("_Pipe") end)),
                    is_goal   = registry.read_bool(cell, "_IsGoal", false),
                    connected = registry.read_bool(cell, "<IsConnectedToGoal>k__BackingField", false),
                    passed    = registry.read_bool(cell, "<IsPass>k__BackingField", false),
                }
            end
        end
    end

    local base = registry.base_state(inst)
    local empty = read_int2(call0(_sdk.m_empty, board))
    if empty == nil then empty = read_int2(safe(function() return board:get_field("_EmptyPosition") end)) end

    return {
        kind     = M.kind,
        width    = w,
        height   = h,
        cells    = cells,
        empty    = empty,
        locked   = registry.read_bool(board, "_IsLocked", false),
        complete = call0(_sdk.m_complete, board) == true,
        playing  = base and base.playing or nil,
        success  = base and base.status_success or false,
        failed   = base and base.status_failed or false,
    }
end


function M.get_state(id)
    local rec = id and store.by_id(id) or current_record()
    return read_state(rec)
end


-- Tile positions are what the plan changes, so the fingerprint covers only the
-- board's shape and where its fixed features are.
local function struct_sig(state)
    if state == nil then return nil end
    local marks = {}
    for _, c in ipairs(state.cells) do
        if c.is_goal then marks[#marks + 1] = "g" .. c.x .. "," .. c.y end
    end
    table.sort(marks)
    return table.concat({ "slide", state.width, state.height, table.concat(marks, ";") }, "|")
end
M.struct_sig = struct_sig


function M.render_state()
    local state = M.get_state(nil)
    if state == nil then return render.unknown("pipe hack") end
    return render.slide(state)
end


function M.lifecycle()
    local rec = current_record()
    local blank = { started = false, changed = false, reset = false, success = false, failed = false }
    if rec == nil then return blank end
    local state = read_state(rec)
    if state == nil then return blank end
    return {
        started = registry.read_bool(rec.inst, "_InitTrg", false),
        changed = false,
        reset   = false,
        success = state.success or state.complete,
        failed  = state.failed,
    }
end


function M.is_interactive()
    local state = read_state(current_record())
    return state ~= nil and state.playing == true and not state.locked
end


-- --------------------------------------------------------------------
-- Force / plan plumbing
-- --------------------------------------------------------------------
function M.snapshot_force_target(id)
    local rec = store.by_id(id)
    P.snapshot(rec, struct_sig(read_state(rec)))
end

function M.clear_force_snapshot(id) P.clear_snapshot(store.by_id(id)) end

function M.struct_changed(id)
    local rec = store.by_id(id)
    return P.changed(rec, struct_sig(read_state(rec)))
end

function M.needs_force(id)
    local rec = store.by_id(id)
    return P.needs_force(rec, struct_sig(read_state(rec)))
end

function M.has_plan(id) return P.has_plan(store.by_id(id)) end

function M.discard_plan(id)
    local rec = store.by_id(id)
    if rec ~= nil then input.cancel(rec.id) end
    P.discard(rec)
end

function M.resolve_plan(id, ok, message) return P.resolve(store.by_id(id), ok, message) end
function M.current_plan_status() return P.status(current_record()) end
function M.consume_plan_events() return P.consume_events() end


function M.set_plan(id, moves, resolve)
    local rec = store.by_id(id)
    if rec == nil then return 0, false end

    local steps = {}
    for _, d in ipairs(moves or {}) do
        if input.is_direction(d) then steps[#steps + 1] = d end
    end
    if #steps == 0 then
        P.resolve(rec, false, "The plan contained no usable directions; nothing was slid.")
        return 0, false
    end

    local cur = current_record()
    local queued, parked = P.set_plan(rec, steps, resolve, cur ~= nil and cur.id == rec.id)
    log.info("puzzle_slide: plan for puzzle " .. tostring(id) .. " -- "
          .. tostring(queued) .. " slides, parked=" .. tostring(parked))
    return queued, parked
end


function M.tick_plan()
    local rec = current_record()
    if rec == nil or rec.plan == nil then return end
    if registry.is_game_paused() then return end

    local state = read_state(rec)
    if state == nil then return end

    if rec.plan.parked then
        rec.plan.parked = false
        P.push_event("resumed")
    end

    if P.changed(rec, struct_sig(state)) then
        input.cancel(rec.id)
        P.discard(rec)
        P.clear_snapshot(rec)
        P.resolve(rec, false, "The board changed before the plan could run; replanning.")
        P.push_event("grid_changed")
        return
    end

    if rec.dispatching or state.playing ~= true or state.locked then return end
    if #rec.plan.queue == 0 then return end

    local items = {}
    for i, direction in ipairs(rec.plan.queue) do
        items[i] = { command = direction, label = direction }
    end

    rec.dispatching = true
    local ok, err = input.queue_sequence(items, {
        owner    = rec.id,
        interval = input.interval_frames(rec.inst),
        -- Drained as presses land, not up front: see bindings/puzzle_buttons.lua.
        on_step  = function(index)
            if rec.plan ~= nil then
                rec.plan.executed = index
                table.remove(rec.plan.queue, 1)
            end
        end,
        on_done  = function(done_ok, reason)
            rec.dispatching = false
            if done_ok then
                local after = read_state(rec)
                if after ~= nil and not after.complete and after.playing == true then
                    P.discard(rec)
                    P.clear_snapshot(rec)
                    P.resolve(rec, false,
                        "The slides were applied but the pipe is still not complete.")
                end
            else
                P.discard(rec)
                if reason ~= "superseded" then
                    P.resolve(rec, false, "The slides could not be entered: " .. tostring(reason))
                    P.push_event("move_failed", { reason = reason })
                end
            end
        end,
    })
    if not ok then
        rec.dispatching = false
        P.discard(rec)
        P.resolve(rec, false, "Could not drive the board: " .. tostring(err))
    end
end


function M.debug_status()
    local rec, active = current_record()
    return {
        kind      = M.kind,
        puzzle_id = rec and rec.id or nil,
        type_name = active and active.type_name or nil,
        state     = read_state(rec),
        plan      = P.status(rec),
        input     = input.status(),
        note      = "unverified family -- written from the type dump only",
    }
end


return M
