# Does the engine reproduce real generals.io games?

Validation against ranked 1v1 replays of the current game (replay formats 16 and 18, 2026). The replays, the
site's own engine run under Node for ground truth, the pipeline and the results live in the paper repository
under `review/replays_2026/`; this directory holds the engine-side tools.

* `gior.py` decodes a `.gior` replay (the format served from the public replay buckets) following
  `Replay.deserialize` of the client bundle.
* `replay_prep.py` turns a decoded replay into engine inputs (padded grid, per-tick actions); base game only.
* `replay_recent.py 'dir/*.gior' [--no-trade] [--out f]` plays every replay through `game.step` as one
  `lax.scan` and checks, from the record alone, that no recorded move is rejected and that each game ends the
  way the record says (capture by the recorded winner on the recorded turn; or no early end for a surrender).
* `board_diff.py <siteboards> 'dir/*.gior' [--out f]` compares our board with the site engine's board tile by
  tile at every tick.

Result (2026-09-20, 10,000 base-game replays drawn at random, 6.3 million moves): boards identical to the site's
engine at every in-game tick in all 10,000 games; 0 recorded moves rejected.

## Privately supplied replay core

`reference_boards.py` runs the separately supplied `ReplaySimulationCore.js`
under Node and exports the snapshot format consumed by the existing comparison
scripts. Keep the reference source and generated snapshots outside this checkout.
Neither belongs in game images, browser bundles, or public artifacts.

Prepare two separate external directories:

- The original live-game bundle retains its original, larger `Constants.js`.
  Replace its older `MoveResolver.js` with the newer supplied resolver.
- The replay-core directory contains the newer `MoveResolver.js`, `Map.js`,
  `ReplaySimulationCore.js`, and the smaller replay `Constants.js`.

Do not flatten these directories or substitute one constants module for the other.
The adapter loads the replay core directly. It does not need `simulator.js`,
`ReplayDeserializer.js`, `EventGameOptions.js`, or `EventReplaySimulation.js`.
The latter two are still needed to run the supplied decoder/statistics entry points.

From the repository root, with Python 3.11+ and Node installed:

```bash
# Use your external paths; the output directory must not already exist.
python paper/validation/reference_boards.py /path/to/private/replay-core \
  '/path/to/replays/*.gior' /path/to/reference-boards
python paper/validation/board_diff.py /path/to/reference-boards \
  '/path/to/replays/*.gior' --out /path/to/classic-comparison.json
python paper/validation/ffa/board_diff_ffa.py /path/to/reference-boards \
  '/path/to/replays/*.gior' --out /path/to/full-comparison.json
```

The FFA comparator also accepts two-player games and models surrender/AFK events.
Use its `engine_afk` result for complete-game comparisons involving those events.
The classic comparator only compares through its move-derived horizon; it does
not establish agreement after a later surrender. Both comparison scripts report
findings rather than exiting nonzero on mismatches. Inspect exclusions,
`mismatch_ticks`, first differing tiles, terminal differences, and `same_end` in
the FFA report before claiming agreement. Zero compared games is not a pass.

Each snapshot records SHA-256 hashes of the replay, four private source files,
and the adapter/decoder. Archive those hashes with the comparison report and the
JAX checkout revision. Frames include the initial board and every completed
turn. Exports fail if the recorded move/AFK timeline does not reach an outcome,
if the game ends before consuming all moves, or if a replay ID collides.
Never extend incomplete recordings until the idle timeout fabricates a winner.
A failed batch can leave completed outputs; use a fresh output directory on retry.

This adapter supports base-game replay versions 16–18 only. It rejects event
modifiers and special terrain rather than silently comparing unsupported rules.
It uses this repository's existing decoder; it does not certify the missing
upstream decoder or newer ChessClock formats. The supplied `Map.js` does not
implement `computeVisibility`, so these exports certify neither fog observations
nor information boundaries. Castle-building and map generation need separate
validation. Identical seeds across different map generators are not identical boards.

Use whole-game cases covering captures, mutual general trades, half-army rounding,
move dependencies, growth, and surrender before changing JAX rules. Preserve the
reported terminal-income difference as a distinct finding; do not silently discard
it or interpret historical replay results as certification of a new source revision.

Run the opt-in system regression with the real external core:

```bash
GENERALS_REFERENCE_ENGINE=/path/to/private/replay-core JAX_PLATFORMS=cpu \
  python -m pytest -q tests/test_reference_validation.py
```

The synthetic fixtures in `tests/fixtures/reference_replays/` are authored for
this workflow, not downloaded player recordings. They cover two- and four-player
movement, a half-army move, growth, and surrender. The incomplete fixture omits
the surrender events. The regression requires matching boards and outcomes and
rejects that incomplete recording. CI skips it unless the private core is supplied;
these two games are plumbing coverage, not broad rules-parity evidence.
