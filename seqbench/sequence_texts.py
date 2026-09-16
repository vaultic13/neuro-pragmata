"""The sequence hack as the peer sees it -- copied from the mod, not imported.

seqbench is independent of the mod on purpose: nothing here reads autorun/.
The plain cross / arms / hints / list texts are line-for-line ports of the Lua
as of 2026-09-15, except that the drawings now put a space between characters
(`0 - + -`, not the mod's `0-+-`):

    util/puzzle_render.lua     button_cross, button_arms, button_example_lines,
                               M.buttons (the force's `state`)
    pragmata_main.lua          pragmata_hack_sequence description and schema
    bindings/puzzle_buttons.lua  M.force_query

Since 2026-09-16 it runs the other way too: the mod's five sequence groups
(variants.GROUPS, mod_config.puzzle_sequence_group) are ports of this file,
spaced drawings and letters included. Editing either side does not change the
other; port a change deliberately.

A `cfg` is a plain dict keyed by the option ids in variants.py. render / hints /
arms mirror mod_config's puzzle_sequence_* switches; the rest exist only here,
as candidates to try before touching the mod:

    hints on arms   the numbered reading steps + worked example on arm lines
    letters         buttons drawn as letters; the peer answers per letter with
                    both / side / dist and the bench fills in the rest
    compass         the list in north/south/west/east, answered in up/down/...
    shuffle         the list's numbered entries shown out of order

Round 1 (distance answer, simple wording, code fence) was removed after it
showed no gain; see results/20260915-164155.
"""
from __future__ import annotations

from typing import Optional

ACTION_NAME = "pragmata_hack_sequence"
# mod_config.puzzle_force_priority.buttons = "Low", sent lowercased.
PRIORITY = "low"
DIRECTIONS = ("up", "down", "left", "right")
LETTERS = "abcdefghijklmnop"
COMPASS = {"up": "north", "down": "south", "left": "west", "right": "east"}
LETTER_FORMS = ("both", "side", "dist")

_ARM_STEP = {"up": (-1, 0), "down": (1, 0), "left": (0, -1), "right": (0, 1)}
_ARM_ORDER = ("up", "down", "left", "right")
_ARM_PREFIX = 8  # len("right 0 "): where an arm line's slots start
# Drawn characters are separated by a space (`- - + -`), so each slot is
# its own token instead of being merged into runs like `--+-`.
_GAP = " "
_EXAMPLE_SEQUENCE = ("right", "up", "right")
_EXAMPLE_PERM = (1, 2, 0)  # the worked example's letters: b, c, a


# ---------------------------------------------------------------------------
# Which branch a cfg selects. Same precedence as the mod: anything but "list"
# is the cross; the letters apply to the cross, compass and shuffle to the list.
# ---------------------------------------------------------------------------

def is_cross(cfg: dict) -> bool:
    return cfg.get("render") != "list"


def uses_arms(cfg: dict) -> bool:
    return is_cross(cfg) and bool(cfg.get("arms"))


def uses_hints(cfg: dict) -> bool:
    return is_cross(cfg) and bool(cfg.get("hints"))


def letter_form(cfg: dict) -> Optional[str]:
    """None for "+" buttons, else "both" / "side" / "dist"."""
    form = cfg.get("letters")
    return form if is_cross(cfg) and form in LETTER_FORMS else None


def uses_compass(cfg: dict) -> bool:
    return not is_cross(cfg) and bool(cfg.get("compass"))


def uses_shuffle(cfg: dict) -> bool:
    return not is_cross(cfg) and bool(cfg.get("shuffle"))


def answer_field(cfg: dict) -> str:
    return "buttons" if letter_form(cfg) else "order"


def _plural(n: int, suffix: str = "s") -> str:
    return "" if n == 1 else suffix


def _perm(perm, n: int) -> tuple[int, ...]:
    return tuple(perm) if perm and len(perm) == n else tuple(range(n))


def marks_for(sequence, perm=None) -> list[str]:
    """The letter drawn for each press, in press order."""
    return [LETTERS[p] for p in _perm(perm, len(sequence))]


