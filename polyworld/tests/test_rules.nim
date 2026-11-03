import generals/[common, worlds, visions]

proc fixture(players = 2): World =
  ## Builds a small open board for focused rule scenarios.
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
    let i = [0, 24, 4, 20][player]
    result.generals[player] = i
    result.alive[player] = true
    result.tiles[i] = Tile(kind: General, owner: player.int8, army: 1)

proc attack(source, target: int, half = false): Move =
  ## Creates one movement action for a rule scenario.
  Move(source: source, target: target, half: half)

proc assertConnected(world: World) =
  ## Requires every non-mountain tile to be reachable from a general.
  var
    seen = newSeq[bool](world.tiles.len)
    queue = @[world.generals[0]]
    read = 0
  seen[queue[0]] = true
  while read < queue.len:
    let
      i = queue[read]
      x = i mod world.config.width
      y = i div world.config.width
    inc read
    for direction in Directions:
      let neighbor = world.index(x + direction[0], y + direction[1])
      if neighbor < 0 or seen[neighbor] or
        world.tiles[neighbor].kind == Mountain:
          continue
      seen[neighbor] = true
      queue.add(neighbor)
  for i, tile in world.tiles:
    doAssert tile.kind == Mountain or seen[i]

echo "Testing cardinal moves and movement boundaries"
block:
  var world = fixture()
  world.tiles[12] = Tile(owner: 0, army: 10)
  doAssert world.validMove(0, attack(12, 13))
  doAssert not world.validMove(1, attack(12, 13))
  doAssert not world.validMove(0, attack(12, 18))
  doAssert not world.validMove(0, attack(12, 12))
  doAssert not world.validMove(0, attack(-1, 12))
  doAssert not world.validMove(0, attack(12, 25))
  doAssert not world.validMove(-1, attack(12, 13))
  doAssert not world.validMove(2, attack(12, 13))
  world.tiles[13].kind = Mountain
  doAssert not world.validMove(0, attack(12, 13))
  world.tiles[13].kind = Plain
  world.tick([attack(12, 13), noMove()])
  doAssert world.tiles[12].army == 1
  doAssert world.tiles[13] == Tile(owner: 0, army: 9)
  doAssert not world.validMove(0, attack(12, 13))
  doAssert world.index(-1, 0) == -1
  doAssert world.index(5, 0) == -1
  doAssert world.index(0, -1) == -1
  doAssert world.index(0, 5) == -1
  doAssert world.index(4, 4) == 24
  world.tiles[4] = Tile(owner: 0, army: 10)
  doAssert not world.validMove(0, attack(4, 5))

echo "Testing half moves, reinforcement, and exact defense ties"
block:
  var world = fixture()
  world.tiles[12] = Tile(owner: 0, army: 11)
  world.tiles[13] = Tile(owner: 0, army: 7)
  world.tick([attack(12, 13, true)])
  doAssert world.tiles[12].army == 6
  doAssert world.tiles[13].army == 12
block:
  var world = fixture()
  world.tiles[12] = Tile(owner: 0, army: 7)
  world.tiles[13] = Tile(owner: 1, army: 6)
  world.tick([attack(12, 13)])
  doAssert world.tiles[13] == Tile(owner: 1, army: 0)
  world.tiles[12].army = 2
  world.tick([attack(12, 13)])
  doAssert world.tiles[13] == Tile(owner: 0, army: 1)

echo "Testing structure and land growth"
block:
  var world = fixture()
  world.tiles[12] = Tile(owner: 0, army: 3)
  world.tiles[13] = Tile(kind: City, owner: 0, army: 10)
  world.tiles[14] = Tile(kind: City, owner: -1, army: 40)
  world.tick([])
  doAssert world.tiles[0].army == 1
  doAssert world.tiles[13].army == 10
  world.tick([])
  doAssert world.tiles[0].army == 2
  doAssert world.tiles[13].army == 11
  doAssert world.tiles[12].army == 3
  doAssert world.tiles[14].army == 40
  world.turn = 49
  world.tick([])
  doAssert world.tiles[0].army == 4
  doAssert world.tiles[13].army == 13
  doAssert world.tiles[12].army == 4
  doAssert world.tiles[14].army == 40

echo "Testing general capture and elimination"
block:
  var world = fixture()
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 2)
  world.tiles[14] = Tile(owner: 1, army: 5)
  world.generals[1] = 13
  world.tick([attack(12, 13), noMove()])
  doAssert world.tiles[13] == Tile(kind: City, owner: 0, army: 7)
  doAssert world.tiles[14] == Tile(owner: 0, army: 3)
  doAssert world.tiles[19].owner == -1
  doAssert not world.alive[1]
  doAssert world.finished and world.winner == 0
  doAssert world.totals(1) == (land: 0, army: 0)
  doAssert world.totals(0) == (land: 4, army: 12)
  world.tick([attack(14, 19)])
  doAssert world.turn == 1
  doAssert world.tiles[19].owner == -1

