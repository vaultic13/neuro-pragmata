"""Offline checks for seqbench. No API, no game.

    py -3 selftest.py            everything, including a loopback run (~20 s)
    py -3 selftest.py --no-e2e   the pure checks only
"""
from __future__ import annotations

import json
import queue
import random
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import puzzles  # noqa: E402
import scoring  # noqa: E402
import sequence_texts as texts  # noqa: E402
import variants  # noqa: E402
from mod_mimic import ModMimic, RunPlan  # noqa: E402
from stub_peer import StubThread, decode_buttons, decode_state  # noqa: E402

_failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok or not detail else f"\n        {detail}"))
    if not ok:
        _failures.append(name)


def cfg_of(**kw) -> dict:
    return variants.make_version(kw).cfg


def sp(line: str) -> str:
    """A drawing line written compactly here, spaced the way the bench draws it:
    `up    0-+-` -> `up    0 - + -`, `***-***` -> `* * * - * * *`."""
    cut = line.find("0") if line[:1].isalpha() else 0
    return line[:cut] + " ".join(line[cut:])


def test_renders() -> None:
    print("renders")
    rest = "****-****"
    expected_1 = [sp(x) for x in ["****+****", rest, rest, rest, "---+0--+-", rest, "****+****", rest, rest]]
    check("cross: up right down left", texts.button_cross(["up", "right", "down", "left"]) == expected_1,
          str(texts.button_cross(["up", "right", "down", "left"])))
    expected_2 = [sp(x) for x in [rest] * 4 + ["+--+0-++-"] + [rest] * 4]
    check("cross: left right right left", texts.button_cross(["left", "right", "right", "left"]) == expected_2)
    check("cross: characters are space separated", texts.button_cross(["up"]) == ["* + *", "- 0 -", "* - *"],
          str(texts.button_cross(["up"])))
    check("cross: 3 presses draw 7x7", len(texts.button_cross(["up", "up", "up"])) == 7)
    arms_cases = {
        ("up", "right", "down", "left"): ["up    0---+", "down  0-+--", "left  0+---", "right 0--+-"],
        ("left", "right", "right", "left"): ["up    0----", "down  0----", "left  0+--+", "right 0-++-"],
        ("up", "left", "down"): ["up    0--+", "down  0+--", "left  0-+-", "right 0---"],
    }
    for seq, want in arms_cases.items():
        check(f"arms: {' '.join(seq)}", texts.button_arms(seq) == [sp(x) for x in want], str(texts.button_arms(seq)))
    check("arms: characters are space separated", texts.button_arms(["up"])[0] == "up    0 +",
          str(texts.button_arms(["up"])))
    ruler = texts.button_cross(["right", "up", "right"], True)
    check("cross ruler header and prefix", ruler[0] == "  3 2 1 0 1 2 3" and ruler[1] == "3 * * * - * * *",
          str(ruler[:2]))
    arms_ruler = texts.button_arms(["right", "up", "right"], True)
    check("arms ruler sits over the slots",
          arms_ruler == ["        1 2 3", "up    0 - + -", "down  0 - - -", "left  0 - - -", "right 0 + - +"],
          str(arms_ruler))

    seq, perm = ["up", "left", "down"], (1, 2, 0)
    marks = texts.marks_for(seq, perm)
    check("letters follow perm, not press order", marks == ["b", "c", "a"], str(marks))
    got = texts.button_cross(seq, marks=marks)
    check("letter cross", got == [sp(x) for x in
                                  ["***b***", "***-***", "***-***", "-c-0---", "***a***", "***-***", "***-***"]],
          str(got))
    got = texts.button_arms(seq, marks=marks)
    check("letter arms", got == [sp(x) for x in ["up    0--b", "down  0a--", "left  0-c-", "right 0---"]], str(got))

    hinted = texts.state_text(cfg_of(arms=True, hints=True), ["up", "right", "down", "left"])
    check("hints on arms: ruler + puzzle", "This puzzle (4 presses):\n        1 2 3 4\nup    0 - - - +" in hinted,
          hinted)
    check("hints on arms: worked example",
          "Worked example -- NOT this puzzle:\n        1 2 3\nup    0 - + -" in hinted)

    compass = texts.state_text(cfg_of(render="list", compass=True), ["up", "left", "left"])
    check("compass list", "On screen, in order: 1.north  2.west  3.west" in compass
          and "north = up" in compass, compass)
    shuffled = texts.state_text(cfg_of(render="list", shuffle=True), ["up", "left", "left"], perm=(2, 0, 1))
    check("shuffled list", "shown out of order: 2.left  3.left  1.up" in shuffled, shuffled)