def truth_by_letter(sequence, perm=None) -> dict[str, tuple[int, str]]:
    """letter -> (distance from 0, direction). Press i of n sits n-i+1 out."""
    n = len(sequence)
    return {m: (n - i, d) for i, (m, d) in enumerate(zip(marks_for(sequence, perm), sequence))}


def shown_word(cfg: dict, direction: str) -> str:
    return COMPASS.get(direction, direction) if uses_compass(cfg) else direction


# ---------------------------------------------------------------------------
# Drawings
# ---------------------------------------------------------------------------

def button_cross(sequence, ruler: bool = False, marks=None) -> Optional[list[str]]:
    """Port of button_cross: 0 centre, "-" slots on the arms, "*" filler, press
    i of n marked n-i+1 slots out -- "+" or its letter. `ruler` labels the top
    and left edges."""
    n = len(sequence)
    arm = max(1, n)
    grid = [
        ["0" if r == 0 and c == 0 else "-" if r == 0 or c == 0 else "*"
         for c in range(-arm, arm + 1)]
        for r in range(-arm, arm + 1)
    ]
    for i, d in enumerate(sequence, start=1):
        step = _ARM_STEP.get(d)
        if step is None:
            return None
        dist = n - i + 1
        grid[arm + step[0] * dist][arm + step[1] * dist] = marks[i - 1] if marks else "+"
    lines = []
    if ruler:
        lines.append("  " + _GAP.join(str(abs(c) % 10) for c in range(-arm, arm + 1)))
    for i, row in enumerate(grid):
        text = _GAP.join(row)
        if ruler:
            text = f"{abs(i - arm) % 10} {text}"
        lines.append(text)
    return lines


def button_arms(sequence, ruler: bool = False, marks=None) -> Optional[list[str]]:
    """Port of button_arms: one line per arm, read from 0 outward. `ruler`
    puts each slot's distance above it."""
    n = len(sequence)
    arm = max(1, n)
    slots = {d: ["-"] * arm for d in _ARM_ORDER}
    for i, d in enumerate(sequence, start=1):
        if d not in slots:
            return None
        slots[d][n - i] = marks[i - 1] if marks else "+"
    lines = [" " * _ARM_PREFIX + _GAP.join(str(k % 10) for k in range(1, arm + 1))] if ruler else []
    return lines + [f"{d:<5} 0{_GAP}{_GAP.join(slots[d])}" for d in _ARM_ORDER]


def _draw(cfg: dict, sequence, perm, ruler: bool) -> Optional[list[str]]:
    marks = marks_for(sequence, perm) if letter_form(cfg) else None
    if uses_arms(cfg):
        return button_arms(sequence, ruler, marks)
    return button_cross(sequence, ruler, marks)


# ---------------------------------------------------------------------------
# Wording that depends on "+" versus letters
# ---------------------------------------------------------------------------

_LETTER_TASK = {
    "both": "For every letter, give its direction and its distance; the mod presses "
            "them farthest first.",
    "side": "For every letter, give only its direction; the mod knows each distance "
            "and presses them farthest first.",
    "dist": "For every letter, give only its distance from 0; the mod knows each "
            "direction and presses them farthest first.",
}

_ARMS_LEGEND = (
    "How to read it: each line is one arm, read from the centre 0 outward. "
    "\"+\" is a button, \"-\" is an empty slot. A \"+\" stands for the direction "
    "its line is named for. Its distance from 0 is its position after the 0: "
    "the slot right after 0 is distance 1. The \"+\" FARTHEST from 0, on "
    "any line, is the first press, and the one nearest 0 is the last. Every "
    "button is a different distance from 0, and a line can hold more than one."
)

_ARMS_LEGEND_LETTERS = (
    "How to read it: each line is one arm, read from the centre 0 outward. "
    "Each letter is a button, \"-\" is an empty slot. A letter's direction is "
    "the name of its line. Its distance from 0 is its position after the 0: "
    "the slot right after 0 is distance 1. Every button is a different "
    "distance from 0, and a line can hold more than one. "
)

