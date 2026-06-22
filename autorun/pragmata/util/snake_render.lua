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
    -- All ActiveSkill variants render as '*'. The 1/2/3 suffixes are NOT the
    -- skill level (a level-2 skill still shows ActiveSkill / '*'); they tag which
    -- of MULTIPLE equipped skills a node belongs to (only the Code Generator
    -- weapon produces that), which never occurs in normal play and which we don't
    -- distinguish anyway. So a numbered glyph would just confuse the model.
    ActiveSkill      = "*",
    ActiveSkill1     = "*",
    ActiveSkill2     = "*",
    ActiveSkill3     = "*",
    Bomb3x3          = "b",
    Bomb5x5          = "B",
    Purge            = "P",
    Attack           = "A",
    EraseCode        = "X",
    -- Red "error nodes" get their OWN glyph 'd', distinct from inert walls '#'.
    -- Both are impassable, but the consequences differ sharply: entering an
    -- error node RESETS the whole hack to the start, while a wall just stops the
    -- cursor. Collapsing them into '#' made the grid unable to show which is
    -- which, so the AI couldn't correlate a post-hit "reset" vs "stopped"
    -- message with the cell it hit. (This is the live ObstacleGrid bit of
    -- _ObstacleReasons / is_blocked, not the _DeadFilamentType purple node.)
    DeadFilament     = "d",
    -- FinishBlow renders as plain floor, NOT a distinct 'F'. In-game the
    -- finish-blow node is almost always INVISIBLE (it only appears under
    -- specific conditions, e.g. enough enemy heat), yet the engine reports it on
    -- nearly every grid — so an 'F' glyph showed a node the player can't see, and
    -- a small model reads "F"/"finish" as a finish/goal space. It's walkable
    -- floor to the planner, so we render it as such and drop it from the legend.
    FinishBlow       = ".",
}

local CURSOR_GLYPH = "@"
local TRAIL_GLYPH  = "~"

-- Backtrack arrows: a visited cell shows the direction to MOVE to step back
-- onto it while retracing toward start (from state.trail_back). This lets the
-- AI plan a multi-cell reverse in one go instead of one undo at a time. Falls
-- back to '~' when the direction is unknown (e.g. history unreadable). In the
-- live render these glyphs are unambiguous: OneWay gates render as '?'.
local TRAIL_ARROW = { up = "^", down = "v", left = "<", right = ">" }

local function trail_glyph_for(state, x, y)
    -- Keep "home" visible while retracing: the start cell is always on the
    -- trail, so without this it would render as an arrow and the AI couldn't
    -- see where the path leads back to.
    if state.start and x == state.start.x and y == state.start.y then
        return GLYPHS.Start
    end
    local tb = state.trail_back
    local dir = tb and tb[x .. "," .. y]
    return (dir and TRAIL_ARROW[dir]) or TRAIL_GLYPH
end


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
--     The blue reward node is a distinct grid TYPE, and a hacking MODE re-rolls
--     which type it is: the default mode uses `Open`, and Offense mode RETYPES it
--     to `Attack` (verified via cell dump: the cells where blues sit read
--     type=Attack in Offense — they are NOT type=Open with a decoration, they're
--     a genuinely different type). `Open` renders 'O' (BLUE); `Attack` renders
--     'A' (ORANGE) — kept DISTINCT because Hybrid mode spawns BOTH on the same
--     grid, and flattening them would hide the difference the mode note explains.
--     Both are route-through reward nodes (REWARD_TYPES). Modes other than
--     Offense/Hybrid leave the node as `Open`; the active mode (see state.mode)
--     dictates the EFFECT.
--   * YELLOW (secondary: the "skill node"): ActiveSkill (and its
--     ActiveSkill1/2/3 variants), glyph `*`/`1`/`2`/`3`.
-- `_IsGoldenPath` is deliberately NOT rendered: it marks the engine's
-- auto-hack route (the feature that turns nodes gold as auto-hack runs) and
-- floods most walkable cells, which (a) hides the real blue nodes and
-- (b) hands the AI a pre-solved route. It stays visible in the debug dump
-- only. Other special grid types (Bomb, Chain, Purge) still render with their
-- own glyphs but aren't collect-targets. (FinishBlow is the exception: it
-- renders as plain floor — see GLYPHS.FinishBlow.)
local ACTIVE_SKILL_TYPES = {
    ActiveSkill  = true,
    ActiveSkill1 = true,
    ActiveSkill2 = true,
    ActiveSkill3 = true,
}

