"""ASCII rendering for PuzzleSnake grids.

This is the surface the AI peer actually reads — what we send in `context`
messages. The exact format is up for tuning based on per-peer eval results,
so keep this module's API small and stable: a single `render(grid)` entry
plus helpers for the legend and adjacency hint.

Two modes:
- `inline=True` (default): cursor and trail overlaid on terrain. Compact.
- `inline=False`: terrain and trail rendered as two separate stacked grids.
  More tokens but easier for the model to disentangle.

Whichever mode is used, the output also includes:
- A header line with grid dimensions
- The cursor and goal coordinates
- An "Available moves" hint listing legal first-move directions
"""
from __future__ import annotations

from .grid_gen import ALL_DIRS, Cell, CellType, Dir, Grid
from .solver import _allowed_exits, _can_enter


# Single-glyph rendering for each cell type. Walls collapsed to one glyph
# since they're functionally identical for routing. None is plain walkable
# floor; Open is the BLUE bonus node (verified against in-game footage —
# the visible blue tiles are exactly the type=Open cells).
_GLYPHS: dict[CellType, str] = {
    CellType.START: "S",
    CellType.GOAL:  "G",
    CellType.OPEN:  "O",
    CellType.OBSTACLE:    "#",
    CellType.IMPASSABLE:  "#",
    CellType.NOTHING:     "#",
    CellType.NONE:        ".",
    CellType.SHIELD:      "s",
    CellType.CHAIN:       "C",
    CellType.TWO_WAY_LR:  "=",
    CellType.TWO_WAY_TD:  "|",
    CellType.TWO_WAY_LT:  "J",
    CellType.TWO_WAY_LD:  "7",
    CellType.TWO_WAY_RT:  "L",
    CellType.TWO_WAY_RD:  "r",
    # All ActiveSkill variants render '*'. The 1/2/3 suffixes are NOT skill level;
    # they tag which of multiple equipped skills a node belongs to (Code Generator
    # only) — never in normal play, and we don't distinguish it. Mirrors
    # snake_render.lua GLYPHS.
    CellType.ACTIVE_SKILL:   "*",
    CellType.ACTIVE_SKILL_1: "*",
    CellType.ACTIVE_SKILL_2: "*",
    CellType.ACTIVE_SKILL_3: "*",
    CellType.BOMB_3X3:    "b",
    CellType.BOMB_5X5:    "B",
    CellType.PURGE:       "P",
    CellType.ATTACK:      "A",
    CellType.ERASE_CODE:  "X",
    # FinishBlow renders as plain floor, NOT a distinct 'F'. In-game the
    # finish-blow node is almost always invisible (it only shows under specific
    # conditions) yet the engine reports it on nearly every grid, and a small
    # model reads "F"/"finish" as a finish/goal space. It's walkable floor to the
    # planner, so render it as such. Mirrors snake_render.lua GLYPHS.FinishBlow.
    CellType.FINISH_BLOW: ".",
    # Red error nodes get their OWN glyph 'd', distinct from inert walls '#':
    # both impassable, but entering an error node RESETS the whole hack while a
    # wall just stops the cursor. Mirrors snake_render.lua GLYPHS.DeadFilament
    # (the ObstacleGrid bit of _ObstacleReasons / is_blocked).
    CellType.DEAD_FILAMENT: "d",
}


_ONE_WAY_GLYPH = {
    Dir.UP: "^", Dir.DOWN: "v", Dir.LEFT: "<", Dir.RIGHT: ">",
}

CURSOR_GLYPH = "@"
TRAIL_GLYPH = "~"

# Backtrack arrows: each visited cell shows the direction to MOVE to step back
# onto it while retracing toward start (mirrors snake_render.lua trail_back).
_DELTA_DIR = {(0, -1): "up", (0, 1): "down", (-1, 0): "left", (1, 0): "right"}
_DIR_ARROW = {"up": "^", "down": "v", "left": "<", "right": ">"}


