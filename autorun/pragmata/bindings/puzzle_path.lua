-- Binding for the rotate-a-column path hack (app.PuzzleThroughThePath).
--
-- A board of path pieces where one row is rotatable. A selection moves along the
-- columns (_SelectingColumn) and the piece under it is turned in quarter steps
-- until an unbroken path runs across the board.
--
-- The peer addresses pieces by COLUMN, because that is what the selection moves
-- over. Dispatch walks the selection to each named column with left/right
-- presses and then turns it, which means the plan is executed in the same terms
-- a player would use.
--
-- UNVERIFIED. Never seen in a capture; the board reader, the meaning of the
-- rotatable row, and which command actually turns a piece are all inferred from
-- the type dump. Gated behind mod_config.puzzle_kinds.path, which ships OFF.
-- mod_config.puzzle_path_rotate_command exists precisely because the turning
-- input is the least certain part -- if the configured direction turns out to be
-- wrong, change it there rather than in code. It defaulted to "decide" until
-- PuzzleDecide was found to be a dead constant that nothing in the game reads;
-- whatever turns a piece here is one of the four directions.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local registry = require("pragmata.bindings.puzzle_registry")
local input = require("pragmata.bindings.puzzle_input")
local plan_lib = require("pragmata.bindings.puzzle_plan")
local render = require("pragmata.util.puzzle_render")

local M = {}

M.kind = "path"
M.action_name = "pragmata_hack_path"
M.force_query = "A path hack is live. Call pragmata_hack_path to turn pieces "
             .. "until a path runs across the board."

local P = plan_lib.new({ kind = "path" })

local store = registry.make_store(function(rec)
    P.resolve(rec, false, "the hack ended before the rotations finished")
end)


local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Fixed-arity call helper; see the note in bindings/puzzle_slide.lua about why
-- varargs (and therefore table.unpack) are avoided here.
local function call0(m, obj)
    if m == nil or obj == nil then return nil end
    return safe(function() return m:call(obj) end)
end


local _sdk = { inited = false }

local function ensure_init()
    if _sdk.inited then return _sdk.path_td ~= nil end
    _sdk.inited = true

    local function td(name) return safe(function() return sdk.find_type_definition(name) end) end
    local function method(t, sig)
        if t == nil then return nil end
        return safe(function() return t:get_method(sig) end)
    end

    _sdk.path_td = td("app.PuzzleThroughThePath")
    _sdk.grid_td = td("app.PuzzleThroughThePath.Grid")
    _sdk.m_rotatable_row = method(_sdk.path_td, "get_RotatableRow()")
        or method(_sdk.path_td, "get_RotatableRow")
    _sdk.m_is_5x5 = method(_sdk.path_td, "get_Is5x5()") or method(_sdk.path_td, "get_Is5x5")

    if _sdk.path_td == nil then
        log.warn("puzzle_path: app.PuzzleThroughThePath not found; binding disabled")
        return false
    end
    return true
end


