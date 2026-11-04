import
  std/math,
  common

const
  MapAttempts = 256
  SpawnAttempts = 128
  Cardinal = [(0, -1), (1, 0), (0, 1), (-1, 0)]

type
  MapScratch = object
    neighbors: seq[array[4, int]]
    distances, queue: seq[int]

proc minimumSpacing*(players: int): int {.raises: [].} =
  ## Returns the classic minimum Manhattan separation between generals.
  max(9, (162 - 9 * players) div 10) + 1

proc distance(first, second, width: int): int {.raises: [].} =
  ## Measures cardinal separation without crossing a row boundary.
  abs(first mod width - second mod width) +
    abs(first div width - second div width)

proc prepare(config: Config): MapScratch =
  ## Allocates reusable flat neighbors and one bounded flood queue.
  let count = config.width * config.height
  result.neighbors.setLen(count)
  result.distances.setLen(count)
  result.queue.setLen(count)
  for i in 0 ..< count:
    let
      x = i mod config.width
      y = i div config.width
    for direction, offset in Cardinal:
      let
        nextX = x + offset[0]
        nextY = y + offset[1]
      result.neighbors[i][direction] =
        if nextX in 0 ..< config.width and nextY in 0 ..< config.height:
          nextY * config.width + nextX
        else:
          -1

proc flood(
    world: World,
    start: int,
    scratch: var MapScratch,
    cities = false
) =
  ## Measures open routes and obstacle frontiers without crossing structures.
  for value in scratch.distances.mitems:
    value = -1
  var
    read = 0
    write = 1
  scratch.queue[0] = start
  scratch.distances[start] = 0
  while read < write:
    let cell = scratch.queue[read]
    inc read
    for neighbor in scratch.neighbors[cell]:
      if neighbor < 0 or scratch.distances[neighbor] >= 0:
        continue
      scratch.distances[neighbor] = scratch.distances[cell] + 1
      if world.tiles[neighbor].kind == Plain or
        (cities and world.tiles[neighbor].kind == City):
        scratch.queue[write] = neighbor
        inc write

proc expansion(world: World, start: int, scratch: var MapScratch): float64 =
  ## Scores early open land with the classic fourteen-step distance weights.
  world.flood(start, scratch)
  var counts: array[15, int]
  for i, steps in scratch.distances:
    if steps in 1 .. 14 and world.tiles[i].kind == Plain:
      inc counts[steps]
  counts[1] = min(3, counts[1])
  var weight = floor(pow(1.18, 15.0))
  for steps in 1 .. 14:
    result += weight * counts[steps].float64
    weight /= (if steps < 7: 1.18 else: 1.10)
    if steps < 5:
      weight /= 1.6

proc connected(world: World, scratch: var MapScratch): bool =
  ## Requires all generals to connect without crossing cities or generals.
  for home in world.generals:
    world.flood(home, scratch)
    for other in world.generals:
      if scratch.distances[other] < 0:
        return false
  true

proc placeGenerals(
    world: var World,
    random: var uint64,
    scratch: var MapScratch
): bool =
  ## Places separated random starts with exits and balanced duel expansion.
  var candidates: seq[int]
  for i, tile in world.tiles:
    if tile.kind != Plain:
      continue
    for neighbor in scratch.neighbors[i]:
      if neighbor >= 0 and world.tiles[neighbor].kind == Plain:
        candidates.add(i)
        break
  if candidates.len < world.config.players:
    return false
  let spacing = minimumSpacing(world.config.players)
  for attempt in 0 ..< SpawnAttempts:
    var count = 0
    for i in countdown(candidates.high, 1):
      swap(candidates[i], candidates[random.nextRandom(i + 1)])
    for candidate in candidates:
      var allowed = true
      for player in 0 ..< count:
        if distance(candidate, world.generals[player], world.config.width) <
          spacing:
            allowed = false
            break
      if allowed:
        world.generals[count] = candidate
        inc count
        if count == world.config.players:
          break
    if count != world.config.players:
      continue
    if count == 2:
      let
        first = world.expansion(world.generals[0], scratch)
        second = world.expansion(world.generals[1], scratch)
      if max(first, second) <= 0 or min(first, second) / max(first, second) <
        0.9175:
          continue
    for player in countdown(count - 1, 1):
      swap(
        world.generals[player],
        world.generals[random.nextRandom(player + 1)]
      )
    for player, home in world.generals:
      world.tiles[home] = Tile(kind: General, owner: player.int8, army: 1)
    if world.connected(scratch):
      return true
    for home in world.generals:
      world.tiles[home] = Tile(kind: Plain, owner: -1)
  false

proc placeCity(world: var World, cell, army: int) =
  ## Converts an unowned obstacle into one neutral city.
  world.tiles[cell] = Tile(kind: City, owner: -1, army: army)

proc citiesNear(world: World): bool =
  ## Enforces the classic nearby-city guarantee for up to eight players.
  if world.config.players > 8:
    return true
  for home in world.generals:
    var found = false
    for i, tile in world.tiles:
      if tile.kind == City and distance(home, i, world.config.width) <= 6:
        found = true
        break
    if not found:
      return false
  true

