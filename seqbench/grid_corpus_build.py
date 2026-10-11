"""Snapshot the mod's real hacking-grid forces into grid_corpus.json.

    py -3 grid_corpus_build.py [path/to/lua_to_bridge.jsonl ...]

Reads every pragmata_hack_plan actions/force the mod wrote (default: the live
mailbox, ../data/pragmata_mailbox/lua_to_bridge.jsonl), keeps each distinct
state once, tags it with its categories and writes grid_corpus.json next to
this file. The bench reads only the snapshot, never the mailbox, so a run is
repeatable; re-run this after playing to add what the mod sent since.

An existing snapshot is merged, not replaced: the mod's mailbox is truncated
when the game starts, so a grid seen in an older session stays in the corpus.
Each entry must survive `render(parse(state)) == state`; one that doesn't is
reported and left out (the port in grid_texts.py has fallen behind the mod).
The one exception is a force sent before the red-block wording (part A): it is
kept, marked `reworded`, and the bench sends it in today's wording.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

import grid_sim
import grid_texts as gt

HERE = Path(__file__).resolve().parent
DEFAULT_SOURCE = HERE.parent / "data" / "pragmata_mailbox" / "lua_to_bridge.jsonl"
CORPUS = HERE / "grid_corpus.json"

CATEGORIES = ("plain", "error", "blocks", "corrupt", "big", "nonsquare", "resume", "finale")
CATEGORY_HELP = {
    "plain": "none of the modifiers below; small square grid, cursor on the start",
    "error": "has d error nodes (entering one resets the hack)",
    "blocks": "red blocks (R): 1-3 of the 4 still up; touching one fails the hack",
    "corrupt": "corrupted enemy: c cells stun the cursor (grids of 30 cells or fewer)",
    "big": "more than 49 cells (9x9, 7x9 ...)",
    "nonsquare": "width differs from height",
    "resume": "a re-force mid-hack: cursor off the start, visited path drawn",
    "finale": "the final boss's five fixed stages, under a time limit, context kept",
}


def categories(p: gt.GridPuzzle) -> list[str]:
    tags = []
    flat = {g for row in p.cells for g in row}
    if "d" in flat:
        tags.append("error")
    if "R" in flat:
        tags.append("blocks")
    if p.corrupted:
        tags.append("corrupt")
    if p.width * p.height > 49:
        tags.append("big")
    if p.width != p.height:
        tags.append("nonsquare")
    if p.trail:
        tags.append("resume")
    if gt.finale_stage(p) is not None:
        tags.append("finale")
    return tags or ["plain"]


def read_forces(path: Path):
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if '"actions/force"' not in line or gt.ACTION_NAME not in line:
            continue
        try:
            data = json.loads(line)["data"]
        except (json.JSONDecodeError, KeyError):
            continue
        if data.get("action_names") == [gt.ACTION_NAME] and isinstance(data.get("state"), str):
            yield data


def build(sources: list[Path]) -> dict:
    old = json.loads(CORPUS.read_text(encoding="utf-8")) if CORPUS.exists() else {"puzzles": []}
    by_state = {e["state"]: e for e in old["puzzles"]}
    seen = Counter()
    rejected = []
    for src in sources:
        for data in read_forces(src):
            state = data["state"]
            seen[state] += 1
            if state in by_state:
                continue
            try:
                p = gt.parse_state(state)
            except gt.ParseError as exc:
                rejected.append(f"unparsed ({exc}): {state.splitlines()[0]}")
                continue
            rendered = gt.render(p)
            reworded = rendered != state
            if reworded and state.replace(gt.OLD_ROUTING_RULE, gt.ROUTING_RULE) != rendered:
                rejected.append(f"render differs: {state.splitlines()[0]} cursor {p.cursor}")
                continue
            by_state[state] = {
                "id": "",
                "categories": categories(p),
                "finale_stage": gt.finale_stage(p),
                "size": f"{p.width}x{p.height}",
                "state": state,
                # Sent before today's wording; the bench sends render(parse(state)).
                "reworded": reworded,
                "query": data.get("query"),
                "ephemeral_context": data.get("ephemeral_context", True),
                "priority": data.get("priority"),
                # As drawn, can the goal be reached at all? A grid that can't
                # (r019: the cursor boxed in by a block the render still shows
                # after it went down) is kept for the record, never benched.
                "solvable": grid_sim.shortest_path(p) is not None,
            }
    entries = sorted(by_state.values(), key=lambda e: (e["categories"], e["size"], e["state"]))
    for i, e in enumerate(entries, start=1):
        e["id"] = f"r{i:03d}"
        e["times_sent"] = max(e.get("times_sent", 0), seen.get(e["state"], 0))
    return {"source": [str(s) for s in sources], "puzzles": entries, "rejected": rejected}


def main() -> int:
    sources = [Path(a) for a in sys.argv[1:]] or [DEFAULT_SOURCE]
    for s in sources:
        if not s.exists():
            print(f"no such file: {s}")
            return 1
    corpus = build(sources)
    rejected = corpus.pop("rejected")
    CORPUS.write_text(json.dumps(corpus, indent=1, ensure_ascii=False), encoding="utf-8")
    counts = Counter(c for e in corpus["puzzles"] for c in e["categories"])
    stages = sorted({e["finale_stage"] for e in corpus["puzzles"] if e["finale_stage"]})
    print(f"{len(corpus['puzzles'])} distinct grids -> {CORPUS.name}")
    for c in CATEGORIES:
        print(f"  {c:<10} {counts.get(c, 0)}")
    print(f"  finale stages: {stages}")
    for e in corpus["puzzles"]:
        if not e["solvable"]:
            print(f"  unsolvable as drawn, not benched: {e['id']} {e['size']} {e['categories']}")
    for r in rejected:
        print("  rejected: " + r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