def _trail_back(grid: Grid) -> dict[tuple[int, int], str]:
    """Map (x,y) -> backtrack-in direction for each visited cell except the
    cursor. grid.trail is ordered start..cursor, so a cell's backtrack-in dir
    is the move FROM its cursor-side neighbour onto it."""
    t = grid.trail
    out: dict[tuple[int, int], str] = {}
    if len(t) < 2 or t[-1] != grid.cursor:
        return out
    for i in range(len(t) - 1):
        a, b = t[i], t[i + 1]  # a nearer start, b nearer cursor
        d = (a[0] - b[0], a[1] - b[1])
        if d in _DELTA_DIR:
            out[a] = _DELTA_DIR[d]
    return out


def _trail_glyph_for(tb: dict[tuple[int, int], str], x: int, y: int,
                     start: tuple[int, int] | None = None) -> str:
    # Keep "home" visible while retracing (the start is always on the trail).
    if start is not None and (x, y) == start:
        return _GLYPHS[CellType.START]
    return _DIR_ARROW.get(tb.get((x, y), ""), TRAIL_GLYPH)


# Bonus nodes the AI should route through, mapped against in-game footage.
# Keep in sync with snake_render.lua so offline prompts match the mod's output:
#   * BLUE  (tier 2, most valuable: more damage + longer-lasting hack) — the
#     Open grid type. Plain floor is None; on every grid checked the visible
#     blue tiles are exactly the type=Open cells.
#   * YELLOW (tier 1, secondary: the "skill node") — the ActiveSkill grid type
#     (and its 1/2/3 variants), glyph */1/2/3.
# Cell.is_golden_path (the engine's _IsGoldenPath) is the AUTO-HACK route
# marker — it floods most walkable cells and is intentionally NOT rendered or
# treated as a bonus; it would both hide the real blue nodes and hand the AI
# a pre-solved route.
# Other special types (Attack, Bomb, Chain, Purge) still render with their
# glyphs but aren't collect-targets. (FinishBlow is the exception: it renders as
# plain floor — see _GLYPHS.)
_ACTIVE_SKILL_TYPES = {
    CellType.ACTIVE_SKILL, CellType.ACTIVE_SKILL_1,
    CellType.ACTIVE_SKILL_2, CellType.ACTIVE_SKILL_3,
}


def cell_glyph(cell: Cell) -> str:
    # Red "error node" hazards win over everything else: in live grids
    # they're a decoration on an otherwise plain (often None) cell, not a
    # grid type — see Cell.blocked (the ObstacleGrid bit). Purple slow nodes
    # (Cell.dead_filament, _DeadFilamentType) are NOT error nodes: they're
    # walkable and fall through to their underlying type ('.' floor or 'O'
    # when also Open).
    if getattr(cell, "blocked", False):
        return _GLYPHS[CellType.DEAD_FILAMENT]
    if cell.type is CellType.ONE_WAY:
        if cell.direction is None:
            return ">"  # arbitrary fallback; shouldn't happen with valid grids
        return _ONE_WAY_GLYPH[cell.direction]
    return _GLYPHS.get(cell.type, "?")


def bonus_info(cell: Cell) -> tuple[int, str, str] | None:
    """(tier, color, label) for a bonus cell, else None. tier 2=blue, 1=yellow."""
    if cell.type in (CellType.GOAL, CellType.START):
        return None
    # Hazards are never collect-targets — the danger labels must win. Purple
    # slow nodes (dead_filament) are NOT hazards: a purple node that's also
    # Open is a real blue bonus and must stay collectible.
    if cell.type in (CellType.ERASE_CODE, CellType.DEAD_FILAMENT) \
            or getattr(cell, "blocked", False):
        return None
    if cell.type is CellType.OPEN:
        return 2, "blue OPEN node", "route THROUGH it - this is what makes the hack deal damage"
    if cell.type is CellType.ATTACK:
        # Offense/Hybrid mode reward node. Same BLUE color in-game, different
        # icon ('A'); never label it another color (clashes with what the
        # streamer says aloud). Mirrors snake_render.lua bonus_info.
        return 2, "blue ATTACK node", "route THROUGH it (just like an OPEN node) to boost your next hack's damage"
    if cell.type in _ACTIVE_SKILL_TYPES:
        return 1, "yellow skill node", "an effective but LIMITED-use bonus - grab it when it's on your way"
    return None