-- Route-through reward node grid types. Both are BLUE in-game; they differ only
-- by ICON, which we mirror as distinct glyphs: Open -> 'O', Attack -> 'A'. Kept
-- distinct because Hybrid mode puts both on one grid. Both are "pass through me"
-- nodes; bonus_info labels each (same BLUE color, different icon/role). NOTE: do
-- NOT assign 'A' a different color name — they're blue, and a wrong color would
-- clash with what the streamer says aloud ("route through the blue ones").
local REWARD_TYPES = {
    Open   = true,   -- blue node, 'O' icon (default / most modes)
    Attack = true,   -- blue offensive node, 'A' icon (Offense / Hybrid; dump-verified)
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
    -- render as a walkable '.'. The live marker is the ObstacleGrid bit of
    -- _ObstacleReasons (is_blocked).
    --
    -- NOTE: dead_filament cells (the PURPLE "slow" nodes, _DeadFilamentType)
    -- are deliberately NOT treated as error nodes — verified in-game they're
    -- walkable (the cursor passes through, just pausing briefly) and often sit
    -- right on the route to the goal. They fall through to their underlying
    -- type here: plain None floor ('.'), or 'O' when the cell is also Open
    -- (a purple node can overlap a blue bonus node and is then both).
    if cell.is_blocked then return GLYPHS.DeadFilament end

    -- The BLUE reward node (type Open) -> 'O'. Directional gating is the one
    -- exception — a blue gate tile must show its arrow (routing-critical) — so
    -- it's checked first. Attack (the offensive-variant node in Offense/Hybrid
    -- mode — also BLUE, just a different icon) is ALSO a reward but renders 'A'
    -- via the fall-through below, kept distinct from 'O' (Hybrid spawns both).
    -- bonus_info classifies both as route-through.
    if cell.type == "Open" then
        if cell.out_way_type and DIRECTIONAL_TYPES[cell.out_way_type] then
            return GLYPHS[cell.out_way_type] or GLYPHS.Open
        end
        if cell.in_way_type and DIRECTIONAL_TYPES[cell.in_way_type] then
            return GLYPHS[cell.in_way_type] or GLYPHS.Open
        end
        return GLYPHS.Open
    end

    -- Non-reward cells: a skill decoration (the YELLOW skill nodes, which sit on
    -- otherwise-floor cells) takes priority over the base terrain glyph.
    if cell.active_skill_type then
        local g = GLYPHS[cell.active_skill_type]
        if g then return g end
    end

    -- Directional gating on a non-Open cell. Prefer the directional glyph since
    -- the AI needs to know about entry/exit restrictions.
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


