import common, maps, profiles

const
  Directions* = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  ActionDirections = [(0, -1), (0, 1), (-1, 0), (1, 0)]

type Geometry = object
  source, target: int
  sourceX, sourceY, targetX, targetY: int
  passing, valid: bool

proc newWorld*(config: Config): World =
  ## Creates a deterministic classic FFA map for two to ten players.
  generateWorld(config)

proc index*(world: World, x, y: int): int =
  ## Returns the flat tile index, or minus one outside the board.
  if x < 0 or y < 0 or x >= world.config.width or y >= world.config.height:
    return -1
  y * world.config.width + x

proc totals*(world: World, player: int): tuple[land, army: int] =
  ## Counts a player's public land and army totals.
  if player < 0 or player >= world.config.players:
    return
  for tile in world.tiles:
    if tile.owner == player:
      inc result.land
      result.army += tile.army

proc next(random: var uint32, maximum: int): int =
  ## Advances a local xorshift generator without global random state.
  random = random xor (random shl 13)
  random = random xor (random shr 17)
  random = random xor (random shl 5)
  int(random mod maximum.uint32)

proc mirrors(world: World, x, y: int): array[4, int] =
  ## Returns one cell and its horizontal and vertical reflections.
  [
    world.index(x, y),
    world.index(world.config.width - 1 - x, y),
    world.index(x, world.config.height - 1 - y),
    world.index(world.config.width - 1 - x, world.config.height - 1 - y)
  ]

proc carve(world: var World, x, y: int) =
  ## Opens reflected mountain cells while preserving cities and generals.
  for i in world.mirrors(x, y):
    if world.tiles[i].kind == Mountain:
      world.tiles[i].kind = Plain

proc reachable(world: World, start: int): seq[bool] =
  ## Floods passable cells with a queue bounded by the board size.
  result = newSeq[bool](world.tiles.len)
  var
    queue = newSeq[int](world.tiles.len)
    read = 0
    write = 1
  queue[0] = start
  result[start] = true
  while read < write:
    let
      i = queue[read]
      x = i mod world.config.width
      y = i div world.config.width
    inc read
    for direction in Directions:
      let neighbor = world.index(x + direction[0], y + direction[1])
      if neighbor < 0 or result[neighbor] or
        world.tiles[neighbor].kind == Mountain:
          continue
      result[neighbor] = true
      queue[write] = neighbor
      inc write

proc connect(world: var World) =
  ## Connects every open region with mirrored corridors in bounded passes.
  let
    centerX = world.config.width div 2
    centerY = world.config.height div 2
  for x in 0 ..< world.config.width:
    world.carve(x, centerY)
  for y in 0 ..< world.config.height:
    world.carve(centerX, y)
  var reached = world.reachable(world.index(centerX, centerY))
  for i in 0 ..< world.tiles.len:
    if world.tiles[i].kind == Mountain or reached[i]:
      continue
    let
      x = i mod world.config.width
      y = i div world.config.width
    for column in min(x, centerX) .. max(x, centerX):
      world.carve(column, y)
    reached = world.reachable(world.index(centerX, centerY))