def test_mod_port_unchanged() -> None:
    print("mod port (the + versions still read as the mod does)")
    hints = texts.state_text(cfg_of(hints=True), ["up", "left", "down"])
    check("2-D hints step 1", "1. 0 is the centre. \"+\" is a button, \"-\" is an empty "
                              "button slot, \"*\" is filler." in hints)
    check("2-D hints step 5", "Each distance holds exactly one button, and an arm can hold more than one." in hints)
    check("2-D hints example", "Largest distance first, so the example's order is right, up, right." in hints)
    plain = texts.state_text(cfg_of(), ["up", "left", "down"])
    check("cross header", plain.startswith("Sequence hack: 3 directions must be entered in order. "
                                           "The puzzle, drawn as a cross:"))
    arms = texts.state_text(cfg_of(arms=True), ["up", "left", "down"])
    check("arms header", arms.startswith("Sequence hack: 3 directions must be entered in order. "
                                         "The puzzle, one line per arm:"))
    check("list line", "On screen, in order: 1.up  2.left  3.down" in texts.state_text(cfg_of(render="list"),
                                                                                        ["up", "left", "down"]))


def test_round_trip() -> None:
    print("round trip: every version decodes back to its sequence")
    rng = random.Random(3)
    versions = variants.expand(variants.all_picks()).versions
    bad = []
    for v in versions:
        for k in range(60):
            n = rng.choice((1, 2, 3, 4, 5))
            seq = list(puzzles.random_sequence(rng, n))
            perm = puzzles.make_perm(f"rt:{v.id}:{k}", n)
            state = texts.state_text(v.cfg, seq, perm=perm)
            got = decode_state(state)
            if got != seq:
                bad.append(f"{v.id}: {seq} -> {got}")
                break
            if texts.letter_form(v.cfg):
                marks = {b[2]: (b[0], b[1]) for b in decode_buttons(state)}
                if marks != texts.truth_by_letter(seq, perm):
                    bad.append(f"{v.id}: letters {marks}")
                    break
    check(f"{len(versions)} versions x 60 sequences", not bad, "; ".join(bad[:3]))


def test_texts() -> None:
    print("texts and schemas")
    want_keys = {"both": ["button", "distance", "direction"], "side": ["button", "direction"],
                 "dist": ["button", "distance"]}
    for v in variants.expand(variants.all_picks()).versions:
        d = texts.action_def(v.cfg)
        json.dumps(d)
        form = texts.letter_form(v.cfg)
        props = d["schema"]["properties"]
        if form:
            items = props.get("buttons", {}).get("items", {})
            ok = list(props) == ["buttons"] and list(items.get("properties", {})) == want_keys[form] \
                and items.get("required") == want_keys[form]
            state = texts.state_text(v.cfg, ["up", "left", "down"], perm=(1, 2, 0))
            ok = ok and '"+"' not in state and "`buttons`" in state
        else:
            ok = list(props) == ["order"] and props["order"]["items"] == {"enum": ["up", "down", "left", "right"]}
        if not ok:
            check(f"schema / wording for {v.id}", False, json.dumps(d["schema"]))
            return
    check("answer field, item keys and wording match the form in every version", True)
    check("full query (cross) is the mod's",
          texts.force_query(cfg_of()).startswith("A sequence hack is live. Read the directions off the drawing"))
    check("letters query names the form",
          texts.force_query(cfg_of(letters="dist")).endswith("with its distance for every letter."))
    check("list twists query", texts.force_query(cfg_of(render="list", compass=True, shuffle=True))
          == "A sequence hack is live. Call pragmata_hack_sequence with the directions sorted by their "
             "numbers, translated from compass points to up/down/left/right.")


