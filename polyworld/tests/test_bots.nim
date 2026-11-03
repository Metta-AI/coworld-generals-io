import ../src/generals/[bots, common, visions, worlds]

proc assertHidden(world: World, player: int) =
  ## Checks that changing concealed opponents and obstacles cannot guide a bot.
  let
    visible = visibility(world, player)
    expected = chooseMove(world, player)
  var changed = World(
    config: world.config,
    tiles: newSeq[Tile](world.tiles.len),
    generals: newSeq[int](world.generals.len),
    alive: world.alive,
    turn: world.turn,
    winner: world.winner,
    finished: world.finished
  )
  for i in 0 ..< world.tiles.len:
    changed.tiles[i] = world.tiles[i]
  for i in 0 ..< world.generals.len:
    changed.generals[i] = world.generals[i]
  for i in 0 ..< changed.tiles.len:
    if visible[i]:
      continue
    changed.tiles[i].owner = ((player + 1) mod world.config.players).int8
    changed.tiles[i].army = 10_000 + i
    case changed.tiles[i].kind
    of Mountain:
      changed.tiles[i].kind = City
    of City:
      changed.tiles[i].kind = Mountain
    of Plain:
      changed.tiles[i].kind = General
    of General:
      changed.tiles[i].kind = Plain
  for opponent in 0 ..< changed.generals.len:
    if opponent != player:
      changed.generals[opponent] = -1
  doAssert chooseMove(changed, player) == expected

proc play(seed, players: int): World =
  ## Runs complete seeded bot matches through the real game engine.
  result = newWorld(defaultConfig(seed, players))
  var
    moves = newSeq[Move](players)
    scratch: BotScratch
  while not result.finished:
    for player in 0 ..< players:
      moves[player] = chooseMove(result, player, scratch)
      doAssert moves[player] == noMove() or
        validMove(result, player, moves[player])
      if result.turn in [80, 300] and result.alive[player]:
        assertHidden(result, player)
    result.tick(moves)

echo "Testing fog-respecting bot decisions"
block:
  var world = newWorld(defaultConfig(7, 4))
  world.tiles[world.generals[0]].army = 80
  assertHidden(world, 0)
  doAssert chooseMove(world, -1) == noMove()
  doAssert chooseMove(world, 4) == noMove()

echo "Testing bots capture exposed generals"
block:
  var world = newWorldLegacy(defaultConfig(4, 2))
  let
    source = world.generals[0]
    target = source + 1
  world.tiles[source].army = 20
  world.tiles[target] = Tile(kind: General, owner: 1, army: 2)
  world.generals[1] = target
  let action = chooseMove(world, 0)
  doAssert action.source == source
  doAssert action.target == target
  world.tick([action, noMove()])
  doAssert world.finished and world.winner == 0

echo "Testing scratch reuse across players, restarts, and rectangular grids"
block:
  var scratch: BotScratch
  for round, dimensions in [
    (13, 13, 2), (23, 19, 4), (18, 21, 2),
    (21, 18, 4), (23, 23, 5), (23, 19, 2)
  ]:
    var config = defaultConfig(7 + round, dimensions[2])
    config.width = dimensions[0]
    config.height = dimensions[1]
    var
      world = newWorld(config)
      moves = newSeq[Move](config.players)
    world.turn = 67
    for player in 0 ..< config.players:
      world.tiles[world.generals[player]].army = 16 + player
    for turn in 0 ..< 12:
      for player in countdown(config.players - 1, 0):
        let expected = chooseMove(world, player)
        moves[player] = chooseMove(world, player, scratch)
        doAssert moves[player] == expected,
          "Reused work buffers changed a decision."
      for player in 0 ..< config.players:
        doAssert chooseMove(world, player, scratch) == moves[player],
          "Player evaluation order changed a decision."
      world.tick(moves)

echo "Testing bots reinforce a threatened general"
block:
  var world = newWorldLegacy(defaultConfig(4, 2))
  let
    home = world.generals[0]
    source = home - world.config.width
    enemy = home + 1
  world.tiles[home].army = 3
  world.tiles[source] = Tile(kind: Plain, owner: 0, army: 50)
  world.tiles[enemy] = Tile(kind: Plain, owner: 1, army: 30)
  let action = chooseMove(world, 0)
  doAssert action.source == source
  doAssert action.target == home
  world.tick([action, Move(source: enemy, target: home)])
  doAssert world.alive[0]

echo "Testing complete seeded bot matches"
var conquests = 0
for players in 2 .. MaxPlayers:
  for seed in [7, 23]:
    let world = play(seed, players)
    var survivors = 0
    for alive in world.alive:
      if alive:
        inc survivors
    echo "Seed ", seed, ", players ", players, ", turns ", world.turn,
      ", winner ", world.winner, ", survivors ", survivors
    doAssert world.finished
    doAssert world.turn <= DefaultTurns
    conquests += players - survivors
    if world.winner >= 0:
      doAssert survivors == 1
      doAssert world.alive[world.winner]
    else:
      doAssert world.turn == DefaultTurns
      doAssert survivors > 1
doAssert conquests > 0, "Seeded bots should capture at least one general"