proc newWorldLegacy*(config: Config): World =
  ## Reconstructs the original local reflected map for version 1/2 replays.
  if config.width < 13 or config.width > 61 or
    config.height < 13 or config.height > 61:
      raise newException(GeneralsError, "Map dimensions must be 13 to 61.")
  if config.players notin [2, 4]:
    raise newException(GeneralsError, "A match needs two or four players.")
  if config.seed < 0:
    raise newException(GeneralsError, "Map seed must not be negative.")
  if config.maxTurns < 1 or config.maxTurns > 100_000:
    raise newException(GeneralsError, "Turn limit must be 1 to 100000.")
  result.config = config
  result.winner = -1
  result.tiles = newSeq[Tile](config.width * config.height)
  result.generals = newSeq[int](config.players)
  result.alive = newSeq[bool](config.players)
  var random = uint32(config.seed and 0xffff_ffff) xor 0xa3c5_9ac3'u32
  if random == 0:
    random = 1
  for tile in result.tiles.mitems:
    tile.owner = -1
  for y in 0 ..< (config.height + 1) div 2:
    for x in 0 ..< (config.width + 1) div 2:
      if random.next(100) < 25:
        for i in result.mirrors(x, y):
          result.tiles[i].kind = Mountain
  let corners = [
    (2, 2),
    (config.width - 3, config.height - 3),
    (config.width - 3, 2),
    (2, config.height - 3)
  ]
  for corner in corners:
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        result.carve(corner[0] + dx, corner[1] + dy)
  result.connect()
  var candidates: seq[int]
  for y in 1 ..< config.height div 2:
    for x in 1 ..< config.width div 2:
      let i = result.index(x, y)
      if result.tiles[i].kind != Plain or abs(x - 2) + abs(y - 2) < 4:
        continue
      candidates.add(i)
  for group in 0 ..< min(2, candidates.len):
    let
      choice = random.next(candidates.len)
      i = candidates[choice]
      army = 40 + random.next(11)
    candidates.delete(choice)
    for cell in result.mirrors(i mod config.width, i div config.width):
      result.tiles[cell].kind = City
      result.tiles[cell].army = army
  for player in 0 ..< config.players:
    let
      corner = corners[player]
      i = result.index(corner[0], corner[1])
    result.generals[player] = i
    result.alive[player] = true
    result.tiles[i] = Tile(kind: General, owner: player.int8, army: 1)

proc geometry(world: World, move: Move): Geometry =
  ## Retains intent coordinates while clipping only the board sampling cells.
  let
    width = world.config.width
    height = world.config.height
  if move.raw:
    result.sourceX = move.column
    result.sourceY = move.row
    if move.direction < 0 or move.direction >= ActionDirections.len:
      result.passing = true
    else:
      let direction = ActionDirections[move.direction]
      result.targetX = move.column + direction[0]
      result.targetY = move.row + direction[1]
  else:
    result.passing = move.source < 0
    result.sourceX = move.source mod width
    result.sourceY = move.source div width
    result.targetX = move.target mod width
    result.targetY = move.target div width
    if move.target < 0:
      result.targetX = -1
      result.targetY = -1
  result.valid = not result.passing and
    result.sourceX >= 0 and result.sourceX < width and
    result.sourceY >= 0 and result.sourceY < height and
    result.targetX >= 0 and result.targetX < width and
    result.targetY >= 0 and result.targetY < height and
    abs(result.sourceX - result.targetX) +
      abs(result.sourceY - result.targetY) == 1
  result.source =
    clamp(result.sourceY, 0, height - 1) * width +
    clamp(result.sourceX, 0, width - 1)
  result.target =
    clamp(result.targetY, 0, height - 1) * width +
    clamp(result.targetX, 0, width - 1)

proc legal(world: World, player: int, intent: Geometry): bool =
  ## Applies the reference FFA validity rule, including zero-army transfers.
  player >= 0 and player < world.config.players and intent.valid and
    world.alive[player] and world.tiles[intent.source].owner == player and
    world.tiles[intent.source].army >= 1 and
    world.tiles[intent.target].kind != Mountain

proc validMove*(world: World, player: int, move: Move): bool =
  ## Reports whether a valid command would move at least one army.
  let intent = world.geometry(move)
  world.legal(player, intent) and world.tiles[intent.source].army > 1

proc amount(world: World, intent: Geometry, half: bool): int =
  ## Computes the sent army while always retaining one unit at the source.
  let army = world.tiles[intent.source].army
  max(0, min(if half: army div 2 else: army - 1, army - 1))

proc lastStanding(world: var World) =
  ## Records the only surviving player without replacing an existing winner.
  if world.winner >= 0:
    return
  var
    survivors = 0
    last = -1
  for player, alive in world.alive:
    if alive:
      inc survivors
      last = player
  if survivors == 1:
    world.winner = last

