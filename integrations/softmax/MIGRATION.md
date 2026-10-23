# Organization-owned Generals

## Provenance

The repository was renamed from `Metta-AI/cogame-gen-generals-io` to
`Metta-AI/coworld-generals-io` on October 15, 2026. Its implementation is imported
from `strakam/generals-bots` branch `softmax`, commit
`0fcb5a00226387670624d2f326f6d5ad61914584`. Both Git histories and the upstream
MIT attribution are retained. The import's first parent preserves the Nim tree.

The old `gen-generals-io` 0.1.1 release points to
`8fe03eabe41c2eacd666029b0bef1377faf937ce`. Its image and replay viewer remain
pinned; the new Python game does not interpret its `COWLDGEN` binary replays
or accept its prompt-plan players. No old episodes or leagues are migrated.

The active game is `generals-competition`, previously published as 0.3.3 from
`strakam/generals-bots` commit `f65fb55d90a1a3397ca89a9591b296b899cca127`.
Keep that game name and its six variant IDs. New releases change source ownership
without creating a duplicate competition.

## Official-engine alignment

The privately supplied engine is not included or licensed by this repository.
The original live-game bundle still lacks GameOptions, BadWords.js,
good-words.json, and dependency/bootstrap files. A separately supplied replay
core now includes Map and an updated MoveResolver, with its own smaller
Constants module. Keep the original live-game Constants separate.

The [private reference adapter](../../paper/validation/README.md#privately-supplied-replay-core)
can export base-game boards without the missing EventGameOptions or
EventReplaySimulation wrappers. This unblocks board comparison, not full live
engine, fog, event-statistics, or castle-building certification. Keep reference
source outside the checkout and all distributed artifacts. Record source hashes
and comparison results before claiming parity.

Use identical initial boards and action streams to compare complete games,
including FFA captures, simultaneous general trades, rounding, move dependencies,
growth, fog observations, surrender, and replay outcomes. Compare map generation
separately; identical numeric seeds across different generators are not equivalent.
Upstream replay-validation claims are historical evidence, not certification of
this release against the supplied engine revision.

## External-server bridge

`generals/remote` already connects a bot to a generals.io lobby. The deployment
bridge still needs the official lobby handoff/authentication agreement, bot/seat
identifiers, reconnect and cancellation behavior, and completion/replay callbacks.
Do not use the existing indefinite auto-force-start loop for human tournaments.
Diplomacy offer/accept events await the official update; agreements do not
restrict subsequent attacks or require either player to honor them.

## Release validation

Run the imported version before changing rules. Validate complete local FFA,
human play, standalone replay, container certification, and hosted operation.
Record release-specific commands and outcomes here before publishing.

### 0.4.0 preparation — October 15, 2026

- Imported FFA baseline: `python -m integrations.softmax.local --variant ffa
  --seed 7 --port 18380`; 2,000 turns, four zero timeout counts.
- Final FFA with the same command/seed: 2,000 turns, identical result and zero
  timeouts. The generated replay contains all four seats.
- `GENERALS_BROWSER_TESTS=1 python -m pytest -q`: 217 passed in 174.47 seconds.
  Existing browser coverage starts a real game, clicks a player move, waits for
  completion, and checks standalone desktop/mobile replay, gzip, and seeking.
- New complete-game regression walks two players across a generated map, exchanges
  generals, verifies both move receipts and survival, and validates saved results
  and replay. Disabling the trade rule fails this regression; restored behavior passes.
- The imported focused suite initially had 52 passing and two failing tests.
  Both failures were cancelled WebSocket cleanup. Shielding the owned-task join
  fixes them; the full suite above includes both checks.
- `python -m integrations.softmax.tools.manifest --check` and Python compilation pass.
- An amd64 image builds, but local emulation fails JAX's AVX guard. Use native
  arm64 certification on Apple Silicon, then rebuild amd64 for hosted validation.
- Full local platform startup was delayed by Nix downloads and disk exhaustion;
  no shared stack was stopped. Real game/browser checks above are independent of it.

The 0.4.0 rule change enables mutual general trades only for classic modes.
Castle-building retains its previous rules. The transition and action receipts
share the same resolver. Historical JSON replay frames still render directly;
resimulation must use each episode's pinned source revision.

Native arm64 container certification passed all ten checks for classic, FFA,
and castle-building. Container testing also exposed host-umask-dependent source
permissions; both image stages now make application sources readable before
starting unprivileged players.

The existing `Coworld release` workflow is retained with a new Python-game build
path and SDK 0.1.60. Dispatch it with the release version to build native amd64,
certify all modes, and publish using the repository's existing `SOFTMAX_TOKEN`.
It never skips certification or cancels an in-progress release. Local upload on
Apple Silicon cannot certify the amd64 JAX wheel because emulation lacks AVX.
