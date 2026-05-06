"""Reference AI peer for smoke-testing the eval pipeline.

Listens on a websocket port and responds to `actions/force` requests with a
plan of the configured quality:

    --strategy optimal  -> solver.solve() result (100% solve rate baseline)
    --strategy random   -> random moves up to a max length (low-skill baseline)
    --strategy dumb     -> always 'right' (exercises the illegal-move path)
    --strategy timeout  -> never responds (exercises the timeout path)

Use this to verify mod_mock + run_eval work end-to-end before pointing them
at the real AI peer. With --strategy optimal you should see 100% solve rate.

Usage:
    # Terminal 1: start stub peer
    python -m sim.stub_peer --port 8000 --strategy optimal

    # Terminal 2: run eval against it
    python -m sim.run_eval --peer-url ws://127.0.0.1:8000 --trials 20

The stub re-derives the grid from the rendered ASCII it received via
`context`. That tests the round-trip: if the rendering is unambiguous,
the solver can reproduce the puzzle and respond correctly. (When pointed
at a real AI peer, this round-trip is exactly what the LLM needs to do
in its head.)
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import random
import re
import sys
from typing import Optional

import websockets

from .grid_gen import ALL_DIRS, Cell, CellType, Dir, Grid
from .solver import solve


logger = logging.getLogger("stub_peer")


# Reverse glyph map for parsing rendered grids back into Grid objects.
# This must agree with ascii_render.py's _GLYPHS table.
_GLYPH_TO_TYPE: dict[str, CellType] = {
    "S": CellType.START,
    "G": CellType.GOAL,
    ".": CellType.OPEN,
    "#": CellType.OBSTACLE,
    "s": CellType.SHIELD,
    "C": CellType.CHAIN,
    "=": CellType.TWO_WAY_LR,
    "|": CellType.TWO_WAY_TD,
    "J": CellType.TWO_WAY_LT,
    "7": CellType.TWO_WAY_LD,
    "L": CellType.TWO_WAY_RT,
    "r": CellType.TWO_WAY_RD,
    "*": CellType.ACTIVE_SKILL,
    "1": CellType.ACTIVE_SKILL_1,
    "2": CellType.ACTIVE_SKILL_2,
    "3": CellType.ACTIVE_SKILL_3,
    "b": CellType.BOMB_3X3,
    "B": CellType.BOMB_5X5,
    "P": CellType.PURGE,
    "A": CellType.ATTACK,
    "X": CellType.ERASE_CODE,
    "F": CellType.FINISH_BLOW,
    "d": CellType.DEAD_FILAMENT,
}
_ONE_WAY_DIRS = {"^": Dir.UP, "v": Dir.DOWN, "<": Dir.LEFT, ">": Dir.RIGHT}


def _parse_grid(rendered: str) -> Optional[Grid]:
    """Re-derive a Grid from a rendered ASCII block.

    Looks for the dimensions line, the coord-header line, and N data rows.
    Then reads cursor/goal coordinates from the metadata lines.
    """
    lines = rendered.splitlines()
    dims_match = None
    for line in lines:
        m = re.match(r"Hacking grid \((\d+)x(\d+)\):", line)
        if m:
            dims_match = m
            break
    if dims_match is None:
        return None
    width, height = int(dims_match.group(1)), int(dims_match.group(2))

    # Find the data rows: N consecutive lines starting with " <y>  ".
    data_rows: list[list[str]] = []
    for line in lines:
        m = re.match(r"\s*(\d+)\s+(.+)$", line)
        if not m:
            continue
        idx = int(m.group(1))
        if idx != len(data_rows):
            continue  # not the next expected row
        glyphs = m.group(2).split()
        if len(glyphs) != width:
            continue
        data_rows.append(glyphs)
        if len(data_rows) == height:
            break
    if len(data_rows) != height:
        return None

    cursor: Optional[tuple[int, int]] = None
    start: Optional[tuple[int, int]] = None
    goal: Optional[tuple[int, int]] = None
    cells = [[Cell(type=CellType.OPEN) for _ in range(width)] for _ in range(height)]

    for y, row in enumerate(data_rows):
        for x, glyph in enumerate(row):
            if glyph == "@":
                cursor = (x, y)
                # Underlying cell is unknown from the render; treat as Start.
                # If there's a separate Start glyph elsewhere, we'll pick that
                # up too. (This is one of the imperfections of inline render —
                # the cursor masks the real cell underneath.)
                cells[y][x] = Cell(type=CellType.START)
                start = start or (x, y)
            elif glyph == "~":
                cells[y][x] = Cell(type=CellType.OPEN)
            elif glyph in _ONE_WAY_DIRS:
                cells[y][x] = Cell(type=CellType.ONE_WAY, direction=_ONE_WAY_DIRS[glyph])
            elif glyph in _GLYPH_TO_TYPE:
                ct = _GLYPH_TO_TYPE[glyph]
                cells[y][x] = Cell(type=ct)
                if ct is CellType.START:
                    start = (x, y)
                elif ct is CellType.GOAL:
                    goal = (x, y)
            else:
                cells[y][x] = Cell(type=CellType.OPEN)

    # Prefer explicit "Cursor:" / "Goal:" metadata over what we inferred.
    for line in lines:
        m = re.match(r"Cursor:\s*\((\d+),\s*(\d+)\)", line)
        if m:
            cursor = (int(m.group(1)), int(m.group(2)))
        m = re.match(r"Goal:\s*\((\d+),\s*(\d+)\)", line)
        if m:
            goal = (int(m.group(1)), int(m.group(2)))

    if cursor is None or start is None or goal is None:
        return None
    return Grid(
        width=width, height=height, cells=cells,
        start=start, goal=goal, cursor=cursor, trail=[cursor],
    )


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

def _plan_optimal(grid: Grid) -> list[Dir]:
    plan = solve(grid)
    return plan if plan is not None else []


def _plan_random(grid: Grid, rng: random.Random, max_len: int = 12) -> list[Dir]:
    return [rng.choice(ALL_DIRS) for _ in range(rng.randint(1, max_len))]


def _plan_dumb(_grid: Grid) -> list[Dir]:
    return [Dir.RIGHT] * 5


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

async def _handle_connection(ws, strategy: str, rng: random.Random):
    logger.info(f"peer connected (strategy={strategy})")
    last_grid: Optional[Grid] = None

    async for raw in ws:
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8", errors="replace")
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning(f"non-JSON from mod: {raw[:120]!r}")
            continue

        cmd = msg.get("command", "")
        data = msg.get("data", {})

        if cmd == "context":
            body = data.get("message", "")
            parsed = _parse_grid(body)
            if parsed is not None:
                last_grid = parsed
                logger.debug(f"parsed grid {parsed.width}x{parsed.height}")

        elif cmd == "actions/force":
            if strategy == "timeout":
                logger.info("timeout strategy — not responding")
                continue
            if last_grid is None:
                logger.warning("force received but no grid context yet — sending empty plan")
                await _send_action(ws, "pragmata_hack_plan", {"moves": []})
                continue

            if strategy == "optimal":
                moves = _plan_optimal(last_grid)
            elif strategy == "random":
                moves = _plan_random(last_grid, rng)
            elif strategy == "dumb":
                moves = _plan_dumb(last_grid)
            else:
                moves = _plan_optimal(last_grid)

            logger.info(f"-> action plan ({len(moves)} moves): {[m.value for m in moves]}")
            await _send_action(ws, "pragmata_hack_plan",
                               {"moves": [m.value for m in moves]})

        elif cmd == "action/result":
            outcome = "ok" if data.get("success") else "fail"
            logger.info(f"<- action/result {outcome}: {data.get('message', '')[:100]}")

        elif cmd == "startup":
            logger.info("mod startup received")

        elif cmd == "actions/register":
            actions = data.get("actions", [])
            logger.info(f"mod registered {len(actions)} actions: "
                        f"{[a.get('name') for a in actions]}")

        elif cmd.startswith("shutdown"):
            logger.info(f"mod sent {cmd}; closing")
            break

        else:
            logger.debug(f"ignoring mod command {cmd!r}")

    logger.info("connection closed")


async def _send_action(ws, name: str, args: dict) -> None:
    import uuid
    await ws.send(json.dumps({
        "command": "action",
        "data": {
            "id": str(uuid.uuid4()),
            "name": name,
            "data": json.dumps(args),
        },
    }))


async def _amain(args: argparse.Namespace) -> int:
    rng = random.Random(args.seed)

    async def handler(ws):
        await _handle_connection(ws, args.strategy, rng)

    logger.info(f"stub peer listening on ws://{args.host}:{args.port} "
                f"(strategy={args.strategy})")
    async with websockets.serve(handler, args.host, args.port):
        await asyncio.Future()  # run forever


def main() -> int:
    parser = argparse.ArgumentParser(description="Pragmata stub AI peer (testing only)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--strategy",
                        choices=["optimal", "random", "dumb", "timeout"],
                        default="optimal")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    logging.getLogger("websockets").setLevel(logging.WARNING)

    try:
        asyncio.run(_amain(args))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
