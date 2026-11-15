-- Enemy-side modifiers on the hacking grid (app.PuzzleSnake subclasses).
--
-- Three mechanics make an enemy's grid harder, and none of them lives on the
-- base grid the rest of puzzle_snake.lua reads:
--
--   red blocks  -- four large red rectangles; touching one fails the hack.
--                  Shooting the enemy's antennas (weak points) removes them one
--                  at a time. With all four up the engine treats the grid as
--                  impossible to progress. Two enemy kinds implement this:
--                  app.ch16092PuzzleSnake keeps an ObstacleGridUnit (a List of
--                  ObstacleGrid {GridPosition{StartPoint, EndPoint}, IsActive})
--                  and answers get_isProgressImpossibleGrid(); the ch14100 /
--                  ch16200 kinds keep "jamming panels" with the same
--                  rectangle shape {StartRectPoint, EndRectPoint, IsActive}.
--                  Covered cells also carry an ObstacleReason bit (Ch16092=4,
--                  Ch14100=8), which puzzle_snake.lua reads per cell.
--   corruption  -- the engine's "dead filament": an enemy flag plus per-cell
--                  _DeadFilamentType; stepping on such a cell blocks the next
--                  move for a moment (_MoveBlockReasonFlag, a Stun move result)
--                  rather than failing the hack.
--   explosions  -- the final boss's PuzzleSnakeAttack system: groups of cells
--                  go through Sign (pulsing) -> Attack (exploding) -> End, and
--                  a cursor on an Attack cell fails the hack.
--
-- Everything here is READ-ONLY. Each reader takes the PuzzleSnake instance puzzle_snake.lua already resolved,
-- returns plain tables in ENGINE grid coordinates (puzzle_snake.lua maps them
-- into the compacted render space), and returns nil when the instance has no
-- such modifier or a read fails -- never an error.
--
-- FIELD READS ONLY. These run every frame, also while a puzzle is not taking
-- input, and calling the puzzle's own methods that often (getObstacleInfo(),
-- the corruption module's isDeadFilament() and friends) locked the game on
-- the final boss's last stage. Stick to fields and plain property getters of
-- objects that only exist on the modifier enemies.

local reflect = require("pragmata.bindings.reflect")

local M = {}

local safe, field, elements = reflect.safe, reflect.field, reflect.elements

local function int2(v)
    if v == nil then return nil end
    local x = safe(function() return v.x end)
    local y = safe(function() return v.y end)
    if type(x) ~= "number" then x = reflect.to_int(field(v, "x")) end
    if type(y) ~= "number" then y = reflect.to_int(field(v, "y")) end
    if type(x) == "number" and type(y) == "number" then return { x = x, y = y } end
    return nil
end

-- Normalise a Start/End pair into an inclusive min/max rectangle.
local function rect(a, b)
    if a == nil or b == nil then return nil end
    return {
        x0 = math.min(a.x, b.x), y0 = math.min(a.y, b.y),
        x1 = math.max(a.x, b.x), y1 = math.max(a.y, b.y),
    }
end


-- ---------------------------------------------------------------------------
-- Red blocks
-- ---------------------------------------------------------------------------

