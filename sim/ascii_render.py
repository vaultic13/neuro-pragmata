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
# since they're functionally identical for routing.
_GLYPHS: dict[CellType, str] = {
    CellType.START: "S",
    CellType.GOAL:  "G",
    CellType.OPEN:  ".",
    CellType.OBSTACLE:    "#",
    CellType.IMPASSABLE:  "#",
    CellType.NOTHING:     "#",
    CellType.NONE:        "#",
    CellType.SHIELD:      "s",
    CellType.CHAIN:       "C",
    CellType.TWO_WAY_LR:  "=",
    CellType.TWO_WAY_TD:  "|",
    CellType.TWO_WAY_LT:  "J",
    CellType.TWO_WAY_LD:  "7",
    CellType.TWO_WAY_RT:  "L",
    CellType.TWO_WAY_RD:  "r",
    CellType.ACTIVE_SKILL:   "*",
    CellType.ACTIVE_SKILL_1: "1",
    CellType.ACTIVE_SKILL_2: "2",
    CellType.ACTIVE_SKILL_3: "3",
    CellType.BOMB_3X3:    "b",
    CellType.BOMB_5X5:    "B",
    CellType.PURGE:       "P",
    CellType.ATTACK:      "A",
    CellType.ERASE_CODE:  "X",
    CellType.FINISH_BLOW: "F",
    CellType.DEAD_FILAMENT: "d",
}


_ONE_WAY_GLYPH = {
    Dir.UP: "^", Dir.DOWN: "v", Dir.LEFT: "<", Dir.RIGHT: ">",
}

CURSOR_GLYPH = "@"
TRAIL_GLYPH = "~"


# Bonus nodes the AI should route through, mapped against in-game node dumps.
# Keep in sync with snake_render.lua so offline prompts match the mod's output:
#   * BLUE  (tier 2, most valuable: more damage + longer-lasting hack) — flagged
#     by Cell.is_golden_path (the engine's _IsGoldenPath; these read as plain
#     Open). Rendered with GOLDEN_GLYPH. The generator doesn't place these yet,
#     so synthetic grids currently exercise only the yellow nodes below.
#   * YELLOW (tier 1, secondary: the "skill node") — the ActiveSkill grid type
#     (and its 1/2/3 variants), glyph */1/2/3.
# Other special types (FinishBlow, Attack, Bomb, Chain, Purge) still render with
# their glyphs but aren't collect-targets.
GOLDEN_GLYPH = "O"  # blue golden-path node

_ACTIVE_SKILL_TYPES = {
    CellType.ACTIVE_SKILL, CellType.ACTIVE_SKILL_1,
    CellType.ACTIVE_SKILL_2, CellType.ACTIVE_SKILL_3,
}


def cell_glyph(cell: Cell) -> str:
    # Blue golden-path nodes read as plain Open, so render them O — but never
    # mask the Goal/Start terminals.
    if getattr(cell, "is_golden_path", False) \
            and cell.type not in (CellType.GOAL, CellType.START):
        return GOLDEN_GLYPH
    if cell.type is CellType.ONE_WAY:
        if cell.direction is None:
            return ">"  # arbitrary fallback; shouldn't happen with valid grids
        return _ONE_WAY_GLYPH[cell.direction]
    return _GLYPHS.get(cell.type, "?")


def bonus_info(cell: Cell) -> tuple[int, str, str] | None:
    """(tier, color, label) for a bonus cell, else None. tier 2=blue, 1=yellow."""
    if cell.type in (CellType.GOAL, CellType.START):
        return None
    if getattr(cell, "is_golden_path", False):
        return 2, "BLUE", "golden-path node: more damage + longer-lasting hack"
    if cell.type in _ACTIVE_SKILL_TYPES:
        return 1, "YELLOW", "skill node"
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

    if grid.trail and len(grid.trail) > 1:
        trail_str = ", ".join(f"({x},{y})" for x, y in grid.trail)
        parts.append(f"Visited: {trail_str}")

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
                # With bonus nodes present, the shortest path is a floor, not a
                # target — a longer bonus-collecting route is the goal.
                parts.append(
                    f"The shortest possible path to G is {len(plan)} moves — "
                    "that's the minimum, not the target. A longer route is "
                    "expected and good if it collects more bonus nodes."
                )
            else:
                parts.append(
                    f"A legal path exists in {len(plan)} moves "
                    "(your plan should be roughly that length)."
                )

    if with_legend:
        parts.append("")
        parts.append(legend())

    return "\n".join(parts)


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
        if getattr(target, "is_golden_path", False) \
                and target.type not in (CellType.GOAL, CellType.START):
            target_type = "GoldenPath"
        info = f"({nx}, {ny}) [{target_glyph}] {target_type}"

        if (nx, ny) in blocked:
            lines.append(f"{label}{info}  ILLEGAL: in trail (already visited)")
            continue

        rule = target.rule()
        if rule.blocks_step:
            lines.append(f"{label}{info}  ILLEGAL: wall — cannot enter")
            continue
        if rule.fails_on_step:
            lines.append(f"{label}{info}  DANGER: EraseCode — entering ends the hack as failure")
            continue
        if rule.transitions is not None:
            entries = {e for (e, _) in rule.transitions}
            if d not in entries:
                lines.append(f"{label}{info}  ILLEGAL: directional cell, won't accept entry from this side")
                continue
        binfo = bonus_info(target)
        if binfo is not None:
            _, bcolor, blabel = binfo
            lines.append(f"{label}{info}  legal — {bcolor} BONUS: {blabel}")
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
        "Bonus nodes - pass through as MANY as possible on the way to G. They",
        "make the hack do more damage and last longer, so a longer, winding",
        "route that collects more bonuses is BETTER than the shortest path - as",
        "long as the plan still ends on G and never steps on an X (EraseCode)",
        "trap or revisits a ~ trail cell. BLUE (O) nodes are worth the most;",
        "grab them first, then YELLOW (*) skill nodes:",
    ]
    for _tier, y, x, glyph, color, label in found:
        lines.append(f"  ({x}, {y}) [{glyph}] {color} - {label}")
    return "\n".join(lines)


def _render_terrain(grid: Grid, *, overlay: bool) -> str:
    """Render the grid as ASCII rows. Optionally overlays cursor and trail."""
    cursor = set([grid.cursor])
    trail = set(grid.trail) - cursor  # cursor takes priority over trail glyph

    # Header row with x coordinates. Single-digit x is fine since width <= 8.
    header = "    " + " ".join(str(x) for x in range(grid.width))
    rows = [header]
    for y in range(grid.height):
        row_glyphs = []
        for x in range(grid.width):
            if overlay and (x, y) in cursor:
                g = CURSOR_GLYPH
            elif overlay and (x, y) in trail:
                g = TRAIL_GLYPH
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
        valid.append(d)
    return valid


def legend() -> str:
    return (
        "Legend: S=start G=goal .=open #=wall  @=cursor ~=trail (cannot revisit)\n"
        "        O=BLUE node (golden path: most damage + longest hack - TOP priority)\n"
        "        *=YELLOW skill node (1/2/3 variants) - secondary bonus\n"
        "        Route through as many O and * nodes as you can en route to G.\n"
        "        X=ERASE_CODE (DO NOT STEP — ends hack as failure)\n"
        "        > < ^ v=oneway (only this direction) = | J L 7 r=twoway/corner\n"
        "        b=bomb3x3 B=bomb5x5 P=purge C=chain A=attack F=finishblow s=shield"
    )
