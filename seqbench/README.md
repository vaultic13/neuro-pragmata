# seqbench — sequence hack prompt bench

A Tk tool that measures how well an AI peer reads the sequence hack
(`pragmata_hack_sequence`) under different prompt versions — the mod's own
switches and new candidates — in batches, without the game.

```
py -3 seqbench_gui.py --url ws://127.0.0.1:8123
```

Use `py -3` (3.12, which has `websockets` and `tkinter` on this machine), as for
apitest.

## Where it sits

The bench plays the mod and sidecar, so it is the WebSocket **client** and the
peer listens:

```
seqbench_gui.py  --WS-->  apitest_gui.py (port 8123, Auto-answer on)  -->  OpenAI
                 <--WS--
```

Start apitest with the model settings under test, e.g.
`py -3 apitest_gui.py --port 8123 --thinking none --speed fast`, tick
**Auto-answer forced actions**, then Connect and Run here. Any other Neuro-SDK
peer works the same way.

It is **independent of the mod**: nothing is read from or imported out of
`autorun/`. `sequence_texts.py` holds a Python copy of the mod's sequence
wording (state render, description, schema, query), and `scoring.py` copies
its result messages. Since 2026-09-16 the mod's five groups are ports of this
file, spaced drawings and letters included. Changing one side does not change
the other, so port a change on purpose.

## What a run does

For each version:

1. `actions/unregister` the previous registration, `actions/register` this
   version's `pragmata_hack_sequence` — plus fixed copies of
   `pragmata_hack_plan` / `pragmata_hack_rotate` when **Register plan + rotate
   copies** is on, so apitest's catalogue (prompt size, cache prefix) matches
   the game.
2. An unscored **warm-up** force, if on. apitest's first call of a session
   measured 5.74 s against 1.1–2.2 s later, and a new registration is a new
   cache prefix, so the first force of every version is paid here.
3. One `actions/force` per puzzle — `state`, `query`, `ephemeral_context`,
   `action_names`, `priority: "low"`, exactly as the mod sends them — then wait
   for the `action`, judge it, and send back the mod's `action/result`.

Each repeat re-rolls the set (seed + repeat) and rotates the version order, so
a slow patch on the API side does not always land on the same version.

## Puzzle sets

| Set | 3-press (7x7) | 4-press (9x9) |
|---|---|---|
| 5 | 3 | 2 |
| 7 | 4 | 3 |
| 9 | 5 | 4 |

Directions are random and may repeat on an arm. The set depends only on the
seed and repeat, so every version is scored on the same puzzles.

Each puzzle also has a seeded shuffle, `perm`, never in press order. It picks
the letters of the letter buttons and the display order of the shuffled list.
It has its own rng, so the directions match the round-1 runs for the same seed.

## Groups

Testing settled on five versions, and the mod ships exactly these as the
**groups** of `mod_config.puzzle_sequence_group`. The GUI offers one checkbox
per group, all ticked at start, and each row shows the mod setting that selects
it. The number is the same in the bench and the mod; the id is the bench's
version id, so results line up with the runs that picked them.

| # | Version id | Shown as | Answer | Mod setting |
|---|---|---|---|---|
| 1 | `cross+arms+hints+letters-both` | arm lines, ruler, steps, example; letter buttons | `buttons`: letter, distance, direction | `puzzle_sequence_group = 1` (default) |
| 2 | `cross+hints+letters-side` | 2-D cross, ruler, steps, example; letter buttons | `buttons`: letter, direction | `puzzle_sequence_group = 2` |
| 3 | `list+compass+shuffle` | compass words, numbered entries out of order | `order` | `puzzle_sequence_group = 3` |
| 4 | `list+compass` | compass words | `order` | `puzzle_sequence_group = 4` |
| 5 | `list` | the original list | `order` | `puzzle_sequence_group = 5` |

In game the group can also be switched for the session, without saving, under
REFramework menu → Pragmata Puzzle Debug → **Sequence hack group**.

The mod's texts for these five are ports of `sequence_texts.py`, checked byte
for byte against it. If either side changes, port the change to the other.

### Options behind the groups

A version is a combination of options:

| Option | Values | What it changes |
|---|---|---|
| Render | cross / list | the drawing, or the `On screen, in order: 1.up 2.left` line |
| Arm lines | off / on | one line per arm instead of the 2-D cross |
| Hints | off / on | distance ruler, numbered reading steps, worked example |
| Letter buttons | + / side+dist / side / dist | buttons drawn as letters; answer per letter |
| Compass words | off / on | list: north/south/west/east, answered as up/down/left/right |
| Shuffled list | off / on | list: numbered entries shown out of order |

`list` makes arms, hints and letters no-ops; `cross` makes compass and shuffle
no-ops. Version ids read like `cross+arms+hints+letters-both`.

