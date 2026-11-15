# Pragmata Neuro-SDK Mod

A REFramework Lua mod for [Pragmata](https://www.capcom-games.com/pragmata/)
that lets **Neuro**, an AI peer, play alongside you as Diana over a standard
Neuro-SDK WebSocket connection. Neuro can use Diana's abilities (Scan,
Auto-Hack, Overdrive), solve the hacking minigames, read the game's menus and
collections, and receives context as you play: dialogue, combat, area changes,
health, new entries.

> **Status: working, actively developed.** Diana's three abilities, the scene
> button prompts, the enemy hacking grid, the circuit and sequence hacks,
> dialogue capture and the Shelter menus all work in game. Each ability reports
> success only after the game is seen to start it.

> [!WARNING]
> **Tested only on Windows with mouse and keyboard.** The mod has not been
> tested on **Linux** or with a **controller**. The mod
> presses buttons for Neuro through the game's own input layer, and the game
> reads input differently depending on the input device, so on a controller
> or under Proton Neuro's inputs (scans, hacking presses, scene prompts) may
> be missed, doubled, or clash with your own. Reports are welcome.

## Contents

- [What Neuro can do](#what-neuro-can-do)
- [Context sent to Neuro](#context-sent-to-neuro)
- [Install](#install)
- [Running](#running)
- [The mod menu](#the-mod-menu)
- [Configuration](#configuration)
- [How the hacking works](#how-the-hacking-works)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Testing hacking solving abilities](#testing-hacking-solving-abilities-of-neuro)

Full schemas, every reply and refusal, the grid format and the whole context
surface are in [ACTIONS.md](ACTIONS.md). Advice for integrations is in
[BEST_PRACTICES.md](BEST_PRACTICES.md).

## What Neuro can do

| Action | Arguments | Effect |
|---|---|---|
| `pragmata_scan` | none | Diana scans and reports what she found, with distances. Within 7 s of the last scan it answers from that scan and says so. |
| `pragmata_enemy_auto_hack` | none | Auto-hacks the locked-on target (needs the Auto-Hack upgrade). |
| `pragmata_overdrive` | none | Fires Overdrive (costs 100 gauge points). During a scene waiting on the Overdrive prompt, presses it instead. |
| `pragmata_purify` | none | Presses a scene's filament-cleaning prompt. Offered only while one is up. |
| `pragmata_status` | `category` (optional) | Health, location, weapons, mods, hacking mods and inventory, or one of them. Read-only. |
| `pragmata_menu_list` | none | Reads the Shelter menu open on screen (Firmware Updater, Unit Printer, train mod menu, Stamp Club, tram sector selection). Read-only. |
| `pragmata_menu_info` | `names` | Detail for up to 8 entries of the open menu. Read-only. |
| `pragmata_archive_list` | `catalog` (optional) | The Archive (the default), or a Shelter catalog: Data Library, Bot Database, Training Simulations, Earth Memories. Read-only. |
| `pragmata_archive_info` | `catalog` (optional), `names` | Full text or details of up to 8 entries. Read-only. |
| `pragmata_enemy_hack_plan` | `moves` | Routes the cursor through an enemy's hacking grid. |
| `pragmata_enviro_hack_rotate` | `rotations` | Solves a circuit hack. |
| `pragmata_enviro_hack_sequence` | `buttons` or `order` | Solves a sequence hack (the shape depends on `puzzle_sequence_group`). |

- **The hacking actions are forced.** When a hack starts, the mod asks Neuro
  with an `actions/force` naming the one action that fits the puzzle on
  screen, so she never has to work out which kind it is. This can be changed in mod_config.lua by editing hacking_auto_force. More info in [Configuration](#configuration).
- **Success means the game acted.** The abilities and the hacks answer when the
  game is seen to act (within a few seconds), not when asked. A precondition
  failure comes back at once with its reason.

  ```
  pragmata_scan             -> true   "Scan done. Diana found: 2x Upgrade Components (34 / 67 m)."
  pragmata_overdrive        -> true   "the game started Overdrive (canDeathblow cleared)"
  pragmata_enemy_auto_hack  -> false  "no valid hack target (nothing is locked on)"
  ```

### When actions are offered

Neuro is told only about actions that make sense right now:

- Scan, Auto-Hack and Overdrive are hidden during the opening (before Diana has
  them) and in the Shelter's sector; the hacking actions are hidden in the
  Shelter too, unless there is something to hack.
- `pragmata_menu_list` / `_info` appear in the main Shelter (once you are past
  the opening tutorial) and while one of their menus is open. Neuro is told when
  a menu opens or closes.
- `pragmata_purify` appears only while a scene waits for the filament-cleaning
  button.
- The Archive versiob of menu action named pragmata_archive_list` / `_info`. Can be access any time.

When a scripted scene stops on the Overdrive button, Neuro is asked to press
it, and the scene carries on. You can still press it yourself. After the first
boss's scene (Solar Power Plant) the mod fires the Overdrive that finishes the
boss by itself.

## Context sent to Neuro

Sent as `context` messages, silent unless noted:

- Dialogue with speaker and type: `Dialogue: [Conversation] Diana says "Let's finish this!"`
- `Overdrive is ready.` · `Auto-Hack upgrade is now available.`
- `Diana scanned: …` for scans you make (Neuro's own scans come back as her
  action result)
- Hack lifecycle: `Hacking grid started.` · `Hack succeeded.` · `Hack failed.`,
  and a spoken notice when a grid cannot be hacked yet (red blocks still up,
  enemy too corrupted)
- `Hugh and Diana entered a new area.`, with the area's name, completion % and
  what is left to collect there
- `Hugh is down to 22% HP (88/400) with 1 repair kit left.` on falling past
  50% / 25%
- Weapons and hacking mods equipped or unequipped
- Menus opening and closing, and new Archive / catalog entries, each with the
  call that reads them
- `Checkpoint reached.` · `Combat started.` · `Combat ended.`
- Optional in-combat ability hints (off by default)
- New entry in archive with way to access it.

Internal scene and checkpoint codes are never sent. Things not found yet are
counted, never named.

## Install

### Prerequisites

- **Pragmata** (PC, Windows; see the warning above for Linux).
- **REFramework** for Pragmata: put `dinput8.dll` from a
  [REFramework nightly](https://github.com/praydog/REFramework-nightly/releases)
  in the game folder. Pressing **Insert** in game should open its menu.
- **Python 3.10+** with `pip`, for the sidecar.
- **Neuro**, or any Neuro-SDK-compatible peer, listening on a WebSocket.

### One-time setup

1. **Copy the mod.** Copy the contents of `autorun/` into
   `<Pragmata>/reframework/autorun/`, so that `pragmata_main.lua` and the
   `pragmata/` folder sit side by side there.
2. **Create the mailbox folder:**

   ```
   mkdir "<Pragmata>/reframework/data/pragmata_mailbox"
   ```

   The sidecar creates it if missing, but creating it first avoids a race at
   startup.
3. **Install the sidecar's dependencies:**

   ```
   pip install -r sidecar/requirements.txt
   ```

## Running

Start these three, in any order:

1. **Neuro** on a WebSocket port.
2. **The sidecar**, which bridges the mod to Neuro (REFramework's Lua cannot
   open sockets):

   ```
   python sidecar/pragmata_mailbox.py \
       --mailbox-dir "<Pragmata>/reframework/data/pragmata_mailbox" \
       --bridge-url "ws://127.0.0.1:8000"
   ```

   `PRAGMATA_BRIDGE_WS` can replace `--bridge-url`.
3. **Pragmata** with REFramework. The mod loads with the game.

Neuro then receives `startup` and the list of actions available at that moment.
The sidecar re-sends them on every reconnect.

```
Pragmata + mod  <-- JSONL files -->  sidecar  <-- WebSocket -->  Neuro
            reframework/data/pragmata_mailbox/
```

The mod reaches the game only through REFramework's reflection and hooks: no
native offsets, no injected DLL, no virtual input device, no OS key presses.

## The mod menu

Press **Insert** in game to open REFramework's menu, then open **Pragmata
Neuro**. It shows whether the bridge is up, when the last message from Neuro
arrived, how many actions she holds, and whether a hack is waiting for her
answer. If something goes wrong, its buttons fix it without restarting the
game:

| Button | Use it when |
|---|---|
| **Re-send actions** | Neuro does not know the mod's actions (after a reconnect, or the sidecar was started late). Sends the startup message and the full action list again. |
| **Reset hacking** | A hack is stuck: Neuro's plan stopped, or a hack request never got an answer. Stops every plan and asks about the hack on screen again. |
| **Rescan archive and catalogs** | The Archive or a Shelter catalog reads wrong, or a new entry was missed. Reads them all again; entries already found are not announced as new. |
| **Clear bridge files** | The mailbox files grew very large, or old messages confuse the sidecar. Click twice within 5 s to empty both files; then press **Re-send actions**. |

**Setup values** (inside the menu) reads the current sector's name and hash
and every held item's internal name, for the "non-English game" settings.

Test Overdrive on a disposable save: with an empty gauge it should
refuse with a reason.

## Configuration

Settings live in `reframework/autorun/pragmata/mod_config.lua`, each documented
in place and read at every game launch. The ones most players touch:

**General**

- `display_name` (`"Neuro"`): the name in the on-screen "is hacking" banner.
- `autonomy_nudges` (`false`): in combat, remind Neuro which abilities are
  ready, at most every `autonomy_nudge_interval_frames` (~30 s).
- `action_descriptions` (`"full"`): `"short"` sends one-sentence action
  descriptions and the long rules separately.

**Hacking**

- `hacking_auto_force` (`true`): ask Neuro the moment a hack appears.
  `"not_open"` asks about every hack except on an enemy that is still open
  (vulnerable) from the last hack: for those Neuro is only shown the grid and
  decides herself whether to hack it. `false` asks about none, and shows her
  each hack the same way (enemy grids and the door / switch / elevator hacks);
  she solves the ones she chooses to.
- `hacking_context_legend` (`false`): a hack shown that way is sent as the
  board alone; `true` adds its legend (grid symbols, the sequence hack's
  reading steps, glyph keys).
- `hacking_render_legend` (`true`) / `hacking_render_adjacency` (`false`):
  extra help text in the grid Neuro is sent.
- `hacking_require_reasoning` (`false`): require a reasoning string before the
  moves. More accurate, slower.
- `hacking_show_overlay` (`true`), `hacking_overlay_x_fraction` /
  `_y_fraction`: the on-screen banner and its position.
- `hack_block_gate`, `hack_corruption_gate`, `hack_corruption_max_cells` (30),
  `hack_explosion_guard`: how the enemy grid modifiers (red blocks, corruption,
  exploding rows) are handled.
- `puzzle_kinds`: which environmental hacks Neuro is offered (circuit,
  sequence; both on).
- `puzzle_sequence_group` (`1`): how the sequence hack is shown to Neuro.

**Scan**

- `scan_report_detail` (`"located"`): every instance, or `"grouped"` per kind.
- `scan_report_distance_limit` (12), `scan_report_max_groups` (8): caps.
- `scan_filters`, `scan_dedupe_markers`, `scan_pickup_checks`: what counts as
  still there.

**Messages to Neuro**

- `state_push_area_summary`, `state_push_low_health`
  (`state_low_health_thresholds`), `state_push_new_weapon`,
  `state_push_hacking_mods`: the game-state lines.
- `catalog_push_archive`, `catalog_push_library`, `catalog_push_bot_database`,
  `catalog_push_simulations`, `catalog_push_earth_memories`: new-entry lines.
- `menu_push_open_close`: menu open / close lines.
- `state_repair_kit_item`: on a non-English game, set the repair kit's item
  name (mod menu -> **Setup values**).

## How the hacking works

There are three hacking minigames the mod plays: the cursor grid on enemies,
and the circuit and sequence hacks on doors, switches and elevators.

**The enemy grid.** When a grid appears the mod sends it to Neuro as text and
asks for a list of moves. The render marks bonus nodes, which make the hack
stronger, and asks her to route through as many as she can on the way to the
goal. The mod then moves the cursor one cell at a time through the game's own
input, so walls, traps and bonuses behave exactly as for a player, and the
goal completes the hack. A banner shows that Neuro, not you, is moving the
cursor. Before running a plan the mod checks that it is legal and reaches the
goal; if such a plan is cut short because you look away, the enemy dies or the
grid changes, Neuro is told her plan was right, and it runs again by itself if
the same grid comes back. The mod also handles the special enemies: it tells Neuro when red
blocks or corruption must be cleared first, waits out corruption stuns, and
times her moves around the final boss's exploding rows.

**The environmental hacks.** Each kind has its own action, because the
mechanics have nothing in common. Neuro never has to time anything: on the
sequence hack with a rotating needle, she gives the order and the mod presses
each button when the game would accept it.

Hack outcomes are watched both on the puzzle you aim at and on your own status,
so a hack that finishes after you look away is still reported.

## Troubleshooting

**`mailbox dir not ready` in the log**: create
`<Pragmata>/reframework/data/pragmata_mailbox/`.

**Sidecar logs `bridge connection failed`**: Neuro is not running, or listens
on a different port than `--bridge-url`.

**The mod doesn't load**: check `<Pragmata>/reframework/log.txt` for Lua
errors. Usually the `pragmata/` folder was not copied next to
`pragmata_main.lua`.

**Neuro gets nothing**: look in
`reframework/data/pragmata_mailbox/lua_to_bridge.jsonl`. If the messages are
there, the problem is between the sidecar and Neuro.

**An ability fails**: read the message, which names the cause (nothing locked
on, gauge empty, jamming, upgrade missing, not in gameplay).

**An ability reports failure but happened anyway**: the confirmation window
(2–3 s) ran out before the game's change was seen. The session log says which
evidence arrived.

**A hack is stuck or Neuro lost her actions**: use **Reset hacking** or
**Re-send actions** in the mod menu (above).

**Inputs missed or doubled on a controller or Linux**: untested setups, see the
warning at the top. Please report what happened, with `reframework/log.txt`.

**No dialogue lines**: `reframework/log.txt` should show `dialogue: …` as
subtitles appear. If not, a game patch may have moved the subtitle screen.

## Known limitations

- Untested on Linux and with a controller.
- Mission and objective state is not read.

## Testing hacking solving abilities of Neuro

**There is a seperate app in seqbench folder that let tests Neuro (or Evil) solving capabilities for hacking puzzle (both enviromental and enemy). More info in Readme.md present in seqbench folder

## License

[MIT](LICENSE).
