"""Play a pragmata_enemy_hack_plan reply on a puzzle, the way the game and mod would.

The rules are the mod's as of 2026-10-08 (bindings/puzzle_snake.lua set_plan /
tick_plan / the settle machine) on top of what the game does with each cell:

    off the grid        the move is rejected; the plan stops, earlier moves count
    # wall              the cursor stops; "blocked by a wall after N move(s)"
    visited cell        only the cell it came from (retrace) -- anything else is
                        blocked like a wall
    d error node        the hack resets: cursor back to the start, path cleared
    X erase trap        the hack fails
    R red block         refuse_red (mod hack_block_refuse_plan, default on): the
                        whole plan is refused before any move, if any move would
                        land on an R counting from the cursor without walls (the
                        mod's own dead reckoning). Off: the hack fails on contact
    c corrupted         walkable; the cursor is stunned (STUN_S)
    G goal              solved; the moves after it are never sent
    = | J 7 L r gate    directional gate: entered only along its arrows, and
                        left only by the exit that entry leads to (= | straight
                        through, the corners turn); any other move into or out
                        of it is blocked like a wall. The rule is the old sim/
                        harness's model of the engine's TwoWay cells, never
                        seen in game; retracing onto the cell you came from is
                        always allowed
    b B P C             bomb / purge / chain nodes: walkable floor here
    plan runs out       "Ran all N planned move(s) without reaching the goal"

Times are estimates for the finale's clock, not measurements of the peer:
MOVE_S per landed move (the 18-move finale plan of 20:26:08 took ~2 s), STUN_S
per corrupted cell (the engine's 0.5 s block-input timer), RESET_S for the
error-node reset.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from typing import Optional

import grid_texts as gt

MOVE_S = 0.12
STUN_S = 0.5
RESET_S = 0.5

Pos = gt.Pos

# Directional gates (snake_render's TwoWay* glyphs): the move that entered
# the gate -> the only move that may leave it. A move into a gate that is not
# a key here is blocked. From the old sim/ harness (CELL_RULES).
GATE_EXITS: dict[str, dict[str, str]] = {
    "=": {"right": "right", "left": "left"},
    "|": {"down": "down", "up": "up"},
    "J": {"right": "up", "down": "left"},     # joins left and top
    "7": {"right": "down", "up": "left"},     # joins left and bottom
    "L": {"left": "up", "down": "right"},     # joins right and top
    "r": {"left": "down", "up": "right"},     # joins right and bottom
}


def _gate_ok(p: gt.GridPuzzle, at: Pos, entered: Optional[str], d: str, target: Pos) -> bool:
    """May the cursor at `at` (reached by the move `entered`, None when not
    known) move `d` onto `target`, as far as gates go?"""
    here = GATE_EXITS.get(p.glyph(*at) or "")
    if here is not None and entered is not None and here.get(entered) != d:
        return False
    there = GATE_EXITS.get(p.glyph(*target) or "")
    return there is None or d in there


def _arrival(p: gt.GridPuzzle) -> Optional[str]:
    """The move that brought the cursor to where it is, from the trail."""
    if not p.trail:
        return None
    px, py = p.trail[-1]
    step = (p.cursor[0] - px, p.cursor[1] - py)
    return next((d for d, v in gt.DELTAS.items() if v == step), None)


@dataclass
class PlayResult:
    outcome: str            # solved | wall | reset | off_grid | short | refused | failed | no_moves
    success: bool
    message: str
    after: gt.GridPuzzle    # the puzzle as the next force would show it
    landed: int = 0         # moves that landed (retraces included)
    stuns: int = 0
    path: list[Pos] = field(default_factory=list)   # cells the cursor entered, in order
    exec_s: float = 0.0

    @property
    def over(self) -> bool:
        """The hack has ended: no further force follows."""
        return self.outcome in ("solved", "failed")


def clean_moves(raw) -> list[str]:
    """The mod's queue: the strings it knows, everything else dropped."""
    if not isinstance(raw, list):
        return []
    return [d for d in raw if isinstance(d, str) and d in gt.DELTAS]


def first_red_step(p: gt.GridPuzzle, moves: list[str]) -> Optional[tuple[int, int, int]]:
    """bindings/puzzle_snake.lua _first_block_step: dead reckoning from the
    cursor, walls ignored. (step number, x, y) of the first move onto an R."""
    x, y = p.cursor
    for i, d in enumerate(moves, start=1):
        dx, dy = gt.DELTAS[d]
        x, y = x + dx, y + dy
        if p.glyph(x, y) == "R":
            return i, x, y
    return None


