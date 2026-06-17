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
    -- None = engine's default "no special type" — plain walkable floor (the
    -- majority of every observed grid).
    None             = ".",
    -- Open is NOT generic floor: on every grid checked against in-game
    -- footage, the type=Open cells are exactly the visible BLUE bonus nodes
    -- (4-way arrow tiles; reskinned by puzzle modifiers like offense mode).
    -- Routing through them improves the hack, so they get the bonus glyph.
    Open             = "O",
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


-- Bonus nodes the AI should route through, mapped against in-game footage:
--   * BLUE  (most valuable: more damage to the enemy + longer-lasting hack).
--     These ARE a distinct grid type: Open. On every grid checked, the
--     type=Open cells line up exactly with the visible blue nodes; plain
--     floor is type None.
--   * YELLOW (secondary: the "skill node"): ActiveSkill (and its
--     ActiveSkill1/2/3 variants), glyph `*`/`1`/`2`/`3`.
-- `_IsGoldenPath` is deliberately NOT rendered: it marks the engine's
-- auto-hack route (the feature that turns nodes gold as auto-hack runs) and
-- floods most walkable cells, which (a) hides the real blue nodes and
-- (b) hands the AI a pre-solved route. It stays visible in the debug dump
-- only. Other special grid types (FinishBlow, Attack, Bomb, Chain, Purge)
-- still render with their own glyphs but aren't collect-targets.
local ACTIVE_SKILL_TYPES = {
    ActiveSkill  = true,
    ActiveSkill1 = true,
    ActiveSkill2 = true,
    ActiveSkill3 = true,
}


local function cell_glyph(cell)
    -- Cells with no entry, or "None"/"Nothing" type cells, are positions
    -- the snake can't traverse — render as '#' (impassable).
    if cell == nil then return "#" end

    -- Decorations layered on top of the terrain take priority. EraseCode,
    -- DeadFilament and ActiveSkill attributes are what the AI cares about;
    -- the underlying terrain (Open / Start / etc.) is less informative.
    if cell.is_erase then return GLYPHS.EraseCode end

    -- Red "error node" hazards. These are a decoration, not a _GridType —
    -- affected cells read as plain None — so without this override they'd
    -- render as a walkable '.'. The live marker is the _ObstacleReasons
    -- bitmask (is_blocked); dead_filament covers the boss-content
    -- _DeadFilamentType variant.
    if cell.is_blocked or cell.dead_filament then return GLYPHS.DeadFilament end

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


-- Classify a bonus cell. Returns (tier, color, label) where tier 2 = blue
-- (most valuable) and tier 1 = yellow (secondary), or nil for a non-bonus
-- cell. Goal/Start terminals are never bonuses.
local function bonus_info(cell)
    if cell == nil then return nil end
    if cell.type == "Goal" or cell.type == "Start" then return nil end
    -- Hazards are never collect-targets — the danger labels must win.
    if cell.is_erase or cell.is_blocked or cell.dead_filament
        or cell.type == "EraseCode" or cell.type == "DeadFilament" then
        return nil
    end
    if cell.type == "Open" then
        return 2, "BLUE", "bonus node: more damage + longer-lasting hack"
    end
    if cell.active_skill_type or (cell.type and ACTIVE_SKILL_TYPES[cell.type]) then
        return 1, "YELLOW", "skill node"
    end
    return nil
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
            -- Hazard decoration trumps the directional overrides above: a
            -- cell carrying an error node must read as one.
            if cell and (cell.is_blocked or cell.dead_filament)
                and type_name ~= "DeadFilament" then
                display_type = "ErrorNode"
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
            elseif (cell and (cell.is_blocked or cell.dead_filament))
                or type_name == "DeadFilament" then
                table.insert(lines, prefix .. info .. "  ILLEGAL: error node - currently blocked, cannot enter")
            else
                local btier, bcolor, blabel = bonus_info(cell)
                if btier then
                    table.insert(lines, prefix .. info .. string.format(
                        "  legal -- %s BONUS: %s", bcolor, blabel))
                else
                    table.insert(lines, prefix .. info .. "  legal")
                end
            end
        end
    end

    return table.concat(lines, "\n")
