# seqbench — hacking puzzle prompt bench

A Tk tool and a command-line runner that measure how well an AI peer handles
the mod's hacking puzzles, in batches, without the game. Two benches, picked
under **Bench** at the top (or as `sequence` / `grid` on the command line):

- **Sequence hack** (`pragmata_enviro_hack_sequence`): the prompt versions and the
  mod's five groups. Most of this README.
- **Enemy grid** (`pragmata_enemy_hack_plan`): the enemy hacking grid with today's
  modifiers (red blocks, corruption), big and non-square grids, mid-hack
  retries, the final boss's timed stages, and the cells the mod can draw but
  no game has shown yet (X traps, bomb / purge / chain nodes, directional
  gates). See
  [Enemy grid bench](#enemy-grid-bench).

```
py -3 seqbench_gui.py --url ws://127.0.0.1:8123 [--bench grid]
```

Use `py -3` (3.12, which has `websockets` and `tkinter` on this machine), as for
apitest.

### Command line

`run_eval.py` runs the same batch without the window: it prints one line per
scored trial or episode and the summary table, and writes the same
`results/<timestamp>[-grid]/` files.

```
py -3 run_eval.py --url ws://127.0.0.1:8123 grid --categories plain,blocks,finale --per 5
py -3 run_eval.py --url ws://127.0.0.1:8123 --repeats 3 sequence --groups 1,3 --set-size 7
py -3 run_eval.py --url ws://127.0.0.1:8124 grid --per 2 --no-warmup --min-solved 100
```

| Option | Meaning |
|---|---|
| `--url` | the peer (apitest listens on 8123) |
| `--seed`, `--repeats`, `--cap`, `--gap` | as in the GUI; `--cap` defaults to 15 s (sequence) / 30 s (grid) |
| `--no-warmup`, `--plan-only` | skip the warm-up; register only the forced action |
| `--out-root DIR` | where the run folder goes (default `results/`) |
| `--quiet` | the summary only |
| `grid --categories --per --source --versions` | the puzzle set and the wording versions |
| `grid --max-forces --finale-budget --no-refuse-red` | as the GUI's grid settings |
| `grid --min-solved P` / `sequence --min-pass P` | exit 2 if any summary row is below P % |
| `sequence --groups 1,2,... --set-size 5/7/9` | the mod groups to run |

Exit status: 0 finished, 1 stopped / aborted / no connection, 2 a threshold
missed.

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
   version's `pragmata_enviro_hack_sequence` — plus fixed copies of
   `pragmata_enemy_hack_plan` / `pragmata_enviro_hack_rotate` when **Register plan + rotate
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

## Enemy grid bench

Tests the enemy hacking grid the way the mod plays it, as of 2026-11-15.
Nothing is imported from `autorun/`: `grid_texts.py` is a Python port of
`util/snake_render.lua` (plus the force query, the `pragmata_enemy_hack_plan`
registration and the mod's tool-result strings). The selftest proves the port
byte for byte against every recorded force. If the mod's render changes, port
the change on purpose.

### Puzzles

Two sources, picked under **Source** (`both` by default):

- **recorded**: the mod's own forces, snapshot into `grid_corpus.json` by
  ```
  py -3 grid_corpus_build.py [lua_to_bridge.jsonl ...]
  ```
  - The default source is `../data/pragmata_mailbox/lua_to_bridge.jsonl`.
  - The snapshot is merged, never replaced, because the mailbox can be emptied (mod menu → **Clear bridge files**). Re-run it after playing.
  - Forces sent before today's red-block wording are kept, marked `reworded`, and sent in today's wording.
  - A grid that cannot be solved as drawn is kept but never benched. Today that is r019 and r020: 3-of-4 red-block grids where the cursor is boxed in by R cells of the top-left block, which had already gone down.
- **generated**: seeded grids from `grid_gen.py`, in the shapes the recorded ones have.
  - `field` is an open grid with a few walls, blue A/O and yellow * nodes.
  - `maze` is one-cell corridors, like the finale.
  - Modifiers go on top of either. Every generated grid is checked solvable.

| Category | What | Recorded | Generated |
|---|---|---|---|
| plain | small grid, no modifier, cursor on the start | yes | 4x4–7x7 |
| error | `d` error nodes (entering one resets the hack) | finale only | 5x5–7x7 |
| blocks | red blocks `R`, 1–3 of 4 up | yes (5x5) | 5x5, 6x6, 2x2 corner blocks, top-left gone first |
| corrupt | corrupted `c` cells stun the cursor | yes | ≤ 30 cells (the mod's gate) |
| big | more than 49 cells | finale only | 8x8, 9x9 |
| nonsquare | width ≠ height | yes | 3x4, 5x4, 4x6, 5x7, 7x9, 9x7 |
| resume | asked again mid-hack: cursor off the start, path drawn as arrows | yes | partway along a safe route |
| finale | the boss's five fixed stages | yes | — |
| erase | 1–3 `X` erase traps (stepping on one fails the hack) | not yet | 5x5–7x7 |
| nodes | bomb `b` / `B`, purge `P` and chain `C` nodes (walkable) | not yet | 5x5–7x7 |
| gates | 2–5 directional gates `=` `\|` `J` `7` `L` `r` | not yet | 5x5–7x7 |

They are unticked by default (and left out of `run_eval.py`'s default), so a
default run stays comparable with earlier ones. `erase`, `nodes` and `gates`
came over from the old `sim/` harness (see
[History](#history)). The mod can draw these cells, but no recorded force has
carried one, so their density and placement are guesses, and the gate rules
are sim's model, not something seen in game. The OneWay cell (`?`) is left out:
the mod draws it without its direction, so no peer could plan through it.

- **Per category** puzzles are taken from each ticked category. A grid tagged `finale` is used only by the finale.
- With `both`, half of each category is recorded and the rest generated. A category short of recorded grids is topped up from the generator.
- The set depends only on seed and repeat, so every version sees the same puzzles.

### Episodes

A grid trial is an **episode**:

1. The bench forces the puzzle exactly as the mod would: `state`, `query`, `priority: "high"`, `ephemeral_context`.
2. It plays the reply on the grid (`grid_sim.py`) and sends back the mod's own result string.
3. A failure while the hack is still live goes back the way the mod sends it: `success: false`, the message, then "The board is now (this replaces the earlier one):", the board from where the cursor ended and the query. No new force is sent: the Neuro server retries a failed forced action by itself (apitest emulates this, and so does `stub_peer.py`), and that retry is the next answer.
4. After 3 retried failures in a row (the mod's `force_retry_limit`) the failure goes back plain and the puzzle is forced afresh; a retry that never arrives within the cap is also followed by a fresh force.
5. Answers per episode stop at **Max forces** (default 3), retries included.

| Move | What happens (game + mod) |
|---|---|
| off the grid | the plan stops; earlier moves count |
| `#`, or a visited cell other than the one it came from | wall: "Move blocked by a wall after N move(s) landed" |
| back onto the cell it came from | retrace: that cell frees up |
| `d` | "Hit an error node": back to the start, path cleared |
| `R` | **Refuse plans into a red block** on (mod `hack_block_refuse_plan`): the whole plan is refused, nothing moves, and the peer retries. Off: the hack fails |
| `X` | the hack fails |
| gate `=` `\|` `J` `7` `L` `r` | entered only along its arrows (`=` / `\|` straight, the corners turn: `J` joins left and top, `7` left and bottom, `L` right and top, `r` right and bottom), left only by the exit that entry leads to; any other move into or out of it is a wall. Stepping back onto the cell you came from is always allowed |
| `b` `B` `P` `C` | walkable floor |
| `c` | walkable, one stun |
| `G` | solved; later moves never run |
| plan runs out | "Ran all N planned move(s) without reaching the goal" |

**Finale.** The five stages run in order as one chain:
- with `ephemeral_context: false`, as the mod now sends them (`hack_finale_keep_context`), so the peer keeps them in context;
- each stage is retried until its **Finale budget** runs out (default 15 s, about 2–3 tries at today's speed), with up to 12 forces only against a runaway peer.

The clock counts:

| Part | Cost |
|---|---|
| each reply's time | as measured |
| each landed move | 0.12 s |
| each stun | 0.5 s (the engine's block-input timer) |
| each reset | 0.5 s |

Past the budget the stage gets "The hack failed." and is rated timeout.

### Grid ratings and columns

| Rating | Meaning |
|---|---|
| very good | solved on the first force, reply under 3 s |
| good | solved on the first force, slower |
| risky | solved, but only on a later answer (a retry or a fresh force) |
| fail | not solved within the forces, or the hack failed |
| timeout | no reply within the cap, or a finale stage over its budget |

One summary row per version and category:

| Column | Meaning |
|---|---|
| Solved % | episodes that reached the goal |
| 1st try % | episodes that reached it on the first force |
| Very good / Good / Risky / Fail / Timeout | the ratings above |
| Forces | average answers per episode, retries included |
| Median ms | the median reply time |
| +Moves | average moves over the shortest safe route, for solved episodes |
| Blue % | blue nodes collected against the best route at most 4 moves longer (`grid_sim.best_route`) |
| Stuns / Refused / Resets / Walls | totals for the version and category |

**Versions:**
- `mod` is the mod's wording as sent today.
- `mod+adjacency` is a candidate that adds `snake_render`'s per-direction adjacency block. The mod has it, but sends it off.

Select an episode to see each answer's moves, the result sent, and the grid with the played path (`+` entered, `!` stopped). It also shows a shortest route and every state sent.

A grid run writes `results/<timestamp>-grid/` with the same four files. `trials.jsonl` holds one episode per line, with every answer inside (`retry: true` for one given to a server retry rather than a force).

## Testing the bench

```
py -3 selftest.py            # renders, round trips, judging, ratings, loopback runs, run_eval
py -3 stub_peer.py --port 8124 --mode correct|wrong|random|redblock|slow:2.5
```

`stub_peer.py` answers from the state text alone, in whatever answer shape the
registered schema asks for, so pointing the GUI at it checks the whole pipeline
at no API cost:
- **sequence hack:** it reads "+", letters, compass words and shuffled numbers;
- **grid:** it parses the state and answers with a shortest safe route, clean of `c` where possible;
- **`redblock` mode:** it walks into a red block the first time it sees a grid, then answers correctly on the retry.
- **retries:** like the Neuro server, it retries a grid answer that came back `success: false`, up to 3 times, planning on the board sent with the failure. A new force cancels a retry still due. Sequence answers are not retried; that bench scores one answer per puzzle.

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
| `grid_texts.py` | grid: the mod's render (port), parser, plan action, result strings |
| `grid_corpus_build.py` | grid: snapshots the mod's forces into `grid_corpus.json` |
| `grid_gen.py` | grid: seeded generated grids |
| `grid_puzzles.py` | grid: categories, sets, the finale chain, versions |
| `grid_sim.py` | grid: plays a reply on a grid; shortest and best routes |
| `grid_scoring.py` | grid: episode ratings, summary, detail pane |
| `stub_peer.py` | local test peer (with the server's retry of a failed grid answer) |
| `run_eval.py` | the command-line runner |
| `selftest.py` | offline checks |

## History

- **2026-11-15: the `sim/` harness was merged in and deleted.** `sim/` (in
  `reframework/` and the `neuro-pragmata-main/` mirror) was the first offline
  grid evaluator: a generator, a BFS solver, its own ASCII render, a mock mod
  and `run_eval.py`. By then it had fallen behind the mod. It registered a
  `pragmata_hack_route` action the mod never shipped and used an older render
  and description. It also scored a single answer per grid, with no retry, red
  blocks, corruption or finale. The grid bench had replaced everything else
  in it. What it still had came over here:
  - its command-line batch runner, as `run_eval.py` above;
  - the cells its generator could place that the bench never generated: X
    traps, bomb / purge / chain nodes and directional gates (the `erase`,
    `nodes` and `gates` categories), with its gate rules in `grid_sim.py`.

  Its difficulty presets (`easy`/`medium`/`hard`/`mixed`) became the category
  picks, and its stub strategies map onto `stub_peer.py`'s modes (`random`,
  `wrong`, `slow:X` for its `timeout`). The old code is in git history.
- **2026-11-15: ports brought up to date.** The descriptions of all three
  puzzle actions (now prefixed "Enemy hack:" / "Environment hack (a door,
  switch or elevator)"), the equipped-skill note in the grid render, and the
  re-ask after a failed plan (sent back with the board for the Neuro server's
  retry instead of a new force) were ported from the mod, and the grid
  forces in the mailbox were merged into `grid_corpus.json` (218 grids).
