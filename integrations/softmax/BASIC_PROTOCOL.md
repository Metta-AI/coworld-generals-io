# Generals BASIC policies

Upload UTF-8 BASIC source with `coworld upload-policy --file player.bas`, or a
Polyworld ZIP package containing exactly one `.bas` entry and optional resources.
The shared `readPolicy` loader detects packages by content, including the
platform's extensionless staged files. Package resources expose no filesystem API.
The same competition accepts BASIC files, container policies, and human seats.
Files need no Docker image or WebSocket client. Start from `players/baseline.bas`.
The existing JSON player protocol remains the container and browser interface.

## Decision interface

The game compiles each policy once using Bassy, then restarts its program at
each observation. Globals and arrays persist between turns. No action defaults
to a pass. The first accepted action function wins; later action calls return 0.
`END` finishes the current decision, not the match.

Native workers enable upstream's `bassyNative`: supported policies execute as
machine code while keeping the same VM budgets and host interface. Unsupported
native programs follow Bassy's interpreted path. CI builds with
`GENERALS_BASIC_NATIVE_STRICT=1` and exercises the bundled policy through real
mixed-seat episodes, so accidental loss of native compilation fails validation.
The browser replay never compiles or executes player policies.

The hosted worker and standalone app import the same `generals/policy_api.nim`
host, source binding and `policyLimits()`. An unmodified
`polyworld/examples/scout.bas` can play hosted container opponents.

The Polyworld interface uses flat tile indices (`row * width() + column`):

| Function | Result |
| --- | --- |
| `selfPlayer()`, `playerCount()` | Your zero-based seat and roster size. |
| `playerInfoEnabled()` | Whether public player identities are exposed. |
| `playerName$(slot)`, `mailboxName$(slot)` | Public name; empty for an invalid seat. |
| `playerMmr(slot)` | Published skill rounded to an integer; −1 when unavailable. |
| `playerRated(slot)`, `playerSkill(slot)` | Availability and exact integer hundredths, including negative scores. |
| `worldTick()`, `worldTurn()` | Engine tick and whole game turn (`tick div 2`). |
| `width()`, `height()`, `tileCount()` | Board dimensions and cell count. |
| `selfGeneral()` | Your current general's tile index. |
| `visible(index)` | 1 for visible terrain, otherwise 0. |
| `terrain(index)` | 0 plain, 1 mountain, 2 castle, 3 general; −1 fog, −2 fog obstacle. |
| `owner(index)` | Absolute zero-based owner; −1 neutral/unknown. |
| `army(index)` | Visible army count; 0 in fog. |
| `send(source, target, half)` | Select one owned cardinal move; 1 accepted, 0 rejected. |
| `sendChat(target, text$)` | Queue one message per decision; target −2 broadcasts, otherwise a zero-based seat. Returns recipient count, or 0 when rejected. |
| `pullMailbox$()` | Consume the oldest message, or return an empty string. |
| `mailboxId()` | Sender of the last pull; −2 for public chat/game events, −3 for an empty pull. |
| `mailboxCount()`, `mailboxSelf()`, `mailboxPlayers()` | Inbox size, own seat and roster size. |

The shared MessageHub delivers queued messages in seat order after every policy
has decided. A BASIC seat cannot see another seat's same-tick pending message.
Text is normalized to 140 Unicode characters, with one pending message per seat
and at most 100 inbox entries. Capture and result events use the same global
mailbox and take priority when an inbox is full. Private traffic reaches only
its recipient and never enters spectator updates or recordings. Public chat is
stored once in the compact replay and appears at its recorded tick.

Existing uploaded row/column policies retain these spellings through the same
host. They can use the Polyworld functions alongside them; no second VM or
separate rule implementation is selected. Free scalar input names are `turn`,
`slot`, `height`, `width`, `max_turns`, `my_land`, `my_army`, `opp_land`, and
`opp_army`. Standalone assignments such as `turn = worldTurn()` remain ordinary
persistent BASIC variables. Coordinates below use `(row, column)`.

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

Each policy runs in a separate process with 512 MiB address space, 1,200 seconds
of CPU time per episode, and no core dumps. BASIC exposes no filesystem,
network, shell, or process functions. Only the shared policy host and game-owned functions above are registered.
The process sandbox is an additional hosted isolation boundary; Docker players
retain their platform-owned resource contract. Native callbacks check coordinates before reading grids.

Limits per policy:

- Compressed policy package: 16 MiB; raw/extracted BASIC source: 256 KiB.
- Bytecode: 65,536 instructions.
- Logical VM memory: 8 MiB; native memory: 8 MiB. Array storage must fit the same VM budget.
- Each decision: 2,000,000 VM instructions and 4,000,000 work units, matching the standalone host.
- Each decision's PRINT output: 4 KiB and 128 events.
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
Run `integrations/softmax/tools/build_polyworld_runtime.sh /tmp/generals-runtime`
from the repository root to compile both native binaries with the pinned
Polyworld/Bassy/Fixxy dependencies. Docker's `runtime-build` stage and CI use
that same command; ad hoc `nim c basic_worker.nim` omits required compiler flags.

```bash
GENERALS_BASIC_WORKER=/absolute/path/to/generals-basic \
  python -m integrations.softmax.local --variant ffa --max-turns 40 \
  --basic 0=integrations/softmax/players/baseline.bas
```

Live skill queries use the public leaderboard snapshot taken at match start.
`playerRated(slot)` returns 1 for a rated seat, otherwise 0. `playerSkill(slot)`
returns the published score multiplied by 100 and rounded to an integer.
For example, −2.34 returns −234. Check `playerRated` to distinguish unrated from zero.
