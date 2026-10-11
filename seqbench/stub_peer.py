"""A stand-in AI peer for testing the bench itself, at no API cost.

It listens like apitest does, decodes each sequence force from the state text
alone (so it also proves every render is decodable by its own rules), and
answers according to --mode:

    correct     the right answer
    wrong       the right answer with the first press changed
    slow:X      the right answer after X seconds
    random      random directions of the right length
    redblock    grid only: the first time a grid is seen, walk into a red block
                (then answer right on the re-force); elsewhere as correct

Hacking grids (pragmata_hack_plan) are answered with a shortest safe route
read off the state text (grid_texts.parse_state), clean of corrupted cells when
possible; `wrong` turns its first move a quarter, `random` is random moves.

    py -3 stub_peer.py --port 8124 --mode slow:2.5
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import threading
import uuid
from typing import Optional

import grid_sim
import grid_texts

try:  # websockets >= 14
    from websockets.asyncio.server import serve
except ImportError:  # pragma: no cover
    from websockets import serve

DIRECTIONS = ("up", "down", "left", "right")
_FROM_COMPASS = {"north": "up", "south": "down", "west": "left", "east": "right"}

_ARM_LINE = re.compile(r"^(up|down|left|right)\s+0((?: [+\-a-p])+)$")
_ROW = re.compile(r"^(?:\d )?([*+\-0a-p](?: [*+\-0a-p])*)$")
_RULER_HEADER = re.compile(r"^ +\d(?: \d)*$")
_LIST = re.compile(r"On screen[^:]*:\s*(.*)$")
_LIST_TOKEN = re.compile(r"^(\d+)\.([a-z]+?)(?:\(done\))?$")


def _blocks(lines: list[str], match) -> list[list]:
    """Runs of consecutive matching lines (ruler headers skipped). The hints put
    a worked example above the real puzzle, so callers take the last run."""
    blocks: list[list] = []
    current: list = []
    for line in lines:
        if _RULER_HEADER.match(line):
            continue
        m = match(line)
        if m:
            current.append(m)
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    return blocks


def decode_buttons(state: str) -> list[tuple[int, str, Optional[str]]]:
    """(distance, direction, mark) per button, read from a state text. The
    mark is "+" or the button's letter, None for the list."""
    lines = state.splitlines()

    for line in lines:
        m = _LIST.search(line)
        if m:
            tokens = [_LIST_TOKEN.match(t) for t in m.group(1).split()]
            ranked = sorted((int(t.group(1)), _FROM_COMPASS.get(t.group(2), t.group(2)))
                            for t in tokens if t)
            n = len(ranked)
            return [(n - k + 1, d, None) for k, d in ranked]

    arms = _blocks(lines, _ARM_LINE.match)
    if arms:
        return [(k, m.group(1), ch) for m in arms[-1]
                for k, ch in enumerate(m.group(2).split(), start=1) if ch != "-"]

    rows = _blocks(lines, _ROW.match)
    if not rows:
        return []
    grid = [m.group(1).split() for m in rows[-1]]
    arm = len(grid) // 2
    out = []
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            if ch in "*-0":
                continue
            dr, dc = r - arm, c - arm
            if dr < 0:
                out.append((-dr, "up", ch))
            elif dr > 0:
                out.append((dr, "down", ch))
            elif dc < 0:
                out.append((-dc, "left", ch))
            elif dc > 0:
                out.append((dc, "right", ch))
    return out


def order_from(buttons) -> list[str]:
    return [b[1] for b in sorted(buttons, key=lambda b: -b[0])]


def decode_state(state: str) -> list[str]:
    return order_from(decode_buttons(state))


def _route_into_red(p) -> Optional[list[str]]:
    """Moves from the cursor that end on a red block, or None."""
    from collections import deque
    prev = {p.cursor: None}
    q = deque([p.cursor])
    while q:
        at = q.popleft()
        for d, (dx, dy) in grid_texts.DELTAS.items():
            nxt = (at[0] + dx, at[1] + dy)
            if p.glyph(*nxt) == "R":
                moves = [d]
                while prev[at] is not None:
                    at, step = prev[at]
                    moves.append(step)
                return moves[::-1]
            if nxt not in prev and p.glyph(*nxt) not in (None, "#", "d", "X") \
                    and nxt not in p.trail and nxt != p.goal:
                prev[nxt] = (at, d)
                q.append(nxt)
    return None


