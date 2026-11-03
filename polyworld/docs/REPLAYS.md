# Replays

![Replay with the player roster and shared controls](replay.png)

Generals uses the shared `POLYWORLDREPLAY` file envelope used by GotA and
Galcon. Its Flatty payload uses Polyworld's `ActionTape`, like GotA. It
stores the initial configuration, the map generator version and initial
map hash, the public player roster and MMR values, submitted moves, public chat, and one state hash for
every completed simulation tick.

Playback regenerates the board from the recorded configuration and runs
the same simulation with the recorded moves. Bots do not run during
playback. Every resulting state is checked against the recorded hash.
Board snapshots are not stored in the replay file.

Record a complete bot match:

```sh
./out/generals --headless --seed=7 --record=out/match.replay
```

Open the recording in the graphical viewer:

```sh
./out/generals --replay=out/match.replay
```

Start the viewer at a particular simulation tick:

```sh
./out/generals --replay=out/match.replay --at=1000
```

Verify every recorded tick without opening a window:

```sh
./out/generals --headless --replay=out/match.replay
```

The headless executable `out/generals-sim` supports recording and
verification with the same options. A mismatch, malformed file, or
unsupported replay version exits with a descriptive error and nonzero
status. The replay configuration determines the board and match rules.
`--record` and `--replay` cannot be combined. Replay playback also rejects
bot and human controller flags. Split forms such as `--replay PATH` work
alongside the existing `--replay=PATH` form.

At the end of a local match, **Watch Replay** opens its in-memory action
tape. Replays start at the beginning, playing automatically with looping
enabled. `--play=false` starts paused, and `--speed N` selects the initial
speed. Use the standard Polyworld ribbon to play, pause, step, scrub,
change speed, or toggle looping. Space toggles playback, Left and Right
step one tick, and Home and End seek to the endpoints. `--at` starts a
file replay at the requested tick while preserving the selected pause state.

The replay-only POV checkboxes combine the selected players' visibility.
With none checked, the complete board is visible. Eliminated players are
unchecked. Eye buttons independently orient the map around a player's
original home; clicking the selected eye restores the default orientation.
The event log is rebuilt from the simulation as playback advances or seeks.
Public chat is recorded at its displayed tick and restored when seeking or
looping. Up to 16,384 public messages fit in a recording; later messages
still reach the UI and mailboxes without stopping simulation recording.
Direct messages, BASIC source, and bot file paths are not saved.

Version 3 supports 2 through 10 FFA players and records the map generator
version. The same seed, dimensions, player count, and generator version
always reconstruct the same starting board. Versions 1 and 2 retain their
original generator and four-seat file layouts, so existing recordings
still play and verify without changing their maps. Saving an older tape
uses the current file layout while retaining its original generator.

Version 2 added public roster and chat metadata. Version 1 recordings
load with `Player N` names and unknown ranks. The bot identity-query flag
is retained with the public roster. See [BASIC bots](BOTS.md) for player
settings, rank values, and the mailbox interface.

Graphical `--record` saves the latest local match on completion and again
when the window closes, including an unfinished match. The default viewer
keeps the current match tape in memory without writing a file.

New matches allow up to 4,000 half-second ticks, or 2,000 displayed
turns, and end earlier when only one player remains. Each replay retains
its recorded turn limit, so older recordings still end at their original
endpoint. Use `--ticks COUNT` or `--turns=COUNT` when recording to choose
a different limit. `--seconds N` and `--minutes N` convert at two ticks
per second. See [command-line flags](CLI.md) for the full shared interface.
