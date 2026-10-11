"""Seeded hacking grids in the shapes the game uses, for the grid bench.

Two layouts, both read off the forces in grid_corpus.json:

    field   an open grid with a few wall pieces (a 2x2 core, single walls), blue
            and yellow nodes scattered; cursor at (0, 0), goal at the centre or
            the far corner. Every ordinary enemy grid looks like this.
    maze    corridors one cell wide (a recursive backtracker, then a few extra
            openings), like the final boss's stages.

and the modifiers on top:

    error   1-4 d error nodes, never on the only way through
    blocks  5x5 or 6x6 with a 2x2 red block in each corner, 1-3 of them still
            up; they go top-left, top-right, bottom-left, bottom-right
    corrupt c cells, on grids of 30 cells or fewer (the mod's gate turns larger
            corrupted grids away)
    resume  the cursor already partway along a safe route, path drawn as arrows

Every puzzle is checked solvable (grid_sim.shortest_path) and depends only on
(category, seed, repeat, index), so every version in a run sees the same ones.
"""
from __future__ import annotations

import random
from typing import Optional

import grid_sim
import grid_texts as gt

MODE_LINE = ("Hacking mode - Offense: the blue OPEN nodes ('O') turn into blue ATTACK nodes "
             "('A') on an exposed hack - route through the A nodes just like O nodes; they "
             "raise the damage of your next hack.")
CORNERS = ("top-left", "top-right", "bottom-left", "bottom-right")

SIZES = {
    "plain": [(4, 4), (5, 5), (6, 6), (7, 7)],
    "error": [(5, 5), (6, 6), (7, 7)],
    "blocks": [(5, 5), (6, 6)],
    "corrupt": [(4, 4), (5, 5), (5, 6), (6, 5)],
    "big": [(8, 8), (9, 9), (9, 9)],
    "nonsquare": [(3, 4), (5, 4), (4, 6), (5, 7), (7, 9), (9, 7)],
    "resume": [(5, 5), (6, 6), (7, 7)],
}
GENERATED = tuple(SIZES)


def _blank(w: int, h: int) -> list[list[str]]:
    return [["." for _ in range(w)] for _ in range(h)]


def _field(rng: random.Random, w: int, h: int) -> tuple[list[list[str]], gt.Pos]:
    cells = _blank(w, h)
    if w >= 6 and h >= 6 and rng.random() < 0.6:
        x0, y0 = w // 2 - 1, h // 2 - 1
        for y in (y0, y0 + 1):
            for x in (x0, x0 + 1):
                cells[y][x] = "#"
    for _ in range(rng.randint(0, max(1, w * h // 16))):
        cells[rng.randrange(h)][rng.randrange(w)] = "#"
    goal = (w // 2, h // 2) if rng.random() < 0.5 and w > 3 and h > 3 else (w - 1, h - 1)
    if cells[goal[1]][goal[0]] == "#":
        goal = (w - 1, h - 1)
    return cells, goal


def _maze(rng: random.Random, w: int, h: int) -> tuple[list[list[str]], gt.Pos]:
    cells = [["#" for _ in range(w)] for _ in range(h)]
    start = (0, 0)
    cells[0][0] = "."
    stack = [start]
    while stack:
        x, y = stack[-1]
        options = []
        for dx, dy in ((0, -2), (0, 2), (-2, 0), (2, 0)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and cells[ny][nx] == "#":
                options.append((nx, ny, x + dx // 2, y + dy // 2))
        if not options:
            stack.pop()
            continue
        nx, ny, mx, my = rng.choice(options)
        cells[my][mx] = "."
        cells[ny][nx] = "."
        stack.append((nx, ny))
    for _ in range(max(1, w * h // 12)):     # a few loops, so there is a choice of route
        x, y = rng.randrange(w), rng.randrange(h)
        cells[y][x] = "."
    open_cells = [(x, y) for y in range(h) for x in range(w) if cells[y][x] == "."]
    far = [c for c in open_cells if c[0] + c[1] >= (w + h) // 2]
    return cells, rng.choice(far or open_cells)


def _scatter(rng: random.Random, cells, glyphs: str, count: int, keep: set) -> None:
    free = [(x, y) for y in range(len(cells)) for x in range(len(cells[0]))
            if cells[y][x] == "." and (x, y) not in keep]
    for x, y in rng.sample(free, min(count, len(free))):
        cells[y][x] = rng.choice(glyphs)


def _puzzle(cells, goal, w, h, **kw) -> gt.GridPuzzle:
    cells[0][0] = "S"
    cells[goal[1]][goal[0]] = "G"
    return gt.GridPuzzle(w, h, cells, (0, 0), goal, (0, 0), mode_line=MODE_LINE, **kw)


def _block_rects(w: int, h: int) -> list[list[gt.Pos]]:
    rects = []
    for cx, cy in ((0, 0), (w - 2, 0), (0, h - 2), (w - 2, h - 2)):
        rects.append([(cx + dx, cy + dy) for dy in (0, 1) for dx in (0, 1)])
    return rects


def make(category: str, rng: random.Random) -> gt.GridPuzzle:
    w, h = rng.choice(SIZES[category])
    big = category in ("big", "nonsquare") and w * h >= 35
    for _ in range(200):
        cells, goal = (_maze if (big and rng.random() < 0.5) else _field)(rng, w, h)
        if category == "blocks":            # the antenna enemy's grid: goal in the middle
            goal = (w // 2, h // 2)
        keep = {(0, 0), goal}
        _scatter(rng, cells, "AAO", rng.randint(2, 3 + w * h // 16), keep)
        _scatter(rng, cells, "*", rng.randint(1, 3), keep)
        kw: dict = {}
        if category == "error" or (big and rng.random() < 0.5):
            _scatter(rng, cells, "d", rng.randint(1, 4), keep)
        if category == "blocks":
            up = rng.randint(1, 3)
            rects = _block_rects(w, h)[4 - up:]
            for rect in rects:
                for x, y in rect:
                    if (x, y) != (0, 0):
                        cells[y][x] = "R"
            kw["blocks"] = (up, 4, CORNERS[4 - up])
        under = {}
        if category == "corrupt":
            for _ in range(rng.randint(3, max(4, w * h // 4))):
                x, y = rng.randrange(w), rng.randrange(h)
                if (x, y) in keep or cells[y][x] in "#dR":
                    continue
                if cells[y][x] in ("O", "A", "*"):
                    under[(x, y)] = cells[y][x]
                cells[y][x] = "c"
        p = _puzzle(cells, goal, w, h, under=under, **kw)
        route = grid_sim.shortest_path(p)
        if route is None or len(route) < 2:
            continue
        if category == "resume":
            p = _advance(p, route, rng)
            if p is None:
                continue
        return p
    raise RuntimeError(f"could not generate a solvable {category} grid")


def _advance(p: gt.GridPuzzle, route: list[str], rng: random.Random) -> Optional[gt.GridPuzzle]:
    """Walk part of a safe route, as if an earlier plan had stopped there."""
    steps = rng.randint(1, max(1, len(route) - 2))
    played = grid_sim.play(p, route[:steps])
    q = played.after
    if played.outcome != "short" or grid_sim.shortest_path(q) is None:
        return None
    q.trail_mode = "arrows"
    return q


def build(category: str, count: int, seed: int, repeat: int = 0) -> list[gt.GridPuzzle]:
    out = []
    for i in range(count):
        rng = random.Random(f"gridbench:{category}:{seed}:{repeat}:{i}")
        out.append(make(category, rng))
    return out
