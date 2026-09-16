"""The mod's side of the wire, for a bench run.

Direction: the sidecar is the WebSocket *client* and the AI peer listens (see
apitest/peer_server.py). This module plays the sidecar, so it dials the peer --
apitest on 8123, or anything else speaking Neuro-SDK.

Threading follows apitest: the asyncio loop runs on a daemon thread and never
touches Tk. Everything it wants shown goes onto a queue.Queue of BenchEvent;
the GUI (or selftest) drains it.

A run, per version:
    actions/unregister (what was registered before)
    actions/register   (this version's sequence action [+ plan/rotate copies])
    optional unscored warm-up force
    one actions/force per puzzle -> wait for `action` -> judge -> action/result

At most one force is outstanding, as in the mod. A reply that misses the cap is
still waited for (up to one more cap) before the next force, so it can never be
taken as the next puzzle's answer; when it does arrive it is told it was stale.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

try:  # websockets >= 14
    from websockets.asyncio.client import connect as ws_connect
except ImportError:  # pragma: no cover - older installs
    from websockets import connect as ws_connect
from websockets.exceptions import ConnectionClosed

import other_actions
import puzzles
import scoring
import sequence_texts as texts
from variants import Version

GAME = "Pragmata"
RESULTS_DIR = Path(__file__).resolve().parent / "results"
STALE_MESSAGE = "stale: this reply arrived after the bench stopped waiting; nothing was pressed"


@dataclass
class BenchEvent:
    kind: str       # status | log | error | run_started | trial | run_finished
    text: str = ""
    data: Any = None


@dataclass
class RunPlan:
    versions: list[Version]
    set_size: int = 5
    seed: int = 1
    repeats: int = 1
    warmup: bool = True
    full_catalogue: bool = True
    cap_s: float = 15.0
    gap_s: float = 0.5
    settle_s: float = 0.3
    out_root: Path = RESULTS_DIR

    def scored_trials(self) -> int:
        return len(self.versions) * self.set_size * self.repeats

    def warmups(self) -> int:
        return len(self.versions) * self.repeats if self.warmup else 0


class ModMimic:
    def __init__(self, events) -> None:
        self.events = events
        self._thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._ws: Any = None
        self._stop: Optional[asyncio.Event] = None
        self._pending: Optional[asyncio.Future] = None
        self._late: Optional[asyncio.Future] = None
        self._run_task: Optional[asyncio.Task] = None
        self._run_active = False
        self._registered: list[str] = []
        self._last_register: Optional[dict] = None

    # -- state -------------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self._ws is not None

    @property
    def running(self) -> bool:
        return self._run_active

    # -- called from the GUI thread ----------------------------------------

    def connect(self, url: str) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._thread_main, args=(url,),
                                        name="mod_mimic", daemon=True)
        self._thread.start()

    def disconnect(self) -> None:
        loop, stop = self._loop, self._stop
        if loop is not None and stop is not None:
            loop.call_soon_threadsafe(stop.set)

    def start_run(self, plan: RunPlan) -> bool:
        if not self.connected or self._loop is None:
            self._emit("error", "not connected to a peer; nothing run")
            return False
        if self._run_active:
            self._emit("error", "a run is already in progress")
            return False
        self._run_active = True
        self._loop.call_soon_threadsafe(self._spawn_run, plan)
        return True

    def stop_run(self) -> None:
        if self._loop is not None:
            self._loop.call_soon_threadsafe(self._cancel_run)

    # -- loop thread -------------------------------------------------------

    def _thread_main(self, url: str) -> None:
        try:
            asyncio.run(self._session(url))
        except Exception as exc:  # noqa: BLE001 - surfaced in the GUI
            self._emit("error", f"connection to {url} failed: {exc}")
        finally:
            self._ws = None
            self._loop = None
            self._run_active = False
            self._emit("status", "disconnected", "disconnected")

    async def _session(self, url: str) -> None:
        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        self._emit("status", f"connecting to {url}", "connecting")
        async with ws_connect(url, ping_interval=20, max_size=None) as ws:
            self._ws = ws
            self._registered = []
            self._emit("status", f"connected to {url}", "connected")
            await self._send({"command": "startup", "game": GAME})
            reader = asyncio.create_task(self._reader(ws))
            stopper = asyncio.create_task(self._stop.wait())
            await asyncio.wait({reader, stopper}, return_when=asyncio.FIRST_COMPLETED)
            self._cancel_run()
            if self._run_task is not None:
                with contextlib.suppress(BaseException):
                    await self._run_task
            for task in (reader, stopper):
                task.cancel()
            self._ws = None

    def _spawn_run(self, plan: RunPlan) -> None:
        self._run_task = asyncio.get_running_loop().create_task(self._run(plan))

    def _cancel_run(self) -> None:
        if self._run_task is not None and not self._run_task.done():
            self._run_task.cancel()

    async def _reader(self, ws: Any) -> None:
        try:
            async for raw in ws:
                received = time.perf_counter()
                if isinstance(raw, (bytes, bytearray)):
                    raw = raw.decode("utf-8", errors="replace")
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    self._emit("log", f"peer sent non-JSON: {raw[:160]!r}")
                    continue
                if not isinstance(msg, dict):
                    continue
                command = msg.get("command")
                if command == "action":
                    await self._on_action(msg, received)
                elif command == "actions/reregister_all":
                    if self._last_register is not None:
                        await self._send(self._last_register)
                    self._emit("log", "peer asked to re-register; sent the current registration")
                else:
                    self._emit("log", f"ignored peer command {command!r}")
        except ConnectionClosed as exc:
            self._emit("log", f"connection closed: {exc}")
        finally:
            for fut in (self._pending, self._late):
                if fut is not None and not fut.done():
                    fut.set_exception(ConnectionError("peer disconnected"))

    async def _on_action(self, msg: dict, received: float) -> None:
        if self._pending is not None and not self._pending.done():
            self._pending.set_result((msg, received))
            return
        data = msg.get("data") or {}
        await self._send_result(str(data.get("id", "")), False, STALE_MESSAGE)
        if self._late is not None and not self._late.done():
            self._late.set_result((msg, received))
        self._emit("log", f"stale reply {data.get('name')} {data.get('data')} -- told it was stale")

    # -- a run -------------------------------------------------------------

    async def _run(self, plan: RunPlan) -> None:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out_dir = Path(plan.out_root) / stamp
        out_dir.mkdir(parents=True, exist_ok=True)
        records: list[dict] = []
        status = "finished"
        self._write_run_files(out_dir, plan)
        self._emit("run_started", f"run started -> {out_dir}", {
            "out_dir": str(out_dir),
            "scored": plan.scored_trials(),
            "warmups": plan.warmups(),
            "versions": [v.id for v in plan.versions],
        })
        try:
            with open(out_dir / "trials.jsonl", "w", encoding="utf-8") as fp:
                for rep in range(plan.repeats):
                    puzzle_set = puzzles.build_set(plan.set_size, plan.seed, rep)
                    # Rotate the version order each repeat, so a slow patch on
                    # the API side does not always land on the same version.
                    shift = rep % len(plan.versions)
                    ordered = plan.versions[shift:] + plan.versions[:shift]
                    for version in ordered:
                        await self._register(version, plan.full_catalogue)
                        await asyncio.sleep(plan.settle_s)
                        batch = [puzzles.warmup_puzzle(plan.seed, rep)] if plan.warmup else []
                        batch += puzzle_set
                        for puzzle in batch:
                            rec = await self._trial(version, puzzle, plan, rep)
                            records.append(rec)
                            fp.write(json.dumps(rec, ensure_ascii=False) + "\n")
                            fp.flush()
                            self._emit("trial", "", rec)
                            await asyncio.sleep(plan.gap_s)
        except asyncio.CancelledError:
            status = "stopped"
        except Exception as exc:  # noqa: BLE001 - a dropped peer ends the run, not the app
            status = "aborted"
            self._emit("error", f"run aborted: {exc!r}")
        finally:
            self._pending = None
            self._late = None
            scoring.write_summary_csv(out_dir / "summary.csv", records)
            self._run_active = False
            scored = sum(1 for r in records if not r["warmup"])
            self._emit("run_finished", f"run {status}: {scored} scored trials -> {out_dir}",
                       {"status": status, "out_dir": str(out_dir), "scored": scored})

    def _write_run_files(self, out_dir: Path, plan: RunPlan) -> None:
        run = {
            "started": datetime.now().isoformat(timespec="seconds"),
            "set_size": plan.set_size, "seed": plan.seed, "repeats": plan.repeats,
            "warmup": plan.warmup, "full_catalogue": plan.full_catalogue,
            "cap_s": plan.cap_s, "gap_s": plan.gap_s, "settle_s": plan.settle_s,
            "versions": [v.id for v in plan.versions],
        }
        (out_dir / "run.json").write_text(json.dumps(run, indent=2), encoding="utf-8")
        versions = {
            v.id: {"cfg": v.cfg, "query": texts.force_query(v.cfg), **texts.action_def(v.cfg)}
            for v in plan.versions
        }
        (out_dir / "versions.json").write_text(
            json.dumps(versions, indent=2, ensure_ascii=False), encoding="utf-8")

    async def _register(self, version: Version, full_catalogue: bool) -> None:
        if self._registered:
            await self._send({"command": "actions/unregister", "game": GAME,
                              "data": {"action_names": list(self._registered)}})
        actions = [texts.action_def(version.cfg)]
        if full_catalogue:
            actions += other_actions.ACTIONS
        msg = {"command": "actions/register", "game": GAME, "data": {"actions": actions}}
        await self._send(msg)
        self._last_register = msg
        self._registered = [a["name"] for a in actions]
        self._emit("log", f"registered {version.id} ({', '.join(self._registered)})")

    async def _trial(self, version: Version, puzzle: puzzles.Puzzle,
                     plan: RunPlan, rep: int) -> dict:
        cfg = version.cfg
        sequence = list(puzzle.sequence)
        state = texts.state_text(cfg, sequence, perm=puzzle.perm)
        query = texts.force_query(cfg)
        record: dict = {
            "time": datetime.now().isoformat(timespec="milliseconds"),
            "repeat": rep,
            "warmup": puzzle.index == 0,
            "version": version.id,
            "cfg": cfg,
            "puzzle": puzzle.label,
            "puzzle_index": puzzle.index,
            "presses": puzzle.presses,
            "sequence": sequence,
            "perm": list(puzzle.perm),
            "letters": texts.marks_for(sequence, puzzle.perm) if texts.letter_form(cfg) else None,
            "state": state,
            "query": query,
        }
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._pending = fut
        await self._send({"command": "actions/force", "game": GAME, "data": {
            "state": state,
            "query": query,
            "ephemeral_context": True,
            "action_names": [texts.ACTION_NAME],
            "priority": texts.PRIORITY,
        }})
        sent = time.perf_counter()

        elapsed_s: Optional[float] = None
        try:
            msg, received = await asyncio.wait_for(fut, plan.cap_s)
        except asyncio.TimeoutError:
            self._pending = None
            verdict = scoring.no_reply(plan.cap_s)
            record.update(action=None, raw_args=None)
            late = await self._wait_late(plan.cap_s)
            record["late_reply_ms"] = (int((late[1] - sent) * 1000) if late else None)
        else:
            self._pending = None
            data = msg.get("data") or {}
            elapsed_s = max(0.0, received - sent)
            verdict = scoring.judge(cfg, sequence, data.get("name"), data.get("data"), perm=puzzle.perm)
            record.update(action=data.get("name"), raw_args=data.get("data"))
            await self._send_result(str(data.get("id", "")), verdict.correct, verdict.message)

        record.update(
            pressed=verdict.pressed,
            outcome=verdict.outcome,
            correct=verdict.correct,
            message=verdict.message,
            elapsed_ms=None if elapsed_s is None else int(round(elapsed_s * 1000)),
            rating="warm-up" if record["warmup"] else scoring.rate(verdict.correct, elapsed_s),
        )
        return record

    async def _wait_late(self, cap_s: float):
        self._late = asyncio.get_running_loop().create_future()
        try:
            return await asyncio.wait_for(self._late, cap_s)
        except asyncio.TimeoutError:
            self._emit("log", f"no late reply within another {cap_s:g} s; moving on")
            return None
        finally:
            self._late = None

    # -- plumbing ----------------------------------------------------------

    async def _send_result(self, action_id: str, success: bool, message: str) -> None:
        await self._send({"command": "action/result", "game": GAME,
                          "data": {"id": action_id, "success": success, "message": message}})

    async def _send(self, payload: dict) -> None:
        ws = self._ws
        if ws is None:
            raise ConnectionError("not connected")
        await ws.send(json.dumps(payload, ensure_ascii=False))

    def _emit(self, kind: str, text: str, data: Any = None) -> None:
        self.events.put(BenchEvent(kind, text, data))