### Letter buttons

The "+" becomes a letter (a, b, c, d). Letters follow `perm`, so `a` is not
the first press. The answer is `buttons`, one entry per letter, `button` first:

| Form | Entry | The bench presses |
|---|---|---|
| `side+dist` | `{button, distance, direction}` | the given directions, sorted by the given distances |
| `side` | `{button, direction}` | the given directions, sorted by each letter's **real** distance |
| `dist` | `{button, distance}` | each letter's **real** direction, sorted by the given distances |

A missing, repeated or unknown letter, or a repeated or skipped distance, is
refused: "Nothing was pressed: …".

### Adding an option or a group

1. Append an `Option` to `variants.OPTIONS` (any number of values), with
   `relevant(cfg)` saying when it can matter.
2. Make `sequence_texts.py` honour it (state, description, schema, query).
3. Add a `CONFLICTS` entry if it contradicts another option.
4. To offer it in the GUI, add a `Group` to `variants.GROUPS`. `expand()`
   still forms every combination from option picks, for scripts and the
   selftest.
5. `py -3 selftest.py`. The round-trip check decodes every version, and
   `stub_peer.py` must learn to read any new render.

## Scoring

Time is measured from the moment the force is sent to the moment the `action`
frame arrives (`time.perf_counter`), so it includes apitest's own overhead and
the network — it should sit a little above apitest's "answered in X s".

| Correct answer in | Rating |
|---|---|
| < 1.6 s | very good |
| < 2.2 s | good |
| < 3.0 s | risky |
| ≥ 3.0 s | timeout |

A wrong answer is a **fail** whatever the time; a right one that is too slow,
or no reply within the cap, is a **timeout**, so the two failures stay apart.
The Summary columns, also explained under the table in the GUI:

| Column | Meaning |
|---|---|
| Group | the mod group number (`puzzle_sequence_group`); empty for a version that is not a group |
| Version | the bench's version id |
| Trials | scored forces; warm-ups are not counted |
| Correct % | right answers at any speed |
| Pass % | right answers under 3 s, the share that works in game |
| Very good / Good / Risky | right answers under 1.6 s / 2.2 s / 3 s |
| Fail | a wrong answer, or one refused without pressing |
| Timeout | a right answer taking 3 s or more, or no reply |
| Median / Mean ms | force sent to reply received, over the replies that arrived |

The best row (pass %, then correct %, very good, median) is highlighted green.

Outcomes: `solved`, `wrong` (first wrong press), `wrong_length`, `refused`
(bad letter or distance, or no presses), `bad_args`, `wrong_action`,
`no_reply`. The message sent back is the mod's: "The hack is complete.", "The
game rejected the sequence after press k of N. Pressed so far: …" (list: with
`(asked X)` in the words shown, so compass stays compass), "Nothing was
pressed: …".

**Reply cap** (default 15 s) only bounds the wait. A reply that misses it is
still waited for, up to one more cap, before the next force, so it can never be
taken as the next puzzle's answer; when it arrives it is told it was stale.

## Output

Every run writes `results/<timestamp>/`:

| File | Contents |
|---|---|
| `run.json` | the run settings |
| `versions.json` | per version: cfg, query, description, schema — what was registered |
| `trials.jsonl` | one line per force: state, perm, letters, reply, verdict, time, rating |
| `summary.csv` | the summary table |

Select a trial in the GUI to see the full state, query, reply and result.

The **Answer** column and the detail pane show the reply as the peer meant it
(`up down left`, or `a left 1, b up 3` per letter), never the raw JSON, and
also for a refused reply, where nothing was pressed. The detail pane adds the
expected answer in the same shape and, for letters, each misread
(`c distance 3, is 2`); the raw arguments are below them.

## Testing the bench

```
py -3 selftest.py            # renders, round trips, judging, ratings, loopback run
py -3 stub_peer.py --port 8124 --mode correct|wrong|random|slow:2.5
```

`stub_peer.py` answers from the state text alone (it reads "+", letters,
compass words and shuffled numbers), in whatever answer shape the registered
schema asks for, so pointing the GUI at it checks the whole pipeline at no API
cost.

## Files

| File | Role |
|---|---|
| `seqbench_gui.py` | the Tk window |
| `mod_mimic.py` | WS client, Neuro-SDK framing, the run loop |
| `variants.py` | option registry, expansion, merging |
| `sequence_texts.py` | the mod's sequence wording (copied) + new candidates |
| `puzzles.py` | seeded puzzle sets |
| `scoring.py` | judging, ratings, summary |
| `other_actions.py` | fixed plan/rotate registrations |
| `stub_peer.py` | local test peer |
| `selftest.py` | offline checks |
