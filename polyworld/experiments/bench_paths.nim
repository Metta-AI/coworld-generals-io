import
  std/[algorithm, json, monotimes, os, strformat, strutils, times],
  generals/[common, worlds],
  jpspaths

const
  DefaultQueries = 2048
  DefaultSamples = 5
  DefaultPasses = 2

type
  Fixture = object
    name: string
    grid: Grid
  Query = tuple[source, target: int]
  Options = object
    verifyOnly, benchOnly: bool
    queries, samples, passes: int
    report: string

proc elapsed(started: MonoTime): float64 =
  ## Converts monotonic elapsed time to seconds without timing wall clocks.
  (getMonoTime() - started).inNanoseconds.float64 / 1.0e9

proc next(seed: var uint32, maximum: int): int =
  ## Generates repeatable fixture and query choices without global RNG state.
  seed = seed xor (seed shl 13)
  seed = seed xor (seed shr 17)
  seed = seed xor (seed shl 5)
  (seed mod maximum.uint32).int

proc fixtures(): seq[Fixture] =
  ## Keeps the measured legacy terrain and city variants stable across searches.
  for dimensions in [(13, 13), (23, 19), (18, 21), (21, 18)]:
    var config = defaultConfig(7, 4)
    config.width = dimensions[0]
    config.height = dimensions[1]
    let world = newWorldLegacy(config)
    for citiesBlocked in [false, true]:
      var blocked = newSeq[bool](world.tiles.len)
      for i, tile in world.tiles:
        blocked[i] = tile.kind == Mountain or
          (citiesBlocked and tile.kind == City)
      result.add Fixture(
        name: $config.width & "x" & $config.height &
          (if citiesBlocked: "-mountains-and-cities" else: "-mountains"),
        grid: newGrid(config.width, config.height, blocked)
      )

proc compare(grid: Grid, label: string): int =
  ## Checks every free source-goal pair and each returned cardinal path.
  var
    breadth, astar, jumps: SearchScratch
    free: seq[int]
  for cell, blocked in grid.blocked:
    if not blocked:
      free.add(cell)
  for source in free:
    for target in free:
      let
        expected = grid.distance(source, target, BreadthFirst, breadth)
        ordinary = grid.distance(source, target, Astar, astar)
        actual = grid.distance(source, target, PrecomputedJumps, jumps)
      doAssert ordinary == expected,
        label & " A* differs at " & $source & " -> " & $target
      doAssert actual == expected,
        label & " JPS differs at " & $source & " -> " & $target &
          ": " & $actual & " != " & $expected
      let path = grid.path(jumps)
      if expected < 0:
        doAssert path.len == 0
      else:
        doAssert path.len == expected + 1
        doAssert path[0] == source and path[^1] == target
        for i in 1 ..< path.len:
          let
            first = path[i - 1]
            second = path[i]
            distance = abs(first mod grid.width - second mod grid.width) +
              abs(first div grid.width - second div grid.width)
          doAssert distance == 1 and not grid.blocked[second]
      inc result

proc counterexample(): JsonNode =
  ## Demonstrates why a mountain-only unit-cost route cannot replace combat costs.
  let grid = newGrid(3, 3, newSeq[bool](9))
  var
    scratch: SearchScratch
    weights = newSeq[int](9)
  for weight in weights.mitems:
    weight = 1
  weights[4] = 101
  let
    steps = grid.distance(3, 5, PrecomputedJumps, scratch)
    path = grid.path(scratch)
  var routeCost = 0
  for i in 1 ..< path.len:
    routeCost += weights[path[i]]
  let cheapest = grid.weightedDistance(3, 5, weights, scratch)
  doAssert steps == 2
  doAssert routeCost == 102
  doAssert cheapest == 4
  %*{
    "grid": "3x3 open terrain",
    "source": [0, 1],
    "goal": [2, 1],
    "centerArmy": 100,
    "uniformPathSteps": steps,
    "uniformPathCombatCost": routeCost,
    "weightedOptimalCost": cheapest
  }

proc verify(items: seq[Fixture]): int =
  ## Covers generated rectangles, narrow grids, dense maps, and disconnected cells.
  for fixture in items:
    let count = fixture.grid.compare(fixture.name)
    result += count
    echo "PASS ", fixture.name, ": ", count, " source-goal pairs."
  for dimensions in [(1, 1), (1, 7), (7, 1), (7, 7)]:
    let grid = newGrid(
      dimensions[0],
      dimensions[1],
      newSeq[bool](dimensions[0] * dimensions[1])
    )
    result += grid.compare("open " & $dimensions)
  var seed = 0x9168_a312'u32
  for sample in 0 ..< 32:
    var blocked = newSeq[bool](6 * 5)
    for value in blocked.mitems:
      value = seed.next(100) < 35
    result += newGrid(6, 5, blocked).compare("dense " & $sample)
  discard counterexample()
  echo "PASS weighted counterexample: static path costs 102, optimal costs 4."
  echo "PASS ", result, " total source-goal comparisons."