_CROSS_LEGEND = (
    "How to read it: 0 is the centre. Each arm of the cross is a row of button "
    "slots -- \"+\" is a button, \"-\" is an empty slot, \"*\" is just filler. "
    "A \"+\" stands for the direction of its arm from 0: above 0 is up, below "
    "is down, left of 0 is left, right of 0 is right. The order is set by "
    "distance from 0 along the row or column: the \"+\" FARTHEST from 0 is the "
    "first press, and the one nearest 0 is the last. Every button is a "
    "different distance from 0, and an arm can hold more than one."
)

_CROSS_LEGEND_LETTERS = (
    "How to read it: 0 is the centre. Each arm of the cross is a row of button "
    "slots -- each letter is a button, \"-\" is an empty slot, \"*\" is just "
    "filler. A letter's direction is the side of 0 its arm is on: above 0 is up, "
    "below is down, left of 0 is left, right of 0 is right. Its distance is how "
    "many slots it sits from 0 along the row or column (1 = next to 0). Every "
    "button is a different distance from 0, and an arm can hold more than one. "
)


def _legend(cfg: dict) -> str:
    form = letter_form(cfg)
    if uses_arms(cfg):
        return _ARMS_LEGEND_LETTERS + _LETTER_TASK[form] if form else _ARMS_LEGEND
    return _CROSS_LEGEND_LETTERS + _LETTER_TASK[form] if form else _CROSS_LEGEND


def _hint_steps(cfg: dict) -> list[str]:
    form = letter_form(cfg)
    button = "each letter (a, b, c, ...) is a button" if form else "\"+\" is a button"
    one = "letter" if form else "\"+\""
    where = "line" if uses_arms(cfg) else "arm"
    if uses_arms(cfg):
        steps = [
            f"1. Each line is one arm, named at its start. 0 is the centre. {button[0].upper()}"
            f"{button[1:]}, \"-\" is an empty slot.",
            "2. The numbers above the slots are each slot's distance from 0.",
            f"3. A {one} stands for the direction its line is named for.",
            "4. Its distance is the number above it.",
        ]
    else:
        steps = [
            f"1. 0 is the centre. {button[0].upper()}{button[1:]}, \"-\" is an empty "
            "button slot, \"*\" is filler.",
            "2. The numbers along the top and the left edge are each "
            "column's and each row's distance from 0.",
            f"3. A {one} above 0 is up, below 0 is down, left of 0 is "
            "left, right of 0 is right.",
            "4. Its distance is its row number if it is up or down, "
            "and its column number if it is left or right.",
        ]
    if form:
        steps.append(f"5. Each distance holds exactly one button, and {'a line' if uses_arms(cfg) else 'an arm'} "
                     f"can hold more than one. {_LETTER_TASK[form]}")
    else:
        steps.append("5. The \"+\" with the LARGEST distance is press 1, the next "
                     "largest is press 2, and so on; distance 1 is the last press. Each "
                     f"distance holds exactly one button, and {'a line' if uses_arms(cfg) else 'an arm'} "
                     "can hold more than one.")
    return steps


def _example_lines(cfg: dict) -> list[str]:
    lines = ["Worked example -- NOT this puzzle:"]
    lines += _draw(cfg, _EXAMPLE_SEQUENCE, _EXAMPLE_PERM, True)
    n = len(_EXAMPLE_SEQUENCE)
    form = letter_form(cfg)
    if form is None:
        found = [f"{d} at distance {n - i + 1}" for i, d in enumerate(_EXAMPLE_SEQUENCE, start=1)]
        lines.append("The buttons are " + ", ".join(found)
                     + ". Largest distance first, so the example's order is "
                     + ", ".join(_EXAMPLE_SEQUENCE) + ".")
        return lines
    truth = sorted(truth_by_letter(_EXAMPLE_SEQUENCE, _EXAMPLE_PERM).items())
    found = [f"{m} is {d} at distance {dist}" for m, (dist, d) in truth]
    if form == "both":
        answer = ", ".join(f"{m} {d} {dist}" for m, (dist, d) in truth)
    elif form == "side":
        answer = ", ".join(f"{m} {d}" for m, (dist, d) in truth)
    else:
        answer = ", ".join(f"{m} {dist}" for m, (dist, d) in truth)
    lines.append("The buttons: " + "; ".join(found) + f". So the example's answer is {answer}.")
    return lines