-- ch16092: ObstacleGridUnit.<ManagedObstacleGridList>.
local function blocks_from_obstacle_unit(inst)
    local unit = field(inst, "ObstacleGridUnit")
    if unit == nil then return nil end
    local list = field(unit, "<ManagedObstacleGridList>k__BackingField")
    local rects = {}
    for i, g in ipairs(elements(list)) do
        local pos = field(g, "<GridPosition>k__BackingField")
        local r = pos and rect(int2(field(pos, "StartPoint")), int2(field(pos, "EndPoint")))
        local active = field(g, "<IsActive>k__BackingField")
        if r ~= nil then
            r.index = i - 1
            r.active = active == true
            rects[#rects + 1] = r
        end
    end
    return { source = "obstacle_unit", rects = rects }
end

-- One JammingPanel[] (ch14100 / ch16200) into rects.
local function panel_rects(panels, rects)
    for _, p in ipairs(elements(panels)) do
        local r = rect(int2(field(p, "<StartRectPoint>k__BackingField")),
                       int2(field(p, "<EndRectPoint>k__BackingField")))
        local active = field(p, "<IsActive>k__BackingField")
        if r ~= nil then
            r.index = #rects
            r.active = active == true
            rects[#rects + 1] = r
        end
    end
end

-- The panels for a JammingPanelUnit's current level: the level's entry in
-- JammingPanelLevelDict (what ch14100's get_CurrentPanelList() returns).
local function unit_panels(unit)
    local level = reflect.to_int(field(unit, "<Level>k__BackingField"))
    local dict = field(unit, "<JammingPanelLevelDict>k__BackingField")
    if level == nil or dict == nil then return nil end
    return reflect.dict_get(dict, level)
end

-- ch14100: a single _JammingPanelUnit; ch16200: a List of them.
local function blocks_from_jamming_panels(inst)
    local units = {}
    local single = field(inst, "_JammingPanelUnit")
    if single ~= nil then units[1] = single end
    for _, u in ipairs(elements(field(inst, "JammingPanelUnits"))) do units[#units + 1] = u end
    if #units == 0 then return nil end
    local rects = {}
    for _, u in ipairs(units) do panel_rects(unit_panels(u), rects) end
    return { source = "jamming_panels", rects = rects }
end

-- { source, total, active, rects = {
--     { index, x0, y0, x1, y1, active } } }  in engine coordinates, or nil when
-- this enemy has no blocks. `rects` keeps the engine's list order.
function M.read_blocks(inst)
    if inst == nil then return nil end
    local out = blocks_from_obstacle_unit(inst) or blocks_from_jamming_panels(inst)
    if out == nil or #out.rects == 0 then return nil end
    out.total, out.active = #out.rects, 0
    for _, r in ipairs(out.rects) do
        if r.active then out.active = out.active + 1 end
    end
    return out
end

-- Which corner of a width x height grid a rectangle sits in, as the words the
-- peer is shown ("top-left" ...). nil without geometry.
function M.corner(r, width, height)
    if r == nil or r.x0 == nil or width == nil or height == nil then return nil end
    local cx, cy = (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
    local v = (cy < (height - 1) / 2) and "top" or "bottom"
    local h = (cx < (width - 1) / 2) and "left" or "right"
    return v .. "-" .. h
end


-- ---------------------------------------------------------------------------
-- Corruption (dead filament)
-- ---------------------------------------------------------------------------


-- The puzzle's input block: (flag, last_move_result). _MoveBlockReasonFlag is
-- nonzero while something -- a corrupted cell's stun, a grid change -- holds
-- the cursor; _LastUnitMoveResult is a UnitMoveResultType (Stun = 3). Read
-- every dispatch tick, so it stays two field reads.
M.MOVE_RESULT_STUN = 3
function M.read_move_block(inst)
    if inst == nil then return nil, nil end
    return reflect.to_int(field(inst, "_MoveBlockReasonFlag")),
           reflect.to_int(field(inst, "_LastUnitMoveResult"))
end


-- ---------------------------------------------------------------------------
-- Explosions (the boss's attack system)
-- ---------------------------------------------------------------------------
-- What the move dispatcher times its moves against, so it runs every
-- dispatch tick on the boss: FIELD READS ONLY (see the top of this file). The
-- attack state is a smart enum hash, named once per hash through the type's
-- static getName and cached; the timers are read off their fields
-- (_TimeLimit - _TransitTime), not through get_RemainingTime().
--
-- Measured in game: whole rows are hit, Sign
-- (pulsing) lasts 1.2 s and Attack (the explosion) 0.2 s; a cursor on a cell
-- while it explodes fails the hack, which then restarts from the start.
--
-- Returns nil for an enemy without the attack system, else
--   { units = { { state = "Sign"|"Attack", explodes_in, ends_in,
--                 cells = { {x, y} engine coords } } } }
-- listing only the units that are pulsing or exploding right now. Times are
-- seconds from now. M.last_attack_clock is the os.clock() of the last read
-- that saw an explosion going off, for telling an explosion failure apart
-- from an error-node reset.

local _attack_state_names = {}
local function attack_state_name(hash)
    if hash == nil then return nil end
    local name = _attack_state_names[hash]
    if name == nil then
        name = reflect.enum_name("app.PuzzleSnakeAttackState", hash) or false
        _attack_state_names[hash] = name
    end
    return name or nil
end

local function timer_remaining(t)
    local limit = reflect.to_float(field(t, "_TimeLimit"))
    local transit = reflect.to_float(field(t, "_TransitTime"))
    if limit == nil or transit == nil then return nil end
    return math.max(0, limit - transit)
end

M.last_attack_clock = nil

function M.read_danger(inst)
    if inst == nil then return nil end
    local think = field(inst, "PuzzleThink")
    local ctrl = think and field(think, "<attackController>k__BackingField") or nil
    if ctrl == nil then return nil end
    local out = { units = {} }
    for _, u in ipairs(elements(field(ctrl, "<AttackUnitList>k__BackingField"))) do
        local name = attack_state_name(reflect.to_int(field(u, "<attackState>k__BackingField")))
        if name == "Sign" or name == "Attack" then
            local attack_timer = field(u, "AttackTimer")
            local explodes_in, ends_in
            if name == "Sign" then
                explodes_in = timer_remaining(field(u, "SignTimer")) or 0
                ends_in = explodes_in
                    + (reflect.to_float(field(attack_timer, "_TimeLimit")) or 0.2)
            else
                explodes_in = 0
                ends_in = timer_remaining(attack_timer) or 0.2
                M.last_attack_clock = safe(os.clock)
            end
            local cells = {}
            for _, p in ipairs(elements(field(u, "<AttackPositionList>k__BackingField"))) do
                local x = reflect.to_int(field(p, "X"))
                local y = reflect.to_int(field(p, "Y"))
                if x ~= nil and y ~= nil then cells[#cells + 1] = { x = x, y = y } end
            end
            out.units[#out.units + 1] = {
                state = name, explodes_in = explodes_in, ends_in = ends_in, cells = cells,
            }
        end
    end
    return out
end

return M
