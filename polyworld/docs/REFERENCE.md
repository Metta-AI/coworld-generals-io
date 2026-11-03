# Python reference comparison

The regression suite runs the original Python/JAX rules engine beside the
Nim engine. Both start from the same board and receive the same actions.
Every tick compares all tile types, owners, armies, surviving players,
general positions, public scores, fog observations, time, and winner.
The first difference fails the run and saves the initial board, actions,
and both states in `build/reference_failure.json`.

The unchanged source files and MIT license are in `tests/reference/upstream`.
They come from `Metta-AI/coworld-generals-io` at revision
`43deb578ccaee91fce317169691a0d8a0206a01e`. The manifest records original paths
and SHA-256 hashes. The harness verifies those hashes and dependency versions
before importing the reference. It calls the actual Python engine rather
than a rewritten model of its rules.

## Run

Use Nim 2.2.10 and Python 3.12:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/reference_requirements.txt
.venv/bin/python tools/check_reference.py
```

The harness builds its own headless Nim runner. No graphical dependencies
are needed. With the virtual environment activated, `nimble reference`
runs the same check. `--quick` runs a smoke check for local iteration.
CI runs the full suite on every push and pull request.
Successful runs write counts and per-game results to
`build/reference_report.json`. CI keeps this report and any failing replay
as the `reference-results` artifact.

## Coverage

- Focused scenarios cover movement, half moves, ties, blocked actions,
  defensive priority, general priority, chase chains, alternating seat ties,
  captures, simultaneous general trades, income, fog, and terminal behavior.
  Ten-player cases include five simultaneous captures, five simultaneous
  general trades, and a chase cycle involving every player.
- Random trajectories exercise legal and accepted invalid actions in
  every free-for-all player count from 2 through 10.
- Separate instances of the original Python Expander agent consume the
  observations from each engine. Their actions must also agree at every
  tick. Default seeds 7 and 23 run to conquest or the 2,000-tick limit in
  every player count from 2 through 10. `--players=2,10` narrows the random
  and agent matches during local iteration; focused cases still run.
- Native-bot matches feed the production game's moves into both engines,
  then check that completed matches stay frozen. Both agent suites use
  production seeded maps with the default dimensions for each player count.
  Additional 18 by 21 and 21 by 18 fixtures check rectangular edges and fog.
- The native episode wrapper stops after conquest and reports a draw at
  the turn limit. The raw engine is also checked separately, including
  the reference's post-win movement behavior.

The selected ruleset is classic free-for-all with `general_trade=True`.
The suite checks identical starting boards. The local seeded map
generator and native opponent policy differ from the competition defaults.
Matching numerical seeds does not imply matching maps. Teams, castle
construction, surrender, server timeouts, and transport are outside scope.
The reference and Python dependencies are test-only and are not bundled
with the native game.

Passing this suite is evidence of agreement on its fixtures and trajectories,
not a proof for every possible state. Keep any discovered difference as a
regression case. To adopt a newer reference, explicitly update the unchanged
source, manifest hashes, dependency pins, and corresponding regression tests.
