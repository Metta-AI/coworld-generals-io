import std/heapqueue

const
  DirectionX = [0, 1, 0, -1]
  DirectionY = [-1, 0, 1, 0]

type
  PathError* = object of CatchableError
  SearchKind* = enum
    BreadthFirst, Astar, PrecomputedJumps
  Grid* = object
    width*, height*: int
    blocked*: seq[bool]
    neighbors: seq[array[4, int16]]
    jumps: seq[array[2, int8]]
    forced: seq[array[2, uint8]]
  Pending = tuple[estimate, negativeCost, state: int]
  SearchScratch* = object
    costs, stamps, parents, queue: seq[int]
    pending: HeapQueue[Pending]
    epoch, source, target, lastState: int
    expanded*: int
    lastKind: SearchKind

proc index(grid: Grid, x, y: int): int {.inline.} =
  ## Returns a flat cell index without wrapping across row boundaries.
  if x < 0 or y < 0 or x >= grid.width or y >= grid.height:
    return -1
  y * grid.width + x

proc open(grid: Grid, x, y: int): bool {.inline.} =
  ## Treats outside cells and static obstacles as blocked.
  let cell = grid.index(x, y)
  cell >= 0 and not grid.blocked[cell]

proc newGrid*(width, height: int, blocked: seq[bool]): Grid =
  ## Precomputes cardinal neighbors and signed vertical JPS4 jump distances.
  if width < 1 or height < 1 or width > 61 or height > 61 or
    blocked.len != width * height:
      raise newException(PathError, "Grid dimensions must fit 61 by 61.")
  result.width = width
  result.height = height
  result.blocked = blocked
  result.neighbors.setLen(blocked.len)
  result.jumps.setLen(blocked.len)
  result.forced.setLen(blocked.len)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let cell = y * width + x
      for direction in 0 .. 3:
        let target = result.index(
          x + DirectionX[direction],
          y + DirectionY[direction]
        )
        result.neighbors[cell][direction] =
          if target >= 0 and not blocked[target]:
            target.int16
          else:
            -1'i16
      if blocked[cell]:
        continue
      for vertical in 0 .. 1:
        let parentY = y + (if vertical == 0: 1 else: -1)
        for direction in [1, 3]:
          let sideX = x + DirectionX[direction]
          if result.open(sideX, y) and not result.open(sideX, parentY):
            result.forced[cell][vertical] =
              result.forced[cell][vertical] or (1'u8 shl direction)
  for vertical in 0 .. 1:
    let direction = vertical * 2
    for row in 0 ..< height:
      let y = if vertical == 0: row else: height - row - 1
      for x in 0 ..< width:
        let
          cell = y * width + x
          adjacent = result.neighbors[cell][direction].int
        if blocked[cell] or adjacent < 0:
          continue
        if result.forced[adjacent][vertical] != 0:
          result.jumps[cell][vertical] = 1
        else:
          let next = result.jumps[adjacent][vertical].int
          result.jumps[cell][vertical] =
            (if next > 0: next + 1 else: next - 1).int8

proc cacheBytes*(grid: Grid): int =
  ## Reports flat immutable grid payload, excluding sequence headers.
  grid.blocked.len * (sizeof(bool) + sizeof(array[4, int16]) +
    sizeof(array[2, int8]) + sizeof(array[2, uint8]))

proc prepare(scratch: var SearchScratch, count: int) =
  ## Reuses query arrays and generation stamps without per-query clearing.
  let states = count * 5
  scratch.costs.setLen(states)
  scratch.stamps.setLen(states)
  scratch.parents.setLen(states)
  scratch.queue.setLen(count)
  scratch.pending.clear()
  scratch.expanded = 0
  scratch.lastState = -1
  if scratch.epoch == high(int):
    for stamp in scratch.stamps.mitems:
      stamp = 0
    scratch.epoch = 0
  inc scratch.epoch

proc manhattan(grid: Grid, first, second: int): int {.inline.} =
  ## Gives the admissible four-connected uniform-grid heuristic.
  abs(first mod grid.width - second mod grid.width) +
    abs(first div grid.width - second div grid.width)

proc jump(grid: Grid, cell, direction, target: int): int {.inline.} =
  ## Intercepts a goal before the next forced point or static wall.
  if direction mod 2 == 1:
    return grid.neighbors[cell][direction].int
  let
    distance = grid.jumps[cell][direction div 2].int
    goalDistance =
      if direction == 0:
        (cell - target) div grid.width
      else:
        (target - cell) div grid.width
  if cell mod grid.width == target mod grid.width and
    goalDistance > 0 and goalDistance <= abs(distance):
      return target
  if distance > 0:
    return cell + DirectionY[direction] * distance * grid.width
  -1

proc breadthFirst(
    grid: Grid,
    source, target: int,
    scratch: var SearchScratch
): int =
  ## Finds an unweighted shortest path using the same cardinal grid cache.
  var
    head = 0
    tail = 1
  scratch.queue[0] = source
  scratch.stamps[source] = scratch.epoch
  scratch.costs[source] = 0
  scratch.parents[source] = -1
  while head < tail:
    let cell = scratch.queue[head]
    inc head
    inc scratch.expanded
    if cell == target:
      scratch.lastState = cell
      return scratch.costs[cell]
    for entry in grid.neighbors[cell]:
      let adjacent = entry.int
      if adjacent >= 0 and scratch.stamps[adjacent] != scratch.epoch:
        scratch.stamps[adjacent] = scratch.epoch
        scratch.costs[adjacent] = scratch.costs[cell] + 1
        scratch.parents[adjacent] = cell
        scratch.queue[tail] = adjacent
        inc tail
  -1

proc distance*(
    grid: Grid,
    source, target: int,
    kind: SearchKind,
    scratch: var SearchScratch
): int =
  ## Queries uniform terrain with BFS, A*, or precomputed horizontal-first JPS4.
  scratch.prepare(grid.blocked.len)
  scratch.source = source
  scratch.target = target
  scratch.lastKind = kind
  if source < 0 or target < 0 or source >= grid.blocked.len or
    target >= grid.blocked.len or grid.blocked[source] or grid.blocked[target]:
      return -1
  if kind == BreadthFirst:
    return grid.breadthFirst(source, target, scratch)
  let start = if kind == PrecomputedJumps: source * 5 + 4 else: source
  scratch.stamps[start] = scratch.epoch
  scratch.costs[start] = 0
  scratch.parents[start] = -1
  scratch.pending.push((grid.manhattan(source, target), 0, start))
  while scratch.pending.len > 0:
    let
      entry = scratch.pending.pop()
      state = entry.state
      cost = -entry.negativeCost
    if scratch.stamps[state] != scratch.epoch or
      scratch.costs[state] != cost:
        continue
    inc scratch.expanded
    let cell = if kind == PrecomputedJumps: state div 5 else: state
    if cell == target:
      scratch.lastState = state
      return cost
    let incoming = if kind == PrecomputedJumps: state mod 5 else: 4
    var allowed = 15'u8
    if incoming < 4:
      if incoming mod 2 == 0:
        allowed = (1'u8 shl incoming) or grid.forced[cell][incoming div 2]
      else:
        allowed = allowed and not (1'u8 shl ((incoming + 2) mod 4))
    for direction in 0 .. 3:
      if (allowed and (1'u8 shl direction)) == 0:
        continue
      let adjacent =
        if kind == PrecomputedJumps:
          grid.jump(cell, direction, target)
        else:
          grid.neighbors[cell][direction].int
      if adjacent < 0:
        continue
      let
        nextState =
          if kind == PrecomputedJumps:
            adjacent * 5 + direction
          else:
            adjacent
        nextCost = cost + grid.manhattan(cell, adjacent)
      if scratch.stamps[nextState] != scratch.epoch or
        nextCost < scratch.costs[nextState]:
          scratch.stamps[nextState] = scratch.epoch
          scratch.costs[nextState] = nextCost
          scratch.parents[nextState] = state
          scratch.pending.push((
            nextCost + grid.manhattan(adjacent, target),
            -nextCost,
            nextState
          ))
  -1

proc path*(grid: Grid, scratch: SearchScratch): seq[int] =
  ## Expands the last successful query's jump segments into cardinal cells.
  var
    waypoints: seq[int]
    state = scratch.lastState
  while state >= 0:
    waypoints.add(
      if scratch.lastKind == PrecomputedJumps:
        state div 5
      else:
        state
    )
    state = scratch.parents[state]
  if waypoints.len == 0:
    return
  result.add(waypoints[^1])
  for i in countdown(waypoints.len - 2, 0):
    let target = waypoints[i]
    var cell = result[^1]
    let offset =
      if cell mod grid.width == target mod grid.width:
        if target > cell: grid.width else: -grid.width
      else:
        if target > cell: 1 else: -1
    while cell != target:
      cell += offset
      doAssert not grid.blocked[cell]
      result.add(cell)

proc weightedDistance*(
    grid: Grid,
    source, target: int,
    weights: seq[int],
    scratch: var SearchScratch
): int =
  ## Supplies an independent weighted Dijkstra counterexample to static JPS.
  doAssert weights.len == grid.blocked.len
  scratch.prepare(grid.blocked.len)
  if source < 0 or target < 0 or source >= grid.blocked.len or
    target >= grid.blocked.len or grid.blocked[source] or grid.blocked[target]:
      return -1
  scratch.stamps[source] = scratch.epoch
  scratch.costs[source] = 0
  scratch.pending.push((0, 0, source))
  while scratch.pending.len > 0:
    let
      entry = scratch.pending.pop()
      cell = entry.state
      cost = entry.estimate
    if scratch.costs[cell] != cost:
      continue
    if cell == target:
      return cost
    for adjacent in grid.neighbors[cell]:
      let next = adjacent.int
      if next < 0:
        continue
      doAssert weights[next] > 0
      let nextCost = cost + weights[next]
      if scratch.stamps[next] != scratch.epoch or
        nextCost < scratch.costs[next]:
          scratch.stamps[next] = scratch.epoch
          scratch.costs[next] = nextCost
          scratch.pending.push((nextCost, 0, next))
  -1
