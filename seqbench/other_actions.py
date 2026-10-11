"""Fixed copies of the other two puzzle actions the mod registers.

apitest builds its prompt prefix from every forcible action in the
registration, so registering the sequence action alone would make the prompt
smaller, and its cache entry different, from what the peer gets in game.
These copies (pragmata_main.lua as of 2026-09-15, hacking_require_reasoning
off; the plan action as of 2026-10-08, kept in grid_texts.py) keep the
catalogue the same size. The sequence bench never forces them; the grid bench
forces the plan action and registers the others around it.
"""
from __future__ import annotations

import grid_texts

DIRECTIONS = ["up", "down", "left", "right"]

# One copy of the plan action for both benches; the grid bench forces it.
HACK_PLAN = grid_texts.ACTION_DEF

HACK_ROTATE = {
    "name": "pragmata_hack_rotate",
    "description": (
        "Solve the active circuit hack. One to four connectors sit around a centre, "
        "each of them one circuit to close. A circuit is a line running in from the "
        "edge of the board; its connector closes it when it JOINS that line to the "
        "centre, both ends lined up -- pointing at the centre is not enough.\n"
        "`piece` names a connector by the direction button that turns it, which the "
        "mod measures on the board before describing it. The state field lists every "
        "connector under that name, what it opens onto now, and whether it is "
        "already connected; use those names verbatim.\n"
        "`steps` is how many presses to give that connector: 1, 2 or 3. Most "
        "connector lines end in `PRESS n to close it` -- use that "
        "number. It is worked out from the board, so it is not a hint to be improved "
        "on. Where a line gives no press count instead, the three options are "
        "spelled out and the answer is the count you judge joins its line to the "
        "centre.\n"
        "Leave a connector out of your answer to leave it alone, and leave alone "
        "any the state already reports as connected -- turning one disconnects it "
        "again. Work out the whole answer before replying; the timed variants do "
        "not wait."
    ),
    "schema": {
        "type": "object",
        "required": ["rotations"],
        "properties": {
            "rotations": {
                "type": "array",
                "minItems": 1,
                "maxItems": 8,
                "items": {
                    "type": "object",
                    "required": ["piece", "steps"],
                    "properties": {
                        "piece": {"type": "string", "enum": DIRECTIONS,
                                  "description": "which piece, by its position relative to the centre"},
                        "steps": {"type": "integer", "minimum": 1, "maximum": 3,
                                  "description": "how many presses to give it"},
                    },
                },
            },
        },
    },
}

ACTIONS = [HACK_PLAN, HACK_ROTATE]


def catalogue_for_grid() -> list[dict]:
    """The rest of the in-game catalogue around the plan action: rotate, and
    the sequence action in the mod's default group."""
    import sequence_texts
    import variants
    group = next(g for g in variants.GROUPS if g.number == variants.DEFAULT_GROUP)
    return [HACK_ROTATE, sequence_texts.action_def(group.version.cfg)]
