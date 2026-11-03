import
  std/[strutils, unicode],
  generals/[common, events, worlds]

proc fixture(players = 2): World =
  ## Builds an open board with distinct generals for event scenarios.
  result.config = Config(
    width: 5,
    height: 5,
    players: players,
    seed: 1,
    maxTurns: DefaultTurns
  )
  result.tiles = newSeq[Tile](25)
  result.generals = newSeq[int](players)
  result.alive = newSeq[bool](players)
  result.winner = -1
  for tile in result.tiles.mitems:
    tile.owner = -1
  for player in 0 ..< players:
    let index = [0, 24, 4, 20][player]
    result.generals[player] = index
    result.alive[player] = true
    result.tiles[index] = Tile(kind: General, owner: player.int8, army: 1)

proc advance(log: var MatchLog, world: var World, moves: openArray[Move]) =
  ## Records events around one real production tick.
  let before = world.snapshotEvents()
  world.tick(moves)
  log.recordTick(before, world, moves)

echo "Testing bounded local chat and match resets"
block:
  var log: MatchLog
  log.resetLog()
  doAssert log.entries.len == 1
  doAssert log.entries[0].kind == Notice
  doAssert log.entries[0].text == "Chat is local to this match."
  doAssert not log.addChat(0, 0, " \t\r\n ")
  doAssert not log.addChat(-1, 0, "hello")
  doAssert not log.addChat(MaxPlayers, 0, "hello")
  doAssert log.addChat(0, 3, " hello\tworld\n\x01 ")
  doAssert log.entries[^1].text == "hello world"
  doAssert log.entries[^1].player == 0
  doAssert log.entries[^1].turn == 3
  doAssert log.addChat(1, 4, "é".repeat(MaxChatCharacters + 20))
  doAssert log.entries[^1].text.runeLen == MaxChatCharacters
  doAssert log.entries[^1].text.validateUtf8 == -1
  doAssert log.addChat(1, 4, "x".repeat(MaxChatCharacters - 1) & " tail")
  doAssert log.entries[^1].text == "x".repeat(MaxChatCharacters - 1)
  var rejected = false
  try:
    discard log.addChat(0, 0, "\xFF")
  except GeneralsError:
    rejected = true
  doAssert rejected
  for i in 0 ..< MaxLogEntries + 20:
    doAssert log.addChat(0, i, $i)
  doAssert log.entries.len == MaxLogEntries
  doAssert log.entries[0].text == "20"
  doAssert log.entries[^1].text == $(MaxLogEntries + 19)
  log.resetLog()
  doAssert log.entries.len == 1
  doAssert log.entries[0].kind == Notice

echo "Testing capture and victory notices are recorded exactly once"
block:
  var
    world = fixture()
    log: MatchLog
  log.resetLog()
  world.tiles[23] = Tile(owner: 0, army: 10)
  let
    moves = [Move(source: 23, target: 24), noMove()]
    before = world.snapshotEvents()
  world.tick(moves)
  log.recordTick(before, world, moves)
  doAssert log.entries.len == 3
  doAssert log.entries[1].kind == Capture
  doAssert log.entries[1].player == 0
  doAssert log.entries[1].target == 1
  doAssert log.entries[1].turn == 1
  doAssert log.entries[2].kind == Victory
  doAssert log.entries[2].player == 0
  log.recordTick(before, world, moves)
  log.advance(world, moves)
  doAssert log.entries.len == 3

echo "Testing surviving general trades do not announce eliminations"
block:
  var
    world = fixture()
    log: MatchLog
  log.resetLog()
  world.tiles[0] = Tile(owner: -1)
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(kind: General, owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 8)
  world.generals = @[12, 13]
  log.advance(world, [
    Move(source: 12, target: 13),
    Move(source: 13, target: 12)
  ])
  doAssert world.generals == @[13, 12]
  doAssert world.alive == @[true, true]
  doAssert log.entries.len == 1

echo "Testing captures after a surviving general changes position"
block:
  var
    world = fixture(4)
    log: MatchLog
  log.resetLog()
  world.tiles[0] = Tile(owner: -1)
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(kind: General, owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 8)
  world.tiles[7] = Tile(owner: 2, army: 8)
  world.generals[0] = 12
  world.generals[1] = 13
  log.advance(world, [
    Move(source: 12, target: 13),
    Move(source: 13, target: 12),
    Move(source: 7, target: 12),
    noMove()
  ])
  doAssert world.generals[1] == 12
  doAssert world.alive[0] and not world.alive[1]
  doAssert log.entries.len == 2
  doAssert log.entries[1].player == 2 and log.entries[1].target == 1

echo "Testing immediate captors survive chained ownership transfers"
block:
  var
    world = fixture(4)
    log: MatchLog
  log.resetLog()
  world.tiles[23] = Tile(owner: 0, army: 20)
  world.tiles[1] = Tile(owner: 2, army: 10)
  log.advance(world, [
    Move(source: 23, target: 24),
    noMove(),
    Move(source: 1, target: 0),
    noMove()
  ])
  doAssert not world.alive[0] and not world.alive[1]
  doAssert world.tiles[24].owner == 2
  doAssert log.entries.len == 3
  doAssert log.entries[1].kind == Capture
  doAssert log.entries[1].player == 0 and log.entries[1].target == 1
  doAssert log.entries[2].player == 2 and log.entries[2].target == 0

echo "Testing ambiguous attacks do not invent a capturing player"
block:
  var
    world = fixture(4)
    log: MatchLog
  log.resetLog()
  world.tiles[23] = Tile(owner: 0, army: 20)
  world.tiles[19] = Tile(owner: 2, army: 10)
  log.advance(world, [
    Move(source: 23, target: 24),
    noMove(),
    Move(source: 19, target: 24),
    noMove()
  ])
  doAssert not world.alive[1]
  doAssert log.entries.len == 2
  doAssert log.entries[1].kind == Capture
  doAssert log.entries[1].player == -1
  doAssert log.entries[1].target == 1

echo "Testing raw capture commands and drawn turn limits"
block:
  var
    world = fixture()
    log: MatchLog
  log.resetLog()
  world.tiles[23] = Tile(owner: 0, army: 10)
  log.advance(world, [actionMove(4, 3, 3), noMove()])
  doAssert log.entries[1].player == 0
  doAssert log.entries[1].target == 1
block:
  var
    world = fixture()
    log: MatchLog
  log.resetLog()
  world.config.maxTurns = 1
  log.advance(world, [])
  doAssert log.entries.len == 2
  doAssert log.entries[1].kind == Draw
  doAssert log.entries[1].player == -1
  log.advance(world, [])
  doAssert log.entries.len == 2

echo "Local event checks passed"
