import
  std/heapqueue,
  common, profiles, visions, worlds

const
  Infinity = high(int) div 8
  RouteLimit = 8

type
  Route = tuple[cost, steps, tile: int]
  BotScratch* = object
    width, height: int
    neighbors: seq[array[4, int]]
    owners, armies, distances, values: seq[int]
    kinds: seq[TileKind]
    visible, blocked, halves: seq[bool]
    strengths, fronts, queue, costs, steps, firsts: seq[int]
    sources: array[RouteLimit, int]
    pending: HeapQueue[Route]

proc prepare(scratch: var BotScratch, world: World) {.raises: [].} =
  ## Allocates flat work buffers and cardinal neighbors once per grid size.
  let
    width = world.config.width
    height = world.config.height
    count = world.tiles.len
  if scratch.width == width and scratch.height == height and
    scratch.owners.len == count:
      return
  scratch.width = width
  scratch.height = height
  scratch.neighbors.setLen(count)
  scratch.owners.setLen(count)
  scratch.armies.setLen(count)
  scratch.distances.setLen(count)
  scratch.values.setLen(count)
  scratch.kinds.setLen(count)
  scratch.visible.setLen(count)
  scratch.blocked.setLen(count)
  scratch.halves.setLen(count)
  scratch.strengths.setLen(count)
  scratch.fronts.setLen(count)
  scratch.queue.setLen(count)
  scratch.costs.setLen(count)
  scratch.steps.setLen(count)
  scratch.firsts.setLen(count)
  scratch.pending.clear()
  for y in 0 ..< height:
    for x in 0 ..< width:
      let i = y * width + x
      scratch.neighbors[i] = [
        if y > 0: i - width else: -1,
        if x + 1 < width: i + 1 else: -1,
        if y + 1 < height: i + width else: -1,
        if x > 0: i - 1 else: -1
      ]

proc observe(
    world: World,
    player: int,
    scratch: var BotScratch
) {.measure, raises: [].} =
  ## Refreshes fog-limited flat data and objective values for one decision.
  let
    width = world.config.width
    home = world.generals[player]
    homeX = home mod width
    homeY = home div width
  world.visibility(player, scratch.visible)
  for y in 0 ..< world.config.height:
    for x in 0 ..< width:
      let
        i = y * width + x
        tile = world.tiles[i]
        distance = abs(x - homeX) + abs(y - homeY)
      scratch.distances[i] = distance
      scratch.owners[i] = -1
      scratch.armies[i] = 0
      scratch.kinds[i] = Plain
      scratch.values[i] = 0
      if scratch.visible[i]:
        scratch.owners[i] = tile.owner
        scratch.armies[i] = tile.army
        scratch.kinds[i] = tile.kind
        scratch.blocked[i] = tile.kind == Mountain
        if tile.owner != player:
          case tile.kind
          of General:
            scratch.values[i] = 200_000
          of City:
            scratch.values[i] = if tile.owner >= 0: 1800 else: 1400
          of Plain:
            scratch.values[i] =
              if tile.owner >= 0:
                900
              elif world.turn < 100:
                260
              else:
                180
          of Mountain:
            discard
      else:
        scratch.blocked[i] = tile.kind in {Mountain, City}
        scratch.values[i] = 260 + min(80, distance * 3)