-- Classify a bonus cell. Returns (tier, name, label) where tier 2 = blue reward
-- (most valuable) and tier 1 = yellow (secondary), or nil for a non-bonus cell.
-- `name` is the canonical node name ("blue OPEN node" etc.) used verbatim in the
-- bonus list + adjacency so blue/open/attack read as interchangeable everywhere.
-- Goal/Start terminals are never bonuses.
local function bonus_info(cell, skill)
    if cell == nil then return nil end
    if cell.type == "Goal" or cell.type == "Start" then return nil end
    -- Hazards are never collect-targets — the danger labels must win. Purple
    -- slow nodes (dead_filament) are NOT hazards: a purple node that's also
    -- Open is a real blue bonus, so it must stay collectible.
    if cell.is_erase or cell.is_blocked
        or cell.type == "EraseCode" or cell.type == "DeadFilament" then
        return nil
    end
    if cell.type == "Open" then
        return 2, "blue OPEN node", "route THROUGH it - this is what makes the hack deal damage"
    end
    if cell.type == "Attack" then
        return 2, "blue ATTACK node", "route THROUGH it (just like an OPEN node) to boost your next hack's damage"
    end
    -- Skill node (the yellow decoration; for the Chain skill it renders 'C', for
    -- the rest '*'). Identity lives in active_skill_type, not cell.type. Only one
    -- skill is ever equipped, so any skill node IS the equipped skill; the full
    -- effect is in the skill note at the top of the render.
    if cell.active_skill_type or (cell.type and ACTIVE_SKILL_TYPES[cell.type]) then
        if skill and skill.display then
            return 1, skill.display .. " skill node",
                "route THROUGH it when it's on your way (effect in the skill note above)"
        end
        return 1, "yellow skill node",
            "an effective but LIMITED-use bonus - grab it when it's on your way"
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
                glyph = trail_glyph_for(state, x, y)
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
            -- FinishBlow is rendered as floor (see GLYPHS.FinishBlow); normalize
            -- its type label too so the adjacency line doesn't leak "FinishBlow"
            -- (which a small model reads as a finish/goal space).
            if type_name == "FinishBlow" then type_name = "None" end
            -- "Attack" can read like a hazard to a small model; relabel it
            -- "ATTACK node" so it lines up with the 'A' glyph + "blue ATTACK
            -- node" reward tag (a route-through reward, not a threat). Open is
            -- relabeled to match its "blue OPEN node" tag for the same symmetry.
            if type_name == "Attack" then type_name = "ATTACK node" end
            if type_name == "Open" then type_name = "OPEN node" end
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
            -- Hazard decoration trumps the directional overrides above. Red
            -- error nodes ('d') and inert walls ('#') are both impassable but
            -- shown distinctly: entering an error node RESETS the whole hack,
            -- a wall just stops the cursor. Purple slow nodes (dead_filament)
            -- are walkable and keep their base type.
            local is_error_cell = cell and cell.is_blocked
            local is_wall_cell = is_wall_type(type_name)
                or type_name == "DeadFilament"
            if is_error_cell then
                display_type = "Error node"
            elseif is_wall_cell then
                display_type = "Wall"
            end
            if cell and cell.active_skill_type then
                display_type = display_type .. "/" .. cell.active_skill_type
            end
            local info = string.format("(%d, %d) [%s] %s", nx, ny, glyph, display_type)

            if in_trail[nx .. "," .. ny] then
                -- A visited cell is enterable only via its backtrack arrow
                -- (move INTO it == its trail_back direction). With no history,
                -- fall back to the single came_from cell.
                local back = state.trail_back and state.trail_back[nx .. "," .. ny]
                local single = state.came_from
                    and nx == state.came_from.x and ny == state.came_from.y
                if (back ~= nil and back == d.name)
                    or (state.trail_back == nil and single) then
                    table.insert(lines, prefix .. info
                        .. "  legal -- BACKTRACK: step back along your visited path (frees it)")
                else
                    table.insert(lines, prefix .. info
                        .. "  ILLEGAL: visited - can't re-enter from this side")
                end
            elseif is_error_cell then
                table.insert(lines, prefix .. info .. "  ILLEGAL: error node - entering RESETS the whole hack to start")
            elseif is_wall_cell then
                table.insert(lines, prefix .. info .. "  ILLEGAL: wall - cannot enter (cursor just stops)")
            elseif (cell and cell.is_erase) or type_name == "EraseCode" then
                table.insert(lines, prefix .. info .. "  DANGER: X trap - entering FAILS the hack")
            else
                local btier, bname, blabel = bonus_info(cell, state.active_skill)
                if btier then
                    table.insert(lines, prefix .. info .. string.format(
                        "  legal -- %s, %s", bname, blabel))
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
                    local tier, color, label = bonus_info(cell, state.active_skill)
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
        "Blue reward nodes (the OPEN 'O' and ATTACK 'A' icons, listed below) are "
            .. "where the damage comes from - a hack that grabs NONE is nearly "
            .. "useless. ACTIVELY "
            .. "pick a SAFE route that passes through one or two of them on the "
            .. "way to G, even if it is a few moves longer than the straight line. "
            .. "Collect them by passing THROUGH them going forward - do NOT detour "
            .. "out to one and come back the same way, since retracing your own "
            .. "path UNDOES the rewards you grabbed. Hard limits: never step on a "
            .. "# (wall) or d (error node) to reach one - a d RESETS the whole "
            .. "hack - and only fall back to the shortest path if none can be "
            .. "reached without crossing a # or d. (Yellow skill nodes - '*' or "
            .. "'C' - are effective but limited-use: grab one when it's on your "
            .. "way, but you don't need one every hack.)",
    }
    for _, b in ipairs(found) do
        table.insert(lines, string.format(
            "  (%d, %d) [%s] %s - %s", b.x, b.y, b.glyph, b.color, b.label))
    end
    return table.concat(lines, "\n")
end


