-- ASCII rendering for hacking grid state.
--
-- Mirrors `sim/ascii_render.py` from the evaluation harness — same glyph
-- table, same coordinate convention, same adjacency-block format. The
-- representation the AI peer sees in production must match what was tested
-- against in the simulator, otherwise the simulator's solve rate doesn't
-- transfer to live play.
--
-- Input: a state table as produced by bindings.puzzle_snake.get_state():
--   {
--     width, height,
--     cursor = {x, y},
--     goal   = {x, y},
--     cells  = { [y+1] = { [x+1] = { type, in_trail, is_erase, ... } } },
--     trail  = { {x, y}, ... },
--   }
--
-- Output: a multi-line string suitable for the `state` field on actions/force.

local M = {}

-- ---------------------------------------------------------------------------
-- Cell-type → glyph table
-- ---------------------------------------------------------------------------
-- Walls collapsed to `#` since Obstacle / Impassable / Nothing / None are all
-- equivalently impassable. Directional cell glyphs (OneWay arrows, TwoWay
-- corners) require the per-cell direction info; for now we ship the general
-- type glyph and refine later if we encounter directional cells.

local GLYPHS = {
    -- None = engine's default "no special type" — the cell is walkable and
    -- undecorated (most of a tutorial grid). Render same as Open.
    None             = ".",
    Open             = ".",
    -- Nothing is a separate engine value; whether it's walkable in practice
    -- isn't yet confirmed. Treat as wall conservatively until we see one
    -- in a context that proves otherwise.
    Nothing          = "#",
    Start            = "S",
    Goal             = "G",
    Obstacle         = "#",
    Impassable       = "#",
    Shield           = "s",
    Chain            = "C",
    OneWay           = "?",  -- directional; refine if/when we encounter one
    TwoWayLeftRight  = "=",
    TwoWayLeftTop    = "J",
    TwoWayLeftDown   = "7",
    TwoWayRightTop   = "L",
    TwoWayRightDown  = "r",
    TwoWayTopDown    = "|",
    ActiveSkill      = "*",
    ActiveSkill1     = "1",
    ActiveSkill2     = "2",
    ActiveSkill3     = "3",
    Bomb3x3          = "b",
    Bomb5x5          = "B",
    Purge            = "P",
    Attack           = "A",
    EraseCode        = "X",
    DeadFilament     = "d",
    FinishBlow       = "F",
}

local CURSOR_GLYPH = "@"
local TRAIL_GLYPH  = "~"


-- Type names that represent a directional-gating tile. When InWayType or
-- OutWayType is one of these, the cell is a passthrough/corner tile even
-- if its underlying _GridType is plain Open.
local DIRECTIONAL_TYPES = {
    OneWay          = true,
    TwoWayLeftRight = true,
    TwoWayLeftTop   = true,
    TwoWayLeftDown  = true,
    TwoWayRightTop  = true,
    TwoWayRightDown = true,
    TwoWayTopDown   = true,
}


local function cell_glyph(cell)
    -- Cells with no entry, or "None"/"Nothing" type cells, are positions
    -- the snake can't traverse — render as '#' (impassable).
    if cell == nil then return "#" end

    -- Decorations layered on top of the terrain take priority. EraseCode
    -- and ActiveSkill attributes are what the AI cares about; the
    -- underlying terrain (Open / Start / etc.) is less informative.
    if cell.is_erase then return GLYPHS.EraseCode end
    if cell.active_skill_type then
        local g = GLYPHS[cell.active_skill_type]
        if g then return g end
    end

    -- Directional gating: the cell may have _GridType = Open but
    -- InWayType/OutWayType set to a TwoWay* / OneWay value. Prefer the
    -- directional glyph in that case since the AI needs to know about
    -- entry/exit restrictions.
    if cell.out_way_type and DIRECTIONAL_TYPES[cell.out_way_type] then
        local g = GLYPHS[cell.out_way_type]
        if g then return g end
    end
    if cell.in_way_type and DIRECTIONAL_TYPES[cell.in_way_type] then
        local g = GLYPHS[cell.in_way_type]
        if g then return g end
    end

    return GLYPHS[cell.type] or "?"
end


-- ---------------------------------------------------------------------------
-- Terrain rendering with cursor + trail overlay
-- ---------------------------------------------------------------------------

local function render_terrain(state)
    local cx, cy = -1, -1
    if state.cursor then cx, cy = state.cursor.x, state.cursor.y end

    -- Build a quick-lookup set of trail coords (excluding cursor itself).
    local in_trail = {}
    if state.trail then
        for _, p in ipairs(state.trail) do
            local key = p.x .. "," .. p.y
            in_trail[key] = true
        end
    end

    local rows = {}

    -- Header row with x coordinates.
    local header = "    "
    for x = 0, state.width - 1 do
        header = header .. tostring(x) .. " "
    end
    table.insert(rows, header)

    for y = 0, state.height - 1 do
        local parts = { string.format(" %d  ", y) }
        for x = 0, state.width - 1 do
            local glyph
            if x == cx and y == cy then
                glyph = CURSOR_GLYPH
            elseif in_trail[x .. "," .. y] then
                glyph = TRAIL_GLYPH
            else
                local row = state.cells[y + 1]
                local c = row and row[x + 1]
                glyph = cell_glyph(c)
            end
            table.insert(parts, glyph)
            table.insert(parts, " ")
        end
        -- Parens force single-return; gsub returns (string, count) and the
        -- count would otherwise be passed as table.insert's `pos` arg.
        table.insert(rows, (table.concat(parts):gsub("%s+$", "")))
    end

    return table.concat(rows, "\n")
