"""Reference solver + plan validator for synthetic PuzzleSnake grids.

`solve(grid)` returns a shortest legal move list from cursor to goal, or None.
`validate_plan(grid, moves)` checks an AI peer's proposed move list against the
same rules and reports the outcome: reached goal / hit EraseCode / illegal move.

Both share an underlying movement-rules engine that respects:
- Cell-level walls (Obstacle, Impassable, Nothing, Shield); None is plain
  walkable floor and Open is the walkable BLUE bonus node
- Red "error nodes" (DeadFilament type / Cell.blocked decoration) — currently
  impassable cells, treated exactly like walls
- The trap node (EraseCode — entering it is legal but ends the hack as failure)
- Directional cells (OneWay, TwoWay*) which constrain entry/exit pairs
- The trail: cells already in `grid.trail` cannot be re-entered
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from typing import Optional

from .grid_gen import ALL_DIRS, Cell, CellType, Dir, Grid


# ---------------------------------------------------------------------------
# Movement rules — shared by solver and validator
# ---------------------------------------------------------------------------

def _allowed_exits(cell: Cell, entry_dir: Optional[Dir]) -> tuple[Dir, ...]:
    """Directions in which we can leave `cell` given how we entered it.

    `entry_dir=None` means "we started on this cell" (no incoming move yet);
    directional rules don't apply.
    """
    rule = cell.rule()
    if rule.transitions is None or entry_dir is None:
        return ALL_DIRS
    return tuple(exit_d for (e, exit_d) in rule.transitions if e == entry_dir)


def _can_enter(cell: Cell, entry_dir: Dir) -> bool:
    """Can we step onto `cell` while moving in `entry_dir`?

    Returns False for walls and blocked error nodes. Returns True for
    EraseCode (the step is *legal* but the caller is responsible for treating
    it as a failure outcome).
    Directional cells require `entry_dir` to be one of their allowed entries.
    """
    rule = cell.rule()
    if rule.blocks_step:
        return False
    if rule.transitions is not None:
        if not any(e == entry_dir for (e, _) in rule.transitions):
            return False
    return True


# ---------------------------------------------------------------------------
# Reference solver
# ---------------------------------------------------------------------------

def solve(grid: Grid) -> Optional[list[Dir]]:
    """Shortest legal move list from cursor to goal, or None if unreachable.

    BFS in (x, y, entry_dir) state-space — entry_dir matters because directional
    cells permit different exits depending on how you entered. Edge cost = 1,
    so BFS is optimal. Refuses to step on EraseCode (treated as a wall for
    pathfinding purposes; you'd never voluntarily route through one). Blocked
    error nodes are already walls via their rule.
    """
    sx, sy = grid.cursor
    if grid.cursor == grid.goal:
        return []

    # Trail blocks revisits. The cursor itself isn't blocking — it's where
    # we're standing.
    blocked = set(grid.trail) - {grid.cursor}

    queue: deque[tuple[int, int, Optional[Dir], list[Dir]]] = deque()
    queue.append((sx, sy, None, []))
    visited_states: set[tuple[int, int, Optional[Dir]]] = {(sx, sy, None)}

    while queue:
        x, y, entry_dir, path = queue.popleft()
        cell = grid.at(x, y)

        for move in _allowed_exits(cell, entry_dir):
            dx, dy = move.delta
            nx, ny = x + dx, y + dy
            if not grid.in_bounds(nx, ny):
                continue
            if (nx, ny) in blocked:
                continue
            target = grid.at(nx, ny)
            if not _can_enter(target, move):
                continue
            if target.rule().fails_on_step:
                continue  # never voluntarily step on EraseCode

            new_path = path + [move]
            if (nx, ny) == grid.goal:
                return new_path

            state = (nx, ny, move)
            if state in visited_states:
                continue
            visited_states.add(state)
            queue.append((nx, ny, move, new_path))

    return None


# ---------------------------------------------------------------------------
# Plan validator
# ---------------------------------------------------------------------------

@dataclass
class ValidationResult:
    legal: bool                                  # every move respected the rules
    reaches_goal: bool                           # plan terminated on the Goal cell
    hit_erase_code: bool                         # plan stepped on EraseCode (fail)
    failure_at_move_index: Optional[int] = None  # 0-based index of the bad move
    reason: str = ""                             # human-readable diagnostic
    visited_path: list[tuple[int, int]] = field(default_factory=list)
    final_position: tuple[int, int] = (0, 0)

    @property
    def outcome(self) -> str:
        """Single-word outcome label for batch metrics."""
        if not self.legal:
            return "illegal"
        if self.reaches_goal:
            return "solved"
        if self.hit_erase_code:
            return "hit_erase"
        return "no_goal"


def validate_plan(grid: Grid, moves: list[Dir]) -> ValidationResult:
    """Replay `moves` from the grid's cursor and report what happens.

    Outcomes (in priority order):
    - illegal:    a move violated bounds, walls/error nodes, trail, or
                  directional rules
    - hit_erase:  plan was legal up to a step onto EraseCode
    - solved:     plan ended on the Goal cell
    - no_goal:    plan was legal but terminated without reaching the Goal
    """
    if not moves:
        return ValidationResult(
            legal=False, reaches_goal=False, hit_erase_code=False,
            failure_at_move_index=0, reason="empty plan",
            visited_path=[grid.cursor], final_position=grid.cursor,
        )

    pos = grid.cursor
    visited = set(grid.trail)
    visited_path: list[tuple[int, int]] = [pos]
    last_entry_dir: Optional[Dir] = None

    for i, move in enumerate(moves):
        cell = grid.at(*pos)
        allowed = _allowed_exits(cell, last_entry_dir)
        if move not in allowed:
            return ValidationResult(
                legal=False, reaches_goal=False, hit_erase_code=False,
                failure_at_move_index=i,
                reason=(
                    f"move {i} ({move.value}) violates exit rule at {pos} "
                    f"(cell={cell.type.value}, entered={last_entry_dir}, "
                    f"allowed_exits={[d.value for d in allowed]})"
                ),
                visited_path=visited_path, final_position=pos,
            )

        dx, dy = move.delta
        nx, ny = pos[0] + dx, pos[1] + dy

        if not grid.in_bounds(nx, ny):
            return ValidationResult(
                legal=False, reaches_goal=False, hit_erase_code=False,
                failure_at_move_index=i,
                reason=f"move {i} ({move.value}) leaves grid bounds at ({nx},{ny})",
                visited_path=visited_path, final_position=pos,
            )

        if (nx, ny) in visited:
            return ValidationResult(
                legal=False, reaches_goal=False, hit_erase_code=False,
                failure_at_move_index=i,
                reason=f"move {i} ({move.value}) revisits trail at ({nx},{ny})",
                visited_path=visited_path, final_position=pos,
            )

        target = grid.at(nx, ny)
        if not _can_enter(target, move):
            blocker = target.type.value
            if getattr(target, "blocked", False) \
                    or getattr(target, "dead_filament", False):
                blocker = f"error node (blocked, terrain={target.type.value})"
            return ValidationResult(
                legal=False, reaches_goal=False, hit_erase_code=False,
                failure_at_move_index=i,
                reason=(
                    f"move {i} ({move.value}) blocked by {blocker} "
                    f"at ({nx},{ny})"
                ),
                visited_path=visited_path, final_position=pos,
            )

        visited.add((nx, ny))
        visited_path.append((nx, ny))
        pos = (nx, ny)
        last_entry_dir = move

        if target.rule().fails_on_step:
            return ValidationResult(
                legal=True, reaches_goal=False, hit_erase_code=True,
                failure_at_move_index=i,
                reason=f"stepped on {target.type.value} at ({nx},{ny}) (move {i})",
                visited_path=visited_path, final_position=pos,
            )

        if (nx, ny) == grid.goal:
            return ValidationResult(
                legal=True, reaches_goal=True, hit_erase_code=False,
                reason=f"reached goal in {i + 1} moves",
                visited_path=visited_path, final_position=pos,
            )

    return ValidationResult(
        legal=True, reaches_goal=False, hit_erase_code=False,
        reason="plan exhausted without reaching goal",
        visited_path=visited_path, final_position=pos,
    )