def render(grid: Grid, *, inline: bool = True, with_legend: bool = True,
           with_hint: bool = True, with_path_hint: bool = True) -> str:
    """Render `grid` to a string suitable for a `context` message body."""
    parts: list[str] = []
    parts.append(
        f"Hacking grid ({grid.width} wide, {grid.height} tall — "
        f"x ranges 0..{grid.width - 1}, y ranges 0..{grid.height - 1}):"
    )
    parts.append(_render_terrain(grid, overlay=inline))

    if not inline:
        parts.append("")
        parts.append("Trail:")
        parts.append(_render_trail_overlay(grid))

    parts.append("")
    parts.append(f"Cursor: ({grid.cursor[0]}, {grid.cursor[1]})")
    parts.append(f"Goal:   ({grid.goal[0]}, {grid.goal[1]})")

    # The whole task in one line; y grows DOWNWARD (LLMs flip this), hazards
    # stated once. Mirrors snake_render.lua's M.render.
    parts.append(
        "Plan moves (up=-y, down=+y, left=-x, right=+x) from @ to G. NEVER step "
        "on a # (wall - cursor just stops), a d (error node - RESETS the whole "
        "hack), or X (fails it); never enter ~ either. A hack that grabs NO blue "
        "reward nodes (the OPEN 'O' and ATTACK 'A' icons) does almost no damage, "
        "so PREFER a route that passes through an O or A or two on the way to G - "
        "even a few moves longer - as long as every cell is safe (never a # or d)."
    )
    if grid.trail and len(grid.trail) > 1:
        parts.append(
            "Hack in progress: @ is the CURRENT cursor (not the start); plan from @."
        )
        if _trail_back(grid):
            parts.append(
                "Your visited path is drawn as ARROWS (^v<>) leading back toward S. "
                "You may RETRACE it: move the way an arrow points to step back onto "
                "that cell (it frees up), and chain arrows to undo many moves at "
                "once - even all the way to S. Stop anywhere and head a new way. You "
                "CANNOT cross your path any other way (entering a visited cell "
                "against its arrow is blocked)."
            )
        else:
            came_from = _backtrack_cell(grid)
            if came_from is not None:
                parts.append(
                    f"You CAN reverse one step back onto the cell you came from "
                    f"({came_from[0]},{came_from[1]}) - it frees up. "
                    "No other ~ cell is enterable."
                )

    if with_legend:
        parts.append("")
        parts.append(legend(grid))

    if with_hint:
        parts.append("")
        parts.append(_adjacency_block(grid))

    bonuses = _bonus_block(grid)
    if bonuses is not None:
        parts.append("")
        parts.append(bonuses)

    if with_path_hint:
        # Lazy import to avoid module cycle.
        from .solver import solve
        plan = solve(grid)
        if plan is not None:
            parts.append("")
            if bonuses is not None:
                # Bonus nodes present: a longer route is fine ONLY if it stays
                # safe and picks up blue O's — never extend a path into # for them.
                parts.append(
                    f"The shortest path to G is {len(plan)} moves. A longer route "
                    "is fine only if it stays safe (no # / X) and collects blue O "
                    "nodes along the way; otherwise just reach G."
                )
            else:
                parts.append(
                    f"A legal path exists in {len(plan)} moves "
                    "(your plan should be roughly that length)."
                )

    return "\n".join(parts)


