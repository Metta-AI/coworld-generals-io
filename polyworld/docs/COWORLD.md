# CoWorld package

Generals uses CoWorld's `game-hosted` player runtime. One Linux AMD64
container runs the deterministic simulation and a separate bounded BASIC
VM for every seat. Matches support 2 to 10 FFA players. File policies do
not need their own containers or a gameplay WebSocket connection.

## Release inputs

| Path | Purpose |
| --- | --- |
| `Dockerfile` | Build the native headless CoWorld executable. |
| `compose.yaml` | Declare the `game` image for CoWorld's builder. |
| `.dockerignore` | Exclude local output, caches, and unrelated files. |
| `dependencies.lock` | Pin every Nim dependency to a Git commit. |
| `coworld_manifest_template.json` | Define schemas, documentation, players, and fixtures. |
| `examples/scout.bas` | Bundled file policy used in every certification seat. |
| `tools/build_replay_viewer.sh` | Build the standalone browser replay bundle. |

The template deliberately omits `game.version` and uses `{{GAME_IMAGE}}`.
`coworld build` inserts the requested version and the Compose image, then
copies the player file and browser bundle beside the generated manifest.
Do not commit generated `dist/` contents.

The package declares a two-player Duel and a ten-player Competition.
Both use seeded automatic map dimensions and a 4,000-tick limit. The
certification fixture runs ten Scout policies. Other roster sizes from
2 through 10 are valid when the configured players, runner tokens, and
staged seats all have the same length.

## Build and local verification

Install Nim 2.2.10, a C compiler, Git, Emscripten, Docker with Compose, and
a current CoWorld CLI. Docker must support Linux AMD64 containers. The
CoWorld CLI must support game-hosted file players, bounded variable
rosters, and static replay build hooks.

From the repository root, fetch the pinned dependencies and check the
native game:

```sh
./tools/fetch_deps.sh
nim check --skipParentCfg:on src/generals.nim
nim r tests/tests.nim
nim c --skipParentCfg:on -d:release -d:coworld -o:out/generals-coworld src/generals.nim
python3 tools/check_coworld.py --executable out/generals-coworld
```

Build the browser viewer by itself when iterating on replay playback:

```sh
./tools/build_replay_viewer.sh "$PWD/out/replay-viewer"
```

Build the complete local CoWorld package:

```sh
COWORLD_AGENT_GUIDANCE=0 coworld build --project . --version 0.1.0
```

Private dependencies need GitHub credentials inside Docker's build step.
When authenticated with `gh auth login`, use this alternative build command:

```sh
(
  set -eu
  umask 077
  generalsTokenFile=$(mktemp)
  trap 'rm -f "$generalsTokenFile"' EXIT HUP INT TERM
  gh auth token > "$generalsTokenFile"
  chmod 600 "$generalsTokenFile"
  export COWORLD_GITHUB_TOKEN_FILE="$generalsTokenFile"
  COWORLD_AGENT_GUIDANCE=0 coworld build --project . --version 0.1.0
)
```

Compose passes this file as the optional BuildKit `github_token` secret.
The Dockerfile reads it only while fetching pinned dependencies. The token
is not copied into the image, passed as a build argument, or printed. The
temporary file is removed when the subshell exits. Without this variable,
Compose uses `/dev/null` and public dependencies can build anonymously.
Local dependency fetches and the browser build use the host's normal Git
credential configuration. `COWORLD_AGENT_GUIDANCE=0` keeps the CLI from
adding agent guidance files while preparing the package.

The build pulls base images, builds and tags a local game image, and
writes the package. It does not upload or publish the game. It also pins
the source URL to the checkout commit, so a future release should be built
from the committed revision that will be submitted.

The output includes:

```text
dist/
  coworld_manifest.json
  examples/scout.bas
  replay-viewer/
    index.html
    ... generated JavaScript, WebAssembly, and assets
```

Run the default ten-player fixture and certification locally:

```sh
COWORLD_AGENT_GUIDANCE=0 coworld run-episode dist/coworld_manifest.json
COWORLD_AGENT_GUIDANCE=0 coworld certify dist/coworld_manifest.json \
  --no-open-report --timeout-seconds 120
```

Use the generated replay to verify the browser viewer renders, starts at
tick zero, plays and loops automatically, supports seeking and POV
selection, and reports loading errors. The same action tape can also be
verified by the native executable:

```sh
nim c --skipParentCfg:on -d:release -d:headless -o:out/generals-sim src/generals.nim
./out/generals-sim --headless --replay PATH_TO_REPLAY
```

With Playwright and Chromium installed, run the browser acceptance checks
against the generated bundle and a native-verified replay. Set `--end-tick`
to the replay's final tick reported by the native verifier:

```sh
python3 tools/check_browser.py --bundle dist/replay-viewer \
  --replay PATH_TO_REPLAY --end-tick FINAL_TICK
```

