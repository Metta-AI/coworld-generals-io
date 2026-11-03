# Generals BASIC policies

Upload raw UTF-8 BASIC source with `coworld upload-policy --file player.bas`.
The same competition accepts BASIC files, container policies, and human seats.
Files need no Docker image or WebSocket client. Start from `players/baseline.bas`.
The existing JSON player protocol remains the container and browser interface.

## Decision interface

The game compiles each policy once using Bassy, then restarts its program at
each observation. Globals and arrays persist between turns. No action defaults
to a pass. The first accepted action function wins; later action calls return 0.
`END` finishes the current decision, not the match.

Read-only integer data: `turn`, `slot`, `height`, `width`, `max_turns`,
`my_land`, `my_army`, `opp_land`, and `opp_army`. Slots and coordinates are
zero-based. Coordinates use `(row, column)`.

| Function | Result |
| --- | --- |
| `tileType(row, col)` | 0 fog, 1 plain, 2 mountain, 3 castle, 4 general, 5 structure in fog. |
| `owner(row, col)` | 0 neutral/unknown, 1 self, 2 opponent. |
| `visibleOwner(row, col)` | 0 neutral/unknown; otherwise absolute owner slot + 1. |
| `army(row, col)` | Visible army count; 0 in fog. |
| `buildCost(row, col)` | Price on eligible owned plains; 0 otherwise. |
| `playerArmy(slot)`, `playerLand(slot)` | Public per-player totals. |
| `playerEliminated(slot)` | 1 if eliminated, 0 otherwise. |
| `move(row, col, direction, split)` | Select move; 1 accepted, 0 rejected. Directions: 0 up, 1 down, 2 left, 3 right. Split: 0 all-but-one, 1 half. |
| `buildCastle(row, col)` | Select construction in building mode; 1 accepted, 0 rejected. |
| `pass()` | Select a pass; 1 accepted, 0 if an action was already selected. |

Out-of-board queries return -1. Action acceptance validates shape and bounds;
ownership, combat, and affordability still follow ordinary game rules. Invalid
game actions have the same no-op behavior as container actions.

The policy receives only its own fog-filtered observation and public scores.
No hidden map, private seed, opponent action, or connection token enters its VM.
Eliminated players stop receiving decisions. BASIC seats use the same match
rules, general trades, scoring, and replay format as other seats. FFA bots allow 50,002 engine ticks; classic/build bots allow
2,000; paced human variants allow 1,200. See [modes](VARIANTS.md#modes).

## Limits and failures

Each policy runs in a separate process with 256 MiB address space, 120 seconds
of CPU time per episode, and no core dumps. BASIC exposes no filesystem,
network, shell, or process functions. Only the game-owned functions above are
registered. Native callbacks check coordinates before reading grids.

Limits per policy:

- Raw source: 256 KiB; bytecode: 100,000 instructions.
- Logical VM memory: 8 MiB; arrays: 100,000 elements.
- Each decision: 200,000 VM instructions and 200,000 work units.
- Each decision's PRINT output: 4 KiB and 256 events.
- Total retained private log: 10 MiB. Further output is drained and discarded.

Bassy's bounded string and call-depth defaults also apply. Compile errors,
runtime errors, and exhausted budgets end the episode with a typed player
failure. They never publish competitive scores. Details stay in the failing
seat's private log. Infrastructure launch failures remain game/platform errors.
File logs and diagnostic status are closed before results are published.

The VM is pinned to Bassy `a9effcaab13abc9dfe42d7658cf87ee4783b0e14`,
with Fixxy `05e5446dffb70093056cebb0c57721a60deaf52a`, matching Polyworld's
published dependency lock when this integration was prepared.

## Local verification

Build the game and player images with a Coworld SDK that supports `player_runtime` lists:

```bash
coworld build --project integrations/softmax --version VERSION
coworld run-episode integrations/softmax/dist/coworld_manifest.json
coworld run-episode integrations/softmax/dist/coworld_manifest.json --variant competition --player-file 0=player.bas
coworld certify integrations/softmax/dist/coworld_manifest.json
```

Use league lobbies for human/BASIC/container games. Bundled players include
BASIC Frontier, Expander, and Builder. The certification fixture exercises all
three in four-player FFA; release checks also exercise classic and castles.

The direct local launcher also accepts repeated `--basic SLOT=PATH` options.
Set `GENERALS_BASIC_WORKER` to a locally compiled worker binary first.
It also requires Linux's `prlimit` (from util-linux). The Docker game target
builds and installs the worker automatically; `pip install` does not compile it.
Use [`Dockerfile`](Dockerfile)'s `basic-build` stage for the pinned Nim,
Bassy, and Fixxy inputs when building a native worker.

```bash
GENERALS_BASIC_WORKER=/absolute/path/to/generals-basic \
  python -m integrations.softmax.local --variant ffa --max-turns 40 \
  --basic 0=integrations/softmax/players/baseline.bas
```

Live skill queries use the public leaderboard snapshot taken at match start.
`playerRated(slot)` returns 1 for a rated seat, otherwise 0. `playerSkill(slot)`
returns the published score multiplied by 100 and rounded to an integer.
For example, −2.34 returns −234. Check `playerRated` to distinguish unrated from zero.