class StubPeer:
    def __init__(self, mode: str = "correct") -> None:
        self.mode = mode
        self.actions: dict[str, dict] = {}
        self.results: list[dict] = []
        self._seen_grids: set[str] = set()

    def _grid_args(self, state: str) -> dict:
        """pragmata_hack_plan: a BFS route read off the state text alone."""
        try:
            p = grid_texts.parse_state(state)
        except grid_texts.ParseError:
            return {"moves": ["up"]}
        route = grid_sim.shortest_path(p, avoid_c=True) or grid_sim.shortest_path(p) or ["up"]
        mode = self.mode.split(":", 1)[0]
        if mode == "wrong":
            # Turn the first move a quarter: usually a wall, the edge or a detour.
            route = [DIRECTIONS[(DIRECTIONS.index(route[0]) + 2) % 4]] + route[1:]
        elif mode == "random":
            route = [random.choice(DIRECTIONS) for _ in range(len(route))]
        elif mode == "redblock" and state not in self._seen_grids:
            # First sight of a grid with a red block: walk into one, so the
            # refusal (or the failure) can be seen; the re-force gets it right.
            self._seen_grids.add(state)
            into = _route_into_red(p)
            if into:
                route = into
        return {"moves": route}

    def _answer_args(self, force: dict) -> dict:
        name = (force.get("action_names") or ["pragmata_hack_sequence"])[0]
        if name == grid_texts.ACTION_NAME:
            return self._grid_args(force.get("state", ""))
        buttons = sorted(decode_buttons(force.get("state", "")), key=lambda b: -b[0])
        schema = (self.actions.get(name) or {}).get("schema") or {}
        field, spec = next(iter((schema.get("properties") or {"order": {}}).items()))
        keys = list(((spec.get("items") or {}).get("properties") or {}))
        mode = self.mode.split(":", 1)[0]
        if mode == "wrong" and buttons:
            dist, d, mark = buttons[0]
            if keys and "direction" not in keys:
                dist = 0  # a distance-only answer has no direction to get wrong
            else:
                d = DIRECTIONS[(DIRECTIONS.index(d) + 1) % 4]
            buttons[0] = (dist, d, mark)
        elif mode == "random":
            buttons = [(dist, random.choice(DIRECTIONS), mark) for dist, _, mark in buttons]
        if keys:
            values = {"button": 2, "distance": 0, "direction": 1}
            return {field: [{k: b[values[k]] for k in keys} for b in buttons]}
        return {field: [b[1] for b in buttons]}

    def _delay(self) -> float:
        if self.mode.startswith("slow:"):
            return float(self.mode.split(":", 1)[1])
        return 0.02

    async def handler(self, ws) -> None:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            command = msg.get("command")
            data = msg.get("data") or {}
            if command == "actions/register":
                for action in data.get("actions") or []:
                    self.actions[action["name"]] = action
            elif command == "actions/force":
                asyncio.create_task(self._answer(ws, data))
            elif command == "action/result":
                self.results.append(data)

    async def _answer(self, ws, force: dict) -> None:
        args = self._answer_args(force)
        await asyncio.sleep(self._delay())
        name = (force.get("action_names") or ["pragmata_hack_sequence"])[0]
        await ws.send(json.dumps({"command": "action", "data": {
            "id": str(uuid.uuid4()), "name": name, "data": json.dumps(args)}}))


class StubThread:
    """Runs a StubPeer on a free port in a background thread (for selftest)."""

    def __init__(self, mode: str = "correct") -> None:
        self.peer = StubPeer(mode)
        self.port: Optional[int] = None
        self._ready = threading.Event()
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._stop: Optional[asyncio.Event] = None
        self._thread = threading.Thread(target=lambda: asyncio.run(self._main()), daemon=True)

    def start(self) -> "StubThread":
        self._thread.start()
        if not self._ready.wait(5):
            raise RuntimeError("stub peer did not start")
        return self

    def stop(self) -> None:
        if self._loop is not None and self._stop is not None:
            self._loop.call_soon_threadsafe(self._stop.set)
        self._thread.join(5)

    async def _main(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        async with serve(self.peer.handler, "127.0.0.1", 0) as server:
            self.port = next(iter(server.sockets)).getsockname()[1]
            self._ready.set()
            await self._stop.wait()


async def _main(port: int, mode: str) -> None:
    peer = StubPeer(mode)
    async with serve(peer.handler, "127.0.0.1", port):
        print(f"stub peer listening on ws://127.0.0.1:{port} (mode={mode})")
        await asyncio.Future()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8124)
    parser.add_argument("--mode", default="correct",
                        help="correct | wrong | random | redblock | slow:SECONDS")
    args = parser.parse_args()
    try:
        asyncio.run(_main(args.port, args.mode))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
