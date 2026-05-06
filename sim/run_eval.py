"""Batch evaluation: run N synthetic-grid trials against an AI peer.

Connects once to the peer's websocket, generates trials per the chosen
difficulty preset, scores each trial, and reports aggregate metrics.

Usage:
    python -m sim.run_eval --peer-url ws://127.0.0.1:8000 --trials 50

    # Just one preset
    python -m sim.run_eval --difficulty hard --trials 100 --seed 1

    # Save full trial logs as JSONL for inspection
    python -m sim.run_eval --trials 200 --out trials.jsonl
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import random
import sys
from dataclasses import asdict
from typing import Optional

from .ascii_render import render
from .grid_gen import Cell, Dir, GenConfig, Grid, generate
from .mod_mock import ModMock, TrialResult


logger = logging.getLogger("run_eval")


# ---------------------------------------------------------------------------
# Difficulty presets
# ---------------------------------------------------------------------------

DIFFICULTY_PRESETS: dict[str, dict] = {
    "easy": dict(
        size=(5, 5), obstacle_density=0.12,
        erase_code_density=0.0, active_skill_density=0.05,
    ),
    "medium": dict(
        size=(6, 6), obstacle_density=0.18,
        erase_code_density=0.05, active_skill_density=0.10,
        bomb_density=0.05,
    ),
    "hard": dict(
        size=(8, 8), obstacle_density=0.20,
        erase_code_density=0.10, active_skill_density=0.10,
        bomb_density=0.05, other_effect_density=0.05,
    ),
}


def make_config(preset: str, seed: Optional[int]) -> GenConfig:
    if preset not in DIFFICULTY_PRESETS:
        raise ValueError(f"unknown preset {preset}; pick from {list(DIFFICULTY_PRESETS)}")
    return GenConfig(seed=seed, **DIFFICULTY_PRESETS[preset])


# ---------------------------------------------------------------------------
# Serialization helpers (JSONL trial log)
# ---------------------------------------------------------------------------

def _grid_to_dict(grid: Grid) -> dict:
    return {
        "width": grid.width,
        "height": grid.height,
        "cells": [
            [{"type": c.type.value,
              "direction": c.direction.value if c.direction else None}
             for c in row]
            for row in grid.cells
        ],
        "start": list(grid.start),
        "goal": list(grid.goal),
        "cursor": list(grid.cursor),
        "trail": [list(p) for p in grid.trail],
        "status": grid.status,
    }


def _trial_to_dict(t: TrialResult, preset: str, trial_idx: int) -> dict:
    return {
        "trial_idx": trial_idx,
        "preset": preset,
        "outcome": t.outcome,
        "detail": t.detail,
        "elapsed_ms": t.elapsed_ms,
        "action_invoked": t.action_invoked,
        "moves": [m.value for m in t.moves] if t.moves else None,
        "reasoning": t.reasoning,
        "optimal_moves": t.optimal_moves,
        "optimality_ratio": t.optimality_ratio(),
        "raw_args": t.raw_args,
        "grid": _grid_to_dict(t.grid),
    }


# ---------------------------------------------------------------------------
# Metrics aggregation
# ---------------------------------------------------------------------------

def _summarize(trials: list[TrialResult]) -> dict:
    if not trials:
        return {"total": 0}

    n = len(trials)
    by_outcome: dict[str, int] = {}
    optimality_ratios: list[float] = []
    elapsed_ms: list[int] = []
    for t in trials:
        by_outcome[t.outcome] = by_outcome.get(t.outcome, 0) + 1
        if t.is_success():
            r = t.optimality_ratio()
            if r is not None:
                optimality_ratios.append(r)
        elapsed_ms.append(t.elapsed_ms)

    summary = {
        "total": n,
        "solved": by_outcome.get("solved", 0),
        "solve_rate": round(by_outcome.get("solved", 0) / n, 3),
        "outcomes": by_outcome,
        "avg_optimality_ratio": (
            round(sum(optimality_ratios) / len(optimality_ratios), 3)
            if optimality_ratios else None
        ),
        "avg_elapsed_ms": round(sum(elapsed_ms) / n) if elapsed_ms else 0,
    }
    return summary


def _print_summary(preset_name: str, trials: list[TrialResult]) -> None:
    s = _summarize(trials)
    print(f"\n=== {preset_name} ({s['total']} trials) ===")
    print(f"  Solve rate:       {s['solve_rate']:.1%}  ({s['solved']}/{s['total']})")
    if s["avg_optimality_ratio"] is not None:
        print(f"  Avg optimality:   {s['avg_optimality_ratio']:.2f}x  (1.0 = optimal)")
    print(f"  Avg time/trial:   {s['avg_elapsed_ms']} ms")
    print("  Outcomes:")
    for outcome, count in sorted(s["outcomes"].items(), key=lambda kv: -kv[1]):
        print(f"    {outcome:12s} {count:4d}  ({count / s['total']:.1%})")


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

async def _run(args: argparse.Namespace) -> int:
    seed_root = random.Random(args.seed)

    presets: list[str]
    if args.difficulty == "mixed":
        presets = list(DIFFICULTY_PRESETS.keys())
    else:
        presets = [args.difficulty]

    out_fp = open(args.out, "w", encoding="utf-8") if args.out else None

    try:
        async with ModMock(
            args.peer_url,
            force_timeout_s=args.timeout,
            plan_only=args.plan_only,
            inter_trial_rng=random.Random(args.seed if args.seed is not None else None),
        ) as mock:
            all_trials: dict[str, list[TrialResult]] = {p: [] for p in presets}
            prev_outcome: Optional[str] = None

            for trial_idx in range(args.trials):
                if args.inter_trial_context and trial_idx > 0:
                    await mock.send_inter_trial_context(prev_outcome)
                if args.inter_trial_delay > 0 and trial_idx > 0:
                    await asyncio.sleep(args.inter_trial_delay)
                preset = (
                    seed_root.choice(presets) if len(presets) > 1 else presets[0]
                )
                cfg = make_config(preset, seed=seed_root.randrange(2**31))
                try:
                    grid = generate(cfg)
                except ValueError as e:
                    logger.warning(f"trial {trial_idx} ({preset}) generate failed: {e}")
                    continue

                if args.verbose:
                    print(f"\n--- trial {trial_idx} [{preset}] ---")
                    print(render(grid))

                result = await mock.run_trial(grid)
                all_trials[preset].append(result)
                prev_outcome = result.outcome

                if args.verbose:
                    print(
                        f"-> {result.outcome:10s} "
                        f"({result.elapsed_ms} ms) {result.detail[:80]}"
                    )
                else:
                    sys.stdout.write(
                        "." if result.is_success()
                        else ("X" if result.outcome == "hit_erase"
                              else ("!" if result.outcome == "illegal"
                                    else ("T" if result.outcome == "timeout"
                                          else "?")))
                    )
                    sys.stdout.flush()

                if out_fp is not None:
                    out_fp.write(json.dumps(_trial_to_dict(result, preset, trial_idx)) + "\n")
                    out_fp.flush()

            if not args.verbose:
                print()

            for preset in presets:
                if all_trials[preset]:
                    _print_summary(preset, all_trials[preset])

            if len(presets) > 1:
                combined = [t for ts in all_trials.values() for t in ts]
                _print_summary("OVERALL", combined)
    finally:
        if out_fp is not None:
            out_fp.close()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Pragmata hacking grid AI eval")
    parser.add_argument("--peer-url", default="ws://127.0.0.1:8000",
                        help="WebSocket URL of the AI peer (default: ws://127.0.0.1:8000)")
    parser.add_argument("--trials", type=int, default=50,
                        help="Number of trials to run (default: 50)")
    parser.add_argument("--difficulty", choices=["easy", "medium", "hard", "mixed"],
                        default="medium", help="Grid difficulty preset")
    parser.add_argument("--timeout", type=float, default=8.0,
                        help="Per-trial force-response timeout in seconds (default: 8.0)")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed for reproducible trial sequences")
    parser.add_argument("--out", type=str, default=None,
                        help="Optional JSONL path to log every trial in detail")
    parser.add_argument("--verbose", action="store_true",
                        help="Print each trial's grid and result")
    parser.add_argument("--plan-only", action="store_true",
                        help="Register only pragmata_hack_plan (omits the route "
                             "fallback). Forces the peer to actually plan moves.")
    parser.add_argument("--inter-trial-context", action="store_true",
                        help="Between trials, send a filler context message "
                             "(streamer-style dialogue or game narrative) to "
                             "match real gameplay conditions where hacks are "
                             "minutes apart with conversation in between. "
                             "Decouples trials from each other in the model's "
                             "recency window.")
    parser.add_argument("--inter-trial-delay", type=float, default=0.0,
                        help="Seconds to wait between trials. Combined with "
                             "--inter-trial-context, simulates real gameplay "
                             "pacing. Default 0 (no delay).")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    logging.getLogger("websockets").setLevel(logging.WARNING)

    try:
        return asyncio.run(_run(args))
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    sys.exit(main())