proc queries(grid: Grid, count: int): seq[Query] =
  ## Selects the same repeatable free-cell endpoint pairs for every algorithm.
  var
    free: seq[int]
    seed = 0x761b_83ca'u32
  for cell, blocked in grid.blocked:
    if not blocked:
      free.add(cell)
  for i in 0 ..< count:
    result.add((free[seed.next(free.len)], free[seed.next(free.len)]))

proc measure(
    grid: Grid,
    queries: seq[Query],
    kind: SearchKind,
    samples, passes: int
): JsonNode =
  ## Times warm point-to-point queries with reused buffers and checksummed results.
  var
    scratch: SearchScratch
    checksum = 0
    expansions = 0
    durations: seq[float64]
  for query in queries:
    checksum += grid.distance(query.source, query.target, kind, scratch)
    expansions += scratch.expanded
  let expected = checksum * passes
  for sample in 0 ..< samples:
    checksum = 0
    let started = getMonoTime()
    for repetition in 0 ..< passes:
      for query in queries:
        checksum += grid.distance(query.source, query.target, kind, scratch)
    durations.add(elapsed(started))
    doAssert checksum == expected
  var sorted = durations
  sorted.sort()
  let
    median = sorted[sorted.len div 2]
    count = queries.len * passes
  %*{
    "algorithm": $kind,
    "samplesSeconds": durations,
    "medianSeconds": median,
    "queriesPerSample": count,
    "medianQueriesPerSecond": count.float64 / median,
    "medianMicrosecondsPerQuery": median * 1.0e6 / count.float64,
    "expandedPerQuery": expansions.float64 / queries.len.float64,
    "checksum": checksum
  }

proc options(): Options =
  ## Parses bounded experiment controls and an optional result path.
  result = Options(
    queries: DefaultQueries,
    samples: DefaultSamples,
    passes: DefaultPasses,
    report: "out/jps-paths.json"
  )
  for argument in commandLineParams():
    if argument == "--verify-only":
      result.verifyOnly = true
    elif argument == "--bench-only":
      result.benchOnly = true
    elif argument.startsWith("--queries="):
      result.queries = parseInt(argument[10 .. ^1])
    elif argument.startsWith("--samples="):
      result.samples = parseInt(argument[10 .. ^1])
    elif argument.startsWith("--passes="):
      result.passes = parseInt(argument[9 .. ^1])
    elif argument.startsWith("--report="):
      result.report = argument[9 .. ^1]
    else:
      raise newException(PathError, "Unknown argument: " & argument)
  if result.queries < 1 or result.queries > 100_000 or
    result.samples < 1 or result.samples > 31 or
    result.passes < 1 or result.passes > 100:
      raise newException(PathError, "Benchmark controls exceed their bounds.")

proc main() =
  ## Verifies the precomputed four-way adaptation before measuring its scope.
  let
    settings = options()
    items = fixtures()
  var verified = 0
  if not settings.benchOnly:
    verified = verify(items)
  if settings.verifyOnly:
    return
  var results = newJArray()
  for fixture in items:
    let selected = queries(fixture.grid, settings.queries)
    var
      rows = newJArray()
      checksum = -1
    for kind in SearchKind:
      let row = measure(
        fixture.grid,
        selected,
        kind,
        settings.samples,
        settings.passes
      )
      if checksum < 0:
        checksum = row["checksum"].getInt()
      doAssert row["checksum"].getInt() == checksum
      echo &"{fixture.name}, {kind}: " &
        &"{row[\"medianMicrosecondsPerQuery\"].getFloat():.3f} us/query"
      rows.add(row)
    results.add %*{
      "map": fixture.name,
      "width": fixture.grid.width,
      "height": fixture.grid.height,
      "cacheBytes": fixture.grid.cacheBytes(),
      "queries": rows
    }
  let report = %*{
    "scope": "Uniform four-way static point-to-point paths only.",
    "algorithm": "Horizontal-first JPS4 with offline signed vertical jumps.",
    "platform": hostOS & "-" & hostCPU,
    "nimVersion": NimVersion,
    "release": defined(release),
    "danger": defined(danger),
    "verifiedPairsThisRun": verified,
    "weightedCounterexample": counterexample(),
    "results": results
  }
  if settings.report.parentDir().len > 0:
    createDir(settings.report.parentDir())
  writeFile(settings.report, report.pretty() & "\n")
  echo "Report: ", settings.report

try:
  main()
except PathError as error:
  quit("Path experiment: " & error.msg, 1)
except ValueError, IOError, OSError:
  let error = newException(PathError, getCurrentExceptionMsg())
  quit("Path experiment: " & error.msg, 1)