proc capture(world: var World, player, victim: int) =
  ## Eliminates a rival and transfers each remaining army at half rounded up.
  world.alive[victim] = false
  for tile in world.tiles.mitems:
    if tile.owner == victim:
      tile.owner = player.int8
      tile.army = (tile.army + 1) div 2
      if tile.kind == General:
        tile.kind = City
  world.lastStanding()

proc move(world: var World, player: int, action: Move, intent: Geometry,
    report: var StepReport) =
  ## Applies one legal transfer or attack, including general elimination.
  if not world.legal(player, intent):
    return
  let
    source = intent.source
    target = intent.target
    sent = world.amount(intent, action.half)
  report.executed[player] = sent > 0
  let defender = world.tiles[target].owner
  if defender >= 0 and defender != player:
    report.damage[player][defender] += min(sent, world.tiles[target].army)
  world.tiles[source].army -= sent
  if world.tiles[target].owner == player:
    world.tiles[target].army += sent
    return
  if sent <= world.tiles[target].army:
    world.tiles[target].army -= sent
    return
  let
    victim = world.tiles[target].owner
    general = world.tiles[target].kind == General
  world.tiles[target].army = sent - world.tiles[target].army
  world.tiles[target].owner = player.int8
  if general:
    world.tiles[target].kind = City
    if victim >= 0:
      report.capturedBy[victim] = player
      report.eliminationOrder.add victim
      world.capture(player, victim)

proc order(
    world: World,
    intents: array[MaxPlayers, Geometry]
): array[MaxPlayers, int] {.measure.} =
  ## Sorts defensive moves, general attacks, armies, ties, and chase chains.
  let count = world.config.players
  var
    defensive, general, queued: array[MaxPlayers, bool]
    armies, ranks: array[MaxPlayers, int]
    dependencies: array[MaxPlayers, array[MaxPlayers, bool]]
  for player in 0 ..< count:
    let intent = intents[player]
    defensive[player] = not intent.passing and
      world.tiles[intent.target].owner == player
    general[player] = not intent.passing and
      world.tiles[intent.target].kind == General
    armies[player] =
      if intent.passing:
        -1
      else:
        world.tiles[intent.source].army
  for i in 0 ..< count:
    for j in 0 ..< count:
      if i == j:
        continue
      let before =
        if intents[j].passing != intents[i].passing:
          not intents[j].passing
        elif defensive[j] != defensive[i]:
          defensive[j]
        elif general[j] != general[i]:
          not general[j]
        elif armies[j] != armies[i]:
          armies[j] > armies[i]
        elif world.turn mod 2 == 0:
          j < i
        else:
          j > i
      if before:
        inc ranks[i]
      let
        enters = intents[j].targetX == intents[i].sourceX and
          intents[j].targetY == intents[i].sourceY
        reverse = intents[i].targetX == intents[j].sourceX and
          intents[i].targetY == intents[j].sourceY
      dependencies[j][i] = enters and not reverse and
        not intents[j].passing and not intents[i].passing
  for position in 0 ..< count:
    var
      free = -1
      any = -1
    for player in 0 ..< count:
      if queued[player]:
        continue
      if any < 0 or ranks[player] < ranks[any]:
        any = player
      var blocked = false
      for chaser in 0 ..< count:
        if dependencies[chaser][player] and not queued[chaser]:
          blocked = true
      if not blocked and (free < 0 or ranks[player] < ranks[free]):
        free = player
    let player = if free >= 0: free else: any
    result[position] = player
    queued[player] = true

proc general(world: World, player: int): int =
  ## Finds a player's live general by its current ownership mask.
  for i, tile in world.tiles:
    if tile.kind == General and tile.owner == player:
      return i
  0