# ---------------------------------------------------------------------------
# The force's `state`
# ---------------------------------------------------------------------------

_UNREADABLE = "A sequence hack is active, but its directions could not be read."


def state_text(cfg: dict, sequence, step: int = 0, timed: bool = False, perm=None) -> str:
    n = len(sequence)
    total = n
    lines: list[str] = []
    cross = is_cross(cfg)
    form = letter_form(cfg)

    if cross and uses_hints(cfg):
        drawn = _draw(cfg, sequence, perm, True)
        if drawn is None:
            return _UNREADABLE
        shape = "one line per arm" if uses_arms(cfg) else "drawn as a cross"
        lines.append(f"Sequence hack: {n} direction{_plural(n)} must be entered in order, {shape}.")
        lines.append("")
        lines.append("How to read the drawing:")
        lines += _hint_steps(cfg)
        lines.append("")
        lines += _example_lines(cfg)
        lines.append("")
        lines.append(f"This puzzle ({n} press{_plural(n, 'es')}):")
        lines += drawn
        lines.append("")
    elif cross:
        drawn = _draw(cfg, sequence, perm, False)
        if drawn is None:
            return _UNREADABLE
        shape = "one line per arm" if uses_arms(cfg) else "drawn as a cross"
        lines.append(f"Sequence hack: {n} direction{_plural(n)} must be entered in order. "
                     f"The puzzle, {shape}:")
        lines.append("")
        lines += drawn
        lines.append("")
        lines.append(_legend(cfg))
    else:
        if any(d not in DIRECTIONS for d in sequence):
            return _UNREADABLE
        lines.append(f"Sequence hack: {n} direction{_plural(n)} must be entered in order.")
        entries = [f"{i}.{shown_word(cfg, d)}(done)" if i <= step else f"{i}.{shown_word(cfg, d)}"
                   for i, d in enumerate(sequence, start=1)]
        if uses_shuffle(cfg):
            slots = _perm(perm, n)
            shown = [entries[i] for i in sorted(range(n), key=lambda i: slots[i])]
            lines.append("On screen, numbered by press but shown out of order: " + "  ".join(shown))
        else:
            lines.append("On screen, in order: " + "  ".join(entries))
        if uses_compass(cfg):
            lines.append("Directions are compass points: north = up, south = down, west = left, "
                         "east = right. Answer with up/down/left/right.")

    if step > 0:
        lines.append(f"{step} of {total} already entered. Give the WHOLE sequence from the start "
                     "anyway -- the plan is checked against the full list.")
    if timed:
        lines.append("This one has a timing dial. You do NOT have to time anything: give "
                     "the order and each press is fired on a frame the game accepts.")

    if form:
        what = {"both": "its `distance` from 0 and its `direction`",
                "side": "its `direction`", "dist": "its `distance` from 0"}[form]
        lines.append(f"Answer with `buttons`: one entry per letter, with its `button` letter and "
                     f"{what}, in any order. It must have exactly {total} entries, one per "
                     "letter -- a missing, repeated or unknown letter is refused without "
                     "pressing anything, because a wrong-length sequence fails the hack outright.")
        return "\n".join(lines)

    if cross:
        how = "farthest button first"
    elif uses_shuffle(cfg):
        how = "sorted by their numbers, press 1 first"
    else:
        how = "in sequence"
    lines.append(f"Answer with `order` listing every direction, {how}. It must have "
                 f"exactly {total} entries -- a short or long "
                 "answer is refused without pressing anything, because a wrong-length "
                 "sequence fails the hack outright.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Query, description, schema
# ---------------------------------------------------------------------------

_FORM_WHAT = {"both": "its direction and distance", "side": "its direction", "dist": "its distance"}


def force_query(cfg: dict) -> str:
    form = letter_form(cfg)
    if form:
        return ("A sequence hack is live. Read each lettered button off the drawing in the "
                f"state and call pragmata_hack_sequence with {_FORM_WHAT[form]} for every letter.")
    if is_cross(cfg):
        return ("A sequence hack is live. Read the directions off the drawing in the "
                "state and call pragmata_hack_sequence with them in order.")
    if not (uses_shuffle(cfg) or uses_compass(cfg)):
        return ("A sequence hack is live. Call pragmata_hack_sequence with the "
                "directions in the order shown.")
    how = "sorted by their numbers" if uses_shuffle(cfg) else "in the order shown"
    words = ", translated from compass points to up/down/left/right" if uses_compass(cfg) else ""
    return f"A sequence hack is live. Call pragmata_hack_sequence with the directions {how}{words}."


def description(cfg: dict) -> str:
    head = ("Solve the active sequence hack. A ring of direction prompts is on screen "
            "and they have to be entered in order.\n")
    form = letter_form(cfg)
    if form:
        per = {
            "both": "its `distance` from 0, counted along its arm (1 is next to 0), and its "
                    "`direction`. List them in any order -- the mod sorts them and presses "
                    "the farthest first",
            "side": "its `direction`, the arm it is on. List them in any order -- the mod "
                    "knows each distance and presses the farthest first",
            "dist": "its `distance` from 0, counted along its arm (1 is next to 0). List them "
                    "in any order -- the mod knows each direction and presses the farthest first",
        }[form]
        middle = ("The state field draws the puzzle in characters around a 0 and says how "
                  "to read it: each letter is a button, pointing the way its arm runs from 0. "
                  "Give one `buttons` entry per letter: its `button` letter and " + per
                  + ". Give every letter")
    elif is_cross(cfg):
        middle = ("The state field draws the puzzle in characters around a 0 and "
                  "says how to read it: each \"+\" is a button pointing the way its arm runs "
                  "from 0, pressed farthest from 0 first. Decode it and give the order in "
                  "`order`, from the FIRST press to the last")
    elif uses_shuffle(cfg):
        middle = ("Read the directions out of the state field; they are numbered by press but "
                  "shown out of order, so sort them by number and give them in `order`, from "
                  "press 1 to the last")
    else:
        middle = ("Read the order out of the state field and repeat it in `order`, from the "
                  "FIRST prompt to the last")
    if uses_compass(cfg):
        middle += (", translating compass points to directions (north = up, south = down, "
                   "west = left, east = right)")
    tail = (" -- including any steps the state says are "
            "already done, because the plan is checked against the full sequence. It "
            "must have exactly as many entries as the state says; a short or long "
            "answer is refused without pressing anything, since a wrong-length "
            "sequence fails the hack outright.\n"
            "Some of these have a timing dial. You do NOT have to time anything and "
            "there is no rush on your reply: give the order, and each press is fired "
            "on a frame the game will accept.")
    return head + middle + tail


def schema(cfg: dict) -> dict:
    form = letter_form(cfg)
    if form:
        # Key order is what the peer generates in: the letter first, so every
        # entry is anchored to a button before anything is read off it.
        props: dict = {"button": {"type": "string", "description": "the button's letter"}}
        if form in ("both", "dist"):
            props["distance"] = {"type": "integer", "minimum": 1, "maximum": 16,
                                 "description": "how far the button is from 0, counted along "
                                                "its arm; 1 is next to 0"}
        if form in ("both", "side"):
            props["direction"] = {"type": "string", "enum": list(DIRECTIONS),
                                  "description": "the arm the button is on"}
        items = {"type": "object", "required": list(props), "properties": props}
        desc = "one entry per letter in the drawing, in any order"
    else:
        items = {"enum": list(DIRECTIONS)}
        if is_cross(cfg):
            desc = "every direction decoded from the drawing, farthest button first"
        elif uses_shuffle(cfg):
            desc = "every direction, sorted by its number, press 1 first"
        else:
            desc = "every direction, in the order shown on screen"
    field = answer_field(cfg)
    return {
        "type": "object",
        "required": [field],
        "properties": {
            field: {
                "type": "array",
                "minItems": 1,
                "maxItems": 16,
                "items": items,
                "description": desc,
            },
        },
    }


def action_def(cfg: dict) -> dict:
    return {"name": ACTION_NAME, "description": description(cfg), "schema": schema(cfg)}
