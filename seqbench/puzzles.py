"""Seeded sequence-hack puzzle sets.

A set is 5, 7 or 9 puzzles, mixing 3-press puzzles (drawn 7 x 7) and 4-press
puzzles (drawn 9 x 9):

    set 5 -> 3 three-press + 2 four-press
    set 7 -> 4 three-press + 3 four-press
    set 9 -> 5 three-press + 4 four-press

The set depends only on (size, seed, repeat), so every version in a run is
scored on exactly the same puzzles -- the only thing that differs between two
rows of the summary is the wording under test.

Each puzzle also carries `perm`, a shuffle of its press indices that is never
the identity. The letter-button versions label press i with "abcd..."[perm[i]]
and the shuffled list shows press i at position perm[i], so neither a letter
nor a position gives the press order away. It comes from its own rng, so the
directions are the same as the sets drawn before `perm` existed.
"""
from __future__ import annotations

import random
from dataclasses import dataclass

DIRECTIONS = ("up", "down", "left", "right")

SET_MIX: dict[int, tuple[int, int]] = {5: (3, 2), 7: (4, 3), 9: (5, 4)}


def make_perm(key: str, n: int) -> tuple[int, ...]:
    perm = list(range(n))
    if n < 2:
        return tuple(perm)
    rng = random.Random(key)
    while perm == sorted(perm):
        rng.shuffle(perm)
    return tuple(perm)


@dataclass(frozen=True)
class Puzzle:
    index: int                    # 1-based within its set; 0 for a warm-up
    sequence: tuple[str, ...]     # press order, first press first
    perm: tuple[int, ...] = ()    # display slot / letter index per press; () = identity

    @property
    def presses(self) -> int:
        return len(self.sequence)

    @property
    def label(self) -> str:
        side = 2 * self.presses + 1
        name = "warm-up" if self.index == 0 else f"#{self.index}"
        return f"{side}x{side} {name}"


def random_sequence(rng: random.Random, presses: int) -> tuple[str, ...]:
    # Directions repeat freely, as they do in game: one arm can hold several
    # buttons and another none.
    return tuple(rng.choice(DIRECTIONS) for _ in range(presses))


def build_set(size: int, seed: int, repeat: int = 0) -> list[Puzzle]:
    if size not in SET_MIX:
        raise ValueError(f"set size must be one of {sorted(SET_MIX)}, not {size}")
    three, four = SET_MIX[size]
    # A string seed goes through sha512 inside random, so it is stable across
    # runs and Python versions, unlike hash().
    rng = random.Random(f"seqbench:{seed}:{repeat}")
    presses = [3] * three + [4] * four
    rng.shuffle(presses)
    return [Puzzle(i + 1, random_sequence(rng, p), make_perm(f"seqbench-perm:{seed}:{repeat}:{i + 1}", p))
            for i, p in enumerate(presses)]


def warmup_puzzle(seed: int, repeat: int = 0) -> Puzzle:
    rng = random.Random(f"seqbench-warmup:{seed}:{repeat}")
    return Puzzle(0, random_sequence(rng, 3), make_perm(f"seqbench-perm:{seed}:{repeat}:0", 3))
