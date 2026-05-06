# Pragmata hacking-grid AI evaluation harness

Standalone simulator for the Pragmata hacking minigame integration. Generates
synthetic grids that match the in-game `app.PuzzleSnake` data model and scores
how well an AI peer can plan paths through them **without** running the game.

The harness speaks the same Neuro-SDK wire format the real mod uses, so any
peer that solves these grids will solve the in-game ones too (modulo
dynamic-grid effects, which the simulator does not currently model).

## Layout

```
sim/
├── grid_gen.py     # Cell taxonomy + Grid dataclass + procedural generator
├── solver.py       # Reference BFS solver + plan validator
├── ascii_render.py # Grid → ASCII (the surface the AI peer reads)
├── mod_mock.py     # Mod-side websocket client (replaces mod + sidecar)
├── stub_peer.py    # Reference AI peer for smoke-testing the pipeline
├── run_eval.py     # Batch runner with metrics
├── requirements.txt
└── README.md       # this file
```

## Install

```bash
pip install -r sim/requirements.txt
```

## Quickstart: smoke-test the pipeline against a stub peer

The stub peer uses the same solver to generate optimal plans. End-to-end run
should print 100% solve rate; if it doesn't, the harness has a bug.

```bash
# Terminal 1 — stub peer
python -m sim.stub_peer --port 8000 --strategy optimal

# Terminal 2 — eval against it
python -m sim.run_eval --peer-url ws://127.0.0.1:8000 --trials 20
```

Try other stub strategies to verify the eval distinguishes them:
- `--strategy random` → most trials illegal or no_goal
- `--strategy dumb` → all trials illegal (always goes right)
- `--strategy timeout` → all trials timeout

## Real evaluation against an AI peer

Point at the AI peer's websocket URL — whatever the peer's Neuro-SDK
endpoint listens on:

```bash
python -m sim.run_eval \
    --peer-url ws://127.0.0.1:8769 \
    --trials 100 \
    --difficulty mixed \
    --seed 1 \
    --out trials.jsonl
```

`--out` writes one JSONL line per trial including the rendered grid, the peer's
proposed plan, the validation result, and timing — useful for inspecting
failure modes after a batch.

## Difficulty presets

| Preset | Size | Obstacles | EraseCode | Skill nodes |
|---|---|---|---|---|
| `easy`   | 5×5 | 12% | 0%  | 5%  |
| `medium` | 6×6 | 18% | 5%  | 10% |
| `hard`   | 8×8 | 20% | 10% | 10% (+bombs +effects) |
| `mixed`  | randomized over the above | | | |

## Outcome labels

| Label | Meaning |
|---|---|
| `solved`     | Plan terminated on the Goal cell |
| `illegal`    | A move violated bounds, walls, trail, or directional rules |
| `hit_erase`  | Plan was legal up to a step onto an EraseCode (red trap) cell |
| `no_goal`    | Plan was legal but exhausted before reaching Goal |
| `timeout`    | Peer didn't respond within `--timeout` seconds |
| `deferred`   | Peer chose `pragmata_hack_route` instead of planning |
| `wrong_action` | Peer called a non-registered action |

## Suggested success thresholds

Reasonable targets for a peer that's tuned for grid planning:

- ≥85% solve rate on `easy` (no EraseCode)
- ≥70% solve rate on `hard` (with EraseCode)
- 0% `hit_erase` rate when warned in the system prompt

If thresholds aren't hit, options:

1. Tune the ASCII rendering (try `inline=False` or richer adjacency hints).
2. Strengthen the action's description copy.
3. Add a server-side fallback solver that runs when the peer's plan is
   invalid, so production play is robust to occasional misroutes.

## Limitations / future work

- **Static grids only.** Real grids mutate mid-hack as enemies attack the puzzle.
  A future revision could re-emit grid updates while the peer is mid-plan.
- **Generator distribution is approximate.** Real grids are designed by hand
  per enemy/sector. Once we have runtime telemetry, refine the generator's
  cell-density mix per difficulty band.
- **Round-trip parsing in `stub_peer.py` is best-effort.** It re-derives the
  grid from the rendered ASCII; if rendering changes shape, parsing must too.
- **Directional cells (OneWay / TwoWay\*) are off by default in presets.**
  Add `directional_density` once we know how often early-game grids use them.
