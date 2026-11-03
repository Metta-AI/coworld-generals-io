import generals/[common, controls]

proc fixture(): World =
  ## Creates a small board for input and queued-order boundary checks.
  result.config = Config(width: 5, height: 5, players: 2)
  result.tiles = newSeq[Tile](25)
  for tile in result.tiles.mitems:
    tile.owner = -1
  result.tiles[0] = Tile(kind: General, owner: 0, army: 20)
  result.tiles[24] = Tile(kind: General, owner: 1, army: 20)
  result.generals = @[0, 24]
  result.alive = @[true, true]

echo "Testing bounded local controls"

block:
  let world = fixture()
  var controls = newControls(0)
  doAssert not controls.step(world, -1, 0)
  doAssert not controls.step(world, 0, -1)
  doAssert not controls.enqueue(world, 6)
  doAssert controls.moves.len == 0
  controls.select(world, 24)
  doAssert controls.selected == 0
  doAssert controls.step(world, 1, 0, half = true)
  doAssert controls.step(world, 1, 0)
  let first = controls.takeMove()
  doAssert first == Move(source: 0, target: 1, half: true)
  doAssert controls.takeMove() == Move(source: 1, target: 2)
  doAssert controls.takeMove() == noMove()

block:
  let world = fixture()
  var controls = newControls(0)
  doAssert controls.enqueue(world, 1)
  doAssert controls.enqueue(world, 2)
  let move = controls.takeMove()
  controls.reconcile(world, move)
  doAssert controls.moves.len == 0
  doAssert controls.selected == 0

block:
  var
    world = fixture()
    controls = newControls(0)
  controls.half = true
  doAssert controls.step(world, 1, 0)
  let move = controls.takeMove()
  doAssert move.half
  world.tiles[1].owner = 0
  controls.reconcile(world, move)
  doAssert controls.selected == 1
  controls.select(world, 0)
  doAssert controls.selected == 0

block:
  let world = fixture()
  var controls = newControls(0)
  doAssert controls.enqueue(world, 1)
  doAssert controls.enqueue(world, 2)
  controls.clear(world)
  doAssert controls.moves.len == 0
  doAssert controls.selected == 0
  doAssert controls.enqueue(world, 1)

block:
  let world = fixture()
  var controls = newControls(0)
  for i in 0 ..< MaxQueuedMoves:
    doAssert controls.enqueue(world, if i mod 2 == 0: 1 else: 0)
  doAssert not controls.enqueue(world, 1)
  doAssert controls.moves.len == MaxQueuedMoves
  controls.clear()
  doAssert controls.moves.len == 0

echo "Testing the tenth human seat owns its controls"
block:
  var world = fixture()
  world.config.players = MaxPlayers
  world.generals.setLen(MaxPlayers)
  world.alive.setLen(MaxPlayers)
  world.generals[^1] = 24
  world.alive[^1] = true
  world.tiles[24].owner = (MaxPlayers - 1).int8
  var controls = newControls(24, MaxPlayers - 1)
  doAssert controls.player == MaxPlayers - 1
  controls.select(world, 0)
  doAssert controls.selected == 24
  doAssert controls.step(world, -1, 0)
  doAssert controls.step(world, -1, 0)
  let first = controls.takeMove()
  doAssert first == Move(source: 24, target: 23)
  world.tiles[23] = Tile(owner: (MaxPlayers - 1).int8, army: 19)
  controls.reconcile(world, first)
  doAssert controls.moves.len == 1 and controls.selected == 22
  controls.clear(world)
  doAssert controls.selected == 23 and controls.moves.len == 0
  doAssert controls.enqueue(world, 22)
  let failed = controls.takeMove()
  controls.reconcile(world, failed)
  doAssert controls.selected == 23 and controls.moves.len == 0
  controls.select(world, 24)
  doAssert controls.selected == 24
  world.tiles[19] = world.tiles[24]
  world.tiles[24].owner = -1
  world.generals[^1] = 19
  controls.reconcile(world, Move(source: 24, target: 23))
  doAssert controls.selected == 19
  controls.selected = -1
  controls.moves = @[Move(source: -1, target: 0), Move(source: 99, target: 0)]
  controls.clear(world)
  doAssert controls.selected == 19 and controls.moves.len == 0
  world.alive[^1] = false
  doAssert not controls.enqueue(world, 18)
  controls.reconcile(world, noMove())
  doAssert controls.selected == -1 and controls.moves.len == 0

echo "Testing spectator and unavailable seats cannot issue orders"
for player in [-1, 2, MaxPlayers, int.high]:
  let world = fixture()
  var controls = newControls(0, player)
  controls.select(world, 0)
  doAssert not controls.enqueue(world, 1)
  doAssert not controls.step(world, 1, 0)
  controls.clear(world)
  doAssert controls.selected == -1 and controls.moves.len == 0
  controls.selected = 0
  controls.moves = @[Move(source: 0, target: 1)]
  controls.reconcile(world, noMove())
  doAssert controls.selected == -1 and controls.moves.len == 0
  doAssert controls.takeMove() == noMove()

echo "Local control checks passed"
