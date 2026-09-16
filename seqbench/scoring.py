"""Judging a reply: was it right, how fast, and what the mod would have said.

The verdict messages are the mod's own tool-result strings (as of 2026-09-15,
bindings/puzzle_buttons.lua and hacking_observer.lua), so the peer reads the
same feedback it would read in game.

Speed ratings, for a correct answer (a wrong one is a fail at any speed):
    < 1.6 s  very good
    < 2.2 s  good
    < 3.0 s  risky
    else     timeout  (also: no reply at all)
"""
from __future__ import annotations

import csv
import json
import statistics
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import sequence_texts as texts
import variants

VERY_GOOD_S = 1.6
GOOD_S = 2.2
RISKY_S = 3.0

RATINGS = ("very good", "good", "risky", "fail", "timeout")


def rate(correct: bool, elapsed_s: Optional[float]) -> str:
    # Too slow is its own rating, so a slow peer is not read as a wrong one.
    if elapsed_s is None:
        return "timeout"
    if not correct:
        return "fail"
    if elapsed_s < VERY_GOOD_S:
        return "very good"
    if elapsed_s < GOOD_S:
        return "good"
    if elapsed_s < RISKY_S:
        return "risky"
    return "timeout"


@dataclass
class Verdict:
    outcome: str        # solved | wrong | wrong_length | refused | bad_args | wrong_action | no_reply
    correct: bool
    message: str        # the action/result message sent back to the peer
    pressed: Optional[list[str]] = field(default=None)


def _lua_tostring(value: Any) -> str:
    # How the mod's tostring() would print a decoded JSON value in a reason.
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (dict, list)):
        return "table"
    return str(value)


