"""seqbench from the command line: one batch run, no window.

    py -3 run_eval.py --url ws://127.0.0.1:8123 grid [options]
    py -3 run_eval.py --url ws://127.0.0.1:8123 sequence [options]

The same run as the GUI's Run button (mod_mimic.ModMimic with a RunPlan or a
GridRunPlan), for scripts, long batches and CI-style checks. It connects to
the peer, runs, prints one line per scored trial or episode, prints the
summary table and writes `results/<timestamp>[-grid]/` exactly as the GUI does.

This replaces the old `sim/` harness's run_eval (retired 2026-11-15, see the
README's "History"). Its options map as:

    sim --peer-url URL     -> --url URL
    sim --trials N         -> grid --per N (per category)
    sim --difficulty X     -> grid --categories ... (pick the categories)
    sim --seed / --timeout -> --seed / --cap
    sim --out FILE         -> results/<timestamp>-grid/trials.jsonl

Exit status: 0 when the run finished, 1 when it was stopped or aborted or
never connected, 2 when --min-solved / --min-pass was set and not reached.

Smoke test without an API (the stub retries like the Neuro server):

    py -3 stub_peer.py --port 8124 --mode correct
    py -3 run_eval.py --url ws://127.0.0.1:8124 grid --per 2 --no-warmup
"""
from __future__ import annotations

import argparse
import queue
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import grid_puzzles  # noqa: E402
import grid_scoring  # noqa: E402
import puzzles  # noqa: E402
import scoring  # noqa: E402
import variants  # noqa: E402
from mod_mimic import RESULTS_DIR, GridRunPlan, ModMimic, RunPlan  # noqa: E402


def _csv(text: str) -> list[str]:
    return [t.strip() for t in text.split(",") if t.strip()]


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="ws://127.0.0.1:8123",
                    help="the peer's WebSocket URL (apitest listens on 8123)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--cap", type=float, default=None,
                    help="seconds to wait for a reply (default: 15 sequence, 30 grid)")
    ap.add_argument("--gap", type=float, default=0.5, help="seconds between forces")
    ap.add_argument("--no-warmup", action="store_true", help="skip the unscored warm-up force")
    ap.add_argument("--plan-only", action="store_true",
                    help="register only the forced action, not the copies of the others")
    ap.add_argument("--out-root", type=Path, default=RESULTS_DIR)
    ap.add_argument("--quiet", action="store_true", help="no per-trial lines")
    sub = ap.add_subparsers(dest="bench", required=True)

    g = sub.add_parser("grid", help="the enemy hacking grid (pragmata_enemy_hack_plan)")
    g.add_argument("--categories", type=_csv, default=list(grid_puzzles.DEFAULT_CATEGORIES),
                   help="comma list, from: " + ", ".join(grid_puzzles.CATEGORIES)
                   + " (default: all but " + ", ".join(grid_puzzles.SPECULATIVE) + ")")
    g.add_argument("--per", type=int, default=3, help="puzzles per category (finale: its 5 stages)")
    g.add_argument("--source", choices=grid_puzzles.SOURCES, default="both")
    g.add_argument("--versions", type=_csv, default=["mod"],
                   help="comma list, from: " + ", ".join(v.id for v in grid_puzzles.VERSIONS))
    g.add_argument("--max-forces", type=int, default=3, help="answers per puzzle, retries included")
    g.add_argument("--finale-budget", type=float, default=15.0, help="seconds per finale stage")
    g.add_argument("--no-refuse-red", action="store_true",
                   help="as mod hack_block_refuse_plan = false: a red block fails the hack")
    g.add_argument("--min-solved", type=float, default=None,
                   help="exit 2 unless every summary row reaches this solved %%")

    s = sub.add_parser("sequence", help="the sequence hack (pragmata_enviro_hack_sequence)")
    s.add_argument("--groups", type=lambda t: [int(x) for x in _csv(t)],
                   default=[g.number for g in variants.GROUPS], help="mod group numbers, e.g. 1,3")
    s.add_argument("--set-size", type=int, default=5, choices=sorted(puzzles.SET_MIX))
    s.add_argument("--min-pass", type=float, default=None,
                   help="exit 2 unless every summary row reaches this pass %%")
    return ap