def play(p: gt.GridPuzzle, raw_moves, refuse_red: bool = True) -> PlayResult:
    moves = clean_moves(raw_moves)
    cur = p.copy()
    if refuse_red:
        hit = first_red_step(cur, moves)
        if hit:
            i, x, y = hit
            return PlayResult("refused", False, gt.MSG_RED_REFUSED.format(i=i, x=x, y=y), cur)

    landed = stuns = 0
    path: list[Pos] = []

    def result(outcome: str, success: bool, message: str, extra_s: float = 0.0) -> PlayResult:
        return PlayResult(outcome, success, message, cur, landed, stuns, path,
                          landed * MOVE_S + stuns * STUN_S + extra_s)

    entered = _arrival(cur)
    for d in moves:
        dx, dy = gt.DELTAS[d]
        x, y = cur.cursor[0] + dx, cur.cursor[1] + dy
        g = cur.glyph(x, y)
        if g is None:
            return result("off_grid", False, gt.MSG_OFF_GRID)
        target = (x, y)
        retrace = bool(cur.trail) and target == cur.trail[-1]
        if not retrace and not _gate_ok(cur, cur.cursor, entered, d, target):
            return result("wall", False, gt.MSG_WALL.format(n=landed))
        entered = None if retrace else d
        if target == cur.goal:
            landed += 1
            path.append(target)
            cur.trail.append(cur.cursor)
            cur.cursor = target
            return result("solved", True, gt.MSG_SOLVED)
        if target in cur.trail:
            if target == cur.trail[-1]:
                cur.trail.pop()
                cur.cursor = target
                landed += 1
                path.append(target)
                continue
            return result("wall", False, gt.MSG_WALL.format(n=landed))
        if g in gt.WALLS:
            return result("wall", False, gt.MSG_WALL.format(n=landed))
        if g == "d":
            cur.cursor = cur.start if cur.start is not None else p.cursor
            cur.trail = []
            return result("reset", False, gt.MSG_RESET, RESET_S)
        if g in ("R", "X"):
            path.append(target)
            return result("failed", False, gt.MSG_FAILED)
        cur.trail.append(cur.cursor)
        cur.cursor = target
        landed += 1
        path.append(target)
        if g == "c":
            stuns += 1
    if not moves:
        return result("no_moves", False, gt.MSG_SHORT.format(n=0, x=cur.cursor[0], y=cur.cursor[1]))
    return result("short", False, gt.MSG_SHORT.format(n=len(moves), x=cur.cursor[0], y=cur.cursor[1]))


# ---------------------------------------------------------------------------
# Reference solutions
# ---------------------------------------------------------------------------

def _passable(p: gt.GridPuzzle, pos: Pos, avoid_c: bool) -> bool:
    g = p.glyph(*pos)
    if g is None or pos in p.trail:
        return False
    if g in gt.WALLS or g in ("d", "R", "X"):
        return False
    return not (avoid_c and g == "c" and pos != p.goal)


def shortest_path(p: gt.GridPuzzle, avoid_c: bool = False) -> Optional[list[str]]:
    """Fewest safe moves from the cursor to the goal, or None. Mid-hack, that
    may mean retracing k steps of the visited path first (each a move onto the
    cell it came from) and heading a new way from there."""
    best: Optional[list[str]] = None
    back: list[str] = []
    q = p.copy()
    while True:
        route = _bfs(q, avoid_c)
        if route is not None and (best is None or len(back) + len(route) < len(best)):
            best = back + route
        if not q.trail:
            return best
        prev = q.trail.pop()
        dx, dy = prev[0] - q.cursor[0], prev[1] - q.cursor[1]
        back = back + [next(d for d, v in gt.DELTAS.items() if v == (dx, dy))]
        q.cursor = prev


def _bfs(p: gt.GridPuzzle, avoid_c: bool) -> Optional[list[str]]:
    # A state is (cell, the move that entered it): on a gate the way out
    # depends on the way in. Off gates the entry is dropped (None).
    start = (p.cursor, _arrival(p))
    prev: dict = {}
    seen = {start}
    q = deque([start])
    while q:
        state = q.popleft()
        at, entered = state
        if at == p.goal:
            moves = []
            while state != start:
                state, d = prev[state]
                moves.append(d)
            return moves[::-1]
        for d, (dx, dy) in gt.DELTAS.items():
            nxt = (at[0] + dx, at[1] + dy)
            if not _passable(p, nxt, avoid_c) or not _gate_ok(p, at, entered, d, nxt):
                continue
            ns = (nxt, d if (p.glyph(*nxt) or "") in GATE_EXITS else None)
            if ns not in seen:
                seen.add(ns)
                prev[ns] = (state, d)
                q.append(ns)
    return None


def best_route(p: gt.GridPuzzle, slack: int = 4, budget: int = 150_000) -> Optional[tuple[int, int]]:
    """(most blue nodes on any safe simple route at most `slack` moves longer
    than the shortest, its length), or None when the search runs out of budget
    or no route exists. Corrupted cells count as safe."""
    base = shortest_path(p)
    if base is None:
        return None
    limit = len(base) + slack
    best = [-1, 0]
    steps = [0]

    def blue(pos: Pos) -> int:
        return 1 if p.bonus_type(*pos) in ("O", "A") else 0

    def dist(pos: Pos) -> int:
        return abs(pos[0] - p.goal[0]) + abs(pos[1] - p.goal[1])

    def dfs(at: Pos, used: set, n: int, blues: int, entered: Optional[str] = None) -> bool:
        steps[0] += 1
        if steps[0] > budget:
            return False
        if at == p.goal:
            if blues > best[0] or (blues == best[0] and n < best[1]):
                best[0], best[1] = blues, n
            return True
        for d, (dx, dy) in gt.DELTAS.items():
            nxt = (at[0] + dx, at[1] + dy)
            if nxt in used or not _passable(p, nxt, False) or not _gate_ok(p, at, entered, d, nxt):
                continue
            if n + 1 + dist(nxt) > limit:
                continue
            used.add(nxt)
            ok = dfs(nxt, used, n + 1, blues + blue(nxt), d)
            used.discard(nxt)
            if not ok:
                return False
        return True

    if not dfs(p.cursor, {p.cursor}, 0, 0, _arrival(p)) or best[0] < 0:
        return None     # out of budget, or only reachable by retracing first
    return best[0], best[1]


def blues_on(p: gt.GridPuzzle, cells) -> int:
    return sum(1 for c in set(cells) if p.bonus_type(*c) in ("O", "A"))