def test_judge() -> None:
    print("judging")
    cross = cfg_of()
    listed = cfg_of(render="list")
    seq = ["up", "down", "left"]
    perm = (1, 2, 0)  # b = up at 3, c = down at 2, a = left at 1
    j = lambda cfg, args, name=texts.ACTION_NAME: scoring.judge(cfg, seq, name, json.dumps(args), perm=perm)
    check("correct", j(cross, {"order": seq}).outcome == "solved")
    check("wrong press (cross: presses only)",
          j(cross, {"order": ["up", "left", "left"]}).message
          == "The game rejected the sequence after press 2 of 3. Pressed so far: up left.")
    check("wrong press (list: with asked)",
          j(listed, {"order": ["up", "left", "left"]}).message
          == "The game rejected the sequence after press 2 of 3. Pressed so far: up(asked up) left(asked down).")
    check("wrong press (compass: asked in compass)",
          j(cfg_of(render="list", compass=True), {"order": ["up", "left", "left"]}).message
          == "The game rejected the sequence after press 2 of 3. Pressed so far: up(asked north) left(asked south).")
    check("shuffled list solved on the true order",
          j(cfg_of(render="list", shuffle=True), {"order": seq}).outcome == "solved")
    check("wrong length", j(cross, {"order": ["up"]}).message
          == "The sequence needs exactly 3 presses but the plan had 1; nothing was pressed.")
    check("wrong action", j(cross, {"order": seq}, "pragmata_hack_plan").outcome == "wrong_action")
    check("bad JSON", scoring.judge(cross, seq, texts.ACTION_NAME, "{nope").outcome == "bad_args")

    both, side, dist = cfg_of(letters="both"), cfg_of(letters="side"), cfg_of(letters="dist")
    b = lambda *rows, keys=("button", "distance", "direction"): {"buttons": [dict(zip(keys, r)) for r in rows]}
    check("letters both: solved", j(both, b(("a", 1, "left"), ("b", 3, "up"), ("c", 2, "down"))).outcome == "solved")
    check("letters side: solved", j(side, b(("c", "down"), ("a", "left"), ("b", "up"),
                                            keys=("button", "direction"))).outcome == "solved")
    check("letters dist: solved", j(dist, b(("a", 1), ("b", 3), ("c", 2), keys=("button", "distance"))).outcome
          == "solved")
    got = j(side, b(("a", "left"), ("b", "up"), ("c", "left"), keys=("button", "direction"))).message
    check("letters side: wrong direction rejected at its press",
          got == "The game rejected the sequence after press 2 of 3. Pressed so far: up left.", got)
    got = j(dist, b(("a", 2), ("b", 3), ("c", 1), keys=("button", "distance"))).message
    check("letters dist: swapped distances rejected",
          got == "The game rejected the sequence after press 2 of 3. Pressed so far: up left.", got)
    check("letters: answer in `order` is empty", j(both, {"order": seq}).message == "plan discarded (no presses given)")
    cases = [
        (both, b(("x", 1, "left"), ("b", 3, "up"), ("c", 2, "down")), "Nothing was pressed: unknown button 'x'."),
        (both, b(("a", 1, "left"), ("a", 3, "up"), ("c", 2, "down")), "Nothing was pressed: button a was given twice."),
        (both, b(("a", 1, "left"), ("b", 3, "up")),
         "Nothing was pressed: button c is missing; give every letter in the drawing once."),
        (both, b(("a", 1, "left"), ("b", 3, "up"), ("c", 3, "down")),
         "Nothing was pressed: two buttons were given distance 3; every button is a different distance from 0."),
        (both, b(("a", 1, "left"), ("b", 4, "up"), ("c", 2, "down")),
         "Nothing was pressed: no button was given distance 3; 3 buttons sit at distances 1 to 3."),
        (side, b(("a", "west"), ("b", "up"), ("c", "down"), keys=("button", "direction")),
         "Nothing was pressed: unknown direction 'west'."),
        (dist, b(("a", 0), ("b", 3), ("c", 2), keys=("button", "distance")),
         "Nothing was pressed: distance must be a whole number from 1 up (got 0)."),
        (side, {"buttons": ["up", "down", "left"]},
         "Nothing was pressed: each entry needs a button and a direction (got up)."),
    ]
    for cfg, args, want in cases:
        got = j(cfg, args).message
        check(f"refusal: {want[21:60]}...", got == want, got)

    # What the trial table and detail pane show: the answer, never raw JSON.
    refused = json.dumps(b(("a", 1, "left"), ("b", 3, "up"), ("c", 3, "down")))
    shown = [
        (scoring.reply_text(cross, json.dumps({"order": seq})), "up down left"),
        (scoring.reply_text(both, refused), "a left 1, b up 3, c down 3"),
        (scoring.reply_text(side, json.dumps(b(("a", "left"), keys=("button", "direction")))), "a left"),
        (scoring.reply_text(cross, "{nope"), "(not JSON) {nope"),
        (scoring.reply_text(both, json.dumps({"order": seq})), '(no buttons array) {"order": ["up", "down", "left"]}'),
        (scoring.reply_text(cross, None), "-"),
        (scoring.truth_text(both, seq, perm), "a left 1, b up 3, c down 2"),
        (scoring.truth_text(side, seq, perm), "a left, b up, c down"),
        (scoring.truth_text(dist, seq, perm), "a 1, b 3, c 2"),
        (scoring.truth_text(listed, seq, perm), "up down left"),
        ("; ".join(scoring.letter_misreads(both, seq, refused, perm)), "c distance 3, is 2"),
        ("; ".join(scoring.letter_misreads(side, seq, json.dumps(b(("a", "up"), keys=("button", "direction"))),
                                           perm)), "a direction up, is left"),
    ]
    for got, want in shown:
        check(f"shown: {want[:40]}", got == want, got)


