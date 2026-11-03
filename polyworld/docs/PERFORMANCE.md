# Headless performance

The measurements use an Apple M4 Pro, macOS arm64, Nim 2.2.10, ARC, and
`-d:release`. Bounds and overflow checks remain enabled. Timings exclude
compilation, map generation, JSON, validation, rendering, and trace recording.
They run on one thread.

The fixed workload contains four complete 23 by 19 matches: two and four
players, seeds 7 and 23. Together they contain 7,826 ticks. The rules-only
workload replays the same recorded actions 100 times, totaling 782,600 ticks.
The benchmark checks original bot actions and a fingerprint of every board
state before measuring. It checks final states again after each timed batch.

Six samples per version ran in before, after, after, before batches, with
three samples per batch. The baseline is revision `21692e4`. Each batch warms
the code first. The full samples and checksums are in `performance.json`.

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Complete matches with native bots | 1,594 ticks/s | 4,404 ticks/s | 2.76x |
| Rules only, recorded actions | 593,930 ticks/s | 2,408,302 ticks/s | 4.05x |

The four bot matches take 1.777 seconds after optimization, versus 4.908
seconds before. Rules-only throughput is about 1,231 matches per second for
this workload. It excludes bot decisions. Results depend on map and game
state, so these are workload measurements rather than universal rates.

## Implementation

Fluffy identified repeated bot route searches as the main cost. The bot now
retains one explicit `BotScratch` across all seats. It contains flat work
arrays, a reusable heap, and cardinal neighbors computed once per grid size.
Each decision refreshes the player's fog-limited values. Searches retain the
original priority and tie rules. When no general or home-defense exception
applies, a search stops after its cheapest remaining route exceeds the
stack's available army. Every later route would fail the original eligibility
test.

In matched Fluffy traces of the first 100 four-player seed-7 ticks, 400 bot
decisions took 40.011 ms before and 3.182 ms after. Their route-search spans
fell from 36.076 ms to 1.047 ms. One hundred rule steps fell from 0.349 ms to
0.095 ms. Early weak armies benefit especially from the exact search cutoff,
so this short trace improves more than the complete-match benchmark.

The rules engine uses fixed four-seat action and order arrays. It computes
action geometry once per tick, rejects ordinary moves before searching for
general trades, and avoids scanning the board on ticks with no production.

The board remains a contiguous array of inline values. Its owner field is
now one byte, reducing each cell from 24 to 16 bytes and a standard board
from 10,488 to 6,992 bytes. Army integers retain their original width. Owner
conversions are explicit at validated boundaries. There are no implicit
narrowing converters. The layout experiments also cover separate arrays,
8-byte cells, and packed cells in `experiments/board_layouts.md`.

## Reproduce

Fetch the pinned dependencies with `sh tools/fetch_deps.sh`, then:

```sh
nim check tests/bench_simulation.nim
nim c -d:release -o:out/bench-simulation tests/bench_simulation.nim
./out/bench-simulation --record=out/benchmark-replays.json --label=before --report=out/benchmark-before.json
```

After a candidate optimization, build a new executable and reuse the same
recording:

```sh
nim c -d:release -o:out/bench-candidate tests/bench_simulation.nim
./out/bench-candidate --replay=out/benchmark-replays.json --label=after --report=out/benchmark-after.json
```

Use `--mode=bots`, `--mode=rules`, or `--mode=verify` for an isolated run.
The default is five timing samples after warmup. JSON reports include every
sample, their median, ticks and matches per second, and the final checksum.
Keep the recording and baseline executable when comparing a candidate.

## Fluffy

The opt-in wrapper follows `aistuff/FLUFFY.md`. Ordinary builds compile out
the measurements. A deterministic capture of the first 100 simulation ticks
is:

```sh
nim check -d:headless -d:profileTracePath=out/trace.json -d:profileFrames=100 src/generals.nim
nim c -d:release -d:headless -d:profileTracePath=out/trace.json -d:profileFrames=100 -o:out/generals-profile src/generals.nim
./out/generals-profile --headless --players=4 --seed=7
```

Add `-d:profileStart=1000` to capture a later interval. Trace captures contain
at most 10,000 events. Use the same seed and frame interval for comparisons.
The trace includes bot observation, frontier distances, immediate choices,
route searches, move ordering, general trades, and rule stepping. Traced
durations include measurement overhead and should not replace the separate
untraced throughput benchmark.

Open a trace with Fluffy from its checkout so its fonts and assets resolve:

```sh
cd ../fluffy
nim r -d:release src/fluffy.nim ../polyworld-generals/out/trace.json
```

For interactive capture, compile the graphical game with `-d:profile`.
F2 starts a trace. F2 again writes `out/fluffy-generals.json` and opens Fluffy.
Set `FLUFFY_VIEWER` to its `src/fluffy.nim` path if it is not a sibling or
pinned dependency checkout. F5 reloads the trace in an existing viewer.

The recorder regression check is:

```sh
nim r -d:release -d:profileTracePath=out/test-profile.json tests/test_profiles.nim
```

## Correctness

The optimized engine passes the original Python differential suite: 17,441
transitions and 24,000 independent original-agent action comparisons.
Historical native bot actions and every state also match for all 7,826 ticks
of the benchmark workload. The Nim tests cover scratch reuse across seats,
restarts, and rectangular grids. See `REFERENCE.md` for the reference scope.

## JPS experiment

`experiments/jpspaths.nim` provides a four-direction adaptation of JPS+
preprocessing using the JPS4 pruning order. One immutable grid stores
neighbors, forced turns, and signed distances to jumps or walls. Its payload
is 5,681 bytes for the standard map. Query scratch is separate and reusable.

The experiment checks 676,676 source-goal pairs against BFS and A*. On the
23 by 19 mountain-only fixture, median query times were 0.671 microseconds
for BFS, 2.572 for A*, and 1.208 for precomputed jumps. These are uniform-cost,
single-goal queries. They do not measure the bot's weighted search across
many possible objectives.

The production bot retains its weighted search. Traversing enemy armies
changes path costs, and unseen cities change the player's passable graph.
The experiment verifies a counterexample: a two-step terrain path costs
102 under combat weights, while a four-step detour costs 4. Static JPS+
preprocessing cannot substitute for that cost model. Full methodology and
primary sources are in `../experiments/jps_paths.md`.

```sh
nim check experiments/bench_paths.nim
nim r -d:release experiments/bench_paths.nim --verify-only
nim r -d:release experiments/bench_paths.nim --bench-only --samples=7 --passes=20
```