-- ---------------------------------------------------------------------------
-- Legend (dynamic — only the glyphs that actually appear in this grid)
-- ---------------------------------------------------------------------------
-- A fixed legend listing every possible node type is mostly noise: late-game
-- grids never show bombs, X traps, etc., yet a static legend describes them
-- all. We instead scan the grid and emit one line per glyph that's actually
-- present, in priority order. Skill variants and directional gates collapse
-- to a single line. Always-relevant markers (@ cursor, . floor, # wall) are
-- only listed if they appear, which in practice they always do.

local LEGEND_ENTRIES = {
    { g = { "G" }, d = "goal - reach this to finish the hack" },
    { g = { "S" }, d = "start" },
    { g = { "@" }, d = "cursor - your current position" },
    { g = { "." }, d = "walkable floor" },
    { g = { "#" }, d = "wall - CANNOT enter (cursor just stops there)" },
    { g = { "d" }, d = "error node - CANNOT enter; entering RESETS the whole hack back to start" },
    { g = { "^", "v", "<", ">" },
      d = "your visited path - MOVE the way an arrow points to retrace one step back onto it (frees that cell); chain them to undo many moves" },
    { g = { "~" }, d = "visited cell (direction unknown) - cannot re-enter" },
    { g = { "O" }, d = "blue OPEN node - route THROUGH these; they're what makes the hack deal damage (a path that skips them does almost nothing)" },
    { g = { "A" }, d = "blue ATTACK node - route THROUGH these just like OPEN nodes to boost your next hack's damage" },
    { g = { "*" }, skill = true, d = "YELLOW skill node - an effective but limited-use bonus (grab when it's on the way)" },
    { g = { "X" }, d = "ERASE trap - stepping here FAILS the hack" },
    { g = { "b", "B" }, d = "bomb node" },
    { g = { "P" }, d = "purge node" },
    { g = { "C" }, skill_grid_type = "Chain", d = "chain node" },
    { g = { "s" }, d = "shield - blocked" },
    { g = { "=", "|", "J", "7", "L", "r" },
      d = "directional gate - only enter/exit along its arrows" },
}

-- Build the set of glyphs actually drawn in the terrain (incl. @ cursor and
-- ~ trail), so the legend can list only what's on screen.
local function collect_present_glyphs(state)
    local present = {}
    local cx, cy = -1, -1
    if state.cursor then cx, cy = state.cursor.x, state.cursor.y end
    local in_trail = {}
    if state.trail then
        for _, p in ipairs(state.trail) do in_trail[p.x .. "," .. p.y] = true end
    end
    for y = 0, state.height - 1 do
        local row = state.cells[y + 1]
        for x = 0, state.width - 1 do
            if x == cx and y == cy then
                present["@"] = true
            elseif in_trail[x .. "," .. y] then
                present[trail_glyph_for(state, x, y)] = true
            else
                present[cell_glyph(row and row[x + 1])] = true
            end
        end
    end
    return present
end

local function dynamic_legend(state)
    local present = collect_present_glyphs(state)
    local lines = { "Legend:" }
    for _, e in ipairs(LEGEND_ENTRIES) do
        local shown = {}
        for _, g in ipairs(e.g) do
            if present[g] then shown[#shown + 1] = g end
        end
        if #shown > 0 then
            local desc = e.d
            -- Name the skill node with the equipped skill (when one is known);
            -- the full effect is in the skill note near the top of the render.
            -- The skill's node is the generic '*' (e.skill) UNLESS it uses a
            -- dedicated grid type like Chain's 'C' (e.skill_grid_type).
            local sk = state.active_skill
            if sk and sk.display
                and ((e.skill and not sk.grid_type)
                    or (e.skill_grid_type and e.skill_grid_type == sk.grid_type)) then
                desc = sk.display
                    .. " skill node - an effective but limited-use bonus; route through it (effect in the skill note above)"
            end
            lines[#lines + 1] = "  " .. table.concat(shown, "/") .. " = " .. desc
        end
    end
    if #lines == 1 then return nil end
    return table.concat(lines, "\n")
end


-- True if any cell on the grid is a skill ('*'/1/2/3) node. Used to gate the
-- skill note: a skill can be equipped without a node appearing this puzzle.
local function grid_has_skill_node(state)
    -- A skill node is the yellow decoration: active_skill_type set (resolves to
    -- "Chain" -> 'C' for the Chain skill, or the ActiveSkill family -> '*').
    for y = 1, (state.height or 0) do
        local row = state.cells and state.cells[y]
        if row then
            for x = 1, (state.width or 0) do
                local cell = row[x]
                if cell and (cell.active_skill_type
                    or (cell.type and ACTIVE_SKILL_TYPES[cell.type])) then
                    return true
                end
            end
        end
    end
    return false
end


-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Render the full prompt block: header, terrain, coords, the single routing
-- rule, dynamic legend, optional adjacency, optional bonus list. Kept lean —
-- only the structural lines (header / " y  glyphs" rows / Cursor:/Goal:) are
-- load-bearing for the sim's round-trip parser; everything else is prose the
-- model reads. Mirrors the sim renderer in `sim/`.
--
-- opts.with_legend (default true)    - include the dynamic legend
-- opts.with_adjacency (default true) - include the per-direction adjacency block
function M.render(state, opts)
    opts = opts or {}
    local with_legend = opts.with_legend
    if with_legend == nil then with_legend = true end
    local with_adjacency = opts.with_adjacency
    if with_adjacency == nil then with_adjacency = true end

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
    if state.goal then
        table.insert(parts, string.format("Goal:   (%d, %d)", state.goal.x, state.goal.y))
    end

    -- The whole task in one line. y grows DOWNWARD, which LLMs routinely flip,
    -- so state it explicitly. Hazards are a hard constraint stated once here
    -- rather than repeated across legend/bonus/query.
    table.insert(parts,
        "Plan moves (up=-y, down=+y, left=-x, right=+x) from @ to G. NEVER step "
        .. "on a # (wall - cursor stops), a d (error node - RESETS the whole "
        .. "hack), or X (fails it). A hack that grabs NO blue reward nodes "
        .. "(the OPEN 'O' and ATTACK 'A' icons) does almost no damage, so PREFER "
        .. "a route that passes through an O or A or two on the way to G - even a "
        .. "few moves longer - as long as every cell is safe (never a # or d).")
    -- Equipped hacking MODE (the game's term): what the blue reward nodes do
    -- THIS hack. Only shown for a non-Default mode (state.mode set by get_state).
    if state.mode and state.mode.style then
        table.insert(parts, string.format(
            "Hacking mode - %s: %s", state.mode.style, state.mode.desc))
    end
    -- Equipped active SKILL: what its node does. Only when exactly one skill is
    -- known (state.active_skill) AND its node is actually on the grid. The node
    -- is '*' for most skills, or a dedicated glyph (Chain -> 'C').
    if state.active_skill and state.active_skill.desc
        and grid_has_skill_node(state) then
        local glyph = "*"
        if state.active_skill.grid_type then
            glyph = GLYPHS[state.active_skill.grid_type] or "*"
        end
        table.insert(parts, string.format("Skill node ('%s') = %s: %s",
            glyph, state.active_skill.display, state.active_skill.desc))
    end

    if state.trail and #state.trail > 1 then
        table.insert(parts,
            "Hack in progress: @ is the CURRENT cursor (not the start); plan from @.")
        if state.trail_back then
            -- Full-path backtracking: arrows on the visited path show the way home.
            table.insert(parts,
                "Your visited path is drawn as ARROWS (^v<>) leading back toward S. "
                .. "You may RETRACE it: move the way an arrow points to step back "
                .. "onto that cell (it frees up), and chain arrows to undo many "
                .. "moves at once - even all the way to S. Stop anywhere and head a "
                .. "new way. You CANNOT cross your path any other way (entering a "
                .. "visited cell against its arrow is blocked).")
        elseif state.came_from then
            -- Fallback: only the single immediately-previous cell is known.
            table.insert(parts, string.format(
                "You CAN reverse one step back onto the cell you came from "
                .. "(%d,%d) - it frees up. No other ~ cell is enterable.",
                state.came_from.x, state.came_from.y))
        end
    end

    if with_legend then
        local legend = dynamic_legend(state)
        if legend then
            table.insert(parts, "")
            table.insert(parts, legend)
        end
    end

    if with_adjacency then
        table.insert(parts, "")
        table.insert(parts, adjacency_block(state))
    end

    local bonuses = bonus_block(state)
    if bonuses then
        table.insert(parts, "")
        table.insert(parts, bonuses)
    end

    return table.concat(parts, "\n")
end


return M
