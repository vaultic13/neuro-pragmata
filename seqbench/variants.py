"""Options under test and the versions they combine into.

Adding an option:
  1. append an Option to OPTIONS (its `relevant` says when it can matter at all)
  2. teach sequence_texts.py what it changes
  3. if it contradicts another option, add a CONFLICTS entry
To offer a new version in the GUI, add it to GROUPS.

GROUPS are the five versions that passed testing, numbered as the mod's
mod_config.puzzle_sequence_group. The GUI offers only those; OPTIONS and
expand() stay for the selftest and for trying a new option later.

Expansion takes, per option, the values ticked, forms every combination, then
clears any option that has no effect in that combination and merges the
duplicates this creates. So "list + arms" and "list" are one version, reported
as merged rather than run twice.
"""
from __future__ import annotations

import itertools
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Optional


@dataclass(frozen=True)
class Option:
    id: str
    label: str
    help: str
    values: tuple = (False, True)
    value_labels: tuple = ("off", "on")
    relevant: Callable[[dict], bool] = lambda cfg: True

    @property
    def default(self) -> Any:
        return self.values[0]


def _cross(cfg: dict) -> bool:
    return cfg["render"] == "cross"


def _list(cfg: dict) -> bool:
    return cfg["render"] == "list"


OPTIONS: tuple[Option, ...] = (
    Option("render", "Render",
           "cross: the drawing, as tuned by the options below. list: the original "
           "\"On screen, in order: 1.up  2.left ...\" line. (mod: puzzle_sequence_render)",
           values=("cross", "list"), value_labels=("cross", "list")),
    Option("arms", "Arm lines",
           "One line per arm (up / down / left / right) instead of the 2-D cross. "
           "(mod: puzzle_sequence_arms)",
           relevant=_cross),
    Option("hints", "Hints",
           "Distance ruler, numbered reading steps and a worked example -- on the 2-D "
           "cross (mod: puzzle_sequence_hints) or, new, on arm lines.",
           relevant=_cross),
    Option("letters", "Letter buttons",
           "New: buttons drawn as letters (a, b, c, d; not in press order) instead of "
           "\"+\". The peer answers per letter with side + distance, side only or "
           "distance only; the bench fills in the rest and presses farthest first.",
           values=(None, "both", "side", "dist"),
           value_labels=("+", "side+dist", "side", "dist"),
           relevant=_cross),
    Option("compass", "Compass words",
           "New, list: shown as north / south / west / east, answered as "
           "up / down / left / right.",
           relevant=_list),
    Option("shuffle", "Shuffled list",
           "New, list: the numbered entries are shown out of order and must be sorted "
           "by number.",
           relevant=_list),
)

OPTION_IDS = tuple(o.id for o in OPTIONS)
_BY_ID = {o.id: o for o in OPTIONS}

# (predicate over a normalised cfg, why the combination is not run)
CONFLICTS: tuple[tuple[Callable[[dict], bool], str], ...] = ()


@dataclass(frozen=True)
class Version:
    id: str
    items: tuple[tuple[str, Any], ...]

    @property
    def cfg(self) -> dict:
        return dict(self.items)


@dataclass
class Expansion:
    versions: list[Version]
    combinations: int
    merged: list[str]
    dropped: list[str]


def default_cfg() -> dict:
    return {o.id: o.default for o in OPTIONS}


def all_picks() -> dict[str, tuple]:
    return {o.id: o.values for o in OPTIONS}


def value_label(option_id: str, value: Any) -> str:
    o = _BY_ID[option_id]
    return o.value_labels[o.values.index(value)]


def version_id(cfg: dict) -> str:
    parts = [str(cfg["render"])]
    for o in OPTIONS[1:]:
        v = cfg.get(o.id, o.default)
        if v == o.default:
            continue
        parts.append(o.id if v is True else f"{o.id}-{v}")
    return "+".join(parts)


def make_version(cfg: dict) -> Version:
    full = default_cfg()
    full.update(cfg)
    return Version(version_id(full), tuple((k, full[k]) for k in OPTION_IDS))


# ---------------------------------------------------------------------------
# Groups: the versions that passed testing, as the mod ships them. The number
# is mod_config.puzzle_sequence_group; the id is the bench's version id, so
# results stay comparable with the runs that picked them.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Group:
    number: int
    version: Version
    about: str

    @property
    def id(self) -> str:
        return self.version.id


GROUPS: tuple[Group, ...] = (
    Group(1, make_version({"render": "cross", "arms": True, "hints": True, "letters": "both"}),
          "arm lines with ruler, steps and example; letter buttons, answered with direction + distance"),
    Group(2, make_version({"render": "cross", "hints": True, "letters": "side"}),
          "2-D cross with ruler, steps and example; letter buttons, answered with direction only"),
    Group(3, make_version({"render": "list", "compass": True, "shuffle": True}),
          "list in compass words, numbered entries shown out of order; answered as an order"),
    Group(4, make_version({"render": "list", "compass": True}),
          "list in compass words; answered as an order"),
    Group(5, make_version({"render": "list"}),
          "the original list; answered as an order"),
)
DEFAULT_GROUP = 1
_GROUP_BY_ID = {g.id: g for g in GROUPS}


def mod_setting(group: Group) -> str:
    return f"puzzle_sequence_group = {group.number}"


def group_number(version_id_: str) -> Optional[int]:
    g = _GROUP_BY_ID.get(version_id_)
    return g.number if g else None


def normalize(raw: dict) -> tuple[dict, list[str]]:
    """Clear every option that cannot matter. In OPTIONS order, so an option's
    relevance sees the options before it already normalised."""
    cfg = dict(raw)
    cleared = []
    for o in OPTIONS:
        if cfg[o.id] != o.default and not o.relevant(cfg):
            cfg[o.id] = o.default
            cleared.append(o.id)
    return cfg, cleared


def _pool(option: Option, picked: Iterable) -> tuple:
    # Compare by identity of type as well, so False is not taken for None.
    chosen = [v for v in option.values if any(type(v) is type(p) and v == p for p in picked)]
    return tuple(chosen) or (option.default,)


def expand(picks: dict[str, Iterable]) -> Expansion:
    """`picks` maps an option id to the values ticked; a missing or empty entry
    means the option's default."""
    pools = [_pool(o, tuple(picks.get(o.id, ()))) for o in OPTIONS]
    versions: dict[str, Version] = {}
    merged: list[str] = []
    dropped: list[str] = []
    count = 0
    for values in itertools.product(*pools):
        count += 1
        raw = dict(zip(OPTION_IDS, values))
        cfg, cleared = normalize(raw)
        reason = next((why for test, why in CONFLICTS if test(cfg)), None)
        vid = version_id(cfg)
        if reason is not None:
            note = f"{vid}: {reason}"
            if note not in dropped:
                dropped.append(note)
            continue
        if cleared:
            merged.append(f"{version_id(raw)} = {vid} ({', '.join(cleared)} has no effect)")
        if vid not in versions:
            versions[vid] = make_version(cfg)
    return Expansion(list(versions.values()), count, merged, dropped)
