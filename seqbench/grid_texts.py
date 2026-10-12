"""The mod's enemy hacking-grid wording (pragmata_enemy_hack_plan), for the grid bench.

A Python port of autorun/pragmata/util/snake_render.lua as of 2026-10-08, at
glyph level: a puzzle here is a grid of glyphs (what the peer sees), not the
engine's cell records. It covers everything the mod has actually sent -- walls,
error nodes, red blocks (R), corrupted cells (c), blue O / A and yellow * nodes,
the trail (arrows or ~), the sticky-bomb note, the red-block and corruption
notes, the hacking-mode line, the dynamic legend and the bonus list. Left out
because no force has ever carried them: directional gates, the equipped-skill
note, bomb / purge / chain / shield nodes.

`parse_state` reads a state text back into a GridPuzzle, and the selftest
checks `render(parse_state(s)) == s` for every force in grid_corpus.json, so
the port is proven byte for byte against what the mod sent. As with
sequence_texts.py, nothing here is imported from autorun/: if the mod's render
changes, port the change on purpose and re-run the selftest.

Also here: the force query, the pragmata_enemy_hack_plan registration and the mod's
tool-result strings (bindings/puzzle_snake.lua, hacking_observer.lua).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from typing import Optional

ACTION_NAME = "pragmata_enemy_hack_plan"
PRIORITY = "high"
FORCE_QUERY = ("Hacking grid is live. Call pragmata_enemy_hack_plan with your moves from @ to G "
               "(see the grid).")

DIRECTIONS = ("up", "down", "left", "right")
DELTAS = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}
ARROW = {"up": "^", "down": "v", "left": "<", "right": ">"}
ARROW_DIR = {v: k for k, v in ARROW.items()}

# The registration the mod sends (pragmata_main.lua, hacking_require_reasoning
# off), copied from the latest actions/register in lua_to_bridge.jsonl.
ACTION_DEF = {
    "name": ACTION_NAME,
    "description": (
        "Plan a path through the active hacking grid from cursor @ to Goal G.\n"
        "Coordinates: (0,0) is TOP-LEFT. x=column (left->right). y=row "
        "(top->bottom). 'up' decreases y by 1; 'down' increases y by 1; "
        "'left' decreases x by 1; 'right' increases x by 1. The first row "
        "is y=0; the last row is y=height-1. You cannot move 'up' from "
        "y=0 or 'down' from y=height-1.\n"
        "Read the state field carefully — the cursor and goal positions "
        "are given there, and the Adjacency block lists which first-moves "
        "are legal. Use those positions verbatim; do not infer or guess.\n"
        "NEVER step on a # (a wall — the cursor just stops), a d (an error "
        "node — entering RESETS the whole hack and you lose all progress), or "
        "an X (it fails the hack), and never re-enter a ~ trail cell against "
        "its arrow. Check "
        "EVERY move's destination cell against the grid, not just the first "
        "one. Plan ends on G.\n"
        "BONUS NODES: blue 'O' nodes are where the damage comes from — a hack "
        "that grabs none is nearly useless, so ACTIVELY prefer a SAFE route "
        "that passes through one or two O's on the way to G, even a few moves "
        "longer. Collect them going forward; do NOT detour out to a blue and "
        "double back, since retracing your own path undoes the blues. Hard "
        "limits: never step on a # (wall) or d (error node) to reach one - a d "
        "resets the whole hack - and only fall back to the shortest path if no "
        "O is reachable without crossing a # or d. (Yellow '*' = minor "
        "secondary bonus.)"
    ),
    "schema": {
        "type": "object",
        "required": ["moves"],
        "properties": {
            "moves": {"type": "array", "minItems": 1, "maxItems": 32,
                      "items": {"enum": list(DIRECTIONS)}},
        },
    },
}

# ---------------------------------------------------------------------------
# Tool-result strings (bindings/puzzle_snake.lua, hacking_observer.lua)
# ---------------------------------------------------------------------------

MSG_SOLVED = "Reached the goal — the hack is complete."
MSG_WALL = "Move blocked by a wall after {n} move(s) landed; the cursor stopped there."
MSG_RESET = ("Hit an error node — the puzzle reset to the start, so none of those "
             "moves counted.")
MSG_OFF_GRID = ("A planned move couldn't run (it ran off the grid), so the plan "
                "stopped before reaching the goal.")
MSG_SHORT = "Ran all {n} planned move(s) without reaching the goal (cursor now at {x},{y})."
MSG_RED_REFUSED = ("Plan refused: move {i} would enter a red block at ({x}, {y}), and "
                   "touching a red block fails the hack. None of the moves were made; "
                   "plan a route that avoids every R cell.")
MSG_FAILED = "The hack failed."
MSG_NO_MOVES = "no moves to apply"

# ---------------------------------------------------------------------------
# The puzzle
# ---------------------------------------------------------------------------

# Glyphs a cell can carry underneath the cursor/trail overlay.
WALLS = frozenset("#s")
BONUS_NAMES = {
    "O": ("blue OPEN node", "route THROUGH it - this is what makes the hack deal damage"),
    "A": ("blue ATTACK node", "route THROUGH it (just like an OPEN node) to boost your next hack's damage"),
    "*": ("yellow skill node", "an effective but LIMITED-use bonus - grab it when it's on your way"),
}
_TIER = {"O": 2, "A": 2, "*": 1}
_NAME_TO_GLYPH = {v[0]: k for k, v in BONUS_NAMES.items()}

Pos = tuple[int, int]


@dataclass
class GridPuzzle:
    width: int
    height: int
    cells: list[list[str]]                 # [y][x] the cell's own glyph (no cursor / trail)
    cursor: Pos
    goal: Pos
    start: Optional[Pos] = None
    # Visited path from the start up to (not including) the cursor, in order.
    trail: list[Pos] = field(default_factory=list)
    trail_mode: str = "arrows"             # arrows | came_from | none: how the mod drew it
    # What a corrupted 'c' cell is underneath when it is also a bonus ('O' / 'A' / '*').
    under: dict[Pos, str] = field(default_factory=dict)
    blocks: Optional[tuple[int, int, Optional[str]]] = None   # (active, total, next corner)
    skipped: Optional[tuple[int, int]] = None                   # sticky bombs: (rows, cols)
    mode_line: Optional[str] = None

    def glyph(self, x: int, y: int) -> Optional[str]:
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.cells[y][x]
        return None

    def bonus_type(self, x: int, y: int) -> Optional[str]:
        g = self.glyph(x, y)
        if g == "c":
            return self.under.get((x, y))
        return g if g in BONUS_NAMES else None

    @property
    def corrupted(self) -> bool:
        return any("c" in row for row in self.cells)

    def copy(self) -> "GridPuzzle":
        return replace(self, cells=[list(r) for r in self.cells], trail=list(self.trail),
                       under=dict(self.under))


# ---------------------------------------------------------------------------
# Render (snake_render.lua M.render, with_adjacency as the observer calls it)
# ---------------------------------------------------------------------------

ROUTING_RULE = (
    "Plan moves (up=-y, down=+y, left=-x, right=+x) from @ to G. NEVER step "
    "on a # (wall - cursor stops), a d (error node - RESETS the whole "
    "hack), or an X or R (fails it). A hack that grabs NO blue reward nodes "
    "(the OPEN 'O' and ATTACK 'A' icons) does almost no damage, so PREFER "
    "a route that passes through an O or A or two on the way to G - even a "
    "few moves longer - as long as every cell is safe (never a #, d or R).")
# The rule as the mod worded it before the red blocks (2026-10-08, part A).
# Forces recorded with it are kept and re-sent in today's wording.
OLD_ROUTING_RULE = (
    "Plan moves (up=-y, down=+y, left=-x, right=+x) from @ to G. NEVER step "
    "on a # (wall - cursor stops), a d (error node - RESETS the whole "
    "hack), or X (fails it). A hack that grabs NO blue reward nodes "
    "(the OPEN 'O' and ATTACK 'A' icons) does almost no damage, so PREFER "
    "a route that passes through an O or A or two on the way to G - even a "
    "few moves longer - as long as every cell is safe (never a # or d).")
CORRUPTED_NOTE = (
    "CORRUPTED ENEMY: the c cells are corrupted - stepping on one stuns the "
    "cursor for a moment. It does NOT fail the hack, it only costs time, "
    "so prefer a clean route but cross a c when that is the only way.")
ARROWS_NOTE = (
    "Your visited path is drawn as ARROWS (^v<>) leading back toward S. "
    "You may RETRACE it: move the way an arrow points to step back "
    "onto that cell (it frees up), and chain arrows to undo many "
    "moves at once - even all the way to S. Stop anywhere and head a "
    "new way. You CANNOT cross your path any other way (entering a "
    "visited cell against its arrow is blocked).")
BONUS_INTRO = (
    "Blue reward nodes (the OPEN 'O' and ATTACK 'A' icons, listed below) are "
    "where the damage comes from - a hack that grabs NONE is nearly "
    "useless. ACTIVELY "
    "pick a SAFE route that passes through one or two of them on the "
    "way to G, even if it is a few moves longer than the straight line. "
    "Collect them by passing THROUGH them going forward - do NOT detour "
    "out to one and come back the same way, since retracing your own "
    "path UNDOES the rewards you grabbed. Hard limits: never step on a "
    "# (wall) or d (error node) to reach one - a d RESETS the whole "
    "hack - and only fall back to the shortest path if none can be "
    "reached without crossing a # or d. (Yellow skill nodes - '*' or "
    "'C' - are effective but limited-use: grab one when it's on your "
    "way, but you don't need one every hack.)")
LEGEND_ENTRIES = (
    (("G",), "goal - reach this to finish the hack"),
    (("S",), "start"),
    (("@",), "cursor - your current position"),
    ((".",), "walkable floor"),
    (("#",), "wall - CANNOT enter (cursor just stops there)"),
    (("d",), "error node - CANNOT enter; entering RESETS the whole hack back to start"),
    (("^", "v", "<", ">"),
     "your visited path - MOVE the way an arrow points to retrace one step back onto it "
     "(frees that cell); chain them to undo many moves"),
    (("~",), "visited cell (direction unknown) - cannot re-enter"),
    (("O",), "blue OPEN node - route THROUGH these; they're what makes the hack deal damage "
             "(a path that skips them does almost nothing)"),
    (("A",), "blue ATTACK node - route THROUGH these just like OPEN nodes to boost your next "
             "hack's damage"),
    (("*",), "YELLOW skill node - an effective but limited-use bonus (grab when it's on the way)"),
    (("X",), "ERASE trap - stepping here FAILS the hack"),
    (("R",), "red block - CANNOT enter; touching it FAILS the hack"),
    (("c",), "corrupted cell - walkable, but stuns the cursor for a moment (the hack does NOT "
             "fail); avoid when a clean route exists"),
    (("b", "B"), "bomb node"),
    (("P",), "purge node"),
    (("C",), "chain node"),
    (("s",), "shield - blocked"),
    (("=", "|", "J", "7", "L", "r"), "directional gate - only enter/exit along its arrows"),
)


def trail_arrows(p: GridPuzzle) -> dict[Pos, str]:
    """Each visited cell's arrow: the move that steps back onto it from the
    cell after it on the path (snake_render's trail_back)."""
    out: dict[Pos, str] = {}
    path = p.trail + [p.cursor]
    for here, nxt in zip(path, path[1:]):
        dx, dy = here[0] - nxt[0], here[1] - nxt[1]
        for d, delta in DELTAS.items():
            if delta == (dx, dy):
                out[here] = d
    return out


def overlay(p: GridPuzzle) -> list[list[str]]:
    """The grid as drawn: cells, then the trail, then the cursor."""
    rows = [list(r) for r in p.cells]
    arrows = trail_arrows(p) if p.trail_mode == "arrows" else {}
    for pos in p.trail:
        x, y = pos
        if p.start is not None and pos == p.start:
            rows[y][x] = "S"
        elif pos in arrows:
            rows[y][x] = ARROW[arrows[pos]]
        else:
            rows[y][x] = "~"
    rows[p.cursor[1]][p.cursor[0]] = "@"
    return rows


def _legend(drawn: list[list[str]]) -> Optional[str]:
    present = {g for row in drawn for g in row}
    lines = ["Legend:"]
    for glyphs, desc in LEGEND_ENTRIES:
        shown = [g for g in glyphs if g in present]
        if shown:
            lines.append("  " + "/".join(shown) + " = " + desc)
    return "\n".join(lines) if len(lines) > 1 else None


def _bonus_block(p: GridPuzzle) -> Optional[str]:
    visited = set(p.trail) | {p.cursor}
    found = []
    for y in range(p.height):
        for x in range(p.width):
            if (x, y) in visited:
                continue
            kind = p.bonus_type(x, y)
            if kind is None:
                continue
            found.append((-_TIER[kind], y, x, kind))
    if not found:
        return None
    found.sort()
    lines = [BONUS_INTRO]
    for _, y, x, kind in found:
        name, label = BONUS_NAMES[kind]
        lines.append(f"  ({x}, {y}) [{p.cells[y][x]}] {name} - {label}")
    return "\n".join(lines)


_ADJ_TYPE = {".": "None", "#": "Wall", "s": "Wall", "d": "Error node", "R": "Red block",
             "O": "OPEN node", "A": "ATTACK node", "*": "None/ActiveSkill", "G": "Goal",
             "S": "Start", "X": "EraseCode"}


def _adjacency(p: GridPuzzle, drawn: list[list[str]]) -> str:
    """snake_render's adjacency block. The mod sends it off; this is a bench
    candidate (version 'adjacency'), so it is not checked against a corpus."""
    cx, cy = p.cursor
    arrows = trail_arrows(p) if p.trail_mode == "arrows" else {}
    came_from = p.trail[-1] if p.trail else None
    visited = set(p.trail)
    lines = [f"From cursor ({cx}, {cy}):"]
    edge = {"up": "y=0 is already the top row", "down": f"y={cy} is already the bottom row",
            "left": "x=0 is already the left edge", "right": f"x={cx} is already the right edge"}
    for d in DIRECTIONS:
        dx, dy = DELTAS[d]
        nx, ny = cx + dx, cy + dy
        prefix = f"  {d:<5} -> "
        g = p.glyph(nx, ny)
        if g is None:
            lines.append(prefix + f"OUT OF BOUNDS ({edge[d]})")
            continue
        under = p.under.get((nx, ny)) if g == "c" else g
        kind = _ADJ_TYPE.get(under or ".", "None")
        info = f"({nx}, {ny}) [{drawn[ny][nx] if (nx, ny) not in visited else g}] {kind}"
        if (nx, ny) in visited:
            back = arrows.get((nx, ny))
            if back == d or (p.trail_mode != "arrows" and (nx, ny) == came_from):
                lines.append(prefix + info + "  legal -- BACKTRACK: step back along your visited path (frees it)")
            else:
                lines.append(prefix + info + "  ILLEGAL: visited - can't re-enter from this side")
        elif g == "R":
            lines.append(prefix + info + "  ILLEGAL: red block - touching it FAILS the hack")
        elif g == "d":
            lines.append(prefix + info + "  ILLEGAL: error node - entering RESETS the whole hack to start")
        elif g in WALLS:
            lines.append(prefix + info + "  ILLEGAL: wall - cannot enter (cursor just stops)")
        elif g == "c":
            lines.append(prefix + info + "  legal -- corrupted: stuns the cursor for a moment (slower, not a fail)")
        elif g == "X":
            lines.append(prefix + info + "  DANGER: X trap - entering FAILS the hack")
        elif g in BONUS_NAMES:
            name, label = BONUS_NAMES[g]
            lines.append(prefix + info + f"  legal -- {name}, {label}")
        else:
            lines.append(prefix + info + "  legal")
    return "\n".join(lines)


def render(p: GridPuzzle, adjacency: bool = False) -> str:
    drawn = overlay(p)
    parts = [f"Hacking grid ({p.width} wide, {p.height} tall - x ranges 0..{p.width - 1}, "
             f"y ranges 0..{p.height - 1}):"]
    rows = ["    " + "".join(f"{x} " for x in range(p.width))]
    for y in range(p.height):
        rows.append((f" {y}  " + "".join(g + " " for g in drawn[y])).rstrip())
    parts.append("\n".join(rows))
    if p.skipped and (p.skipped[0] or p.skipped[1]):
        parts.append(f"NOTE: {p.skipped[0]} row(s) and {p.skipped[1]} column(s) are currently "
                     "REMOVED from the grid")
        parts.append("(sticky bombs). The layout above is the live, playable grid.")
    parts.append("")
    parts.append(f"Cursor: ({p.cursor[0]}, {p.cursor[1]})")
    parts.append(f"Goal:   ({p.goal[0]}, {p.goal[1]})")
    if p.blocks and p.blocks[0] > 0:
        active, total, corner = p.blocks
        nxt = f" (next to go: the {corner} one)" if corner else ""
        parts.append(f"RED BLOCKS: {active} of {total} still up (the R cells). Touching one FAILS "
                     "the hack - route around them. Shooting the enemy's antennas removes them one "
                     f"at a time{nxt}.")
    if p.corrupted:
        parts.append(CORRUPTED_NOTE)
    parts.append(ROUTING_RULE)
    if p.mode_line:
        parts.append(p.mode_line)
    if len(p.trail) >= 1:
        parts.append("Hack in progress: @ is the CURRENT cursor (not the start); plan from @.")
        if p.trail_mode == "arrows":
            parts.append(ARROWS_NOTE)
        elif p.trail_mode == "came_from":
            cx, cy = p.trail[-1]
            parts.append(f"You CAN reverse one step back onto the cell you came from "
                         f"({cx},{cy}) - it frees up. No other ~ cell is enterable.")
    legend = _legend(drawn)
    if legend:
        parts += ["", legend]
    if adjacency:
        parts += ["", _adjacency(p, drawn)]
    bonuses = _bonus_block(p)
    if bonuses:
        parts += ["", bonuses]
    return "\n".join(parts)


def layout_fingerprint(p: GridPuzzle) -> str:
    """snake_render.layout_fingerprint: size, goal and the # / d / R cells."""
    rows = ["".join(g if g in "#dR" else "." for g in row) for row in p.cells]
    return f"{p.width}x{p.height}|{p.goal[0]},{p.goal[1]}|" + "/".join(rows)


# The final boss's five fixed stages (bindings/puzzle_snake.lua FINALE_STAGES).
FINALE_STAGES = {
    "9x9|4,4|####....#/#..###.##/##.....#./##.#####./##.#...../##.###.##/#....#..#/#.##.##.#/####....#": 1,
    "7x9|3,8|###.###/......./#####.#/......./#.#####/......./###.###/......./###.###": 2,
    "9x9|4,6|#########/##..#..##/####..###/###...###/###.#.###/###...###/###..####/##..#..##/#########": 3,
    "7x7|6,6|.#####d/.#...##/.#.#.../.#.#.#./...#.#./##...#./d#####.": 4,
    "7x7|3,6|d#d.##./d#..#.#/#d.##.d/#....#d/d###.d./#d#...#/d##.#d#": 5,
}


def finale_stage(p: GridPuzzle) -> Optional[int]:
    return FINALE_STAGES.get(layout_fingerprint(p))


# ---------------------------------------------------------------------------
# Parse a state text back into a puzzle
# ---------------------------------------------------------------------------

_HEADER = re.compile(r"^Hacking grid \((\d+) wide, (\d+) tall")
_ROW = re.compile(r"^ (\d+)  (.*)$")
_POS = re.compile(r"^(Cursor|Goal):\s+\((\d+), (\d+)\)$")
_BLOCKS = re.compile(r"^RED BLOCKS: (\d+) of (\d+) still up.*?(?:\(next to go: the ([a-z-]+) one\))?\.$")
_SKIP = re.compile(r"^NOTE: (\d+) row\(s\) and (\d+) column\(s\) are currently REMOVED")
_CAME = re.compile(r"^You CAN reverse one step back onto the cell you came from \((\d+),(\d+)\)")
_BONUS = re.compile(r"^  \((\d+), (\d+)\) \[(.)\] (.+?) - ")


class ParseError(ValueError):
    pass


def _order_trail(cells: set[Pos], start: Optional[Pos], cursor: Pos,
                 arrows: dict[Pos, str], came_from: Optional[Pos]) -> list[Pos]:
    """The visited cells in path order, start first. Arrows give each cell's
    successor directly; a ~ trail is walked back from the cursor through
    neighbouring trail cells (a snake path; the first simple path found)."""
    if not cells:
        return []
    if arrows:
        succ = {}
        for pos, d in arrows.items():
            dx, dy = DELTAS[d]
            succ[pos] = (pos[0] - dx, pos[1] - dy)
        pred = {v: k for k, v in succ.items()}
        path, at = [], cursor
        while at in pred:
            at = pred[at]
            path.append(at)
        if start is not None and start in cells and start not in path:
            path.append(start)
        path.reverse()
        if set(path) == cells:
            return path
    # Depth-first from the cursor back to the start through trail cells.
    first = came_from if came_from in cells else None
    target = start if start in cells else None

    def walk(at: Pos, seen: list[Pos]) -> Optional[list[Pos]]:
        if len(seen) == len(cells):
            return seen if target is None or seen[-1] == target else None
        for dx, dy in DELTAS.values():
            nxt = (at[0] + dx, at[1] + dy)
            if nxt in cells and nxt not in seen:
                got = walk(nxt, seen + [nxt])
                if got:
                    return got
        return None

    starts = [first] if first else [c for c in cells if abs(c[0] - cursor[0]) + abs(c[1] - cursor[1]) == 1]
    for s in starts:
        got = walk(s, [s])
        if got:
            return list(reversed(got))
    raise ParseError("could not order the visited path")


def parse_state(text: str) -> GridPuzzle:
    lines = text.split("\n")
    m = _HEADER.match(lines[0])
    if not m:
        raise ParseError("not a hacking-grid state")
    w, h = int(m.group(1)), int(m.group(2))
    drawn: list[list[str]] = []
    for y in range(h):
        rm = _ROW.match(lines[2 + y])
        if not rm or int(rm.group(1)) != y:
            raise ParseError(f"grid row {y} missing")
        row = rm.group(2).split(" ")
        if len(row) != w:
            raise ParseError(f"grid row {y} has {len(row)} cells, not {w}")
        drawn.append(row)

    cursor = goal = None
    blocks = skipped = mode_line = came_from = None
    trail_mode = "none"
    under: dict[Pos, str] = {}
    for line in lines[2 + h:]:
        pm = _POS.match(line)
        if pm:
            pos = (int(pm.group(2)), int(pm.group(3)))
            if pm.group(1) == "Cursor":
                cursor = pos
            else:
                goal = pos
            continue
        bm = _BLOCKS.match(line)
        if bm:
            blocks = (int(bm.group(1)), int(bm.group(2)), bm.group(3))
            continue
        sm = _SKIP.match(line)
        if sm:
            skipped = (int(sm.group(1)), int(sm.group(2)))
            continue
        if line.startswith("Hacking mode - "):
            mode_line = line
            continue
        if line == ARROWS_NOTE:
            trail_mode = "arrows"
            continue
        cm = _CAME.match(line)
        if cm:
            came_from = (int(cm.group(1)), int(cm.group(2)))
            trail_mode = "came_from"
            continue
        bn = _BONUS.match(line)
        if bn and bn.group(3) == "c":
            kind = _NAME_TO_GLYPH.get(bn.group(4))
            if kind:
                under[(int(bn.group(1)), int(bn.group(2)))] = kind
    if cursor is None or goal is None:
        raise ParseError("no Cursor / Goal line")

    cells = [list(r) for r in drawn]
    trail_cells: set[Pos] = set()
    arrows: dict[Pos, str] = {}
    start = None
    for y in range(h):
        for x in range(w):
            g = drawn[y][x]
            if g in ARROW_DIR:
                arrows[(x, y)] = ARROW_DIR[g]
                trail_cells.add((x, y))
                cells[y][x] = "."
            elif g == "~":
                trail_cells.add((x, y))
                cells[y][x] = "."
            elif g == "S":
                start = (x, y)
            elif g == "@":
                cells[y][x] = "."
    if trail_mode != "none" or trail_cells:
        if start is not None:
            trail_cells.add(start)
    else:
        if start is None:
            start = cursor
    if start == cursor:
        cells[cursor[1]][cursor[0]] = "S"
    trail = _order_trail(trail_cells, start, cursor, arrows, came_from) if trail_cells else []
    return GridPuzzle(w, h, cells, cursor, goal, start, trail, trail_mode, under,
                      blocks, skipped, mode_line)


def moves_text(moves) -> str:
    return " ".join(str(m) for m in moves) if moves else "-"
