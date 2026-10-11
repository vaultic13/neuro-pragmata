"""Scoring a grid episode: one puzzle, up to `max_forces` forces.

An episode ends when the hack is solved, fails (an X, a red block with the
refusal off, the finale's clock), the peer does not answer, or the force limit
is reached (a finale stage has no limit of its own but its clock). Ratings, per episode:

    very good  solved on the first force, that reply under VERY_GOOD_S
    good       solved on the first force, slower
    risky      solved, but only on a retry (a wall, reset, refusal, short plan)
    fail       not solved within the forces, or the hack failed
    timeout    no reply within the cap, or the finale stage ran out of time

Plan quality, for the solved ones: moves against the shortest safe route, and
blue nodes collected against the most a route at most 4 moves longer could
collect (grid_sim.best_route; blank where its search gave up).
"""
from __future__ import annotations

import csv
import statistics
from pathlib import Path
from typing import Optional

VERY_GOOD_S = 3.0
RATINGS = ("very good", "good", "risky", "fail", "timeout")


def rate(solved: bool, forces: int, first_reply_s: Optional[float], timed_out: bool) -> str:
    if timed_out:
        return "timeout"
    if not solved:
        return "fail"
    if forces > 1:
        return "risky"
    if first_reply_s is not None and first_reply_s < VERY_GOOD_S:
        return "very good"
    return "good"


SUMMARY_COLUMNS = ("version", "category", "episodes", "solved_pct", "first_try_pct", "very good", "good",
                   "risky", "fail", "timeout", "avg_forces", "median_ms", "extra_moves", "blue_pct",
                   "stuns", "refusals", "resets", "walls", "outcomes")


def summarize(records: list[dict]) -> list[dict]:
    rows: dict[tuple, dict] = {}
    for rec in records:
        if rec.get("warmup"):
            continue
        key = (rec["version"], rec["category"])
        row = rows.get(key)
        if row is None:
            row = {"version": key[0], "category": key[1], "episodes": 0, "solved": 0, "first": 0,
                   **{r: 0 for r in RATINGS}, "forces": 0, "times": [], "extra": [], "blue_got": 0,
                   "blue_best": 0, "stuns": 0, "refusals": 0, "resets": 0, "walls": 0, "outcomes": {}}
            rows[key] = row
        row["episodes"] += 1
        row["solved"] += 1 if rec["solved"] else 0
        row["first"] += 1 if rec["solved"] and rec["forces_used"] == 1 else 0
        row[rec["rating"]] += 1
        row["forces"] += rec["forces_used"]
        row["times"] += [f["elapsed_ms"] for f in rec["forces"] if f.get("elapsed_ms") is not None]
        if rec["solved"] and rec.get("optimal_moves") is not None:
            row["extra"].append(rec["moves_made"] - rec["optimal_moves"])
        if rec["solved"] and rec.get("best_blues"):
            row["blue_got"] += min(rec["blues"], rec["best_blues"])
            row["blue_best"] += rec["best_blues"]
        for k in ("stuns", "refusals", "resets", "walls"):
            row[k] += rec.get(k, 0)
        row["outcomes"][rec["outcome"]] = row["outcomes"].get(rec["outcome"], 0) + 1
    out = []
    for row in rows.values():
        n = row["episodes"]
        t = row.pop("times")
        extra = row.pop("extra")
        row["solved_pct"] = round(100.0 * row["solved"] / n, 1)
        row["first_try_pct"] = round(100.0 * row["first"] / n, 1)
        row["avg_forces"] = round(row["forces"] / n, 2)
        row["median_ms"] = int(statistics.median(t)) if t else None
        row["extra_moves"] = round(statistics.fmean(extra), 2) if extra else None
        row["blue_pct"] = round(100.0 * row["blue_got"] / row["blue_best"], 1) if row["blue_best"] else None
        out.append(row)
    return out


def path_drawing(state: str, path) -> str:
    """The force's grid with the cells the plan entered marked: '+' for each
    one, '!' where it stopped short of the goal, 'G' kept on the goal."""
    import grid_texts as gt
    p = gt.parse_state(state)
    drawn = gt.overlay(p)
    cells = [tuple(c) for c in path or []]
    for x, y in cells:
        if (x, y) != p.goal:
            drawn[y][x] = "+"
    if cells and cells[-1] != p.goal:
        drawn[cells[-1][1]][cells[-1][0]] = "!"
    rows = ["    " + " ".join(str(x) for x in range(p.width))]
    rows += [f" {y}  " + " ".join(drawn[y]) for y in range(p.height)]
    return "\n".join(rows)


def detail_text(rec: dict) -> str:
    """The trial pane for a grid episode: every force with its reply, what it
    did on the grid and what the peer was told, then the states sent."""
    import grid_texts as gt
    stage = f"   finale stage {rec['finale_stage']} ({rec['chain']})" if rec.get("finale_stage") else ""
    parts = [
        f"{rec['version']}   {rec['category']}   {rec['puzzle']} ({rec['source']})   "
        f"repeat {rec['repeat'] + 1}{stage}",
        f"outcome: {rec['outcome']}   rating: {rec['rating']}   forces: {rec['forces_used']}   "
        f"clock: {rec.get('clock_s')} s   context: {'kept' if not rec.get('ephemeral') else 'ephemeral'}",
        f"moves made: {rec.get('moves_made')}   shortest safe route: {rec.get('optimal_moves')}   "
        f"blues: {rec.get('blues')} (best {rec.get('best_blues')})   stuns: {rec.get('stuns')}   "
        f"refused: {rec.get('refusals')}   resets: {rec.get('resets')}   walls: {rec.get('walls')}",
        f"a shortest route: {gt.moves_text(rec.get('optimal'))}",
    ]
    for k, f in enumerate(rec["forces"], start=1):
        ms = "no reply" if f.get("elapsed_ms") is None else f"{f['elapsed_ms']} ms"
        parts += [
            "", f"== FORCE {k}: {ms}, cursor {tuple(f['cursor'])} ==",
            f"moves:  {gt.moves_text(f.get('moves'))}",
            f"result: {f.get('outcome')} -- {f.get('message')}",
        ]
        if f.get("path") is not None:
            parts += ["played (+ entered, ! stopped):", path_drawing(f["state"], f["path"])]
        if f.get("action") is not None:
            parts.append(f"raw: {f.get('action')}  {f.get('raw_args')}")
    for k, f in enumerate(rec["forces"], start=1):
        parts += ["", f"== STATE {k} ==", f["state"]]
    parts += ["", "== QUERY ==", gt.FORCE_QUERY, "", "== DESCRIPTION ==", gt.ACTION_DEF["description"]]
    return "\n".join(parts)


def write_summary_csv(path: Path, records: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fp:
        writer = csv.writer(fp)
        writer.writerow([c.replace(" ", "_") for c in SUMMARY_COLUMNS])
        for row in summarize(records):
            values = []
            for c in SUMMARY_COLUMNS:
                v = row.get(c)
                if c == "outcomes":
                    v = " ".join(f"{k}={n}" for k, n in sorted(v.items()))
                values.append("" if v is None else v)
            writer.writerow(values)