def _backtrack_cell(grid: Grid) -> tuple[int, int] | None:
    """The one visited cell the cursor may reverse onto (mirrors snake_render
    state.came_from). With reverse/undo, that's the trail cell the cursor
    arrived from — the entry just before the cursor in the ordered trail."""
    t = grid.trail
    if len(t) >= 2 and t[-1] == grid.cursor:
        cf = t[-2]
        cx, cy = grid.cursor
        if abs(cf[0] - cx) + abs(cf[1] - cy) == 1:  # orthogonally adjacent
            return cf
    return None


def _adjacency_block(grid: Grid) -> str:
    """Spell out the four cardinal directions from the cursor in detail.

    Format example:
        From cursor (3, 0):
          up    -> OUT OF BOUNDS (y=0 is already the top row)
          down  -> (3, 1) Open  [legal]
          left  -> (2, 0) Open  [legal]
          right -> (4, 0) Open  [legal]
    """
    cx, cy = grid.cursor
    blocked = set(grid.trail) - {grid.cursor}
    came_from = _backtrack_cell(grid)
    tb = _trail_back(grid)
    lines = [f"From cursor ({cx}, {cy}):"]

    for d in (Dir.UP, Dir.DOWN, Dir.LEFT, Dir.RIGHT):
        dx, dy = d.delta
        nx, ny = cx + dx, cy + dy
        label = f"  {d.value:5s} -> "

        if not grid.in_bounds(nx, ny):
            reason = f"y={cy} is already the top row" if d is Dir.UP and cy == 0 \
                else f"y={cy} is already the bottom row" if d is Dir.DOWN and cy == grid.height - 1 \
                else f"x={cx} is already the left edge" if d is Dir.LEFT and cx == 0 \
                else f"x={cx} is already the right edge" if d is Dir.RIGHT and cx == grid.width - 1 \
                else "out of grid"
            lines.append(f"{label}OUT OF BOUNDS ({reason})")
            continue

        target = grid.at(nx, ny)
        target_glyph = cell_glyph(target)
        target_type = target.type.value
        # FinishBlow renders as floor (see _GLYPHS); normalize its label too so
        # the adjacency line doesn't leak "FinishBlow" (read as a finish space).
        if target.type is CellType.FINISH_BLOW:
            target_type = "None"
        # Reward nodes: relabel to match their "blue OPEN/ATTACK node" reward tag
        # (and so "Attack" doesn't read as a hazard). Mirrors snake_render.lua.
        elif target.type is CellType.OPEN:
            target_type = "OPEN node"
        elif target.type is CellType.ATTACK:
            target_type = "ATTACK node"
        # Red error nodes ('d') are shown distinct from inert walls ('#'): both
        # impassable, but entering an error node RESETS the whole hack while a
        # wall just stops the cursor. Mirrors snake_render.lua adjacency_block.
        is_error_node = (target.type is CellType.DEAD_FILAMENT
                         or getattr(target, "blocked", False))
        if is_error_node:
            target_type = "Error node"
        info = f"({nx}, {ny}) [{target_glyph}] {target_type}"

        if (nx, ny) in blocked:
            # Enterable only via its backtrack arrow (move into it == its
            # trail_back dir); fall back to the single came_from cell.
            back = tb.get((nx, ny))
            if (back is not None and back == d.value) \
                    or (not tb and came_from is not None and (nx, ny) == came_from):
                lines.append(f"{label}{info}  legal - BACKTRACK: "
                             "step back along your visited path (frees it)")
            else:
                lines.append(f"{label}{info}  ILLEGAL: visited - "
                             "can't re-enter from this side")
            continue

        rule = target.rule()
        if is_error_node:
            lines.append(f"{label}{info}  ILLEGAL: error node - "
                         "entering RESETS the whole hack to start")
            continue
        if rule.blocks_step:
            lines.append(f"{label}{info}  ILLEGAL: wall - cannot enter "
                         "(cursor just stops)")
            continue
        if rule.fails_on_step:
            lines.append(f"{label}{info}  DANGER: X trap - entering FAILS the hack")
            continue
        if rule.transitions is not None:
            entries = {e for (e, _) in rule.transitions}
            if d not in entries:
                lines.append(f"{label}{info}  ILLEGAL: directional cell, won't accept entry from this side")
                continue
        binfo = bonus_info(target)
        if binfo is not None:
            _, bname, blabel = binfo
            lines.append(f"{label}{info}  legal — {bname}, {blabel}")
        else:
            lines.append(f"{label}{info}  legal")

    return "\n".join(lines)