def _lua_tonumber(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def order_from_distances(order: list) -> tuple[Optional[list[str]], str]:
    """Port of puzzle_buttons.lua order_from_distances: the distances must run
    1..N with none repeated; the result is sorted farthest first."""
    by_distance: dict[int, str] = {}
    for entry in order:
        if not isinstance(entry, dict):
            return None, ("each entry needs a distance and a direction (got "
                          + _lua_tostring(entry) + ")")
        dist, direction = _lua_tonumber(entry.get("distance")), entry.get("direction")
        if direction not in texts.DIRECTIONS:
            return None, "unknown direction '" + _lua_tostring(direction) + "'"
        if dist is None or not dist.is_integer() or dist < 1:
            return None, ("distance must be a whole number from 1 up (got "
                          + _lua_tostring(entry.get("distance")) + ")")
        d = int(dist)
        if d in by_distance:
            return None, (f"two buttons were given distance {d}; every "
                          "button is a different distance from 0")
        by_distance[d] = direction
    n = len(by_distance)
    for d in range(1, n + 1):
        if d not in by_distance:
            return None, f"no button was given distance {d}; {n} buttons sit at distances 1 to {n}"
    return [by_distance[d] for d in range(n, 0, -1)], ""


_LETTER_NEEDS = {"both": ", a distance and a direction", "side": " and a direction",
                 "dist": " and a distance"}


def order_from_letters(form: str, entries: list, sequence, perm) -> tuple[Optional[list[str]], str]:
    """The letter-button answers (bench candidates, no mod original). Every
    letter exactly once; then the half the peer did not give comes from the
    drawing itself, and the presses are sorted farthest first."""
    truth = texts.truth_by_letter(sequence, perm)
    given: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            return None, (f"each entry needs a button{_LETTER_NEEDS[form]} (got "
                          + _lua_tostring(entry) + ")")
        raw = entry.get("button")
        letter = raw.strip().lower() if isinstance(raw, str) else raw
        if letter not in truth:
            return None, "unknown button '" + _lua_tostring(raw) + "'"
        if letter in given:
            return None, f"button {letter} was given twice"
        given[letter] = entry
    for letter in sorted(truth):
        if letter not in given:
            return None, f"button {letter} is missing; give every letter in the drawing once"
    if form == "side":
        for letter, entry in given.items():
            if entry.get("direction") not in texts.DIRECTIONS:
                return None, "unknown direction '" + _lua_tostring(entry.get("direction")) + "'"
        ranked = sorted(given, key=lambda m: -truth[m][0])
        return [given[m]["direction"] for m in ranked], ""
    if form == "dist":
        pairs = [{"distance": e.get("distance"), "direction": truth[m][1]} for m, e in given.items()]
    else:
        pairs = [{"distance": e.get("distance"), "direction": e.get("direction")} for e in given.values()]
    return order_from_distances(pairs)


def judge(cfg: dict, sequence, action_name: Any, raw_args: Any, perm=None) -> Verdict:
    sequence = list(sequence)
    n = len(sequence)
    if action_name != texts.ACTION_NAME:
        return Verdict("wrong_action", False, f"unexpected action {action_name!r}")
    try:
        args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
    except json.JSONDecodeError:
        return Verdict("bad_args", False, "action arguments were not valid JSON")
    if not isinstance(args, dict):
        return Verdict("bad_args", False, "action arguments were not a JSON object")

    order = args.get(texts.answer_field(cfg))
    # The mod walks the payload with ipairs, which yields nothing for an object
    # or a scalar -- so anything but an array is an empty answer.
    if not isinstance(order, list):
        order = []

    form = texts.letter_form(cfg)
    if form and order:
        steps, why = order_from_letters(form, order, sequence, perm)
        if steps is None:
            return Verdict("refused", False, f"Nothing was pressed: {why}.")
    elif form:
        steps = []
    else:
        steps = [d for d in order if isinstance(d, str) and d in texts.DIRECTIONS]

    if not steps:
        return Verdict("refused", False, "plan discarded (no presses given)", pressed=steps)
    if len(steps) != n:
        return Verdict("wrong_length", False,
                       f"The sequence needs exactly {n} presses but the plan had "
                       f"{len(steps)}; nothing was pressed.", pressed=steps)
    for k, (got, want) in enumerate(zip(steps, sequence), start=1):
        if got != want:
            # run_summary: the cross render reports the presses only, since the
            # asked-for directions would hand back what the picture hides.
            if texts.is_cross(cfg):
                summary = " ".join(steps[:k])
            else:
                # In the words shown on screen, so compass stays compass.
                summary = " ".join(f"{steps[j]}(asked {texts.shown_word(cfg, sequence[j])})"
                                   for j in range(k))
            return Verdict("wrong", False,
                           f"The game rejected the sequence after press {k} of {n}. "
                           f"Pressed so far: {summary}.", pressed=steps)
    return Verdict("solved", True, "The hack is complete.", pressed=steps)


def _parsed_answer(cfg: dict, raw_args: Any) -> tuple[Optional[list], str]:
    """The answer array, or None and the raw text when there is none to show."""
    try:
        args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
    except json.JSONDecodeError:
        return None, "(not JSON) " + str(raw_args)
    answer = args.get(texts.answer_field(cfg)) if isinstance(args, dict) else None
    if not isinstance(answer, list):
        return None, "(no " + texts.answer_field(cfg) + " array) " + json.dumps(args)
    return answer, ""


def reply_text(cfg: dict, raw_args: Any) -> str:
    """The reply as the peer meant it, for the trial table: the directions of an
    `order`, or `letter direction distance` per letter entry -- never the raw
    JSON, which hides the answer behind its punctuation."""
    if raw_args is None:
        return "-"
    answer, fallback = _parsed_answer(cfg, raw_args)
    if answer is None:
        return fallback
    if not texts.letter_form(cfg):
        return " ".join(_lua_tostring(d) for d in answer)
    parts = []
    for e in answer:
        if isinstance(e, dict):
            bits = [e.get("button"), e.get("direction"), e.get("distance")]
            parts.append(" ".join(_lua_tostring(b) for b in bits if b is not None))
        else:
            parts.append(_lua_tostring(e))
    return ", ".join(parts)


def truth_text(cfg: dict, sequence, perm=None) -> str:
    """The right answer in the reply's own shape."""
    form = texts.letter_form(cfg)
    if not form:
        return " ".join(sequence)
    truth = texts.truth_by_letter(sequence, perm)
    return ", ".join(
        " ".join([m] + ([d] if form != "dist" else []) + ([str(k)] if form != "side" else []))
        for m, (k, d) in sorted(truth.items()))


def letter_misreads(cfg: dict, sequence, raw_args: Any, perm=None) -> list[str]:
    """Per-letter differences between a letter reply and the drawing, e.g.
    `c distance 1, is 2` -- which half of reading the drawing went wrong."""
    form = texts.letter_form(cfg)
    if not form or raw_args is None:
        return []
    answer, _ = _parsed_answer(cfg, raw_args)
    if answer is None:
        return []
    truth = texts.truth_by_letter(sequence, perm)
    out = []
    for e in answer:
        if not isinstance(e, dict):
            continue
        letter = e.get("button")
        letter = letter.strip().lower() if isinstance(letter, str) else letter
        if letter not in truth:
            continue
        k, d = truth[letter]
        if form != "dist" and e.get("direction") != d:
            out.append(f"{letter} direction {_lua_tostring(e.get('direction'))}, is {d}")
        dist = _lua_tonumber(e.get("distance"))
        if form != "side" and dist != k:
            out.append(f"{letter} distance {_lua_tostring(e.get('distance'))}, is {k}")
    return out


def no_reply(cap_s: float) -> Verdict:
    return Verdict("no_reply", False, f"no action within {cap_s:g} s")


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

SUMMARY_COLUMNS = ("group", "version", "trials", "correct", "correct_pct", "pass_pct",
                   "very good", "good", "risky", "fail", "timeout", "median_ms", "mean_ms", "outcomes")


def summarize(records: list[dict]) -> list[dict]:
    """One row per version, in first-seen order. Warm-ups are not scored."""
    rows: dict[str, dict] = {}
    times: dict[str, list[int]] = {}
    for rec in records:
        if rec.get("warmup"):
            continue
        vid = rec["version"]
        row = rows.get(vid)
        if row is None:
            row = {"group": variants.group_number(vid), "version": vid, "trials": 0, "correct": 0,
                   **{r: 0 for r in RATINGS}, "outcomes": {}}
            rows[vid] = row
            times[vid] = []
        row["trials"] += 1
        row["correct"] += 1 if rec["correct"] else 0
        row[rec["rating"]] += 1
        row["outcomes"][rec["outcome"]] = row["outcomes"].get(rec["outcome"], 0) + 1
        if rec.get("elapsed_ms") is not None:
            times[vid].append(rec["elapsed_ms"])
    out = []
    for vid, row in rows.items():
        t = times[vid]
        trials = row["trials"]
        row["correct_pct"] = round(100.0 * row["correct"] / trials, 1)
        row["pass_pct"] = round(100.0 * (trials - row["fail"] - row["timeout"]) / trials, 1)
        row["median_ms"] = int(statistics.median(t)) if t else None
        row["mean_ms"] = int(statistics.fmean(t)) if t else None
        out.append(row)
    return out


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