echo "Testing parity-reversed priority and four-player continuation"
for turn in 0 .. 1:
  var world = fixture()
  world.tiles[11] = Tile(owner: 0, army: 5)
  world.tiles[13] = Tile(owner: 1, army: 5)
  world.turn = turn
  world.tick([attack(11, 12), attack(13, 12)])
  doAssert not world.finished
  doAssert world.tiles[12].owner == turn
  doAssert world.tiles[12].army == 0
for turn in 0 .. 1:
  var
    world = fixture(4)
    moves = [noMove(), noMove(), noMove(), noMove()]
  world.tiles[11] = Tile(owner: 0, army: 5)
  world.tiles[13] = Tile(owner: 3, army: 5)
  world.turn = turn
  moves[0] = attack(11, 12)
  moves[3] = attack(13, 12)
  world.tick(moves)
  doAssert world.tiles[12].owner == (if turn == 0: 0 else: 3)
  doAssert world.tiles[12].army == 0
block:
  var world = fixture(4)
  world.tiles[19] = Tile(owner: 0, army: 10)
  world.tick([attack(19, 24)])
  doAssert not world.alive[1]
  doAssert not world.finished

echo "Testing defensive priority and chased source dependencies"
block:
  var world = fixture()
  world.tiles[11] = Tile(owner: 0, army: 5)
  world.tiles[12] = Tile(owner: 1, army: 1)
  world.tiles[13] = Tile(owner: 1, army: 4)
  world.tick([attack(11, 12), attack(13, 12)])
  doAssert world.tiles[12] == Tile(owner: 1, army: 0)
block:
  var world = fixture()
  world.tiles[10] = Tile(owner: 1, army: 5)
  world.tiles[11] = Tile(owner: 0, army: 20)
  world.tick([attack(11, 12), attack(10, 11)])
  doAssert world.tiles[11] == Tile(owner: 0, army: 1)
  doAssert world.tiles[12] == Tile(owner: 0, army: 15)

echo "Testing general attacks wait behind ordinary moves"
block:
  var world = fixture()
  world.tiles[24] = Tile(owner: -1)
  world.tiles[11] = Tile(owner: 0, army: 30)
  world.tiles[12] = Tile(kind: General, owner: 1, army: 2)
  world.tiles[17] = Tile(owner: 1, army: 10)
  world.generals[1] = 12
  world.tick([attack(11, 12), attack(17, 18)])
  doAssert world.finished and world.winner == 0
  doAssert world.tiles[18] == Tile(owner: 0, army: 5)

echo "Testing mutual general trades and transferred reserves"
block:
  var world = fixture()
  world.tiles[0] = Tile(owner: -1)
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(kind: General, owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 8)
  world.tiles[5] = Tile(owner: 0, army: 5)
  world.tiles[22] = Tile(owner: 1, army: 6)
  world.generals = @[12, 13]
  world.step([attack(12, 13), attack(13, 12)])
  doAssert world.generals == @[13, 12]
  doAssert world.alive == @[true, true]
  doAssert not world.finished
  doAssert world.tiles[12] == Tile(kind: General, owner: 1, army: 6)
  doAssert world.tiles[13] == Tile(kind: General, owner: 0, army: 8)
  doAssert world.tiles[5] == Tile(owner: 1, army: 3)
  doAssert world.tiles[22] == Tile(owner: 0, army: 3)
block:
  var world = fixture()
  world.tiles[1] = Tile(owner: 1, army: 9)
  world.tiles[23] = Tile(owner: 0, army: 11)
  world.step([attack(23, 24), attack(1, 0)])
  doAssert world.generals == @[24, 0]
  doAssert world.tiles[0] == Tile(kind: General, owner: 1, army: 7)
  doAssert world.tiles[24] == Tile(kind: General, owner: 0, army: 9)
  doAssert world.tiles[1] == Tile(owner: 0, army: 1)
  doAssert world.tiles[23] == Tile(owner: 1, army: 1)
block:
  var world = fixture()
  world.tiles[0] = Tile(owner: -1)
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(kind: General, owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 10)
  world.generals = @[12, 13]
  world.step([attack(12, 13, true), attack(13, 12, true)])
  doAssert world.generals == @[12, 13]
  doAssert world.tiles[12] == Tile(kind: General, owner: 0, army: 3)
  doAssert world.tiles[13] == Tile(kind: General, owner: 1, army: 3)

