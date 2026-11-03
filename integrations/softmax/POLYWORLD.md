# Polyworld hosted runtime

The `polyworld/` tree imports all tracked files from
[Metta-AI/polyworld-generals](https://github.com/Metta-AI/polyworld-generals)
from its floating `main` branch. Its MIT license,
asset notices, native Silky application, experiments and original checks remain
beside the code. `polyworld/dependencies.lock` pins native application dependencies.
Private official reference sources are not part of this import.

Run `python -m integrations.softmax.tools.sync_polyworld` before preparing an
upstream update. It fetches the current `main`, imports its changes and preserves
our simulation receipts and trade switch. Overlapping edits fail before applying;
resolve those edits before building. Commit and validate the resulting source.
`polyworld-upstream.txt` records the last imported revision for incremental sync
and release provenance; it does not constrain the next upstream revision.
Release builds use the reviewed repository tree, so their source URL identifies
the exact code tested. The standalone package under `polyworld/` currently
accepts file players; our hosted adapter continues to support mixed seats.

## Ownership and execution

`polyworld/src/generals` owns the Nim simulation. The imported `step` now returns
executed-move receipts, capture order and damage, and accepts a general-trade
switch. Native callers retain their existing behavior.

`polyworld_bridge.nim` runs this engine in a persistent subprocess. It applies
hosted castle construction before ordinary moves and pays terminal-tick income.
`polyworld_engine.py` owns Coworld observations, FFA Survival placement,
surrender windows, inactivity and long-game adjudication. Neither bridge receives
connection tokens, policy source or private player logs.

`server.py` owns authentication, deadlines, mixed seats, result persistence and
browser sessions for both engines. `file_players.py` retains the isolated,
budgeted BASIC workers. Container players keep the existing JSON/WebSocket and
stdio contracts; existing BASIC policies keep the published BASIC contract.
The standalone native app's BASIC/mailbox API remains its separate interface.

The hosted game uses Polyworld's deterministic map generator. Hosted seeds use
their low 31 bits for identical native and WebAssembly arithmetic. Map dimensions,
layouts and seeds differ from the former JAX generator. This release does not
claim official map parity. Human seats retain the browser player client. Completed
matches use the actual Polyworld Silky viewer compiled to WebAssembly.
The native desktop application remains available under `polyworld/`.
Hosted variants still support two through eight seats, the same sixteen variant
IDs, all three leagues, both player artifact kinds and human seats.

## Build and run

The Coworld Compose game service targets Docker's `polyworld-game` stage.
The native hosted binary needs only Nim's standard library. The replay build
fetches the public native dependencies and uses Emscripten 5.0.7. The image
contains the compiled viewer and licenses; source dependency trees stay in its
build stage. `replay-dependencies.lock` supplies two transitive viewer libraries
omitted from the imported dependency list.
The game image contains no JAX runtime. The former Docker `game` target and
Python engine remain independently buildable.

```sh
nim c -d:release --mm:arc --path:polyworld/src \
  -o:/tmp/generals-polyworld integrations/softmax/polyworld_bridge.nim
GENERALS_POLYWORLD_ENGINE=/tmp/generals-polyworld \
  python -m integrations.softmax.local --variant ffa --max-turns 40
# Explicitly run the retained engine:
python -m integrations.softmax.local --engine jax --variant ffa --max-turns 40

python -m integrations.softmax.tools.manifest
coworld build --project integrations/softmax --version VERSION
coworld certify integrations/softmax/dist/coworld_manifest.json
coworld upload-coworld integrations/softmax/dist/coworld_manifest.json --wait-certification
```

`GENERALS_ENGINE=polyworld` selects the new backend in the shared server.
The generated manifest and new game image both set it. Completed replay files
record `engine: polyworld`, `format: polyworld-generals-hosted`, and `version: 1`.
They contain commands and a portable state hash after each command. Playback
rebuilds every tick through `polyworld_hosted.nim`, the same module used by the
game process, including builds, surrenders and delayed neutralization.
This hosted tape represents those additional operations separately from the
standalone application's binary v4 recordings. The retained JAX runtime keeps
its frame-based recordings and viewer; archived release bundles remain intact.

The server preloads the native replay bundle before joining browser seats.
After completion, it sends the saved tape over the established socket. The
preloaded viewer receives it through a parent/origin-checked message, so replay
controls and download keep working after the hosted HTTP proxy retires.
`/client/replay.json` returns the saved tape; `/replay.json` exposes completed
diagnostic frames. Neither endpoint reveals replay state during play.

For source browser checks, first build a local viewer:

```sh
integrations/softmax/tools/build_polyworld_viewer.sh "$PWD/polyworld/out/replay-viewer"
GENERALS_POLYWORLD_ENGINE=/tmp/generals-polyworld \
GENERALS_POLYWORLD_VIEWER="$PWD/polyworld/out/replay-viewer" \
GENERALS_BROWSER_TESTS=1 pytest tests/system/test_polyworld_system.py
```

For the imported native application's commands, run from `polyworld/` and follow
its [README](../../polyworld/README.md). Use the pinned dependency fetcher before
running the complete Nim suite. Core rules and hosted builds need no such fetch.
