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

### Hosted completion handoff — October 29, 2026

The live HTTP proxy can retire after results are saved. Browser clients now
request `replay=1` and receive the completed recording on their existing socket.
Both player and spectator views enter replay mode without another HTTP request.
Bot connections retain result-only terminal messages. Shutdown waits for owned
socket senders to finish instead of relying on a fixed delay. Hidden frames remain
unavailable until both replay and result artifacts are saved.

Validation for the next release, using Coworld SDK 0.1.60:

- `GENERALS_BROWSER_TESTS=1 python -m pytest -q`: 220 passed, one private-reference
  check skipped. This includes real player controls, reconnect, and static replay.
- The new system workflow returns HTTP 410 immediately after completion. Human
  play and spectating still reach replay, then seek and retain their download
  after server shutdown. The original implementation fails this workflow;
  restoring the change passes it.
- `python -m integrations.softmax.tools.manifest --check` and JavaScript syntax
  validation pass.
- Native arm64 build for version 0.4.2 and all ten container certification steps
  pass separately for classic, FFA, and castle-building.
- Certified game image:
  `sha256:54ecdc06342e19fb3609fb642dad0bd5ea9f32c304adeb35b175d864b1fc2357`.
  Certified player image:
  `sha256:8b1679a7981f945f1fa0fd97d432011c6bd2de4a6b4c103abb4493f3611265b8`.

Validation includes the full-height replay layout merged from main at `84a2005`.

These are local validation results. Publishing a canonical amd64 release still
uses the existing release workflow. Late navigation to an expired live URL is
owned by the platform proxy, which must resolve the episode's recorded replay.

### Ranked FFA map alignment — 0.5.0 preparation

FFA now accepts three through eight players. The new startup sampler follows
base-game ranked map generation, including squared-uniform dimensions,
player-count-dependent spacing and city budgets, mountain draws with replacement,
fair city placement, and rejection of blocked or city-starved spawns.
Four-player maps have 20–26 tiles per side; eight-player maps have 25–33.

The reference was the developer-supplied `GeneralsIOProbablyAllYouNeedInitially.zip`
(Constants version 31.4.4), with the separately supplied base Map. The supplied
JavaScript files remain external to this repository and distributed artifacts.
A local loader exercised the real `Game.tryInitializeGame`, `Terrain`, Map,
shuffle, and city-placement methods. Unavailable chat/options imports were
bypassed; options were supplied directly. This validates base FFA map sampling,
not the unavailable live server or its authentication and event wrappers.

With identical random-draw streams, all 600 generated boards matched tile for
tile, including the draw count: 100 seeds for each of 3, 4, 5, 6, 7, and 8 seats.
The comparison includes city-placement fallback and rejected-map retries.
[Comparison report](https://softmax.nexus/artifacts/9d7631a8-adef-42a9-b0ae-f82edcecd81b).

Reference SHA-256 identities:

| Input | SHA-256 |
| --- | --- |
| Original archive | `58de1a86022a97fc79a9905da0c27996fb86d104b7e34fd1cbf1994ce781e8f5` |
| Game.js | `3f93ed25346cec357414c8a3ab894938437c13bff747539f4c015e7945290c41` |
| Terrain.js | `a73ba43eb3e14b88b3bf9e285625bf9099fde67aaab3675bd3cbefced7ca803e` |
| Utils.js | `c8aba8420162a5df73035abe47b37d6f6c5eb0d2dba2560501adf64cc4d6711b` |
| Original Constants.js | `ce4d795ce1fd5c860a05276daa8987f21059795a8c135237bdde794f6cbe5c30` |
| Separate Map.js | `08a06a43751020f1c68aa84b0c3c39940c90871f9451a0508a340af554b11276` |
| Separate Constants.js | `ee1df1683c38f941ff6548e3fb29313405dd151c28f871f4e029f6ef75e8fc14` |
| Comparison report | `f9e9b1946ff39a5c9e9f57f5376feeff06f1ba4d4f8e02f58efff8c13933d451` |

The real eight-bot workflow exposed compilation exceeding the launcher's
60-second readiness window. Keeping move ordering and general-trade resolution
as compiled loops, rather than unrolling player pairs, reduced a fresh eight-seat
Match startup to 8.23 seconds on the validation host. The same workflow then
completed and rendered all eight players, colors, fog perspectives, and seeking
on desktop and mobile.

The bot turn cap, winner-only scoring, action deadlines, and timeout-neutralization
policy remain Softmax hosting choices. Map alignment does not establish parity
for those policies or the public ladder's rating system.