def _bonus_block(grid: Grid) -> str | None:
    """List uncollected bonus nodes, highest tier first, with the route goal.

    Mirrors `bonus_block` in snake_render.lua. Returns None when the grid has
    no bonus nodes so plain grids stay uncluttered.
    """
    blocked = set(grid.trail)  # cells already crossed = bonus already collected
    found: list[tuple[int, int, int, str, str, str]] = []
    for y in range(grid.height):
        for x in range(grid.width):
            if (x, y) in blocked:
                continue
            cell = grid.at(x, y)
            binfo = bonus_info(cell)
            if binfo is not None:
                tier, color, label = binfo
                found.append((tier, y, x, cell_glyph(cell), color, label))
    if not found:
        return None

    # Most valuable (blue) first, then top-to-bottom / left-to-right.
    found.sort(key=lambda t: (-t[0], t[1], t[2]))

    lines = [
        "Blue reward nodes (the OPEN 'O' and ATTACK 'A' icons) are where the "
        "damage comes from - a hack that grabs NONE is nearly useless. ACTIVELY "
        "pick a SAFE route that "
        "passes through one or two on the way to G, even if it is a few moves "
        "longer than the straight line. Collect them by passing THROUGH them "
        "going forward - do NOT detour out to one and come back the same way, "
        "since retracing your own path UNDOES the rewards you grabbed. Hard "
        "limits: never step on a # (wall) or d (error node) to reach one - a d "
        "resets the whole hack - and only fall back to the shortest path if none "
        "can be reached without crossing a # or d. (Yellow skill nodes - '*' or "
        "'C' - are effective but limited-use: grab one when it's on your way, "
        "but you don't need one every hack.)",
    ]
    for _tier, y, x, glyph, color, label in found:
        lines.append(f"  ({x}, {y}) [{glyph}] {color} - {label}")
    return "\n".join(lines)


def _render_terrain(grid: Grid, *, overlay: bool) -> str:
    """Render the grid as ASCII rows. Optionally overlays cursor and trail."""
    cursor = set([grid.cursor])
    trail = set(grid.trail) - cursor  # cursor takes priority over trail glyph
    tb = _trail_back(grid)

    # Header row with x coordinates. Single-digit x is fine since width <= 8.
    header = "    " + " ".join(str(x) for x in range(grid.width))
    rows = [header]
    for y in range(grid.height):
        row_glyphs = []
        for x in range(grid.width):
            if overlay and (x, y) in cursor:
                g = CURSOR_GLYPH
            elif overlay and (x, y) in trail:
                g = _trail_glyph_for(tb, x, y, grid.start)
            else:
                g = cell_glyph(grid.at(x, y))
            row_glyphs.append(g)
        rows.append(f" {y}  " + " ".join(row_glyphs))
    return "\n".join(rows)


def _render_trail_overlay(grid: Grid) -> str:
    """Layered-mode trail rendering: '.' for empty, '~' for trail, '@' for cursor."""
    header = "    " + " ".join(str(x) for x in range(grid.width))
    rows = [header]
    trail = set(grid.trail) - {grid.cursor}
    for y in range(grid.height):
        row = []
        for x in range(grid.width):
            if (x, y) == grid.cursor:
                row.append(CURSOR_GLYPH)
            elif (x, y) in trail:
                row.append(TRAIL_GLYPH)
            else:
                row.append(".")
        rows.append(f" {y}  " + " ".join(row))
    return "\n".join(rows)


