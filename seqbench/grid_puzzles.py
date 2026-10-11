"""Grid puzzle sets for a bench run: recorded, generated, and the finale chain.

Categories (grid_corpus_build.CATEGORY_HELP has the long form):

    plain  error  blocks  corrupt  big  nonsquare  resume  finale

A set holds `per_category` puzzles of each ticked category except `finale`,
which is always the boss's five stages in order, once per repeat -- they are
played as one chain with the context kept, as the mod now sends them.

Recorded puzzles are the mod's own forces (grid_corpus.json); a puzzle tagged
`finale` is used only by the finale chain, so `big` and `nonsquare` without
`finale` come from the generator. With source "both", the first half of a
category is recorded and the rest generated; a category with too few recorded
grids is topped up from the generator, and one the generator cannot make
(finale) uses only what was recorded.
"""
from __future__ import annotations

import json
import random
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Optional

import grid_gen
import grid_texts as gt

CORPUS = Path(__file__).resolve().parent / "grid_corpus.json"
CATEGORIES = ("plain", "error", "blocks", "corrupt", "big", "nonsquare", "resume", "finale")
SOURCES = ("both", "recorded", "generated")


@dataclass(frozen=True)
class GridVersion:
    id: str
    adjacency: bool
    about: str


VERSIONS = (
    GridVersion("mod", False, "the mod's wording as sent today (no adjacency block)"),
    GridVersion("mod+adjacency", True,
                "candidate: the same plus snake_render's per-direction adjacency block "
                "(the mod has it, but sends it off)"),
)
_VERSION_BY_ID = {v.id: v for v in VERSIONS}


def version(vid: str) -> GridVersion:
    return _VERSION_BY_ID[vid]


@dataclass
class GridItem:
    id: str                 # r012 (recorded) or g-plain-3 (generated)
    category: str
    source: str             # recorded | generated
    puzzle: gt.GridPuzzle
    ephemeral: bool = True
    finale_stage: Optional[int] = None
    chain: Optional[str] = None     # set on the finale stages: one chain per repeat

    @property
    def size(self) -> str:
        return f"{self.puzzle.width}x{self.puzzle.height}"

    @property
    def label(self) -> str:
        if self.finale_stage:
            return f"{self.size} finale {self.finale_stage}"
        return f"{self.size} {self.id}"


@lru_cache(maxsize=1)
def corpus() -> tuple[dict, ...]:
    if not CORPUS.exists():
        return ()
    return tuple(json.loads(CORPUS.read_text(encoding="utf-8"))["puzzles"])


def recorded(category: str) -> list[dict]:
    """The recorded grids of a category that can be solved as drawn."""
    usable = [e for e in corpus() if e.get("solvable", True)]
    if category == "finale":
        return [e for e in usable if "finale" in e["categories"]]
    return [e for e in usable if category in e["categories"] and "finale" not in e["categories"]]


def _from_entry(e: dict, category: str) -> GridItem:
    return GridItem(e["id"], category, "recorded", gt.parse_state(e["state"]),
                    ephemeral=bool(e.get("ephemeral_context", True)),
                    finale_stage=e.get("finale_stage"))


def finale_chain(repeat: int = 0) -> list[GridItem]:
    """The five stages as each first appears (cursor on the start), in order."""
    out = []
    for stage in range(1, 6):
        fresh = [e for e in recorded("finale") if e.get("finale_stage") == stage
                 and not gt.parse_state(e["state"]).trail]
        if not fresh:
            continue
        item = _from_entry(sorted(fresh, key=lambda e: e["id"])[0], "finale")
        item.ephemeral = False          # the mod's hack_finale_keep_context
        item.chain = f"finale-{repeat + 1}"
        out.append(item)
    return out


def build_set(categories, per_category: int, source: str, seed: int, repeat: int = 0) -> list[GridItem]:
    items: list[GridItem] = []
    for cat in categories:
        if cat == "finale":
            items += finale_chain(repeat)
            continue
        rng = random.Random(f"gridbench-set:{cat}:{seed}:{repeat}")
        pool = recorded(cat) if source in ("both", "recorded") else []
        rng.shuffle(pool)
        if source == "recorded":
            want_rec = per_category if pool else 0
        elif source == "both":
            want_rec = min(len(pool), (per_category + 1) // 2)
        else:
            want_rec = 0
        picked = [_from_entry(pool[i % len(pool)], cat) for i in range(want_rec)] if pool else []
        gen_n = per_category - len(picked) if source != "recorded" or not pool else 0
        if cat in grid_gen.GENERATED:
            for i, p in enumerate(grid_gen.build(cat, gen_n, seed, repeat)):
                picked.append(GridItem(f"g-{cat}-{i + 1}", cat, "generated", p))
        items += picked
    return items


def warmup_item(seed: int, repeat: int = 0) -> GridItem:
    p = grid_gen.build("plain", 1, seed + 100_000, repeat)[0]
    return GridItem("warm-up", "warm-up", "generated", p)