proc trade(
    world: var World,
    moves: openArray[Move],
    intents: array[MaxPlayers, Geometry],
    first, second: int,
    report: var StepReport
): bool {.measure.} =
  ## Exchanges generals and territory when both pending attacks capture.
  let
    firstMove = intents[first]
    secondMove = intents[second]
  if not world.legal(first, firstMove) or
    not world.legal(second, secondMove):
      return false
  if (firstMove.target != 0 and
    (world.tiles[firstMove.target].kind != General or
    world.tiles[firstMove.target].owner != second)) or
    (secondMove.target != 0 and
    (world.tiles[secondMove.target].kind != General or
    world.tiles[secondMove.target].owner != first)):
      return false
  let
    firstGeneral = world.general(first)
    secondGeneral = world.general(second)
  if firstMove.target != secondGeneral or secondMove.target != firstGeneral:
    return false
  let
    firstArmy = world.amount(firstMove, moves[first].half)
    secondArmy = world.amount(secondMove, moves[second].half)
    firstReserve = world.tiles[firstMove.source].army - firstArmy
    secondReserve = world.tiles[secondMove.source].army - secondArmy
    firstGarrison =
      if firstMove.source == firstGeneral:
        firstReserve
      else:
        world.tiles[firstGeneral].army
    secondGarrison =
      if secondMove.source == secondGeneral:
        secondReserve
      else:
        world.tiles[secondGeneral].army
  if firstArmy <= secondGarrison or secondArmy <= firstGarrison:
    return false
  world.tiles[firstMove.source].army = firstReserve
  world.tiles[secondMove.source].army = secondReserve
  for i, tile in world.tiles.mpairs:
    if i == firstGeneral or i == secondGeneral:
      continue
    if tile.owner == first:
      tile.owner = second.int8
      tile.army = (tile.army + 1) div 2
    elif tile.owner == second:
      tile.owner = first.int8
      tile.army = (tile.army + 1) div 2
  world.tiles[firstGeneral].owner = second.int8
  world.tiles[firstGeneral].army = secondArmy - firstGarrison
  world.tiles[secondGeneral].owner = first.int8
  world.tiles[secondGeneral].army = firstArmy - secondGarrison
  world.generals[first] = secondGeneral
  world.generals[second] = firstGeneral
  report.executed[first] = true
  report.executed[second] = true
  report.damage[first][second] += secondGarrison
  report.damage[second][first] += firstGarrison
  true

proc step*(world: var World, moves: openArray[Move], generalTrades = true):
    StepReport {.discardable, measure.} =
  ## Matches the reference classic step, including trades and terminal ticks.
  assert world.alive.len == world.config.players
  assert world.generals.len == world.config.players
  assert world.tiles.len == world.config.width * world.config.height
  assert world.config.players in 2 .. MaxPlayers
  let doneBefore = world.winner >= 0
  result.executed = newSeq[bool](world.config.players)
  result.capturedBy = newSeq[int](world.config.players)
  result.damage = newSeq[seq[int]](world.config.players)
  for player in 0 ..< world.config.players:
    result.capturedBy[player] = -1
    result.damage[player] = newSeq[int](world.config.players)
  var
    actions: array[MaxPlayers, Move]
    intents: array[MaxPlayers, Geometry]
    consumed: array[MaxPlayers, bool]
  for player in 0 ..< world.config.players:
    actions[player] = if player < moves.len: moves[player] else: noMove()
    intents[player] = world.geometry(actions[player])
  let ordered = world.order(intents)
  for i in 0 ..< world.config.players:
    let player = ordered[i]
    if consumed[player]:
      continue
    for j in i + 1 ..< world.config.players:
      let other = ordered[j]
      if generalTrades and not consumed[other] and world.trade(actions, intents, player, other, result):
        consumed[player] = true
        consumed[other] = true
        break
    if not consumed[player]:
      world.move(player, actions[player], intents[player], result)
  if not doneBefore:
    inc world.turn
  world.lastStanding()
  if world.winner < 0 and world.turn mod 2 == 0:
    let landGrowth = world.turn mod 50 == 0
    for tile in world.tiles.mitems:
      if tile.owner < 0:
        continue
      if tile.kind in {City, General}:
        inc tile.army
      if landGrowth:
        inc tile.army
  world.finished = world.winner >= 0

proc tick*(world: var World, moves: openArray[Move]) =
  ## Advances a local episode, stopping at conquest or a drawn turn limit.
  if world.finished:
    return
  world.step(moves)
  if world.turn >= world.config.maxTurns:
    world.finished = true