def test_rating() -> None:
    print("ratings")
    table = [(True, 1.59, "very good"), (True, 1.6, "good"), (True, 2.19, "good"),
             (True, 2.2, "risky"), (True, 2.99, "risky"), (True, 3.0, "timeout"),
             (False, 0.5, "fail"), (False, 4.0, "fail"), (True, None, "timeout"), (False, None, "timeout")]
    for correct, t, want in table:
        check(f"{correct} {t} -> {want}", scoring.rate(correct, t) == want)


def test_expand() -> None:
    print("version expansion")
    e = variants.expand(variants.all_picks())
    ids = [v.id for v in e.versions]
    check("128 combinations -> 20 versions", e.combinations == 128 and len(ids) == 20, f"{e.combinations} -> {len(ids)}")
    check("no duplicate versions", len(set(ids)) == len(ids))
    check("nothing dropped", not e.dropped, str(e.dropped))
    ids_of = lambda picks: [v.id for v in variants.expand(picks).versions]
    check("empty picks -> the default", ids_of({}) == ["cross"], str(ids_of({})))
    got = variants.expand({"render": ("list",), "letters": ("side",)})
    check("list + letters -> list (merged)", [v.id for v in got.versions] == ["list"] and got.merged)
    check("hints now applies to arms", ids_of({"arms": (True,), "hints": (False, True)})
          == ["cross+arms", "cross+arms+hints"], str(ids_of({"arms": (True,), "hints": (False, True)})))
    check("letter forms subset", ids_of({"letters": ("side", "dist")}) == ["cross+letters-side", "cross+letters-dist"])
    check("False is not taken for None", ids_of({"letters": (False,)}) == ["cross"])


def test_groups() -> None:
    print("groups (what the mod ships)")
    ids = [g.id for g in variants.GROUPS]
    check("five groups, numbered 1-5", [g.number for g in variants.GROUPS] == [1, 2, 3, 4, 5])
    check("group ids", ids == ["cross+arms+hints+letters-both", "cross+hints+letters-side",
                               "list+compass+shuffle", "list+compass", "list"], str(ids))
    check("each id is its normalised version id",
          all(g.id == variants.version_id(variants.normalize(g.version.cfg)[0]) for g in variants.GROUPS))
    check("mod setting", variants.mod_setting(variants.GROUPS[2]) == "puzzle_sequence_group = 3")
    check("group lookup", variants.group_number("list+compass") == 4 and variants.group_number("cross") is None)


def test_puzzles() -> None:
    print("puzzle sets")
    for size, (three, four) in puzzles.SET_MIX.items():
        s = puzzles.build_set(size, 1)
        check(f"set {size}: {three}x3 + {four}x4",
              [p.presses for p in s].count(3) == three and [p.presses for p in s].count(4) == four)
    check("same seed, same set", puzzles.build_set(7, 5) == puzzles.build_set(7, 5))
    check("next repeat differs", puzzles.build_set(7, 5, 0) != puzzles.build_set(7, 5, 1))
    perms_ok = all(len(p.perm) == p.presses and sorted(p.perm) == list(range(p.presses))
                   and list(p.perm) != list(range(p.presses))
                   for seed in range(1, 30) for p in puzzles.build_set(9, seed) + [puzzles.warmup_puzzle(seed)])
    check("perm is a non-identity shuffle for every puzzle", perms_ok)


# ---------------------------------------------------------------------------
# Loopback: ModMimic against the stub peer
# ---------------------------------------------------------------------------