end


-- ---------------------------------------------------------------------------
-- Adjacency block — spells out every direction from cursor in detail
-- ---------------------------------------------------------------------------

local DIRS = {
    { name = "up",    dx =  0, dy = -1 },
    { name = "down",  dx =  0, dy =  1 },
    { name = "left",  dx = -1, dy =  0 },
    { name = "right", dx =  1, dy =  0 },
}


local function in_bounds(state, x, y)
    return x >= 0 and x < state.width and y >= 0 and y < state.height
end


-- Engine types that mean "the snake genuinely can't enter here". `None` is
-- the default for unmarked-but-walkable cells; it's NOT a wall.
local function is_wall_type(type_name)
    return type_name == "Obstacle"
        or type_name == "Impassable"
        or type_name == "Nothing"
        or type_name == "Shield"
end


local function adjacency_block(state)
    if state.cursor == nil then return "" end
    local cx, cy = state.cursor.x, state.cursor.y

    local in_trail = {}
    if state.trail then
        for _, p in ipairs(state.trail) do
            in_trail[p.x .. "," .. p.y] = true
        end
    end

    local lines = { string.format("From cursor (%d, %d):", cx, cy) }

    for _, d in ipairs(DIRS) do
        local nx, ny = cx + d.dx, cy + d.dy
        local prefix = string.format("  %-5s -> ", d.name)

        if not in_bounds(state, nx, ny) then
            local reason
            if d.name == "up" and cy == 0 then
                reason = "y=0 is already the top row"
            elseif d.name == "down" and cy == state.height - 1 then
                reason = "y=" .. cy .. " is already the bottom row"
            elseif d.name == "left" and cx == 0 then
                reason = "x=0 is already the left edge"
            elseif d.name == "right" and cx == state.width - 1 then
                reason = "x=" .. cx .. " is already the right edge"
            else
                reason = "out of grid"
            end
            table.insert(lines, prefix .. "OUT OF BOUNDS (" .. reason .. ")")
        else
            local row = state.cells[ny + 1]
            local cell = row and row[nx + 1]
            local type_name = (cell and cell.type) or "Unknown"
            local glyph = cell_glyph(cell)
            -- Display the most-specific type name for the cell — if the
            -- directional gating is set, surface that; otherwise the base
            -- type. This is what the AI should reason about.
            local display_type = type_name
            if cell and cell.out_way_type and DIRECTIONAL_TYPES[cell.out_way_type] then
                display_type = cell.out_way_type
            elseif cell and cell.in_way_type and DIRECTIONAL_TYPES[cell.in_way_type] then
                display_type = cell.in_way_type
            end
            if cell and cell.active_skill_type then
                display_type = display_type .. "/" .. cell.active_skill_type
            end
            local info = string.format("(%d, %d) [%s] %s", nx, ny, glyph, display_type)

            if in_trail[nx .. "," .. ny] then
                table.insert(lines, prefix .. info .. "  ILLEGAL: in trail (already visited)")
            elseif is_wall_type(type_name) then
                table.insert(lines, prefix .. info .. "  ILLEGAL: wall - cannot enter")
            elseif cell and cell.is_erase then
                table.insert(lines, prefix .. info .. "  DANGER: EraseCode - entering ends the hack as failure")
            elseif type_name == "EraseCode" then
                table.insert(lines, prefix .. info .. "  DANGER: EraseCode - entering ends the hack as failure")
            else
                table.insert(lines, prefix .. info .. "  legal")
            end
        end
    end

    return table.concat(lines, "\n")
end


-- ---------------------------------------------------------------------------
-- Legend
-- ---------------------------------------------------------------------------

local LEGEND =
    "Legend: S=start G=goal .=open #=wall *=skill(stackable: 1/2/3 variants)\n" ..
    "        b=bomb3x3 B=bomb5x5 P=purge C=chain A=attack F=finishblow s=shield\n" ..
    "        X=ERASE_CODE (DO NOT STEP - ends hack as failure)\n" ..
    "        @=cursor ~=trail (already-visited cells; cannot revisit)"


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Render the full prompt block: header, terrain, cursor/goal coords,
-- adjacency block, optional legend. Mirrors the sim renderer in `sim/`.
function M.render(state, opts)
    opts = opts or {}
    local with_legend = opts.with_legend
    if with_legend == nil then with_legend = true end

    local parts = {}
    table.insert(parts, string.format(
        "Hacking grid (%d wide, %d tall - x ranges 0..%d, y ranges 0..%d):",
        state.width, state.height, state.width - 1, state.height - 1
    ))
    table.insert(parts, render_terrain(state))
    table.insert(parts, "")
    if state.cursor then
        table.insert(parts, string.format("Cursor: (%d, %d)", state.cursor.x, state.cursor.y))
    end
    if state.goal then
        table.insert(parts, string.format("Goal:   (%d, %d)", state.goal.x, state.goal.y))
    end

    if state.trail and #state.trail > 1 then
        local pieces = {}
        for _, p in ipairs(state.trail) do
            table.insert(pieces, string.format("(%d,%d)", p.x, p.y))
        end
        table.insert(parts, "Visited: " .. table.concat(pieces, ", "))
    end

    table.insert(parts, "")
    table.insert(parts, adjacency_block(state))

    if with_legend then
        table.insert(parts, "")
        table.insert(parts, LEGEND)
    end

    return table.concat(parts, "\n")
end


return M