echo "Testing terminal income and raw post-win reference steps"
for turn in [1, 49]:
  var world = fixture()
  world.tiles[24] = Tile(owner: -1)
  world.tiles[12] = Tile(owner: 0, army: 10)
  world.tiles[13] = Tile(kind: General, owner: 1, army: 2)
  world.generals[1] = 13
  world.turn = turn
  world.step([attack(12, 13)])
  doAssert world.turn == turn + 1
  doAssert world.tiles[0].army == 1
  doAssert world.tiles[12].army == 1
  doAssert world.tiles[13] == Tile(kind: City, owner: 0, army: 7)
  doAssert world.generals[1] == 13
  world.step([attack(13, 14)])
  doAssert world.turn == turn + 1
  doAssert world.tiles[13] == Tile(kind: City, owner: 0, army: 1)
  doAssert world.tiles[14] == Tile(owner: 0, army: 6)
  doAssert world.finished and world.winner == 0
  world.tick([attack(14, 19)])
  doAssert world.tiles[19].owner == -1

echo "Testing raw off-board and invalid-owner commands"
block:
  var world = fixture()
  world.tiles[0].army = 10
  world.step([actionMove(0, 0, 0), actionMove(0, 0, 3)])
  doAssert world.tiles[0].army == 10
  doAssert world.tiles[1].owner == -1
  world.step([actionMove(0, 0, 3)])
  doAssert world.tiles[1] == Tile(owner: 0, army: 9)

echo "Testing visibility and observations with eliminated land"
block:
  var world = fixture()
  world.tiles[0] = Tile(owner: -1)
  world.tiles[12] = Tile(owner: 0, army: 1)
  let seen = world.visibility(0)
  for i in 0 ..< world.tiles.len:
    let
      x = i mod 5
      y = i div 5
    doAssert seen[i] == (x in 1 .. 3 and y in 1 .. 3)
  world.alive[0] = false
  doAssert world.visibility(0) == seen
  for visible in world.visibility(-1):
    doAssert not visible
  world.tiles[0] = Tile(kind: Mountain, owner: -1)
  world.tiles[4] = Tile(kind: City, owner: -1, army: 40)
  let observation = world.observed(0)
  doAssert observation.kinds[0] == -2
  doAssert observation.kinds[4] == -2
  doAssert observation.kinds[24] == -1
  doAssert observation.owners[24] == -1
  doAssert observation.armies[4] == 0
  doAssert observation.armies[24] == 0
  doAssert observation.kinds[12] == Plain.ord
  doAssert observation.owners[12] == 0
  doAssert observation.armies[12] == 1
  doAssert observation.myLand == 1 and observation.myArmy == 1
  doAssert observation.oppLand == 1 and observation.oppArmy == 1

echo "Testing drawn turn-limit episodes regardless of army and land"
block:
  var world = fixture()
  world.config.maxTurns = 1
  world.tick([])
  doAssert world.finished and world.winner == -1
block:
  var world = fixture()
  world.config.maxTurns = 1
  world.tiles[12] = Tile(owner: 1, army: 5)
  world.tick([])
  doAssert world.finished and world.winner == -1
block:
  var world = fixture()
  world.config.maxTurns = 1
  world.tiles[12] = Tile(owner: 0, army: 0)
  world.tick([])
  doAssert world.finished and world.winner == -1

echo "Testing legacy connected and symmetric replay maps"
for players in [2, 4]:
  for seed in 0 .. 30:
    let
      config = Config(
        width: 23,
        height: 19,
        players: players,
        seed: seed,
        maxTurns: DefaultTurns
      )
      world = newWorldLegacy(config)
      again = newWorldLegacy(config)
    doAssert world == again
    world.assertConnected()
    for player in 0 ..< players:
      doAssert world.totals(player) == (land: 1, army: 1)
      doAssert world.tiles[world.generals[player]].kind == General
    for i, tile in world.tiles:
      let opposite = world.tiles[world.tiles.len - 1 - i]
      doAssert tile.kind == opposite.kind
      doAssert tile.army == opposite.army
for size in [13, 14, 31, 60, 61]:
  var config = defaultConfig(4)
  config.width = size
  config.height = size
  newWorldLegacy(config).assertConnected()

echo "Testing deterministic repeated simulation"
block:
  let config = defaultConfig(7)
  var
    first = newWorld(config)
    second = newWorld(config)
  for turn in 0 ..< 100:
    var moves = newSeq[Move](config.players)
    for player in 0 ..< config.players:
      moves[player] = noMove()
      let
        source = first.generals[player]
        x = source mod config.width
        y = source div config.width
        direction = Directions[(turn + player) mod Directions.len]
      moves[player] = attack(
        source,
        first.index(x + direction[0], y + direction[1])
      )
    first.tick(moves)
    second.tick(moves)
    doAssert first == second

echo "Testing invalid map configuration"
block:
  var config = defaultConfig()
  config.players = 1
  var failed = false
  try:
    discard newWorld(config)
  except GeneralsError:
    failed = true
  doAssert failed

echo "Generals rules passed"