end


-- ---------------------------------------------------------------------------
-- Bonus-node summary
-- ---------------------------------------------------------------------------
-- Lists every uncollected bonus node on the grid, highest tier first, with
-- an explicit instruction to route through as many as possible. This is the
-- primary signal the peer uses to plan a bonus-collecting path; the goal is
-- to maximize collected bonuses, not to take the shortest route.

local function bonus_block(state)
    local found = {}
    for y = 0, state.height - 1 do
        local row = state.cells[y + 1]
        if row then
            for x = 0, state.width - 1 do
                local cell = row[x + 1]
                -- Skip cells already on the trail: a bonus the cursor has
                -- already crossed is collected, so it's not a target.
                if cell and not cell.in_trail then
                    local tier, color, label = bonus_info(cell)
                    if tier then
                        table.insert(found, {
                            x = x, y = y, tier = tier,
                            color = color, label = label,
                            glyph = cell_glyph(cell),
                        })
                    end
                end
            end
        end
    end
    if #found == 0 then return nil end

    -- Most valuable (blue) first so the must-grab nodes read at the top.
    table.sort(found, function(a, b)
        if a.tier ~= b.tier then return a.tier > b.tier end
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    local lines = {
        "Bonus nodes - pass through as MANY as possible on the way to G. They",
        "make the hack do more damage and last longer, so a longer, winding",
        "route that collects more bonuses is BETTER than the shortest path - as",
        "long as the plan still ends on G, never steps on an X (EraseCode)",
        "trap or a d (error node), and never revisits a ~ trail cell. BLUE (O)",
        "nodes are worth the most; grab them first, then YELLOW (*) skill nodes:",
    }
    for _, b in ipairs(found) do
        table.insert(lines, string.format(
            "  (%d, %d) [%s] %s - %s", b.x, b.y, b.glyph, b.color, b.label))
    end
    return table.concat(lines, "\n")
end


-- ---------------------------------------------------------------------------
-- Legend
-- ---------------------------------------------------------------------------

local LEGEND =
    "Legend: S=start G=goal .=walkable floor #=wall  @=cursor ~=trail (cannot revisit)\n" ..
    "        O=BLUE bonus node (more damage + longer hack - TOP priority)\n" ..
    "        *=YELLOW skill node (1/2/3 variants) - secondary bonus\n" ..
    "        Route through as many O and * nodes as you can en route to G.\n" ..
    "        X=ERASE_CODE (DO NOT STEP - ends hack as failure)\n" ..
    "        d=ERROR NODE (red warning node - BLOCKED, cannot enter)\n" ..
    "        b=bomb3x3 B=bomb5x5 P=purge C=chain A=attack F=finishblow s=shield"


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

    -- Rows/cols removed by sticky bombs are compacted out of the layout
    -- above; say so explicitly so the smaller grid doesn't read as an error.
    local n_skip_r = state.skipped_rows and #state.skipped_rows or 0
    local n_skip_c = state.skipped_cols and #state.skipped_cols or 0
    if n_skip_r > 0 or n_skip_c > 0 then
        table.insert(parts, string.format(
            "NOTE: %d row(s) and %d column(s) are currently REMOVED from the grid",
            n_skip_r, n_skip_c))
        table.insert(parts, "(sticky bombs). The layout above is the live, playable grid.")
    end

    table.insert(parts, "")
    if state.cursor then
        table.insert(parts, string.format("Cursor: (%d, %d)", state.cursor.x, state.cursor.y))
    end
    if state.start then
        table.insert(parts, string.format("Start:  (%d, %d)", state.start.x, state.start.y))
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
        table.insert(parts,
            "Hack already in progress: @ is the CURRENT cursor (not the start);")
        table.insert(parts,
            "~ cells are already visited and CANNOT be re-entered. Plan from @.")
    end

    table.insert(parts, "")
    table.insert(parts, adjacency_block(state))

    local bonuses = bonus_block(state)
    if bonuses then
        table.insert(parts, "")
        table.insert(parts, bonuses)
    end

    if with_legend then
        table.insert(parts, "")
        table.insert(parts, LEGEND)
    end

    return table.concat(parts, "\n")
end


return M