def _plan(args) -> GridRunPlan | RunPlan:
    common = dict(seed=args.seed, repeats=args.repeats, warmup=not args.no_warmup,
                  full_catalogue=not args.plan_only, gap_s=args.gap, out_root=args.out_root)
    if args.bench == "grid":
        bad = [c for c in args.categories if c not in grid_puzzles.CATEGORIES]
        if bad:
            raise SystemExit(f"unknown categories: {', '.join(bad)}")
        try:
            versions = [grid_puzzles.version(v) for v in args.versions]
        except KeyError as exc:
            raise SystemExit(f"unknown version: {exc}")
        return GridRunPlan(versions=versions, categories=args.categories, per_category=args.per,
                           source=args.source, max_forces=args.max_forces,
                           finale_budget_s=args.finale_budget, refuse_red=not args.no_refuse_red,
                           cap_s=args.cap or 30.0, **common)
    by_number = {g.number: g for g in variants.GROUPS}
    bad = [n for n in args.groups if n not in by_number]
    if bad:
        raise SystemExit(f"unknown groups: {bad}")
    return RunPlan(versions=[by_number[n].version for n in args.groups], set_size=args.set_size,
                   cap_s=args.cap or 15.0, **common)


def _trial_line(rec: dict, grid: bool) -> str:
    if grid:
        ms = [f.get("elapsed_ms") for f in rec["forces"] if f.get("elapsed_ms") is not None]
        return (f"  {rec['version']:<14} {rec['category']:<9} {rec['puzzle']:<18} "
                f"{rec['outcome']:<12} {rec['rating']:<9} answers={rec['forces_used']} "
                f"ms={'/'.join(str(m) for m in ms) or '-'}")
    return (f"  {rec['version']:<34} {rec.get('outcome', ''):<12} {rec['rating']:<9} "
            f"ms={rec.get('elapsed_ms') if rec.get('elapsed_ms') is not None else '-'}")


def _table(rows: list[dict], columns) -> str:
    cols = [c for c in columns if c != "outcomes"]
    cells = [[("" if r.get(c) is None else str(r.get(c))) for c in cols] for r in rows]
    widths = [max([len(c)] + [len(row[i]) for row in cells]) for i, c in enumerate(cols)]
    lines = ["  ".join(c.ljust(w) for c, w in zip(cols, widths))]
    lines += ["  ".join(v.ljust(w) for v, w in zip(row, widths)) for row in cells]
    return "\n".join(lines)


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    plan = _plan(args)
    grid = isinstance(plan, GridRunPlan)
    events: queue.Queue = queue.Queue()
    mimic = ModMimic(events)
    mimic.connect(args.url)
    deadline = time.time() + 10
    while not mimic.connected and time.time() < deadline:
        time.sleep(0.05)
    if not mimic.connected:
        while not events.empty():
            ev = events.get()
            if ev.kind == "error":
                print(ev.text)
        print(f"could not connect to {args.url}")
        return 1
    print(f"connected to {args.url}; {plan.scored_trials()} scored "
          f"{'episodes' if grid else 'trials'} + {plan.warmups()} warm-up(s)")
    if not mimic.start_run(plan):
        return 1

    records: list[dict] = []
    finished = None
    try:
        while finished is None:
            try:
                ev = events.get(timeout=0.5)
            except queue.Empty:
                if not mimic.connected and not mimic.running:
                    print("the peer went away")
                    break
                continue
            if ev.kind == "trial":
                records.append(ev.data)
                if not args.quiet and not ev.data.get("warmup"):
                    print(_trial_line(ev.data, grid), flush=True)
            elif ev.kind in ("run_started", "error"):
                print(ev.text, flush=True)
            elif ev.kind == "run_finished":
                finished = ev.data
                print(ev.text)
    except KeyboardInterrupt:
        print("stopping...")
        mimic.stop_run()
        deadline = time.time() + 10
        while finished is None and time.time() < deadline:
            try:
                ev = events.get(timeout=0.5)
            except queue.Empty:
                continue
            if ev.kind == "run_finished":
                finished = ev.data
    finally:
        mimic.disconnect()
        time.sleep(0.2)

    rows = grid_scoring.summarize(records) if grid else scoring.summarize(records)
    if rows:
        print()
        print(_table(rows, grid_scoring.SUMMARY_COLUMNS if grid else scoring.SUMMARY_COLUMNS))
    if finished is None or finished.get("status") != "finished":
        return 1
    if grid and args.min_solved is not None and any(r["solved_pct"] < args.min_solved for r in rows):
        return 2
    if not grid and args.min_pass is not None and any(r["pass_pct"] < args.min_pass for r in rows):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