def available_moves(grid: Grid) -> list[Dir]:
    """Directions the cursor could move right now, accounting for trail/walls/rules.

    Mirrors solver._can_enter but doesn't account for directional exit rules
    on the cursor cell, since we don't know `last_entry_dir` from outside the
    plan-replay context. For Start cells, all 4 dirs are evaluated.
    """
    cursor_cell = grid.at(*grid.cursor)
    last_entry_dir = None  # consistent with solver's start-state assumption
    exits = _allowed_exits(cursor_cell, last_entry_dir)
    blocked = set(grid.trail) - {grid.cursor}

    valid: list[Dir] = []
    for d in exits:
        dx, dy = d.delta
        nx, ny = grid.cursor[0] + dx, grid.cursor[1] + dy
        if not grid.in_bounds(nx, ny):
            continue
        if (nx, ny) in blocked:
            continue
        target = grid.at(nx, ny)
        if not _can_enter(target, d):
            continue
        # EraseCode is technically enterable but suicidal; we still list it as
        # available so the model has the full picture and can choose to avoid.
        # Error nodes (blocked) are excluded by _can_enter like other walls.
        valid.append(d)
    return valid


# Dynamic legend — only the glyphs that actually appear in the grid. Mirrors
# snake_render.lua's LEGEND_ENTRIES / dynamic_legend so offline prompts match
# what the mod sends live. Order is priority; some entries group glyphs.
_LEGEND_ENTRIES: list[tuple[list[str], str]] = [
    (["G"], "goal - reach this to finish the hack"),
    (["S"], "start"),
    (["@"], "cursor - your current position"),
    (["."], "walkable floor"),
    (["#"], "wall - CANNOT enter (cursor just stops there)"),
    (["d"], "error node - CANNOT enter; entering RESETS the whole hack back to start"),
    (["~"], "visited cell (direction unknown) - cannot re-enter"),
    (["O"], "blue OPEN node - route THROUGH these; they're what makes the hack deal damage (a path that skips them does almost nothing)"),
    (["A"], "blue ATTACK node - route THROUGH these just like OPEN nodes to boost your next hack's damage"),
    (["*"], "YELLOW skill node - an effective but limited-use bonus (grab when it's on the way)"),
    (["X"], "ERASE trap - stepping here FAILS the hack"),
    (["b", "B"], "bomb node"),
    (["P"], "purge node"),
    (["C"], "chain node"),
    (["s"], "shield - blocked"),
    (["^", "v", "<", ">"], "one-way gate - only enter along its arrow"),
    (["=", "|", "J", "7", "L", "r"],
     "directional gate - only enter/exit along its arrows"),
]


def _present_glyphs(grid: Grid) -> set[str]:
    present: set[str] = set()
    trail = set(grid.trail) - {grid.cursor}
    tb = _trail_back(grid)
    for y in range(grid.height):
        for x in range(grid.width):
            if (x, y) == grid.cursor:
                present.add("@")
            elif (x, y) in trail:
                present.add(_trail_glyph_for(tb, x, y, grid.start))
            else:
                present.add(cell_glyph(grid.at(x, y)))
    return present


def legend(grid: Grid | None = None) -> str:
    if grid is None:
        # No grid context: fall back to listing every entry.
        present = {g for entry in _LEGEND_ENTRIES for g in entry[0]}
    else:
        present = _present_glyphs(grid)
    lines = ["Legend:"]
    for glyphs, desc in _LEGEND_ENTRIES:
        shown = [g for g in glyphs if g in present]
        if shown:
            lines.append("  " + "/".join(shown) + " = " + desc)
    return "\n".join(lines)