local _path_bits = nil
local function decode_openings(value)
    local v = registry.to_int(value)
    if v == nil then return {} end
    if _path_bits == nil then
        _path_bits = {}
        for name, bit in pairs(registry.enum_values("app.PuzzleThroughThePath.PathType")) do
            if name ~= "None" and bit ~= nil and bit > 0 then
                _path_bits[#_path_bits + 1] = { name = name:lower(), bit = bit }
            end
        end
        table.sort(_path_bits, function(a, b) return a.bit < b.bit end)
    end
    local out = {}
    for _, e in ipairs(_path_bits) do
        if registry.has_bit(v, e.bit) or v == e.bit then out[#out + 1] = e.name end
    end
    return out
end


-- _Grids is a rank-2 managed array. REFramework exposes those inconsistently, so
-- both the two-index and the flattened accessor are tried; whichever the build
-- supports wins and the other is never called again.
local function grid_at(grids, x, y, width)
    if grids == nil then return nil end
    local v = safe(function() return grids[y][x] end)
    if v ~= nil then return v end
    v = safe(function() return grids:get_element(y * width + x) end)
    if v ~= nil then return v end
    return safe(function() return grids[y * width + x] end)
end


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


local function read_state(rec)
    if rec == nil or not ensure_init() then return nil end
    local inst = rec.inst
    if not registry.is_alive(inst) then return nil end

    -- Dimensions come from the authored userdata; the 5x5 flag is the fallback
    -- for a build where the userdata is not readable.
    local ud = safe(function() return inst:get_field("_UserData") end)
    local width = ud and registry.to_int(safe(function() return ud:get_field("_ColumnNum") end)) or nil
    local height = ud and registry.to_int(safe(function() return ud:get_field("_RowNum") end)) or nil
    if width == nil or height == nil then
        local five = call0(_sdk.m_is_5x5, inst) == true
        width = five and 5 or 3
        height = width
    end

    local grids = safe(function() return inst:get_field("_Grids") end)
    local cells = {}
    local rotatable_cols = {}
    local rotatable_rows = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local cell = grid_at(grids, x, y, width)
            if cell ~= nil then
                local rot = registry.read_bool(cell, "_IsRotatable", false)
                cells[#cells + 1] = {
                    x = x, y = y,
                    openings  = decode_openings(safe(function() return cell:get_field("_PathType") end)),
                    rotatable = rot,
                }
                if rot then
                    rotatable_cols[x] = true
                    rotatable_rows[y] = true
                end
            end
        end
    end

    local rows = {}
    for y in pairs(rotatable_rows) do rows[#rows + 1] = y end
    table.sort(rows)
    local cols = {}
    for x in pairs(rotatable_cols) do cols[#cols + 1] = x end
    table.sort(cols)

    local base = registry.base_state(inst)
    return {
        kind            = M.kind,
        width           = width,
        height          = height,
        cells           = cells,
        rotatable_rows  = rows,
        rotatable_cols  = cols,
        row             = call0(_sdk.m_rotatable_row, inst),
        selecting       = registry.to_int(safe(function() return inst:get_field("_SelectingColumn") end)) or 0,
        success         = registry.read_bool(inst, "_SuccessTrigger", false)
                          or registry.read_bool(inst, "_Success", false),
        failed          = base and base.status_failed or false,
        playing         = base and base.playing or nil,
    }
end


function M.get_state(id)
    local rec = id and store.by_id(id) or current_record()
    return read_state(rec)
end


-- Piece rotations and the selection are progress, so neither is in the
-- fingerprint -- only the board's shape and which columns can be turned.
local function struct_sig(state)
    if state == nil then return nil end
    local cols = {}
    for _, c in ipairs(state.rotatable_cols or {}) do cols[#cols + 1] = tostring(c) end
    return table.concat({ "path", state.width, state.height, table.concat(cols, ",") }, "|")
end
M.struct_sig = struct_sig


function M.render_state()
    local state = M.get_state(nil)
    if state == nil then return render.unknown("path hack") end
    return render.path(state)
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
        success = state.success,
        failed  = state.failed,
    }
end


function M.is_interactive()
    local state = read_state(current_record())
    return state ~= nil and state.playing == true
end


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


-- Expands { column, steps } into the presses a player would make: walk the
-- selection to that column, then turn the piece. The walk is recomputed as the
-- list is built, so consecutive entries do not each start from scratch.
function M.set_plan(id, rotations, resolve)
    local rec = store.by_id(id)
    if rec == nil then return 0, false end

    local state = read_state(rec)
    if state == nil then
        P.resolve(rec, false, "The board could not be read; nothing was rotated.")
        return 0, false
    end

    local rotate_command = config.puzzle_path_rotate_command or "up"
    local cursor = state.selecting or 0
    local steps = {}
    local rejected = nil

    for _, entry in ipairs(rotations or {}) do
        local column = type(entry) == "table" and tonumber(entry.column) or nil
        local turns = type(entry) == "table" and tonumber(entry.steps) or nil
        if column == nil or column < 0 or column >= state.width then
            rejected = "column " .. tostring(column) .. " is not on the board"
            break
        end
        turns = math.floor(turns or 1)
        if turns < 1 or turns > 3 then
            rejected = "steps must be 1, 2 or 3 (got " .. tostring(turns) .. ")"
            break
        end
        column = math.floor(column)
        while cursor < column do
            steps[#steps + 1] = "right"
            cursor = cursor + 1
        end
        while cursor > column do
            steps[#steps + 1] = "left"
            cursor = cursor - 1
        end
        for _ = 1, turns do
            steps[#steps + 1] = rotate_command
        end
    end

    if rejected ~= nil then
        P.resolve(rec, false, "Nothing was rotated: " .. rejected .. ".")
        return 0, false
    end

    local cur = current_record()
    local queued, parked = P.set_plan(rec, steps, resolve, cur ~= nil and cur.id == rec.id)
    log.info("puzzle_path: plan for puzzle " .. tostring(id) .. " -- "
          .. tostring(queued) .. " inputs, parked=" .. tostring(parked))
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

    if rec.dispatching or state.playing ~= true then return end
    if #rec.plan.queue == 0 then return end

    local items = {}
    for i, command in ipairs(rec.plan.queue) do
        items[i] = { command = command, label = command }
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
                if after ~= nil and after.success ~= true and after.playing == true then
                    P.discard(rec)
                    P.clear_snapshot(rec)
                    P.resolve(rec, false,
                        "The rotations were applied but no path runs across the board yet.")
                end
            else
                P.discard(rec)
                if reason ~= "superseded" then
                    P.resolve(rec, false, "The rotations could not be entered: " .. tostring(reason))
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
        rotate_command = config.puzzle_path_rotate_command or "up",
        note      = "unverified family -- written from the type dump only",
    }
end


return M
