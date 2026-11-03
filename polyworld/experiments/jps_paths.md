# Precomputed four-way jump paths

`jpspaths.nim` implements horizontal-first JPS4 with offline jump distances.
This is a four-way adaptation of the JPS+ preprocessing idea. Standard JPS+
targets uniform eight-way movement. The game allows four cardinal moves.

The implementation follows the pruning rules in
[Jump Point Search Pathfinding in 4-connected Grids](https://arxiv.org/html/2501.14816v1).
Horizontal successors advance one cell. Vertical successors jump to the
next forced turn or the goal. Signed distances to forced turns or walls
are precomputed once, following the caching approach described in
[JPS+](https://www.gameaipro.com/GameAIPro2/GameAIPro2_Chapter14_JPS_Plus_An_Extreme_A_Star_Speed_Optimization_for_Static_Uniform_Cost_Grids.pdf).
The query can stop a cached jump early when it passes over its goal.

The static grid uses 13 bytes per cell: one obstacle byte, four 16-bit
neighbor indices, two signed 8-bit jump distances, and two forced-turn masks.
The 23 by 19 grid payload is 5,681 bytes, excluding sequence headers.
All searches share that grid. Per-query scratch buffers are reused.
Changing passability requires rebuilding the cache.

## Correctness

```sh
nim check experiments/bench_paths.nim
nim c -d:release -o:out/bench_paths experiments/bench_paths.nim
./out/bench_paths --verify-only
```

The experiment passes 676,676 source-goal comparisons. For every free pair
on generated 13 by 13, 23 by 19, 18 by 21, and 21 by 18 maps, JPS4 and A*
must return the same distance as breadth-first search. Each map is checked
with mountains blocked, and again with both mountains and cities blocked.
Additional cases cover open and narrow grids, random dense obstacles, and
disconnected regions. Returned jump paths are expanded and checked one
cardinal cell at a time. Direction is included in search state to avoid
discarding a useful arrival with different pruning rules.

## Scope

This experiment answers static, uniform-cost, single-destination queries.
The production bot computes army-dependent weighted costs and scores many
destinations from each source. A mountain-only cache cannot replace those
weights or the visibility-dependent treatment of cities.

The executable verifies a concrete counterexample on an open 3 by 3 grid.
Start and goal sit at opposite ends of the middle row. The middle cell
has a hostile army of 100, so entering it costs 101. The uniform shortest
path takes two steps and costs 102. Weighted Dijkstra takes the four-step
detour at cost 4. Both paths obey the same static mountain grid.

The experiment is retained separately from the production bot. Its speed
numbers describe point-to-point queries, not complete matches or equivalent
weighted policy decisions.

## Measure

```sh
./out/bench_paths --report=out/jps-paths.json
```

The default benchmark uses 2,048 seeded endpoint pairs, five samples, and
two passes per sample for each map and algorithm. It warms and reuses search
buffers, checksums every result, and reports medians and node expansions.
Grid construction and exhaustive verification are outside the timed query
loops. `--bench-only` skips the correctness pass after it has already passed.

On Apple M4 Pro, macOS arm64, Nim 2.2.10 release with runtime checks retained,
the longer run below used seven samples and 20 passes per sample. Each timing
is a median in microseconds per query. All three algorithms returned identical
distance checksums.

```sh
./out/bench_paths --bench-only --samples=7 --passes=20 --report=out/jps-paths.json
```

| Grid and blocked terrain | BFS | A* | Precomputed JPS4 |
| --- | ---: | ---: | ---: |
| 13 by 13, mountains | 0.284 | 0.847 | 0.512 |
| 13 by 13, mountains and cities | 0.259 | 0.852 | 0.567 |
| 23 by 19, mountains | 0.671 | 2.572 | 1.208 |
| 23 by 19, mountains and cities | 0.754 | 2.666 | 1.205 |
| 18 by 21, mountains | 0.698 | 1.738 | 0.937 |
| 18 by 21, mountains and cities | 0.666 | 1.935 | 0.913 |
| 21 by 18, mountains | 0.752 | 1.710 | 0.992 |
| 21 by 18, mountains and cities | 0.698 | 1.662 | 0.994 |

On the production-size mountain grid the precomputed jumps are 2.13 times
faster than this A* implementation, but BFS is 1.80 times faster than the
jump implementation. These small maps make a simple flat queue competitive
despite its greater expansion count. The measurement does not establish
that JPS is generally slower on larger maps or other obstacle patterns.
