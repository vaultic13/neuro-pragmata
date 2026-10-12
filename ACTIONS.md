# Pragmata Neuro-SDK Mod — Action & Context Reference

Reference for AI integrators wiring up to this mod. All wire content is standard
Neuro-SDK JSON over WebSocket.

Every example message in this document is real output copied from
`reframework/data/pragmata_mailbox/lua_to_bridge.jsonl`.

## Actions registered by the mod

The actions below are registered at startup, but the peer is only ever told
about the ones **available right now** — see
[Action availability](#action-availability). Outside the Shelter that is
nine (more if a hack family is switched on in `mod_config.puzzle_kinds`,
plus `pragmata_ping` with `mod_config.debug_actions`).

| Action | Arguments | Effect |
|---|---|---|
| [`pragmata_ping`](#pragmata_ping) | none | Sanity check. Only with `mod_config.debug_actions`. |
| [`pragmata_scan`](#pragmata_scan) | none | Diana scans and reports what she found; a recent scan from about the same spot is answered from cache. |
| [`pragmata_status`](#game-state-read-only) | `category` (optional) | Health, location, weapons, mods, hacking mods and inventory in one reply, or just the one `category` names. Read-only. |
| [`pragmata_enemy_auto_hack`](#pragmata_enemy_auto_hack) | none | Auto-hack the locked-on target. |
| [`pragmata_overdrive`](#pragmata_overdrive) | none | Fire Overdrive. |
| [`pragmata_purify`](#scene-prompts) | none | Press a scene's filament-cleaning prompt. Only while one is up; auto-forced. |
| [`pragmata_enemy_hack_plan`](#pragmata_enemy_hack_plan) | `moves` | Route the hacking grid. Auto-forced. |
| [`pragmata_enviro_hack_rotate`](#the-other-hacking-puzzles) | `rotations` | Solve a circuit hack. Auto-forced; the render names the press count. Not forced when there is nothing to press. |
| [`pragmata_enviro_hack_sequence`](#the-other-hacking-puzzles) | `buttons` or `order` | Solve a sequence hack; the payload follows `mod_config.puzzle_sequence_group`. Auto-forced. |
| [`pragmata_enviro_hack_slide`](#the-other-hacking-puzzles) | `moves` | Solve a pipe hack. Auto-forced. |
| [`pragmata_enviro_hack_path`](#the-other-hacking-puzzles) | `rotations` | Solve a path hack. Auto-forced. |
| [`pragmata_menu_list`](#shelter-menus) | `menu` | Read a Shelter menu or catalog: `firmware`, `printer`, `mod_terminal`, `stamps`, `sectors` (while that screen is open), `library`, `bot_database`, `simulations`, `earth_memories` (in the Shelter), `archive` (anywhere). Always registered; refuses with the reason when it cannot be read. Read-only. |
| [`pragmata_menu_info`](#shelter-menus) | `menu`, `names` | Detail for up to 8 entries of one of those (all but `stamps`). Same availability. Read-only. |

The five hacking actions are the hacking minigames: `pragmata_enemy_hack_plan` for the grid on enemies, and the four `pragmata_enviro_hack_*` for doors, switches and elevators. (Renamed on 2026-10-12 so the two kinds read apart: they were `pragmata_auto_hack`, `pragmata_hack_plan`, `pragmata_hack_rotate`, `pragmata_hack_sequence`, `pragmata_hack_slide` and `pragmata_hack_path`.) **Only one of them is ever offered at a
time** — the force names exactly the action that matches the puzzle actually on
screen, so the peer never has to work out which kind it is looking at.

Each force also carries a **`priority`** — `"low"`, `"medium"`, `"high"` or
`"critical"`. The enemy grid goes out as `high`, because it is nearly always
mid-combat and the window to act closes; the four environmental hacks (doors,
switches, elevators) go out as `low`, because nothing is shooting at you while
you solve one. It is a hint about urgency, not a queue: the mod still keeps
exactly one force outstanding at a time, first come first served. Defaults are
per family in `mod_config.puzzle_force_priority`.

**All three of Diana's abilities take no arguments.** Their schema is exactly
`{"type": "object"}`. There is nothing to choose: Scan is a single input
command, Overdrive is a single driver call, and Auto-Hack's engine entry point
(`startAutoHack()`) has no target parameter — the game's lock-on decides the
target. Only `pragmata_enemy_hack_plan` takes arguments, and only because it is
answering a question the mod asked.

### Action availability

Some actions only make sense in some places, so the action set changes while
the game runs:

| Where | Hidden | Shown |
|---|---|---|
| In the Shelter | `pragmata_scan`, `pragmata_enemy_auto_hack`, `pragmata_overdrive` (`mod_config.hide_abilities_in_shelter`), `pragmata_enemy_hack_plan` and every `pragmata_enviro_hack_*` (`hide_hacking_in_shelter`; not while a hack target is in front of the player, e.g. the opening tutorial, which runs in the Shelter sector) | — |
| A scene waits on the filament-cleaning button | — | `pragmata_purify` |

`pragmata_menu_list` / `pragmata_menu_info` are **not** in this table: they are
always registered, because the Shelter's menus open and close constantly and
every change to the action set slows the peer down (BEST_PRACTICES.md). Which
menus can be read where is a property of the `menu` argument instead
([Shelter menus](#shelter-menus)), and a menu that cannot be read right now is
refused with the reason, e.g. `The Unit Printer cannot be read right now: only
available while that menu is open.`

A change is sent as `actions/unregister` for the names that went away, followed
by `actions/register` carrying the **whole** current list (a peer that treats
each register as the complete catalogue stays correct). Nothing is sent while
the set is unchanged; it is re-checked about five times a second, and loading
screens never flap it. A call that races a change — the menu closed a moment
before — is refused with the reason, e.g. `pragmata_purify is not available
right now: only while a scene waits for the filament-cleaning button.`

### Confirmed, not acknowledged

Scan, Auto-Hack and Overdrive all use **deferred results**. The mod does not
reply when it asks the engine to act; it replies when the engine is observed to
have acted, or when a confirmation window expires.

| Action | Confirmation signal | Window |
|---|---|---|
| `pragmata_scan` | the engine reaches `ScanManager.requestScan`, then the result list settles | 120 frames (~2 s) to start, then up to 180 (~3 s) for the results |
| `pragmata_enemy_auto_hack` | the work unit reports Auto-Hack running | 120 frames (~2 s) |
| `pragmata_overdrive` | a Deathblow start flag, or a real gauge spend | 180 frames (~3 s) |

So a `success: true` here means the game actually started the ability. Two
consequences worth designing around: results arrive a beat late, and a
precondition failure comes back **immediately** while a genuine no-op comes back
at the end of the window with a `did not produce its expected game-state
transition` message.

### Results, failures and retries

These follow BEST_PRACTICES.md and hold for every action:

- **Every result arrives within ~12 s.** The Neuro server counts an action with
  no result after ~20 s as failed and discards a later one. A deferred result
  still open after `mod_config.deferred_result_max_seconds` (12) is answered
  `success: true`, *"… was accepted and is still running; its outcome will
  follow as a context message."*, and the real outcome then arrives as a
  (non-silent) context line `<action> finished: <outcome>`. A hack plan that
  arrives after the player looked away from its target is answered at once the
  same way (*"Plan saved: … runs when he aims at it again"*).
- **`success: false` means "try again, differently".** It is used where a
  retry can succeed: a refused plan, a move that is not a direction, a name
  that matches nothing (the reply lists valid names), arguments that are not a
  JSON object, an unknown action (the reply lists the registered ones).
- **A hack answer that changed nothing useful is answered `success: true`**
  with *"Nothing was done: …"* when retrying cannot help — no hack is waiting,
  the target is gone.
- **Forced hacks use the server's automatic retry.** A failing result to a
  forced action is retried by the server at once, so the mod does **not** send
  a second `actions/force` alongside it. When the hack is still live — plan
  refused, reset to the start, stopped at a wall, fell short, grid changed —
  the mod holds the failure until the puzzle can be described again and sends
  it with the current board appended (*"The board is now (this replaces the
  earlier one): …"*), then the force query. The mod forces afresh only after
  `mod_config.force_retry_limit` (3) failures in a row, when no retry reply
  comes within `force_retry_wait_seconds` (10), or when the puzzle does not
  settle within `force_retry_settle_seconds` (4) — then the failure is sent as
  `success: true` with *"… nothing to retry; you will be asked again when it
  is."* A hack that ends in failure ("The hack failed.") is final and not
  retried.
- **Reconnects.** On `actions/reregister_all` — from the server, or from the
  sidecar on every WebSocket connect — the mod sends `startup` and its full
  action list again, and drops any force that belonged to the old connection
  so a live puzzle or scene prompt is offered again.

---

### `pragmata_ping`

Sanity check. Confirms mod, sidecar, and peer are wired up end to end.
Registered only with `mod_config.debug_actions = true` (default `false`): it
does nothing in the game, so the peer does not see it otherwise.

- **Schema:** `{"type": "object"}` — no arguments.
- **Result:** always `success: true`, message `"pong"`. Synchronous.

---

### `pragmata_scan`

Diana's environmental scan, and the way to re-read it. Highlights nearby
objectives, paths, and — with the in-game Object Scan upgrade — pickups such as
REM disks, Upgrade Modules, Mods and Pure Lunum. Until 2026-10-12 re-reading was
a separate action, `pragmata_scan_results`.

- **Schema:** `{"type": "object"}` — no arguments.
- **Scan or cache.** A new scan is made only when the last scan — the peer's or
  the player's own — is at least `mod_config.scan_cache_seconds` (7) old.
  Otherwise the results already held are returned, and the reply says so. With
  nothing held, it scans anyway. (A "Hugh has moved 5 m" condition was tried
  and removed on 2026-10-12: the player's position could not be read.)
- **Dispatch:** injects the game's own Scan input command (the one bound to
  **C** by default). No OS key event and no virtual device is involved.
- **Result of a new scan** — deferred until the result list has settled, so the
  findings are in the result itself:

  ```
  success: true   "Scan done. Diana found: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m)."
  success: true   "Scan done. Nothing the scan can place was found nearby."
  ```

- **Result from cache** (immediate):

  ```
  success: true   "No new scan (a new scan runs once the last is 7 s old). Cached scan from 4 s ago; the distances are from where it was made: 1x escape hatch (32 m), …."
  ```

  A list the game marks as possibly out of date ends with
  `(the game marks this list as possibly out of date)`.

- **Result on refusal** (immediate):

  ```
  success: false  "FAIL: scan manager singleton unavailable"
  success: false  "FAIL: scan request is locally debounced"
  ```

  Scan requests are debounced 8 frames, so hammering the action is refused
  rather than queued.

A scan the player makes themselves (pressing C) is still reported as context,
`Diana scanned: …`. A scan the peer asked for is not: its findings went back as
the tool result.

#### Scan results

One row per kind of thing, with the distance to each instance:

```
Diana scanned: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m), 1x Lunafilament (67 m).
```

- The leading count is the number of instances listed, and **always equals the
  number of distances after it**. `2x Upgrade Components (34 / 67 m)` is two
  separate pickups, at 34 m and at 67 m — not a group summarised by its nearest.
- Names come from the game's own catalogs. Markers the catalogs do not name are
  described by what they are: `objective marker`, `sub-objective marker`,
  `escape hatch`, `item marker`. No hashes or internal codes ever appear.
- Only **live, locatable** markers are listed. Collected items, deactivated
  objects, markers in rooms the engine has not streamed in, and anything the
  engine cannot place are all omitted — including from any total. There are
  deliberately no marker counts in the line: a number the peer cannot act on
  was pure noise, and it contradicted the rows printed beside it.
- `cannot be taken yet` means the game is refusing interaction with every
  instance in that row right now — a cutscene or a locked phase. It means "not
  yet", not "never". `some cannot be taken yet` is the partial case.
- `(+N more marker types)` means the report hit its group cap
  (`scan_report_max_groups`, default 8). Nothing vanishes silently.

When the engine can name things but cannot place any of them, the line degrades
to names and counts alone:

```
Diana scanned: 12x Upgrade Components, 3x Lunafilament, 1x Mods, 1x Pure Lunum, 24x sub-objective markers, 15x markers (some cannot be taken yet), 4x escape hatches, 3x objective markers (+1 more marker type).
```

---

### Game state (read-only)

One question the peer can ask about the player. `pragmata_status` answers
**synchronously** from live game data and changes nothing in the game. Names
are the game's own localised strings.

It takes one optional argument, `category`, an enum: `health`, `location`,
`weapons`, `mods`, `hacking_mods`, `inventory`. With it, only that part is
returned; without it (or with no arguments at all), every part is. An unknown
value is refused with the valid ones.

```json
{"type": "object", "properties": {"category": {"type": "string",
  "enum": ["health", "location", "weapons", "mods", "hacking_mods", "inventory"]}}}
```

It answers with one labelled line per part — `Health:`, `Location:`,
`Weapons:`, `Mods:`, `Hacking mods:`, `Inventory:` — as below. A part that cannot be read says so
on its own line and the others still answer; the reply fails only when none can
be read. Until 2026-10-12 these were five actions (`pragmata_health`,
`pragmata_location`, `pragmata_weapons`, `pragmata_mods`, `pragmata_inventory`),
plus `pragmata_upgrades`, which was dropped: the equipped levels are in the
Weapons and Mods lines, and the full upgrade picture is what the Shelter's Unit
Printer and Firmware Updater show (`pragmata_menu_list`).

| Action / part | Reports |
|---|---|
| `pragmata_status` — Health | Current / max HP, repair kits carried of the carry limit, HP restored per kit. The per-kit figure is computed from the upgrade tables until a kit is used, then it is the HP actually gained ("measured on the last use"). |
| `pragmata_status` — Weapons | Equipped weapons only, one per line: name (main weapon marked), `Lv current/max`, `ammo current/max` where the game tracks ammo, and what it does (the Unit Printer's unit text; left off when the printer data does not name the weapon). Weapons owned but not equipped are not listed. |
| `pragmata_status` — Mods / Hacking mods | Two parts: equipped mods, and equipped hacking mods, each one per line with slot use, level where the mod has levels, hacking-mod uses left, and what the mod does; the hacking-mods part ends with the equipped hacking style. Mods owned but not equipped are not listed (`pragmata_menu_list` with `menu: "mod_terminal"` lists them at the train terminal). |
| `pragmata_status` — Inventory | Every held item with a quantity, grouped by the game's item category — currency, collectibles, materials, consumables. Items the game gives no name for are left out entirely. |
| `pragmata_status` — Location | The current sector and area names (sector first; the last checkpoint's name if the map names neither), the map screen's completion % for it, and what is still left to collect there, grouped. Use `pragmata_scan` for *where* those things are. |

Outside gameplay (title menu, loading) each returns `success: true` with a
reason — "not available right now (not in gameplay…)" — never an empty report
that would read as "you have nothing". Illustrative replies (wording is fixed,
values are examples until captured from a live session):

```
Health: HP 312/400 (78%). Repair kits: 2 of 3 carried. Each repair kit restores about 120 HP.
Location: Current location: <sector>, <area>. Map completion here: 60%. Still to collect (3 of 12): 2x Upgrade Components, 1x Archive.
Weapons: equipped:
- <weapon> (main weapon) Lv 2/5 ammo 18/30: <what it does>
Mods: Mods equipped (2/4 slots):
- <mod>: <what it does>
…
```

---

### Shelter menus

Every Shelter menu and catalog is read through two actions, with the menu as
an enum argument:

- `pragmata_menu_list` `{"menu": "printer"}` — everything the menu lists.
- `pragmata_menu_info` `{"menu": "printer", "names": ["...", ...]}` — 1 to 8
  names as the list gives them. Case does not matter; a name is matched exactly
  first, then as a unique part of a name. Each requested name gets its own
  line: the detail, `Not found: 'x'.`, or `'x' matches several: A, B. Give the
  full name.` When not one name matches, the reply is `success: false` and ends
  with the valid names (up to 20).

| `menu` | Readable | Section |
|---|---|---|
| `firmware`, `printer`, `mod_terminal` | while that menu is open | below |
| `stamps` (list only) | while the Cabin's Stamp Club tab is selected | [Stamp Club](#stamp-club) |
| `library`, `bot_database`, `simulations`, `earth_memories` | in the Shelter, or while that catalog's screen is open | [Catalogs](#catalogs) |
| `archive` | anywhere | [Catalogs](#catalogs) |
| `sectors` | while the tram's sector selection is open | [Tram sector selection](#tram-sector-selection) |

Both actions are always registered, and the `menu` enum's description says
what each value covers. A menu that cannot be read right now is refused with
the reason. Until 2026-10-11 these were nineteen separate actions
(`pragmata_firmware_list`, `pragmata_stamps`, …), each shown only while its menu
was open.

The three upgrade menus read the open menu itself, so levels, costs and
have-counts are exactly what the screen shows. All are read-only.

**Firmware Updater** (`menu: "firmware"`):

```
Firmware Updater:
- Suit (Suit) - Lv 15/20, next level costs 7x Upgrade Components (have 2, not enough)
- Primary Unit (Grip Gun) - Lv 20/20, fully upgraded
```

Info adds "Upgradable up to Lv N for now." when progress caps it, and the stat
changes at the next level (`HP 120 -> 140; Defense ...`).

**Unit Printer** (`menu: "printer"`). The printer shows one tab
at a time; the list covers **every** tab (Weapon, Attachment, Ability,
HackingNode) from the first call — the tab on screen read from the menu, the
others rebuilt from the same game data:

```
Unit Printer, tab Weapon (on screen):
- Lim Cannon - printed, Lv 1/8, next level costs 900x Lunafilament (have 594, not enough)
- Homing Missiles - not printed yet, printing costs 900x Lunafilament (have 594, not enough)
- Riot Blaster - printed, Lv 8/8, fully upgraded
Tab HackingNode:
- ??? - not found yet
```

Info adds the unit's description and one line per level, the current and next
level marked (`Lv 2 (current): ...`, `Lv 3 (next): ...`). Units not found yet
get no text, as on screen.

**Train terminal mod menu** (`menu: "mod_terminal"`):

```
Mod capacity: 5 used of 6.
Equipped: Relay Amplifier; Overclocked Weaponry; Recursive Learning; Hyperfocus; Sympathetic Hacking; empty slot.
Not equipped: Hardened Suit; Pocket Refinery (new); ...
3 more mods not unlocked yet.
```

Equipped mods are in slot order; a mod's capacity cost is shown only when it is
not 1. Locked mods are only counted. Info gives what each mod does and
`[equipped]` / `[not equipped]`.

---

### Stamp Club

`pragmata_menu_list` with `menu: "stamps"`. Readable only while the Cabin's Stamp Club tab is selected (the
Training Simulations tab shares the screen and does not count). It reads the
board on screen; to see another board, switch to it in game.

```
Stamp Club board 'Board A' (3x3).
Lines completed: 2 of 8 (each line gives 100 Filament).
Cells stamped: 5 of 9. Cabin Coin: 1; each cell costs 1.
Map (row 1 at the top; [X] stamped, [ ] not yet, [?] hidden reward):
     A   B   C
1  [X] [X] [?]
2  [ ] [X] [ ]
3  [X] [ ] [X]
Cells:
- A1 Hugh Outfit - stamped (was a hidden reward)
- B1 Target Weakness - stamped
- C1 hidden reward (Encrypted Reward) - not stamped yet
- A2 Bot Data - not stamped yet (selected): Watcher bot data will be uploaded to the Bot Database in the Shelter.
...
Bonuses:
- Bonus (1 line): ... - earned
- Bonus (2 lines): ... - earned
- Bonus (every cell): ... - not earned yet
Boards: Board A (on screen); Board B; Board C (locked).
```

- A line is a full row, column or diagonal (8 on a 3x3 board).
- A hidden reward's content is unknown until it is stamped; once stamped, the
  cell shows what it gave.
- Cells not stamped yet carry their description, so the peer can weigh them.
- The cost of one Cabin Coin per cell is what the game's text says; the shop
  data carries no per-cell price.

---

### Catalogs

Five of the game's collections are `menu` values of `pragmata_menu_list` /
`pragmata_menu_info`. All are read-only and read the game's own data, so they answer the same whether or not
the collection's screen is open.

| Catalog | `menu` | Readable | In game |
|---|---|---|---|
| Data Library | `library` | in the Shelter | the Shelter terminal |
| Archive | `archive` | anywhere | the pause menu (Esc) |
| Bot Database | `bot_database` | in the Shelter | the Bot Database screen |
| Training Simulations | `simulations` | in the Shelter | the Cabin's Training tab |
| Earth Memories | `earth_memories` | in the Shelter | the Rem Replicators, and the items placed around the Shelter |

`pragmata_menu_info` takes `{"menu": ..., "names": [...]}` and matches exactly as the
[Shelter menus](#shelter-menus) do: 1 to 8 names, case ignored, exact first,
then a unique part of a name, one reply per name (`Not found: 'x'.` or
`'x' matches several: ...`). **Only found entries can be asked about.** Entries
not found yet are counted, never named, so the lists give nothing away.

**Data Library and Archive.** Both are the game's narrative records, split by
category: the Library takes the terminal's categories, the Archive the pause
menu's. A Library category with nothing found is left out (as on the terminal),
as is an Archive category with no entries at all. The bracket is the entry's
group, usually where it was found.

```
Data Library: 12 of 12 entries found.
Secrets (12 of 12):
- Cradle Infiltration Log - Day 1
- Cradle Infiltration Log - Day 2
...

Archive: 103 of 106 entries found.
Files (39 of 40):
- Mini Cabin Figures [The Shelter]
- Read Earth Memory Guide [Solar Power Plant]
...
```

Info gives the title, the category and group, and the full text; a document
with several pages adds `[page N]` lines. Replies for several names are
separated by a blank line.

```
'Time to Say Goodbye' (Files, Secret Reports):
It's been three days since I got the notice to work at
Dr. Higgins' lab. I've thought it over, and I've made
my decision: I'm not going, and I'm leaving Delphi.
...
```

**Bot Database.** Info gives a figure's size and description.

```
Bot Database: 31 of 31 figures collected.
Collected: Walker; Watcher; Crusher; SectorGuard; Spider; Missile Watcher; ...
```

**Training Simulations.** Only the simulations run from the Training tab are
listed; the unnamed ones and the event (extra) missions are left out, and
locked ones are only counted.

```
Training Simulations: 30 available, 30 of them cleared.
- Lightning Speed (Movement Training) - cleared
- Shimmering Drift & Discovery (Skill Training) - cleared
...
```

Info gives the description, and the time limit, special rules and each reward
with whether it is earned. Those three come from the Training tab, so until it
has been opened once in the session the reply says so:

```
Round and Round (Movement Training) - cleared
  Reach target area in 60 secs
  Rewards and rules are shown once the Training Simulations tab has been opened.
```

**Earth Memories.** The items the Rem Replicators collect, in the game's
groups (numbered, as the game gives them no names). Only owned ones are named;
each is either placed in the Shelter (Diana has set it up) or not placed yet.

```
Earth Memories: 16 of 16 owned, 16 of them placed in the Shelter.
Group 1 (3 of 3 owned, 3 placed):
- Globe - placed in the Shelter
- Crayons - placed in the Shelter
- CRT TV - placed in the Shelter
Group 2 (5 of 5 owned, 5 placed):
...
```

Info gives the group, the state and the description. A placed memory's
description drops its closing line ("This can be given to Diana in the
Shelter."), which is no longer true once it is placed.

```
Parasol (group 4) - placed in the Shelter: This waterside umbrella offers protection from
the burning summer sun. Lay out a towel and
set up home base for a fun beach adventure.
```

New entries are announced as silent context; see
[Catalogs](#catalogs-shelter-only) under the context messages.

---

### Tram sector selection

`pragmata_menu_list` / `pragmata_menu_info` with `menu: "sectors"`, readable
only while the tram terminal's sector selection is open; they read that screen, which holds every
sector at once. Read-only.

The list gives each sector's completion (the screen's own %), then each
location in it with the stations that lead there. Counts belong to the
location, so two stations into one area are one line. Stations not reached
yet are only counted.

```
Tram sectors (6):
Solar Power Plant - 100% complete:
- Generator Entrance (station: Power Plant Platform) - all 1 collected
- Power Distribution Center (station: Sealed Sector Gate) - all 4 collected
...
Terra Dome - 100% complete:
- Terra Dome Entrance (stations: Terra Dome Platform; Central Lift) - all 10 collected
- Center Hall - Upper Floor (station: Central Lift - Upper Floor) - nothing to collect
...
```

`pragmata_menu_info` takes `{"menu": "sectors", "names": [...]}`, matched as in the
[Shelter menus](#shelter-menus): a location, a station (which gives its
location) or a sector. A location gives every collectible kind present there
with how many are found; a sector gives its %, its locations and the kinds
added up over them.

```
Lunafilament Lab (in Central Port) (station: Connect Center): all 10 collected (100%).
- Pure Lunum: 1 of 1
- Mods: 1 of 1
- Storage Expander: 3 of 3
- Red Gate Key: 4 of 4
- Training Data: 1 of 1

Not found: 'Port Entrace'.
```

---

### `pragmata_enemy_auto_hack`

Auto-hack the target Diana is currently locked on to. Consumes part of the
hacking gauge to bypass the manual minigame. **Requires the in-game Auto-Hack
upgrade**, which unlocks mid-game from the Unit Printer.

- **Schema:** `{"type": "object"}` — no arguments.
- **Result on success:** `success: true`, `"auto-hack started"` — the work unit
  reports Auto-Hack actually running, not merely that preconditions passed.
- **Results on refusal** (all immediate, and each names the specific reason):

  ```
  "not implemented: auto-hack not currently available (locked, missing driver, or per-target disabled)"
  "jamming active in this area; auto-hack would be refused"
  "auto-hack already in progress"
  "no valid hack target (nothing is locked on)"
  "hacking gauge empty; cannot pay auto-hack cost"
  ```

  Lock on to a target before calling, or the fourth message is what comes back.

---

### `pragmata_overdrive`

Fire Diana's Overdrive Protocol. AoE pulse that stuns and exposes weak points on
nearby enemies. The ability itself unlocks during the Sector 1 boss fight.

- **Schema:** `{"type": "object"}` — no arguments.
- **Dispatch:** `app.PlayerDeathblowDriver.tryDeathblow()` — the game's own
  entry point, which re-runs all of its normal guards. Runtime captures settled
  this: it is **not** command-driven, and it wraps the lower-level start call,
  so there is exactly one route and no fallback.
- **Cost:** a fixed **100** gauge points. Not a "gauge must be full"
  requirement.
- **Readiness:** the engine's own `canDeathblow()`, corroborated by the
  `DeathblowStatus.CanDeathblow` flag, with the gauge threshold as a last
  resort.
- **Result on success:**

  ```
  success: true   "the game started Overdrive (canDeathblow cleared)"
  ```

  Other confirmations you may see, depending on which evidence lands first:
  `"the game started Overdrive (gauge spent 100.0 points)"`.

- **Results on refusal:**

  ```
  "the game reports Overdrive is not currently usable (canDeathblow() is false; gauge holds 26.7 points)"
  "no engine readiness signal and the gauge holds 26.7 of the 100 points one activation costs"
  "hacking gauge is unreachable (not in gameplay?)"
  "the Deathblow driver is not captured (not in gameplay?)"
  "an overdrive request is already awaiting confirmation"
  ```

- **If the window expires:** `success: false`, `"overdrive did not produce its
  expected game-state transition"`. That means the call was accepted but the
  game never started the ability — distinct from the refusals above, which are
  the game saying no up front.

Activation is not instantaneous: the driver call raises a request that the
engine's state machine consumes about four frames later, and the ability runs
for roughly 90 frames after that.

> **⚠️ Save-safety note:** Overdrive drives a cinematic/animation pipeline.
> Calling it in unexpected scene states (loading, paused, mid-cinematic) carries
> a small but real save-corruption risk.

#### Scene prompts

Some scripted scenes (the Overdrive unlock, a boss finisher) stop on a single
centred button icon and wait for the Overdrive button. While one is up,
`pragmata_overdrive` **presses that prompt for the player** instead of firing
combat Overdrive. It takes no gauge and has no readiness check, and the result
reports whether the scene continued:

```
success: true   "pressed the scene's Overdrive prompt; the scene continued (StartedDeathBlow)"
success: false  "pressing the scene's Overdrive prompt did not work: the scene is still waiting for the button"
success: false  "the scene's Overdrive prompt was already answered; the scene has moved on"
```

The last result means the player pressed the prompt before your reply arrived.
Nothing was fired.

When a prompt comes up, the mod sends an `actions/force` listing only
`pragmata_overdrive`, with `ephemeral_context: true` and the priority from
`mod_config.cutscene_prompt_force_priority` (default `"high"`). Its `state` is:

```
A scene has stopped on the Overdrive button prompt: Diana's Overdrive has to be used to continue. Calling pragmata_overdrive presses it for the player and the scene carries on.
```

The query is `Use Overdrive now to continue the scene.`. (On a boss scene,
"to continue" reads "to finish the boss".)
`pragmata_overdrive` stays available during a prompt even where the abilities
gate would hide it. If the player answers it first, you get the silent context
`The scene's button prompt was answered without Diana; the scene has moved
on.` With `cutscene_prompt_auto_force` off, the `state` text above is sent as
a spoken context line instead of a force.

**`pragmata_purify`** works the same way for the scene that first asks for the
filament-cleaning button (the Filament Remover). It is announced only while
that prompt is up, and forced with this `state`:

```
A scene has stopped on the filament-cleaning button prompt: Diana has to clean the filament to continue. Calling pragmata_purify presses it for the player and the scene carries on.
```

The query is `Clean the filament now to continue the scene.`. Results:
`"pressed the scene's filament-cleaning prompt; the scene continued (StartedDeathBlow)"`,
or `"no scene is waiting for the filament-cleaning button"` outside such a
prompt. Which action each scene gets is `mod_config.cutscene_prompt_buttons`.

**First boss (Solar Power Plant).** Pressing that scene's prompt ends the
cutscene, and the boss is then finished with a normal Overdrive. The mod does
that itself: once the scene is over it waits 2 s and fires Overdrive (retrying
for up to 10 s), then sends the silent context `Diana used Overdrive to finish
the boss.` Nothing is forced for it. The sectors and delays are
`mod_config.cutscene_prompt_followup_overdrive`.

---

### `pragmata_enemy_hack_plan`

Plan a path through an active hacking grid (the `app.PuzzleSnake` minigame).
Fired automatically by the mod via `actions/force` the moment a grid appears
(`mod_config.hacking_auto_force`, on by default). This is the one action with
arguments, because it is a reply.

The peer reads the grid from the force's `state` field and returns an ordered
list of cardinal moves.

- **Schema** depends on `mod_config.hacking_require_reasoning` (default
  `false`).

  Default — faster reaction:

  ```json
  {
    "type": "object",
    "required": ["moves"],
    "properties": {
      "moves": {
        "type": "array",
        "items": {"enum": ["up", "down", "left", "right"]},
        "minItems": 1, "maxItems": 32
      }
    }
  }
  ```

  With `hacking_require_reasoning = true`, a `reasoning` string is required
  **before** `moves`. The property order is pinned in the serialized schema on
  purpose: a trace generated after the moves is a post-hoc rationalization that
  does not even have to match them.

- **Result:** the mod queues the plan and dispatches one cell per ~130 ms by
  writing each target into `app.PuzzleSnake._NextMovePosition`. The engine's own
  input pipeline then runs every per-cell side effect — walls block, directional
  gates enforce, trail flags update, bonus and skill cells trigger, `EraseCode`
  traps fire, and **goal arrival auto-completes the puzzle** with the full
  completion flow. The result is deferred until the plan's outcome is known:
  reached the goal (`success: true`), or a failure that leaves the hack live —
  refused, reset, stopped short — which comes back `success: false` with the
  current board for the server's retry (see
  [Results, failures and retries](#results-failures-and-retries)).

#### Reading the grid render

Coordinates are `(x, y)` with `(0, 0)` at **top-left**; `up` is `-y`.

| Glyph | Meaning |
|---|---|
| `@` | cursor — current position |
| `G` | goal — reach it to finish the hack |
| `.` | walkable floor |
| `O` | **blue OPEN node** — the bonus that makes a hack deal damage |
| `A` | **blue ATTACK node** — what `O` becomes on an exposed hack; same value |
| `*` | yellow skill node — effective but limited-use |
| `C` | chain node |
| `#` | wall — the cursor stops |
| `d` | **red error node — entering one RESETS the whole hack** |
| `X` | `EraseCode` trap — fails the hack |
| `~` | your own trail — retracing it undoes the bonuses already collected |
| `S` start, `s` shield, `b` / `B` bomb 3x3 / 5x5, `P` purge | less common cell types |
| `=` `J` `7` `L` `r` and the vertical bar | two-way directional cells |
| `?` | a directional `OneWay` cell — never yet observed in a live grid |

The routing objective is to **maximize collected bonuses**, not to take the
shortest path: a longer winding route through more `O`/`A` nodes is better, as
long as it ends on `G` and never steps on `#`, `d`, `X`, or `~`. Collect nodes
by passing *through* them going forward — detouring out and back retraces the
trail and undoes them.

One boss blows up whole rows of its grid. These are **not drawn**: they are
short-lived, can start partway through a hack, and would cover the goal and
the bonus nodes. The mod times the moves itself. It waits on a safe cell, or
steps aside and back, including while you are replanning. If a row still
catches the cursor, the tool result is `"An exploding row caught the cursor -
the hack failed and restarted from the start, so none of those moves
counted."` rather than the error-node message.

The render also carries an "Adjacency from cursor" block (legal first moves,
suppressible via `hacking_render_adjacency`), a bonus-node list, and a dynamic
legend listing only the glyphs actually present (`hacking_render_legend`).

#### Notable engine-internals findings

Useful to other RE Engine modders; all derived from in-game captures.

- **Sticky-bomb row/column removal never changes the grid dimensions.** Removed
  rows/cols are flagged per cell (`Grid.<IsSkipRow>/<IsSkipCol>`), tracked as
  index lists on `GridAccessor` (`get_SkipRow()`/`get_SkipCol()`), and restored
  over time by `expansionRow()`/`expansionCol()`. `GRID_ACTUAL_SIZE_X/Y` keeps
  reporting the full size, so a reader that ignores the skip flags renders rows
  that no longer exist — and a dimension-based structural check misses both the
  removal and the gradual restore.
- **The red error nodes are not a `_GridType`.** They read as plain `None`; the
  live marker is `Grid._ObstacleReasons`, a bitmask of `ObstacleReason`
  (`ObstacleGrid=1` verified in-game, plus `DeadFilament=2`, `Ch16092=4`,
  `Ch14100=8`, `AllPassed=16`). The engine sets and clears bits mid-fight, so
  treat it as dynamic state, not authored layout. A cell reader keyed only off
  `_GridType` cannot see them at all.
- **`_NextMovePosition` is the move-dispatch entry point.** Writing an absolute
  target cell into this polled `via.Int2` routes the move through the engine's
  own input pipeline with every side effect intact. Calling `Unit.move(via.Int2)`
  instead *teleports* the cursor and bypasses all of them.
- **Polled state fields propagate; one-frame `*Trg`/`*Trigger` fields silently
  drop writes.** Value-type fields must be mutated on an engine-supplied
  wrapper — a fresh `sdk.create_instance("via.Int2")` exposes no writable fields
  on the builds tested.
- **`_IsGoldenPath` is deliberately not rendered.** It marks the engine's own
  auto-hack route and floods most walkable cells; rendering it as the blue-node
  marker would bury the real bonuses and hand the peer a pre-solved path.

---

## The other hacking puzzles

`pragmata_enemy_hack_plan` covers the cursor-routing grid that appears on enemies. The
game has four more hacking minigames, used on environmental interactables —
switches, doors, elevators. They are entered the same way, use the same
controls, and produce the same outcome, and each has its own action.

Why one action per family rather than one polymorphic action: the mechanics have
nothing in common — turn a piece, press a sequence, slide a tile — so a shared
schema would be a union of unrelated fields with a description that contradicted
itself most of the time. The observer only ever offers the one action that
matches the puzzle in front of the player, so the peer is never choosing.

All four are auto-forced on start, exactly like the grid, and all four **defer**
their result: the tool result reports what the hack actually did, not that a
plan was accepted.

### `pragmata_enviro_hack_rotate` — circuit hack

One to four connectors around a centre, each of them one circuit to close. A
circuit is a line that starts at a source on the edge of the board and runs
through fixed cells and one connector into the centre; the connector closes it
when it **joins its line to the centre, both ends lined up**. Pointing at the
centre is not enough — an elbow with one arm on the centre and the other off
its line stays dark. Some variants run on a timer.

This was measured, not reasoned: replaying 175 recorded board states against
the game's own connected flags, "a line runs from its edge source into the
centre" matches the game and "whatever the centre can reach" does not (79
states wrong), and a turn made by hand that left an arm on the centre put the
whole line out.

```json
{"rotations": [{"piece": "up", "steps": 1}, {"piece": "left", "steps": 3}]}
```

`piece` names a connector by **the direction button that turns it**, measured on
the board rather than deduced from it. `steps` is how many
presses to give it, 1 to 3; each press is a quarter turn and four is back where
it started, so 4 or more is refused without pressing anything. Connectors left
out of the answer are left alone.

The render no longer promises which way a press turns. Which way it turns is a
fact about the board's own frame — a mirrored one runs the other way — so it
is measured from the first press that moves an elbow, and the openings listed
beside every press count are computed from the measured direction. The peer
never has to know which it is.

Most connector lines end in **`PRESS n to close it`**, and that
number is the answer for that connector. The board is solved as a WHOLE to get
it: the mod searches every combination of connector orientations for the cheapest
one that leaves every connector connected, having first checked that its model of
the wiring reproduces the engine's own connection flags on every cell of that
board. Where that check fails, or nothing connects everything, the count falls
back to a per-connector rule, and failing that the line spells out all three
options and says so.

The opening names beside each count ("up+right") are the board's own names
for its grid, not directions on screen — the boards are transposed — so they
appear only to tell the counts apart. Each new round is treated as a new board:
the mod fingerprints every fixed cell, so a round that reuses the previous
round's source positions with different lines is solved afresh rather than
inheriting the old answer.

Solving the board whole is what makes a connector sitting NEXT TO another
connector answerable at all. The per-connector rule cannot speak for one: what
the neighbour will end up opening onto is not settled, so no number could be
stood behind. In the 2026-09-08 capture that case carried 103 of 138 forces.

The render draws no board: the player sees rows, not a grid, and the ASCII board
the mod used to send was both unlike the screen and — because the side labels
came from raw grid offsets — liable to name the wrong side entirely.

**The names are measured, not deduced.** Before the force goes out the mod
presses each direction once and records which connector moved; that pairing is
what `piece` means. The four presses cost a quarter turn each and are taken
before the peer is shown anything, so the state block always describes the board
as it is after them. Where a button turns nothing, no connector is offered under
that name. Earlier versions worked the side out from the grid's orientation and
could be confidently wrong, which showed up as answers being applied to a
connector the peer had never described.

Sample render:

```
Circuit hack: 3 circuits to close, 1 of 3 already connected. Each one is a
line running in from the edge of the board through one connector to the centre,
and the connector closes it when it JOINS its line to the centre -- both ends
lined up. Pointing at the centre is not enough.

  up     the connector the up button turns -- call it "up"
         opens up+left now -- not connected
         PRESS 2 to close it   (1 -> up+right, 3 -> down+left)
  left   the connector the left button turns -- call it "left"
         opens left+right now -- ALREADY CONNECTED, leave it alone
```

**The answer is re-checked against the board before it is pressed.** This puzzle
is driven by the same buttons as player movement, so the board can move while
the peer is thinking — and in the 2026-09-08 capture it did, forty-six times,
each one costing a retry as the mod pressed a connector that had already reached
the orientation the answer was asking for. A press count plus the openings it
was read against name one absolute orientation, so the mod re-expresses the
answer on the live board: a connector that drifted onto its target is dropped,
one that drifted past it is turned the rest of the way round, and the plan still
ends exactly where the peer intended with no input it did not ask for. Nothing
about how to answer changes; the correction happens after the reply.

The tool result reports what the board did, settled rather than sampled in the
same frame as the last press: a hack the game completed comes back as a success,
and a hack that did not says how many connectors are connected and how many
presses the engine dropped on the way. One result is about the board rather than
the answer — *"every connector you named had already reached the orientation you
asked for, so nothing was pressed"* — and it comes with a fresh state block; it
means the drift above went the whole way, not that the answer was wrong.

**A board with nothing to press is not forced at all.** A force is a question,
and 28 of the 79 circuit forces in the 2026-09-08 capture asked one while telling
the peer to leave every connector alone. When the mod can see no press worth
making it waits instead, and says once, quietly, that the board reads as already
correct. If such a board still has not completed a few seconds later the mod's
own reading is wrong, so the force goes out anyway carrying a warning that says
exactly that — judge the board yourself and turn whichever connector looks off.

### `pragmata_enviro_hack_sequence` — sequence hack

A ring of direction prompts that must be entered in order. Two variants: one
plain, one with a rotating needle that each press has to land inside.

**The peer never times anything.** A window a few frames wide is unreachable
across a websocket round trip, so the peer supplies the answer and the mod fires
each press on a frame the engine says would count, gated on the engine's own
"is the needle inside the window" flag. There is no time pressure on the reply.

#### Groups

How the puzzle is shown, and the shape of the answer, is one of five **groups**,
set by `mod_config.puzzle_sequence_group` (default `1`). Each group passed the
seqbench prompt bench (`reframework/seqbench/`) with a peer answering without a
thinking pass. The action's description, its schema and the force's query all
follow the group, so a peer always sees one consistent format.

| # | Group | Shown as | Answer |
|---|---|---|---|
| 1 | `cross+arms+hints+letters-both` (default) | one line per arm, with a distance ruler, numbered reading steps and a worked example; letter buttons | `buttons`: `{button, distance, direction}` per letter |
| 2 | `cross+hints+letters-side` | the 2-D cross, with the same aids; letter buttons | `buttons`: `{button, direction}` per letter |
| 3 | `list+compass+shuffle` | compass points, numbered by press but shown out of order | `order` |
| 4 | `list+compass` | compass points, in order | `order` |
| 5 | `list` | the original list | `order` |

The group can be switched for the session in the REFramework menu under
**Pragmata Puzzle Debug → Sequence hack group**. The switch is not saved. It
re-registers the action: `actions/unregister` for `pragmata_enviro_hack_sequence`, then
`actions/register` with the full action list, carrying the new description and
schema (the other actions are already registered, so a Neuro-SDK peer ignores them;
a peer that treats each register as the whole catalogue keeps them). A switch is refused
while a sequence force is waiting for its answer, because that answer would come
in the old format.

#### The drawn groups (1 and 2)

The prompts are drawn on screen for the player, and the whole ring is visible at
once. The render gives the peer the same information, as a picture to decode.
`0` is the centre, each arm is a row of button slots, `-` is an empty slot and
`*` is filler. Every drawn character is separated by a space, so each slot is its
own token.

Each button is drawn as a **letter**. The letters are shuffled per puzzle, so
`a` is never simply the first press; the same puzzle keeps its letters across a
replan. A letter's direction is the arm it is on, and its distance is how many
slots it sits from `0`. Press *i* of *n* sits *n − i + 1* slots out, and every
distance holds exactly one button. The peer describes each letter, and the mod
sorts the presses farthest first.

Group 1, for the sequence up, right, down, left:

```
        1 2 3 4
up    0 - - - c
down  0 - d - -
left  0 b - - -
right 0 - - a -
```

```json
{"buttons": [{"button": "a", "distance": 3, "direction": "right"},
             {"button": "b", "distance": 1, "direction": "left"},
             {"button": "c", "distance": 4, "direction": "up"},
             {"button": "d", "distance": 2, "direction": "down"}]}
```

Group 2 draws the same puzzle as a cross with its edges numbered, and is
answered with directions only; the mod knows each letter's distance:

```
  4 3 2 1 0 1 2 3 4
4 * * * * c * * * *
3 * * * * - * * * *
2 * * * * - * * * *
1 * * * * - * * * *
0 - - - b 0 - - a -
1 * * * * - * * * *
2 * * * * d * * * *
3 * * * * - * * * *
4 * * * * - * * * *
```

```json
{"buttons": [{"button": "a", "direction": "right"}, {"button": "b", "direction": "left"},
             {"button": "c", "direction": "up"}, {"button": "d", "direction": "down"}]}
```

Before either drawing, the state carries numbered reading steps and a worked
example drawn by the same code and marked as not the live puzzle.

The following are **refused without pressing anything**, each with its reason
(`Nothing was pressed: …`):
- an unknown letter, a letter given twice, or a letter left out;
- an unknown direction;
- in group 1, distances that do not run from 1 to the number of buttons with
  none repeated.

A rejected sequence's tool result lists only the presses made, never the
directions asked for.

#### The list groups (3, 4 and 5)

The directions are written out:

```
On screen, in order: 1.up  2.right  3.down  4.left                                  (5)
On screen, in order: 1.north  2.east  3.south  4.west                               (4)
On screen, numbered by press but shown out of order: 2.east  4.west  1.north  3.south   (3)
```

Compass groups add `north = up, south = down, west = left, east = right`. The
answer is always the plain directions in press order:

```json
{"order": ["up", "right", "down", "left"]}
```

`order` must have exactly as many entries as the puzzle wants. A short or long
answer is refused without pressing anything, because a wrong-length sequence
fails the hack outright. A rejected sequence's tool result names the word each
press was asked for, as shown: `up(asked north) left(asked east)`.

#### All groups

The order is read from the puzzle's own button list, the one it checks presses
against. Until 2026-09-11 it was read from the GUI's copy, which came back
undecodable, so every force said `1.?  2.?  3.?` and the peer could only guess.
**A sequence the mod cannot read is not forced at all**: a guess fails the hack
on its first wrong press. The peer is told once, quietly, that the directions
could not be read and the player can enter them.

Each press waits until the puzzle's step counter shows the one before it has
registered, so a dropped press cannot shift the rest onto the wrong steps. If
part of the sequence is already entered, give the whole sequence anyway; the
mod skips the steps that are done. If the game rejects a press, the remaining
presses are cancelled and the tool result says after which press it failed.

### `pragmata_enviro_hack_slide` — pipe hack

Sliding tiles with one empty space; complete an unbroken pipe from source to
goal.

```json
{"moves": ["up", "left", "left", "down"]}
```

Each move names the direction the **empty space** travels, so `"up"` pulls the
tile above the gap down into it. A move that would push the gap off the board
does nothing.

### `pragmata_enviro_hack_path` — path hack

Turn pieces until a path runs across the board.

```json
{"rotations": [{"column": 2, "steps": 1}]}
```

Pieces are addressed by column, numbered from 0 at the left; the render says
which columns can be turned. The selection is walked to each column for the
peer, so the entries can be listed in any order.

### Availability

`pragmata_enviro_hack_slide` and `pragmata_enviro_hack_path` cover two families that have not
yet been seen in a live capture — their readers and input mapping are written
from the type dump. They are **off by default** (`mod_config.puzzle_kinds`) and
are not registered until enabled. With them off, those puzzles are still
detected and narrated; they just aren't offered to the peer.

---

## Context messages emitted by the mod

Sent as Neuro-SDK `context` messages with `silent: true`. Every example below is
verbatim from a real session.

### Dialogue

```
Dialogue: [Conversation] Diana says "Let's finish this!"
Dialogue: [Conversation] Hugh says "Check."
```

Format is `Dialogue: [<Type>] <Speaker> says "<text>"`, or
`Dialogue: [<Type>] "<text>"` when no speaker resolves. `<Type>` is the
dialogue category from the engine's `MessageInfo`. Multi-line wrapped subtitles
are combined, so each utterance is forwarded once.

Collectible documents, when `mod_config.archive_gui_path` is configured, arrive
as `Collectible document text: "…"`.

### Ability state

| Trigger | Example |
|---|---|
| Overdrive becomes ready | `Overdrive is ready.` |
| Auto-Hack upgrade unlocks | `Auto-Hack upgrade is now available.` |
| Scan results resolve (scans the player makes; the peer's own come back as its result) | `Diana scanned: 1x escape hatch (32 m), 1x Upgrade Components (49 m).` |

The gauge's 25 / 50 / 75 % steps are no longer sent (until 2026-10-11 they were,
as `Hacking gauge: 75%`): a stream of small updates is what BEST_PRACTICES.md
asks integrations not to send, and readiness is the one that changes what the
peer can do.

### Hack lifecycle

| Trigger | Example |
|---|---|
| Grid appears | `Hacking grid started.` |
| Grid changed under an in-flight plan | `Hacking grid changed; replanning.` |
| Grid reset | `Hacking grid was reset.` |
| Terminal outcome | `Hack succeeded.` / `Hack failed.` |

The same lines cover the environmental hacks, with the subject naming what is
being hacked rather than a grid:

```
Device hack started.
Circuit hack started.
Sequence hack changed; replanning.
```

`Hack succeeded.` / `Hack failed.` are unchanged for every kind — the outcome
reads the same whether it was an enemy or a door.

Outcomes are reported from two places. The primary one watches the puzzle the
player is aimed at. The backstop watches the player's own status, which carries
the success/fail flags regardless of aim, and reports an outcome the first
source missed — a hack finishing after the player has already turned away.
Only one line is emitted per outcome.

### World state

| Trigger | Example |
|---|---|
| Scene/area transition | `Hugh and Diana entered a new area.` |
| Checkpoint activation | `Checkpoint reached.` |
| Combat starts | `Combat started.` |
| Combat ends | `Combat ended.` |

Combat must read the same for ~2 s before it counts, so a flag that flickers at
an encounter's edges does not send start / end pairs.

The mod does **not** send internal scene or checkpoint codes — only opaque hash
identifiers are used internally for transition detection. The one name it does
send is the map area's player-facing name, below.

### Game state

Silent context, each switchable in `mod_config.lua`:

| Trigger | Example | Switch |
|---|---|---|
| Entering a new map area | `Hugh and Diana entered a new area. Current location: <sector>, <area>. Map completion here: 60%. Still to collect (3 of 12): 2x Upgrade Components, 1x Archive.` | `state_push_area_summary` |
| HP falls below a threshold (downward only) | `Hugh is down to 22% HP (88/400) with 1 repair kit left.` | `state_push_low_health`, `state_low_health_thresholds` (default 50% / 25%) |
| The set of equipped weapons changes (a field pickup equips the new weapon); ammo is not compared; a save load is not announced | `Weapon equipped: <name>.` / `Weapon unequipped: <name>.` | `state_push_new_weapon` |
| The set of equipped hacking mods changes; remaining uses are not compared; a save load is not announced | `Hacking mod equipped: <name>.` / `Hacking mod unequipped: <name>.` | `state_push_hacking_mods` |

While the area summary is on and resolving, it replaces the bare "entered a new
area" line above. Baselines reset on every loading screen, so loading a save
announces neither the whole arsenal nor a drop from full health.

### Catalogs (Shelter only)

Silent context when a [catalog](#catalogs) gains an entry, sent **only while
in the Shelter**. A gain made outside it moves the baseline quietly, so it is
not announced later either. Wording is fixed; the names are examples (these
lines have not yet been captured from a live session).

| Trigger | Example | Switch |
|---|---|---|
| A Data Library entry is found | `New Data Library entry: 'Cradle Infiltration Log - Day 1' in Secrets.` | `catalog_push_library` |
| A Bot Database figure is collected | `New Bot Database figure: Walker.` | `catalog_push_bot_database` |
| A Training Simulation becomes available | `New Training Simulation available: Lightning Speed.` | `catalog_push_simulations` |
| An Earth Memory is obtained | `New Earth Memory: Globe.` | `catalog_push_earth_memories` |
| An Earth Memory is placed (Diana's cutscene) | `Earth Memory placed in the Shelter: Globe.` | `catalog_push_earth_memories` |

Several gains at once are joined with `; `. The collections are compared about
every two seconds, and a change must hold for two readings. More than six new
entries at once is taken as a save load, not an unlock, and is not announced;
loading screens reset the baselines. The Archive has no push.

### Autonomy nudges (opt-in)

When `autonomy_nudges` is true in
[`mod_config.lua`](autorun/pragmata/mod_config.lua), the mod emits an in-combat
hint at most once per `autonomy_nudge_interval_frames` (default ~30 s):

```
Combat is active. Available now: Overdrive Protocol is ready; Auto-Hack is available. Consider using these abilities if it would help Hugh.
```

The available set is recomputed on each emission; if nothing is available, no
nudge fires.

## Wire protocol notes

Standard Neuro-SDK message shapes throughout. The mod sends:

- `startup` on connect
- `actions/register` immediately after startup
- `context` for all the categories above
- `actions/force` when a scene stops on the Overdrive button prompt, naming
  `pragmata_overdrive` (see [Scene prompts](#scene-prompts))
- `actions/force` on any hack starting, with `action_names` naming the one
  action for that puzzle family, `ephemeral_context: true`, the rendered board
  in `state`, and a `priority` of `"low"` / `"medium"` / `"high"` /
  `"critical"` (omitted if the setting is unrecognised)
- `action/result` in response to incoming `action` commands
- with `mod_config.action_descriptions = "short"`: one-sentence descriptions,
  the hacking rules at the top of each force's `state` (`## Rules`), and the
  other long descriptions once as a context message after startup

The mod handles incoming `action` and `actions/reregister_all` commands; the
latter re-sends `startup` and the full action list (the sidecar sends it to the
mod on every WebSocket connect). Other Neuro-SDK message types are not
currently produced or consumed.
