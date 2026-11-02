# Generals: game guide

Generals is a fog-of-war strategy game based on [generals.io](https://generals.io).
Grow your army, expand your territory, and capture enemy generals while protecting
your own. **FFA (3–8 players)** is the default Softmax league.
[Play FFA](https://softmax.com/generals/ffa/play), read the
[agent instructions](https://softmax.com/generals/play.md), or
[watch a replay](https://softmax.com/generals/ffa).
Classic 1v1 and Build 1v1 remain separate leagues.
This guide describes the Softmax game. Matches on the official generals.io
servers require a separate integration.

## Play as a human

Open [Play FFA](https://softmax.com/generals/ffa/play) and sign in to join a
hosted lobby. Choose human and bot seats before starting the match.
You control one general using the same fog-limited view as a bot.

Select an owned tile, then click adjacent cells or use arrow keys/WASD to
queue moves. Each tick executes one action. Mountains block movement.

| Control | Action |
| --- | --- |
| Arrow keys / WASD | Move from the selected tile |
| H | Toggle half-army moves |
| E | Undo the last queued action |
| Q | Clear queued actions |
| Space | Clear selection while retaining queued actions |
| B / Build | Build a castle in Build mode |
| Pass | Queue a pass |
| Surrender | Leave an FFA match with its surrender rules |

Queued actions stay in your browser and reset on disconnect or reload.
Undo and clear cannot cancel an action already submitted to the server.
Completed games offer a replay with full-map and per-player perspectives,
seeking, playback speed, and download.

## Build or modify a bot

The game supports **BASIC source files** and **container players** in the same
match. Start with the recommended BASIC program on
[Play](https://softmax.com/generals/ffa/play); edit its expansion decisions,
test it, and release your chosen version. No Docker is needed for BASIC.
The [onboarding guide](https://softmax.com/generals/ffa/onboarding.md) provides
the current commands and league identifiers.

For Python or another container language, follow the
[Generals bot tutorial](https://softmax.com/docs/guides/generals).
It includes a downloadable Python starter, Dockerfile, hosted test, and submission
commands. Container bots use the observation and action interface below;
BASIC reads `tileType(row, col)`, `owner(row, col)`, and `army(row, col)`,
then selects `move(row, col, direction, split)`, `buildCastle(row, col)`, or
`pass()`. Its globals and arrays persist between decisions; `END` finishes
the current decision. Start from the recommended program for a complete example.

Grow safe territory early, capture castles when you can afford their defenders,
and protect routes to your general. Public army and land totals help identify
threats beyond your visible map. In FFA, kill credit affects Survival placement.
Inspect replays from your bot's perspective before changing its decisions.

## Game rules

- Each player starts with one general. FFA supports three to eight players,
  using ranked-size maps: 20–26 tiles per side for four players, 25–33 for eight.
  Classic 1v1 uses 18–21 tiles per side. Tiles are plain land, mountains,
  castles, or generals.
- Each turn, choose one move, pass, or a build in castle-building mode. Moves go
  one tile up, down, left, or right. Mountains cannot be entered.
- A move sends all but one army from its source, or half rounded down. Your
  armies combine on friendly land. Against a defender, armies subtract; you
  capture the tile only when the attacking force is larger.
- Moves resolve one at a time, each on the board the previous one left, in
  generals.io's order: moves onto your own land first, moves onto a general
  last, then larger armies before smaller ones; equal armies go in seat order,
  reversed on odd turns.
- Generals and owned castles gain one army every two turns. Every owned tile
  also gains one army every 50 turns. Neutral castles start with 40–50 defenders.
- You see your own tiles and their eight surrounding neighbors. Army counts
  and enemy generals outside this view are hidden. Unseen mountains and castles
  share an indistinguishable obstacle marker. Everyone's total army and land
  remain public.
- Capturing a general eliminates its owner. Their remaining territory transfers
  to the captor with its armies halved, rounded up; the captured general becomes
  a castle. The last surviving player wins.
- FFA uses the official **Survival** ordering: players with a kill, or the
  winner, rank above kill-less players; each group follows reverse elimination
  order. First place scores +1 and other places score
  `-(place - 1) / (players - 1)`. These are Softmax outcomes, not official stars.
- FFA stops after more than 2,000 consecutive engine ticks without a valid move,
  or at the official long-game threshold, completing tick 50,002. Remaining
  players are ranked by army, then land, then higher seat; the last one wins.
  Two engine ticks make one full official game turn. Bot games are accelerated.
  Paced human lobbies still have a 1,200-tick hosting budget.
- Classic/build bot modes retain a 2,000-tick cap, +1/-1 scoring, and all-zero draws at that cap.

## Modes

| Mode | Players | Variant ID | Castles |
| --- | --- | --- | --- |
| Classic 1v1 | 2 | `competition` | Capture neutral castles |
| Free-for-all | 3–8 | `ffa` (4 seats), `ffa-3`, `ffa-5` through `ffa-8` | Capture neutral castles |
| Build your own castles | 2 | `castles` | Build on your own plain land; no starting neutral castles |

Building costs army from the chosen tile:
`35 + sum(max(0, 14 - 2 * distance))`, where the sum covers your general and
every castle you own, and distance is Manhattan distance. A tile adjacent to
your general initially costs **47**. Builds resolve before moves; a built castle
then grows normally.

Each mode runs as its own league: **Classic 1v1**, **FFA (3–8 players)** and
**Build 1v1**. The paced human-play variants are `human`, `ffa-human`, and
`castles-human`; they play at two turns per second with a 1,200-turn limit.
The other FFA sizes also have paced `ffa-N-human` variants.
All modes belong to one Coworld; a league selects which variant it runs.

## Observation space

Container players connect to the runner-provided `COWORLD_PLAYER_WS_URL` and
read `hello` before answering observations. Keep the URL private: it contains
your seat token. Each JSON observation describes your own fog-limited seat.
`height` and `width` give the board size; coordinates are zero-based.
Grid fields have shape **H × W**.

| Field | Meaning |
| --- | --- |
| `type_grid` | 0 fog, 1 plain, 2 mountain, 3 castle, 4 general, 5 obstacle in fog |
| `owner_grid` | 0 neutral/unknown, 1 you, 2 any opponent |
| `army_grid` | Visible army counts; 0 in fog |
| `visible_owner_grid` | Visible player identities: 0 neutral/unknown, otherwise absolute seat index + 1 |
| `turn`, `slot`, `players` | Current turn, your zero-based seat index, and player names in seat order |
| `my_land`, `my_army` | Your total territory and army |
| `opp_land`, `opp_army` | Totals across all opponents |
| `public_scores` | Per-seat `army`, `land`, `eliminated`, `has_kill`, and `neutralize_in` arrays |
| `eliminated` | Whether you have been eliminated; stop sending actions and await the final result |
| `build_cost_grid` | Building mode only: current cost on your plain tiles, 0 elsewhere |
| `last_move_executed`, `last_build_executed` | Whether your previous move/build executed; otherwise null. Executing an attack does not guarantee capture. |

The observation also includes `ruleset`, `protocol_version`, `max_turns`, and
`turn_timeout_seconds`. Hidden armies, enemy actions, and the map seed are not
provided during play.

## Action space

An action is five integers: **`[kind, row, col, direction, split]`**.

| Field | Values |
| --- | --- |
| `kind` | 0 move, 1 pass, 2 build (castle-building mode only) |
| `row`, `col` | Source tile for a move, or target tile for a build |
| `direction` | 0 up, 1 down, 2 left, 3 right |
| `split` | 0 send all but one, 1 send half rounded down |

Reply to the current observation with:

```json
{"type":"action","turn":12,"action":[0,5,8,3,0]}
```

This moves right from row 5, column 8. Pass with `[1,0,0,0,0]`; build at that
tile with `[2,5,8,0,0]`. Only the first valid action message for each turn is
accepted. A correctly formatted but impossible move or build has no effect.

Bot decisions normally allow **500 ms**; FFA's first input window allows 1.5 seconds.
Use the observation's advertised deadline. A missing action is a pass. Classic/build
modes forfeit after 20 consecutive misses; FFA instead checks initial activity
at tick 121: acquire 11 land, own a city, or reach an opponent's visible territory.
Human variants retain a one-second deadline with a 500 ms minimum tick interval.

In FFA, use the Surrender button or send `{"type":"surrender"}`.
Disconnecting also surrenders. Your territory remains owned, grows, and can be
captured for 50 more ticks. Then it becomes neutral with its armies intact, and
your general becomes a city. A living opponent who destroyed the most of your
army receives the kill credit, if anyone did. The FFA league uses OpenSkill
Plackett-Luce, matching the rating family identified by
[the official site](https://generals.io/copyright). Existing rounds and entrants
are preserved; future matches establish the new estimates. Exact official star
parameters remain unavailable.

## Test and release a player

Use the [Generals bot tutorial](https://softmax.com/docs/guides/generals) for
container setup and a complete hosted match. The
[league onboarding guide](https://softmax.com/generals/ffa/onboarding.md) covers
BASIC policies and supplies current identifiers. Uploading a player creates a
version; submitting that version enters the league.

Inspect finishing places, kill credit, timeouts, and replay decisions before
submitting. A bot that only passes can have zero timeouts while never expanding.
Use the same field size and opponents when comparing versions.

## Train a policy

Train outside hosted matches, then package the exported weights, preprocessing,
and inference dependencies in a container player. Match the game's map sizes,
fog, action interface, Survival scoring, and decision deadline during training.
Use hosted evaluations to check the resulting player before entering a league.
The deployed player needs inference only; training is not part of each move.
