"""Fixed copies of the other two puzzle actions the mod registers.

apitest builds its prompt prefix from every forcible action in the
registration, so registering the sequence action alone would make the prompt
smaller, and its cache entry different, from what the peer gets in game.
These copies (pragmata_main.lua as of 2026-09-15, hacking_require_reasoning
off) keep the catalogue the same size. They are never forced.
"""
from __future__ import annotations

DIRECTIONS = ["up", "down", "left", "right"]

HACK_PLAN = {
    "name": "pragmata_hack_plan",
    "description": (
        "Plan a path through the active hacking grid from cursor @ to Goal G.\n"
        "Coordinates: (0,0) is TOP-LEFT. x=column (left->right). y=row "
        "(top->bottom). 'up' decreases y by 1; 'down' increases y by 1; "
        "'left' decreases x by 1; 'right' increases x by 1. The first row "
        "is y=0; the last row is y=height-1. You cannot move 'up' from "
        "y=0 or 'down' from y=height-1.\n"
        "Read the state field carefully — the cursor and goal positions "
        "are given there, and the Adjacency block lists which first-moves "
        "are legal. Use those positions verbatim; do not infer or guess.\n"
        "NEVER step on a # (a wall — the cursor just stops), a d (an error "
        "node — entering RESETS the whole hack and you lose all progress), or "
        "an X (it fails the hack), and never re-enter a ~ trail cell against "
        "its arrow. Check "
        "EVERY move's destination cell against the grid, not just the first "
        "one. Plan ends on G.\n"
        "BONUS NODES: blue 'O' nodes are where the damage comes from — a hack "
        "that grabs none is nearly useless, so ACTIVELY prefer a SAFE route "
        "that passes through one or two O's on the way to G, even a few moves "
        "longer. Collect them going forward; do NOT detour out to a blue and "
        "double back, since retracing your own path undoes the blues. Hard "
        "limits: never step on a # (wall) or d (error node) to reach one - a d "
        "resets the whole hack - and only fall back to the shortest path if no "
        "O is reachable without crossing a # or d. (Yellow '*' = minor "
        "secondary bonus.)"
    ),
    "schema": {
        "type": "object",
        "required": ["moves"],
        "properties": {
            "moves": {"type": "array", "minItems": 1, "maxItems": 32,
                      "items": {"enum": DIRECTIONS}},
        },
    },
}

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
