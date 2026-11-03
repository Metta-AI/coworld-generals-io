import generals/[common, povs, visions, worlds]

echo "Testing replay player views"

for players in 2 .. MaxPlayers:
  var
    world = newWorld(defaultConfig(seed = 7, players = players))
    pov = newPov(world)
    visible, scratch: seq[bool]
  pov.updateVisibility(world, visible, scratch)
  doAssert pov.orientation == -1
  doAssert visible.len == world.tiles.len
  for shown in visible:
    doAssert shown

  pov.togglePlayer(world, 0)
  pov.updateVisibility(world, visible, scratch)
  doAssert visible == world.visibility(0)
  pov.togglePlayer(world, 1)
  pov.updateVisibility(world, visible, scratch)
  let
    first = world.visibility(0)
    second = world.visibility(1)
  for i in 0 ..< visible.len:
    doAssert visible[i] == (first[i] or second[i])

  for player in 0 ..< players:
    pov.toggleOrientation(player)
    doAssert pov.orientation == player
    let
      home = pov.origins[player]
      x = home mod world.config.width
      y = home div world.config.width
    doAssert pov.coordinates(world.config, home) == (
      min(x, world.config.width - 1 - x),
      min(y, world.config.height - 1 - y)
    )
    doAssert pov.selected[0] and pov.selected[1]
    pov.toggleOrientation(player)
    doAssert pov.orientation == -1
  pov.toggleOrientation(1)
  let home = pov.origins[1]
  swap(world.generals[0], world.generals[1])
  doAssert pov.origins[1] == home
  doAssert pov.coordinates(world.config, home) == (
    min(home mod world.config.width,
      world.config.width - 1 - home mod world.config.width),
    min(home div world.config.width,
      world.config.height - 1 - home div world.config.width)
  )

  world.alive[0] = false
  pov.updateVisibility(world, visible, scratch)
  doAssert not pov.selected[0]
  doAssert visible == second
  pov.togglePlayer(world, 0)
  doAssert not pov.selected[0]
  for tile in world.tiles.mitems:
    if tile.owner == 1:
      tile.owner = -1
  pov.updateVisibility(world, visible, scratch)
  doAssert not pov.selected[1]
  for shown in visible:
    doAssert shown
  pov.togglePlayer(world, 1)
  doAssert not pov.selected[1]
  doAssert pov.orientation == 1

  pov.togglePlayer(world, -1)
  pov.togglePlayer(world, MaxPlayers)
  pov.toggleOrientation(-1)
  pov.toggleOrientation(MaxPlayers)
  doAssert pov.orientation == 1
  doAssert pov.coordinates(world.config, -1) == (-1, -1)
  doAssert pov.coordinates(world.config, world.tiles.len) == (-1, -1)
  if players == 2:
    pov.togglePlayer(world, 2)
    pov.toggleOrientation(2)
    doAssert not pov.selected[2]
    doAssert pov.orientation == 1

block:
  let world = newWorld(defaultConfig(seed = 7, players = MaxPlayers))
  var
    pov = newPov(world)
    visible, scratch: seq[bool]
  pov.togglePlayer(world, MaxPlayers - 1)
  pov.updateVisibility(world, visible, scratch)
  doAssert visible == world.visibility(MaxPlayers - 1)
  pov.toggleOrientation(MaxPlayers - 1)
  doAssert pov.orientation == MaxPlayers - 1
  for i in 0 ..< world.tiles.len:
    let position = pov.coordinates(world.config, i)
    doAssert position.x in 0 ..< world.config.width
    doAssert position.y in 0 ..< world.config.height
    doAssert pov.coordinates(
      world.config, position.y * world.config.width + position.x
    ) == (i mod world.config.width, i div world.config.width)

echo "Replay player view checks passed"