The check uses CoWorld's browser security policy and verifies initial
playback, looping, every replay hash, pause, stepping, seeking, speed,
resizing, compressed replay loading, and visible errors. Screenshots and
the JSON report are written under `out/coworld/browser/`.

The same hosted contract checks can run against the Linux image:

```sh
python3 tools/check_coworld.py --docker-image polyworld-generals:latest
```

`coworld play` and hosted human lobbies are not available for game-hosted
file policies. Use automated episodes and replay viewing for the CoWorld
package. The normal desktop game still supports local human play.

## Runtime contract

The CoWorld build reads these runner-supplied environment variables:

| Variable | Value |
| --- | --- |
| `COGAME_CONFIG_URI` | Absolute local `file://` URI for runtime JSON. |
| `COGAME_PLAYER_SEATS_URI` | Absolute local URI for the staged seat document. |
| `COGAME_RESULTS_URI` | Local destination for the final result JSON. |
| `COGAME_SAVE_REPLAY_URI` | Local destination for the Polyworld replay. |
| `COGAME_PLAYER_FAILURE_URI` | Local destination for a terminal policy failure. |
| `COGAME_HOST` | Optional listen address, default `0.0.0.0`. |
| `COGAME_PORT` | Optional listen port, default `8080`. |

Runtime JSON requires runner-managed `tokens`, `players`, `seed`, and
`max_ticks`. Authored variants and certification configs omit `tokens`.
Each player supplies `name` and optionally `mmr`, where `-1` is unknown.
The rank must fit a signed 32-bit integer. `expose_player_info` defaults
to true and controls BASIC name and MMR queries.

Seeds range from 0 to 2147483647. Hosted limits are 1 through 28,800 ticks,
with a 4,000-tick default. This hosted upper bound comes from the pinned
Polyworld CoWorld runtime. Local standalone matches retain their
100,000-tick upper bound. A simulation tick represents half a second of
game time, independent of headless execution speed. `width` and `height`
are independently 0 for seeded automatic sizing or 13 through 61. Custom
maps must still satisfy general spacing and connectivity.

The seat document accepts `coworld-player-seats/1` and
`coworld-player-seats/2`. Seat slots are consecutive and zero-based. Each
seat supplies a staged file URI, content hash, size, private log URI, and
optional annotation or artifact locations. The platform verifies the
content hash before launch; the Polyworld loader also verifies file size.
The staged filename need not have a `.bas` or `.zip` suffix.

Policies accept raw BASIC or ZIP packages with exactly one `.bas` file.
Input is limited to 16 MiB, 256 ZIP entries, 64 MiB decoded package data,
and 256 KiB BASIC source. Each decision permits 200,000 instructions,
400,000 work units, 4,096 PRINT bytes, and 128 PRINT events. Each seat has
4 MiB BASIC memory and 4 MiB native memory. No filesystem, network, or
process APIs are exposed to BASIC. See [BASIC bots](BOTS.md) for the
observation, action, identity, and mailbox interface.

PRINT, policy errors, and optional annotations stay in the owning seat's
private outputs. Package or compile errors publish the failing slot
through `COGAME_PLAYER_FAILURE_URI`. Runtime errors disable that policy
and let the game continue. Every seat receives a real log, including seats
that print nothing. The shared runtime bounds each log to 10 MiB.

The game saves its replay and closes player outputs before atomically
writing results. `scores` has exactly one value per slot: the sole winner
receives 1 and everyone else receives 0. Draws score 0 for all players.
Results also include `ticks`, `seed`, and `outcome`. The result schema
accepts the shared runtime's empty `banked_gold` and `returned` arrays.
The server stays alive for artifact collection and exits on SIGTERM.

`/healthz`, `/client/global`, and `/global` satisfy CoWorld readiness and
legacy status probes. The global WebSocket responds to Ping with Pong.
Game actions do not travel over that socket. The declared static viewer
handles replay rendering without a running game server.

## Browser replay contract

The manifest declares bundle `replay-viewer` and gzip compression.
`tools/build_replay_viewer.sh OUTPUT_DIRECTORY` must be executable and
produce a bundle containing `index.html` with relative asset references.
The viewer reads `#replay=` before the legacy `?replay=` parameter,
detects gzip from the downloaded bytes, and reports loading, ready, or
error through the CoWorld iframe message protocol.

Replay playback compiles the same Nim rules to WebAssembly, regenerates
the seeded map, and verifies each recorded tick hash. Replays contain
public roster data, moves, and public chat. They do not contain policy
source, private messages, PRINT output, or private reference materials.
The current bundle accepts replay version 4, with four-byte ordinary
commands. Older recordings require their archived game build and viewer.

## Private submission

Preparing and testing this package does not publish it. Publishing is a
separate action requiring the repository owner's authorization. Any
future upload must explicitly select private visibility. The CLI uploads
the game image, bundled Scout policy, and replay bundle without a separate
manual Docker push.

Hosted certification and the hosted smoke episode must both pass before
treating a submitted release as ready. Keep the GitHub repository private
and do not include private reference archives or implementation files in
the image or package.