proc chooseMove*(
    world: World,
    player: int,
    scratch: var BotScratch
): Move {.measure, raises: [].} =
  ## Chooses the same fog-limited policy with reusable grid work buffers.
  result = noMove()
  if world.finished or player < 0 or player >= world.alive.len or
    not world.alive[player]:
      return
  scratch.prepare(world)
  world.observe(player, scratch)
  let
    count = world.tiles.len
    home = world.generals[player]
  var
    reserve = 1
    threat = 0
    generalSeen = false
    bestScore = -Infinity
    queued = 0
    sourceCount = 0
    chosen = noMove()
  if world.turn >= 60:
    reserve = 3 + min(7, world.turn div 100)
  for i in 0 ..< count:
    if scratch.visible[i] and scratch.kinds[i] == General and
      scratch.owners[i] != player:
        generalSeen = true
    if scratch.visible[i] and scratch.owners[i] >= 0 and
      scratch.owners[i] != player:
        let steps = scratch.distances[i]
        if steps <= 5:
          threat = max(threat, scratch.armies[i] - steps + 1)
  if threat > 0:
    reserve = max(reserve, threat + 2)
  let bounded = not generalSeen and threat < scratch.armies[home]
  for i in 0 ..< count:
    scratch.fronts[i] = Infinity
    scratch.strengths[i] = 0
    scratch.halves[i] = false
    if not scratch.blocked[i] and scratch.owners[i] != player:
      scratch.fronts[i] = 0
      scratch.queue[queued] = i
      inc queued
    if scratch.owners[i] == player and scratch.armies[i] >= 2:
      scratch.strengths[i] = scratch.armies[i] - 1
      if i == home and reserve > 1:
        scratch.halves[i] = true
        scratch.strengths[i] = scratch.armies[i] div 2
        if scratch.armies[i] - scratch.strengths[i] < reserve:
          scratch.strengths[i] = 0
  profileBlock "front distances":
    var head = 0
    while head < queued:
      let tile = scratch.queue[head]
      inc head
      for adjacent in scratch.neighbors[tile]:
        if adjacent >= 0 and not scratch.blocked[adjacent] and
          scratch.fronts[adjacent] > scratch.fronts[tile] + 1:
            scratch.fronts[adjacent] = scratch.fronts[tile] + 1
            scratch.queue[queued] = adjacent
            inc queued

  template offer(sourceValue, targetValue, scoreValue: int) =
    ## Evaluates each candidate once and preserves stable utility ties.
    let
      source = sourceValue
      target = targetValue
      score = scoreValue
    if target >= 0 and score > bestScore:
      let move = Move(
        source: source,
        target: target,
        half: scratch.halves[source]
      )
      if validMove(world, player, move):
        bestScore = score
        chosen = move

  profileBlock "immediate moves":
    for source in 0 ..< count:
      let force = scratch.strengths[source]
      if force <= 0:
        continue
      var position = 0
      while position < sourceCount and
        scratch.strengths[scratch.sources[position]] >= force:
          inc position
      if position < RouteLimit:
        sourceCount = min(RouteLimit, sourceCount + 1)
        for i in countdown(sourceCount - 1, position + 1):
          scratch.sources[i] = scratch.sources[i - 1]
        scratch.sources[position] = source
      for target in scratch.neighbors[source]:
        if target < 0 or scratch.blocked[target]:
          continue
        if scratch.owners[target] != player:
          let defender = scratch.armies[target]
          if force > defender:
            let score = scratch.values[target] div 3 + min(force, 80) * 2 -
              defender * 3
            offer(source, target, score)
        else:
          if threat >= scratch.armies[home] and target == home:
            offer(source, target, 10_000 + force * 20)
          if scratch.fronts[target] < scratch.fronts[source]:
            let score = 30 + min(force, 80) * 2 - scratch.fronts[target] * 8 +
              min(30, min(force, scratch.armies[target]))
            offer(source, target, score)

  profileBlock "route searches":
    for sourceIndex in 0 ..< sourceCount:
      let
        source = scratch.sources[sourceIndex]
        force = scratch.strengths[source]
      for cost in scratch.costs.mitems:
        cost = Infinity
      scratch.costs[source] = 0
      scratch.steps[source] = 0
      scratch.firsts[source] = -1
      scratch.pending.push((0, 0, source))
      while scratch.pending.len > 0:
        let route = scratch.pending.pop()
        if route.cost != scratch.costs[route.tile] or
          route.steps != scratch.steps[route.tile]:
            continue
        if bounded and route.cost > force:
          # Higher-cost routes cannot offer expansion or a special objective.
          scratch.pending.clear()
          break
        let tile = route.tile
        if tile != source:
          let
            first = scratch.firsts[tile]
            canAdvance = scratch.owners[first] == player or
              force > scratch.armies[first]
            general = scratch.visible[tile] and
              scratch.kinds[tile] == General and scratch.owners[tile] != player
          if scratch.owners[tile] != player and canAdvance and
            (force >= route.cost or general):
              let score = scratch.values[tile] div (route.steps + 2) +
                min(force, 80) * 2 - route.cost * 3
              offer(source, scratch.firsts[tile], score)
          if threat >= scratch.armies[home] and tile == home:
            let score = 10_000 div (route.steps + 1) + force * 20
            offer(source, scratch.firsts[tile], score)
        for target in scratch.neighbors[tile]:
          if target < 0 or scratch.blocked[target]:
            continue
          var cost = route.cost + 1
          if scratch.owners[target] != player:
            cost += scratch.armies[target]
          if cost < scratch.costs[target]:
            scratch.costs[target] = cost
            scratch.steps[target] = route.steps + 1
            scratch.firsts[target] =
              if tile == source:
                target
              else:
                scratch.firsts[tile]
            scratch.pending.push((cost, route.steps + 1, target))
  result = chosen

proc chooseMove*(world: World, player: int): Move {.raises: [].} =
  ## Preserves the simple facade for callers without persistent work buffers.
  var scratch: BotScratch
  world.chooseMove(player, scratch)