def _bench(port: int, versions, cap_s: float = 15.0, warmup: bool = False, timeout: float = 60.0):
    events: queue.Queue = queue.Queue()
    mimic = ModMimic(events)
    mimic.connect(f"ws://127.0.0.1:{port}")
    deadline = time.time() + 5
    while not mimic.connected and time.time() < deadline:
        time.sleep(0.02)
    trials, logs, finished = [], [], None
    with tempfile.TemporaryDirectory() as tmp:
        plan = RunPlan(versions=versions, set_size=5, seed=7, warmup=warmup, cap_s=cap_s,
                       gap_s=0.02, settle_s=0.02, out_root=Path(tmp))
        mimic.start_run(plan)
        deadline = time.time() + timeout
        while finished is None and time.time() < deadline:
            try:
                ev = events.get(timeout=0.2)
            except queue.Empty:
                continue
            if ev.kind == "trial":
                trials.append(ev.data)
            elif ev.kind == "run_finished":
                finished = ev.data
                out = Path(ev.data["out_dir"])
                finished["files"] = sorted(p.name for p in out.iterdir())
            elif ev.kind in ("log", "error"):
                logs.append(ev.text)
        mimic.disconnect()
        time.sleep(0.2)
    return trials, logs, finished


def test_e2e() -> None:
    print("loopback run against the stub peer")
    stub = StubThread("correct").start()
    try:
        vs = [variants.make_version(c) for c in (
            {}, {"arms": True, "hints": True}, {"letters": "both"}, {"letters": "side", "arms": True},
            {"letters": "dist", "hints": True}, {"render": "list", "compass": True, "shuffle": True})]
        trials, logs, fin = _bench(stub.port, vs, warmup=True)
        scored = [t for t in trials if not t["warmup"]]
        check("correct: 6 versions x 5 + 6 warm-ups", len(trials) == 36 and len(scored) == 30, f"{len(trials)}")
        check("correct: all very good", all(t["rating"] == "very good" for t in scored),
              str({(t["version"], t["outcome"], t["message"]) for t in scored if t["rating"] != "very good"}))
        check("run files written", fin and fin["files"] == ["run.json", "summary.csv", "trials.jsonl", "versions.json"],
              str(fin))
        check("letters recorded", all(t["letters"] for t in trials if "letters-" in t["version"]))
        rows = scoring.summarize(trials)
        check("summary skips warm-ups", sum(r["trials"] for r in rows) == 30)
        check("summary group column", [r["group"] for r in rows] == [None, None, None, None, None, 3],
              str([r["group"] for r in rows]))

        trials, _, _ = _bench(stub.port, [g.version for g in variants.GROUPS])
        check("groups: all five solved", len(trials) == 25 and all(t["correct"] for t in trials),
              str({(t["version"], t["outcome"]) for t in trials if not t["correct"]}))

        stub.peer.mode = "wrong"
        trials, _, _ = _bench(stub.port, vs)
        check("wrong: nothing solved", not any(t["correct"] for t in trials))
        pressed_wrong = [t for t in trials if "letters-dist" not in t["version"]]
        check("wrong: rejected at press 1 where a direction is given",
              all(t["outcome"] == "wrong" and "after press 1 of" in t["message"] for t in pressed_wrong),
              str([t["message"] for t in pressed_wrong if "after press 1 of" not in t["message"]][:2]))

        stub.peer.mode = "slow:1.7"
        trials, _, _ = _bench(stub.port, vs[:1])
        check("slow 1.7 s: all good", all(t["rating"] == "good" for t in trials),
              str([(t["elapsed_ms"], t["rating"]) for t in trials]))

        # Lands after the 0.3 s cap and inside the one-cap drain that follows.
        stub.peer.mode = "slow:0.45"
        trials, logs, _ = _bench(stub.port, vs[:1], cap_s=0.3)
        check("cap: rated timeout, not fail", all(t["rating"] == "timeout" for t in trials),
              str([t["rating"] for t in trials]))
        check("cap: all no reply", all(t["outcome"] == "no_reply" for t in trials),
              str([t["outcome"] for t in trials]))
        check("cap: late replies told stale, not reused",
              sum("stale reply" in l for l in logs) == 5 and all(t["late_reply_ms"] for t in trials),
              str(logs[-3:]))
        stale = [r for r in stub.peer.results if r["message"].startswith("stale")]
        check("cap: peer received 5 stale results", len(stale) == 5, str(len(stale)))
    finally:
        stub.stop()


def main() -> int:
    test_renders()
    test_mod_port_unchanged()
    test_round_trip()
    test_texts()
    test_judge()
    test_rating()
    test_expand()
    test_groups()
    test_puzzles()
    if "--no-e2e" not in sys.argv:
        test_e2e()
    print()
    if _failures:
        print(f"{len(_failures)} FAILED: " + ", ".join(_failures))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
