# Board layout experiment

The production baseline at `21692e4` stores cells in a contiguous `seq[Tile]`.
These are inline values, not individually allocated objects. A tile takes
24 bytes on this 64-bit build. The standard 23 by 19 board therefore uses
10,488 bytes for cell payload, before the sequence header.

`bench_layouts.nim` retains an explicit 24-byte `OriginalCell`, independent
of the production Tile definition. It compares the original five layouts
and the current production layout using identical deterministic boards and
loops. Each result is the mean of seven samples. Every sample
runs 20,000 totals, growth, or capture scans, or 2,000 fog scans. Checksums
must agree across layouts. The fog case reuses its output buffer so that
allocation does not obscure the layout comparison.

```sh
nim check --path:../benchy/src experiments/bench_layouts.nim
nim c -d:release --path:../benchy/src -o:out/bench_layouts experiments/bench_layouts.nim
./out/bench_layouts
```

Measured on macOS arm64, Nim 2.2.10, ARC, release mode. These are isolated
kernels, not full-game speedups. The fixture distributes owners throughout
the board and is intended to compare data access, not model an entire match.

| Layout | Bytes per cell | Totals | Growth | Capture | Fog |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native inline values | 24 | 4.722 ms | 3.549 ms | 6.173 ms | 1.831 ms |
| Compact inline values | 8 | 3.566 ms | 2.953 ms | 5.780 ms | 1.796 ms |
| Separate arrays, 32-bit armies | 6 | 3.616 ms | 3.124 ms | 6.004 ms | 1.820 ms |
| Separate arrays, native armies | 10 | 3.669 ms | 3.059 ms | 5.658 ms | 1.695 ms |
| Packed 64-bit cells | 8 | 3.561 ms | 2.621 ms | 5.960 ms | 1.825 ms |

The separate arrays need three sequence headers. Byte counts above include
cell payload only. Packed cells use 32 army bits, two terrain bits, and three
owner bits. The compact representation uses a signed 32-bit army and byte
owner and terrain fields. The wide separate arrays retain native integer
armies. The existing small board already fits in L1 cache, so reducing its
size does not remove the main simulation bottleneck.

# Complete-match check

An isolated copy of `21692e4` was also compiled with the production Tile
fields narrowed to `owner: int8` and `army: int32`. Experiment-only integer
converters kept the existing call sites compiling. No production source
was changed. This is not proposed as a public API because implicit narrowing
would require a careful boundary review.

Six alternating native and compact executions ran the same headless
four-player seed-7 match, each ending at 2,000 ticks:

| Layout | CPU seconds, six samples | Median |
| --- | --- | ---: |
| Native 24-byte Tile | 1.522, 1.509, 1.533, 1.600, 1.593, 1.547 | 1.540 s |
| Compact 8-byte Tile | 1.526, 1.539, 1.541, 1.620, 1.615, 1.607 | 1.574 s |

The compact full engine showed no useful speed gain. The Python quick
comparison passed 739 transitions and 720 original-agent action comparisons
with this layout. This quick check is not the full parity qualification
required before adopting an implementation change.

Retain these layouts as experiments. Optimize the measured bot route work
first, then measure a layout change against that new baseline if memory
access becomes a significant part of the remaining cost.

# Layouts after optimizing the rules core

A second comparison used the optimized core with fixed action and order
arrays, cached move geometry, early trade rejection, and skipped odd-tick
income scans. It compared 24-byte cells, 16-byte cells with byte owners and
unchanged native integer armies, and the experimental 8-byte cells.

Each sample replayed the original 7,826 recorded ticks 100 times, or 400
complete matches and 782,600 ticks. Setup, bot decisions, and state hashing
were excluded from the timer. Every executable first checked all original
bot actions and per-tick state fingerprints. All final checksums were
`34A27D79491A8B0D`.

Two rounds ran in opposite layout order, with three samples per executable.
The commands used `--mode=rules --samples=3 --repeats=100` with the same
`out/baseline-replays.json` input.

| Layout | Round 1 median | Round 2 median | All six samples median |
| --- | ---: | ---: | ---: |
| Native, 24 bytes | 0.323567 s | 0.336364 s | 0.332703 s |
| Byte owner, native army, 16 bytes | 0.308171 s | 0.322702 s | 0.311259 s |
| Byte owner, 32-bit army, 8 bytes | 0.300474 s | 0.302710 s | 0.301592 s |

The 16-byte layout preserves the original army range and reduces standard
board payload from 10,488 to 6,992 bytes. Its measured rules-only gain was
about 6.4 percent. The 8-byte layout gained about 9.4 percent but narrows the
army range. These small gains are below the earlier improvement from fixing
repeated work in the rules loop. Neither result establishes a complete-game
speedup. Any production adoption should use explicit owner conversions at
API boundaries and rerun the full Python parity suite.

The production game now uses the 16-byte layout with explicit conversions
for validated owners and unchanged native army integers. It passed all
7,826 historical bot decisions and states, and the full Python suite of
17,441 transitions. Combined with the route and rules-loop changes, paired
complete-match timings improved 2.76x. That combined gain is not attributed
to the cell layout alone. See `../docs/PERFORMANCE.md` for final measurements.
The kernel benchmark's `production` row uses the current layout, while
`original24` always retains the old 24-byte representation.