proc duelCities(
    world: var World,
    desired: int,
    random: var uint64,
    scratch: var MapScratch
): bool =
  ## Pairs opposite city opportunities at equal walking costs and garrisons.
  world.flood(world.generals[0], scratch)
  let first = scratch.distances
  world.flood(world.generals[1], scratch)
  let second = scratch.distances
  var
    candidates: seq[int]
    pairs: seq[tuple[first, second: int]]
    neutrals: seq[int]
    count = 0
  for i, tile in world.tiles:
    if tile.kind == Mountain and first[i] >= 0 and second[i] >= 0:
      candidates.add(i)
  for i in countdown(candidates.high, 1):
    swap(candidates[i], candidates[random.nextRandom(i + 1)])
  for cell in candidates:
    if count >= desired:
      break
    if world.tiles[cell].kind != Mountain:
      continue
    if first[cell] == second[cell] or min(first[cell], second[cell]) >= 17:
      world.placeCity(cell, 40 + random.nextRandom(11))
      neutrals.add(cell)
      inc count
      continue
    for other in candidates:
      if world.tiles[other].kind == Mountain and other != cell and
        first[cell] == second[other] and second[cell] == first[other]:
          let army = 40 + random.nextRandom(11)
          world.placeCity(cell, army)
          world.placeCity(other, army)
          pairs.add((cell, other))
          count += 2
          break
  if count == 0 or not world.citiesNear():
    return false
  world.flood(world.generals[0], scratch, cities = true)
  let finalFirst = scratch.distances
  world.flood(world.generals[1], scratch, cities = true)
  let finalSecond = scratch.distances
  for cell in neutrals:
    if finalFirst[cell] != finalSecond[cell] and
      min(finalFirst[cell], finalSecond[cell]) < 17:
        return false
  var deficit = 0
  for pair in pairs:
    let
      firstCell =
        if finalFirst[pair.first] < finalSecond[pair.first]:
          pair.first
        else:
          pair.second
      secondCell = if firstCell == pair.first: pair.second else: pair.first
      rangeDifference = finalFirst[firstCell] - finalSecond[firstCell] +
        finalFirst[secondCell] - finalSecond[secondCell]
      placementDifference = finalFirst[firstCell] + finalSecond[firstCell] -
        finalFirst[secondCell] - finalSecond[secondCell]
    if finalFirst[firstCell] >= finalSecond[firstCell] or
      finalSecond[secondCell] >= finalFirst[secondCell] or
      abs(placementDifference) > 3:
        return false
    deficit += 3 * rangeDifference + 2 * placementDifference
    if abs(deficit) > 6:
      return false
  true

proc ffaCities(
    world: var World,
    desired: int,
    random: var uint64,
    scratch: var MapScratch
): bool =
  ## Gives each FFA start a nearby city before filling the random city budget.
  var count = 0
  let sharedArmy = 40 + random.nextRandom(11)
  for home in world.generals:
    world.flood(home, scratch)
    var candidates: seq[int]
    for i, tile in world.tiles:
      if tile.kind == Mountain and scratch.distances[i] in 1 .. 6 and
        distance(home, i, world.config.width) <= 6:
          candidates.add(i)
    if candidates.len == 0:
      return false
    world.placeCity(candidates[random.nextRandom(candidates.len)], sharedArmy)
    inc count
  var candidates: seq[int]
  for i, tile in world.tiles:
    if tile.kind == Mountain:
      candidates.add(i)
  for i in countdown(candidates.high, 1):
    swap(candidates[i], candidates[random.nextRandom(i + 1)])
  for cell in candidates:
    if count >= desired:
      break
    world.placeCity(cell, 40 + random.nextRandom(11))
    inc count
  world.citiesNear()

proc generateWorld*(config: Config): World =
  ## Builds reproducible classic FFA terrain with bounded validation retries.
  if config.width notin 13 .. 61 or config.height notin 13 .. 61:
    raise newException(GeneralsError, "Map dimensions must be 13 to 61.")
  if config.players notin 2 .. MaxPlayers:
    raise newException(GeneralsError, "A match needs 2 to 10 players.")
  if config.maxTurns notin 1 .. 100_000:
    raise newException(GeneralsError, "Turn limit must be 1 to 100000.")
  result.config = config
  result.winner = -1
  result.tiles = newSeq[Tile](config.width * config.height)
  result.generals = newSeq[int](config.players)
  result.alive = newSeq[bool](config.players)
  for alive in result.alive.mitems:
    alive = true
  var
    random = mapRandom(config.seed)
    scratch = prepare(config)
  discard random.nextRandom(65_536)
  discard random.nextRandom(65_536)
  for attempt in 0 ..< MapAttempts:
    for tile in result.tiles.mitems:
      tile = Tile(kind: Plain, owner: -1)
    let
      desired = 5 + config.players * 2 + random.nextRandom(config.players + 1)
      budget = result.tiles.len * (20 + random.nextRandom(9)) div 100 + desired
    for obstacle in 0 ..< budget:
      result.tiles[random.nextRandom(result.tiles.len)].kind = Mountain
    if not result.placeGenerals(random, scratch):
      continue
    let placed =
      if config.players == 2:
        result.duelCities(desired, random, scratch)
      else:
        result.ffaCities(desired, random, scratch)
    if placed and result.connected(scratch):
      return
  raise newException(
    GeneralsError,
    "Cannot place " & $config.players & " separated generals on " &
      $config.width & "x" & $config.height & " for seed " & $config.seed &
      ". Use larger dimensions or another seed."
  )
