"""Synthetic PuzzleSnake grid generator for AI-peer evaluation.

Models the in-game hacking grid (`app.PuzzleSnake`) closely enough that an
AI peer's solve rate against generated grids is predictive of its in-game
performance. The data model and cell-type vocabulary match the IL2CPP dump
(`app.PuzzleSnakeGridType`, 27 values).

Generated grids are guaranteed solvable (verified against `solver.solve`)
unless `force_unsolvable=True` is passed.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class CellType(str, Enum):
    # Engine enum names from app.PuzzleSnakeGridType. String values match exactly
    # so we can serialize and compare against runtime data without translation.
    NONE = "None"
    NOTHING = "Nothing"
    OPEN = "Open"
    START = "Start"
    GOAL = "Goal"
    OBSTACLE = "Obstacle"
    IMPASSABLE = "Impassable"
    SHIELD = "Shield"
    CHAIN = "Chain"
    ONE_WAY = "OneWay"
    TWO_WAY_LR = "TwoWayLeftRight"
    TWO_WAY_LT = "TwoWayLeftTop"
    TWO_WAY_LD = "TwoWayLeftDown"
    TWO_WAY_RT = "TwoWayRightTop"
    TWO_WAY_RD = "TwoWayRightDown"
    TWO_WAY_TD = "TwoWayTopDown"
    ACTIVE_SKILL = "ActiveSkill"
    ACTIVE_SKILL_1 = "ActiveSkill1"
    ACTIVE_SKILL_2 = "ActiveSkill2"
    ACTIVE_SKILL_3 = "ActiveSkill3"
    BOMB_3X3 = "Bomb3x3"
    BOMB_5X5 = "Bomb5x5"
    PURGE = "Purge"
    ATTACK = "Attack"
    ERASE_CODE = "EraseCode"
    DEAD_FILAMENT = "DeadFilament"
    FINISH_BLOW = "FinishBlow"


class Dir(str, Enum):
    UP = "up"
    DOWN = "down"
    LEFT = "left"
    RIGHT = "right"

    @property
    def delta(self) -> tuple[int, int]:
        return _DIR_DELTAS[self]

    @property
    def opposite(self) -> "Dir":
        return _DIR_OPPOSITES[self]


_DIR_DELTAS = {
    Dir.UP: (0, -1),
    Dir.DOWN: (0, 1),
    Dir.LEFT: (-1, 0),
    Dir.RIGHT: (1, 0),
}
_DIR_OPPOSITES = {
    Dir.UP: Dir.DOWN,
    Dir.DOWN: Dir.UP,
    Dir.LEFT: Dir.RIGHT,
    Dir.RIGHT: Dir.LEFT,
}

ALL_DIRS = (Dir.UP, Dir.DOWN, Dir.LEFT, Dir.RIGHT)


# ---------------------------------------------------------------------------
# Cell traversal rules
# ---------------------------------------------------------------------------
# `transitions` encodes directional cells: a set of (entry_move_dir,
# forced_exit_move_dir) pairs. None means "any direction in, any direction out".
# `blocks_step` => can't enter at all (walls).
# `fails_on_step` => stepping on it ends the hack (EraseCode).
# `is_goal` / `is_start` are flagged for quick lookup.

@dataclass(frozen=True)
class _CellRule:
    transitions: Optional[set[tuple[Dir, Dir]]] = None
    blocks_step: bool = False
    fails_on_step: bool = False
    is_start: bool = False
    is_goal: bool = False


_CORNER_TRANSITIONS = {
    # Coming from the left edge means "I was moving right when I arrived".
    # The cell connects left↔top, so the only legal exit is up.
    CellType.TWO_WAY_LT: {(Dir.RIGHT, Dir.UP),    (Dir.DOWN,  Dir.LEFT)},
    CellType.TWO_WAY_LD: {(Dir.RIGHT, Dir.DOWN),  (Dir.UP,    Dir.LEFT)},
    CellType.TWO_WAY_RT: {(Dir.LEFT,  Dir.UP),    (Dir.DOWN,  Dir.RIGHT)},
    CellType.TWO_WAY_RD: {(Dir.LEFT,  Dir.DOWN),  (Dir.UP,    Dir.RIGHT)},
}

CELL_RULES: dict[CellType, _CellRule] = {
    CellType.OPEN:           _CellRule(),
    CellType.START:          _CellRule(is_start=True),
    CellType.GOAL:           _CellRule(is_goal=True),
    CellType.CHAIN:          _CellRule(),
    CellType.ACTIVE_SKILL:   _CellRule(),
    CellType.ACTIVE_SKILL_1: _CellRule(),
    CellType.ACTIVE_SKILL_2: _CellRule(),
    CellType.ACTIVE_SKILL_3: _CellRule(),
    CellType.BOMB_3X3:       _CellRule(),
    CellType.BOMB_5X5:       _CellRule(),
    CellType.PURGE:          _CellRule(),
    CellType.ATTACK:         _CellRule(),
    CellType.FINISH_BLOW:    _CellRule(),
    CellType.DEAD_FILAMENT:  _CellRule(),

    CellType.OBSTACLE:   _CellRule(blocks_step=True),
    CellType.IMPASSABLE: _CellRule(blocks_step=True),
    CellType.NOTHING:    _CellRule(blocks_step=True),
    CellType.NONE:       _CellRule(blocks_step=True),
    CellType.SHIELD:     _CellRule(blocks_step=True),

    CellType.ERASE_CODE: _CellRule(fails_on_step=True),

    # OneWay rules depend on the per-cell direction; built dynamically by
    # `oneway_rule(dir)`. The static entry here just blocks until refined.
    CellType.ONE_WAY:    _CellRule(blocks_step=True),

    CellType.TWO_WAY_LR: _CellRule(transitions={(Dir.RIGHT, Dir.RIGHT), (Dir.LEFT,  Dir.LEFT)}),
    CellType.TWO_WAY_TD: _CellRule(transitions={(Dir.DOWN,  Dir.DOWN),  (Dir.UP,    Dir.UP)}),
    CellType.TWO_WAY_LT: _CellRule(transitions=_CORNER_TRANSITIONS[CellType.TWO_WAY_LT]),
    CellType.TWO_WAY_LD: _CellRule(transitions=_CORNER_TRANSITIONS[CellType.TWO_WAY_LD]),
    CellType.TWO_WAY_RT: _CellRule(transitions=_CORNER_TRANSITIONS[CellType.TWO_WAY_RT]),
    CellType.TWO_WAY_RD: _CellRule(transitions=_CORNER_TRANSITIONS[CellType.TWO_WAY_RD]),
}


def oneway_rule(allowed_dir: Dir) -> _CellRule:
    """Per-cell rule for a OneWay tile that only permits travel in `allowed_dir`."""
    return _CellRule(transitions={(allowed_dir, allowed_dir)})


# ---------------------------------------------------------------------------
# Cell + Grid data model
# ---------------------------------------------------------------------------

@dataclass
class Cell:
    type: CellType
    # Only meaningful for OneWay cells; ignored otherwise.
    direction: Optional[Dir] = None

    def rule(self) -> _CellRule:
        if self.type is CellType.ONE_WAY and self.direction is not None:
            return oneway_rule(self.direction)
        return CELL_RULES[self.type]


@dataclass
class Grid:
    width: int
    height: int
    cells: list[list[Cell]]            # cells[y][x]
    start: tuple[int, int]
    goal: tuple[int, int]
    cursor: tuple[int, int]
    trail: list[tuple[int, int]] = field(default_factory=list)
    status: str = "active"             # active | succeeded | failed | resetting

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height

    def at(self, x: int, y: int) -> Cell:
        return self.cells[y][x]


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

@dataclass
class GenConfig:
    """Knobs for grid generation. Defaults are tuned for an 'easy' early-sector
    grid: small, mostly Open, a few obstacles, no traps or directional cells.
    Crank density values to simulate boss / late-sector hacks.
    """
    size: tuple[int, int] = (5, 5)            # (width, height); each in [3, 8]
    obstacle_density: float = 0.15            # fraction of non-start/goal cells
    erase_code_density: float = 0.0           # 0 in early sectors; up to ~0.10 late
    active_skill_density: float = 0.10        # any of ActiveSkill / 1/2/3
    bomb_density: float = 0.0                 # Bomb3x3 / Bomb5x5
    other_effect_density: float = 0.0         # Chain, Purge, Attack, etc.
    directional_density: float = 0.0          # OneWay / TwoWay*
    seed: Optional[int] = None
    max_regen_attempts: int = 50              # if a roll yields unsolvable grid


_ACTIVE_SKILL_VARIANTS = (
    CellType.ACTIVE_SKILL, CellType.ACTIVE_SKILL_1,
    CellType.ACTIVE_SKILL_2, CellType.ACTIVE_SKILL_3,
)
_BOMB_VARIANTS = (CellType.BOMB_3X3, CellType.BOMB_5X5)
_OTHER_EFFECTS = (CellType.CHAIN, CellType.PURGE, CellType.ATTACK, CellType.FINISH_BLOW)
_DIRECTIONAL_TWO_WAYS = (
    CellType.TWO_WAY_LR, CellType.TWO_WAY_LT, CellType.TWO_WAY_LD,
    CellType.TWO_WAY_RT, CellType.TWO_WAY_RD, CellType.TWO_WAY_TD,
)


def generate(config: GenConfig) -> Grid:
    """Generate a guaranteed-solvable grid matching `config`.

    Retries up to `config.max_regen_attempts` times if a random roll produces
    an unsolvable grid (e.g. obstacles cut off the goal). Raises ValueError if
    we exhaust attempts — usually means densities are too high for the size.
    """
    from .solver import solve  # local import to avoid module cycle at load

    rng = random.Random(config.seed)
    w, h = config.size
    if not (3 <= w <= 8 and 3 <= h <= 8):
        raise ValueError(f"size {config.size} outside engine bounds [3, 8]")

    for _ in range(config.max_regen_attempts):
        grid = _roll(rng, config)
        if solve(grid) is not None:
            return grid
    raise ValueError(
        f"could not generate solvable grid in {config.max_regen_attempts} tries; "
        f"densities likely too high for size {config.size}"
    )


def _roll(rng: random.Random, config: GenConfig) -> Grid:
    w, h = config.size
    cells = [[Cell(type=CellType.OPEN) for _ in range(w)] for _ in range(h)]

    # Place Start and Goal at random distinct positions, with a Manhattan
    # distance floor so the grid isn't trivially solved in one move.
    all_positions = [(x, y) for y in range(h) for x in range(w)]
    rng.shuffle(all_positions)
    start = all_positions.pop()
    min_distance = max(2, (w + h) // 3)
    while all_positions:
        candidate = all_positions.pop()
        if abs(candidate[0] - start[0]) + abs(candidate[1] - start[1]) >= min_distance:
            goal = candidate
            break
    else:
        # Fall back to any non-start cell if the floor was too aggressive.
        goal = all_positions[0] if all_positions else (
            (start[0] + 1) % w, start[1]
        )

    cells[start[1]][start[0]] = Cell(type=CellType.START)
    cells[goal[1]][goal[0]] = Cell(type=CellType.GOAL)

    fillable = [pos for pos in all_positions if pos != start and pos != goal]
    rng.shuffle(fillable)

    def _take(n: int) -> list[tuple[int, int]]:
        out = fillable[:n]
        del fillable[:n]
        return out

    n_total = len(fillable) + 2  # the +2 for start/goal we already placed
    n_obstacles = int(round(config.obstacle_density * n_total))
    n_erase = int(round(config.erase_code_density * n_total))
    n_skill = int(round(config.active_skill_density * n_total))
    n_bomb = int(round(config.bomb_density * n_total))
    n_other = int(round(config.other_effect_density * n_total))
    n_directional = int(round(config.directional_density * n_total))

    for pos in _take(n_obstacles):
        cells[pos[1]][pos[0]] = Cell(type=CellType.OBSTACLE)
    for pos in _take(n_erase):
        cells[pos[1]][pos[0]] = Cell(type=CellType.ERASE_CODE)
    for pos in _take(n_skill):
        cells[pos[1]][pos[0]] = Cell(type=rng.choice(_ACTIVE_SKILL_VARIANTS))
    for pos in _take(n_bomb):
        cells[pos[1]][pos[0]] = Cell(type=rng.choice(_BOMB_VARIANTS))
    for pos in _take(n_other):
        cells[pos[1]][pos[0]] = Cell(type=rng.choice(_OTHER_EFFECTS))
    for pos in _take(n_directional):
        # Half OneWay, half TwoWay variants.
        if rng.random() < 0.5:
            cells[pos[1]][pos[0]] = Cell(
                type=CellType.ONE_WAY,
                direction=rng.choice(ALL_DIRS),
            )
        else:
            cells[pos[1]][pos[0]] = Cell(type=rng.choice(_DIRECTIONAL_TWO_WAYS))

    return Grid(
        width=w, height=h, cells=cells,
        start=start, goal=goal, cursor=start,
        trail=[start],
    )
