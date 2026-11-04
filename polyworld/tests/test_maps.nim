import
  polyworld/hashes,
  generals/[common, worlds]

const
  MinimumSpacings = [15, 14, 13, 12, 11, 10, 10, 10, 10]
  DimensionBounds = [
    (18, 23), (19, 25), (20, 26), (21, 28), (22, 29),
    (24, 31), (25, 33), (26, 34), (26, 35)
  ]
  SeedSevenHashes = [
    4066235706'u32, 3981090564'u32, 723501003'u32,
    3333240923'u32, 2136627035'u32, 4217085026'u32,
    1649587078'u32, 3295942409'u32, 2696611605'u32
  ]

proc separation(world: World, first, second: int): int =
  ## Measures cardinal distance between two board cells.
  abs(first mod world.config.width - second mod world.config.width) +
    abs(first div world.config.width - second div world.config.width)

proc assertRoutes(world: World) =
  ## Checks every general pair without crossing cities or a third general.
  for home in world.generals:
    var
      reached = newSeq[bool](world.tiles.len)
      queue = @[home]
      read = 0
    reached[home] = true
    while read < queue.len:
      let
        cell = queue[read]
        x = cell mod world.config.width
        y = cell div world.config.width
      inc read
      for offset in Directions:
        let neighbor = world.index(x + offset[0], y + offset[1])
        if neighbor < 0 or reached[neighbor] or
          world.tiles[neighbor].kind in {Mountain, City}:
            continue
        reached[neighbor] = true
        if world.tiles[neighbor].kind == Plain:
          queue.add(neighbor)
    for other in world.generals:
      doAssert reached[other], "Every general must have an open route."

proc assertMap(world: World) =
  ## Checks classic initial ownership, city defenses, spacing, and access.
  let players = world.config.players
  doAssert world.turn == 0
  doAssert world.winner == -1 and not world.finished
  doAssert world.generals.len == players
  doAssert world.alive.len == players
  doAssert world.tiles.len == world.config.width * world.config.height
  var
    generals: array[MaxPlayers, int]
    cities = 0
    mountains = 0
  for i, tile in world.tiles:
    case tile.kind
    of General:
      doAssert tile.owner in 0 ..< players
      doAssert tile.army == 1
      doAssert world.generals[tile.owner] == i
      inc generals[tile.owner]
    of City:
      doAssert tile.owner == -1
      doAssert tile.army in 40 .. 50
      inc cities
    of Mountain:
      doAssert tile.owner == -1 and tile.army == 0
      inc mountains
    of Plain:
      doAssert tile.owner == -1 and tile.army == 0
  doAssert cities > 0 and mountains > 0
  for player, home in world.generals:
    doAssert generals[player] == 1
    doAssert world.alive[player]
    doAssert world.totals(player) == (land: 1, army: 1)
    for other in player + 1 ..< players:
      doAssert world.separation(home, world.generals[other]) >=
        MinimumSpacings[players - 2]
    if players <= 8:
      var hasCity = false
      for i, tile in world.tiles:
        if tile.kind == City and world.separation(home, i) <= 6:
          hasCity = true
          break
      doAssert hasCity, "Every start needs a nearby city through eight players."
  world.assertRoutes()

proc assertRejected(config: Config) =
  ## Requires invalid or impossible map requests to fail through the API.
  var rejected = false
  try:
    discard newWorld(config)
  except GeneralsError as error:
    doAssert error.msg.len > 0
    rejected = true
  doAssert rejected

echo "Testing reproducible seeded maps for every FFA player count"
for players in 2 .. MaxPlayers:
  doAssert hashy(newWorld(defaultConfig(7, players))) ==
    SeedSevenHashes[players - 2],
    "Changing a recorded map requires a new replay generator version."
  for seed in 0 .. 40:
    let
      config = defaultConfig(seed, players)
      world = newWorld(config)
      bounds = DimensionBounds[players - 2]
    doAssert config.width in bounds[0] .. bounds[1]
    doAssert config.height in bounds[0] .. bounds[1]
    doAssert world.config == config
    world.assertMap()
    doAssert newWorld(config) == world
  for seed in [65535, 1_234_567_890, int32.high.int]:
    let
      config = defaultConfig(seed, players)
      world = newWorld(config)
    world.assertMap()
    doAssert newWorld(config) == world

echo "Testing map randomness stays independent of other games and duration"
block:
  var config = defaultConfig(7, 10)
  let before = newWorld(config)
  discard newWorld(defaultConfig(23, 3))
  config.maxTurns = 1
  let after = newWorld(config)
  doAssert before.tiles == after.tiles
  doAssert before.generals == after.generals
  doAssert before.alive == after.alive

echo "Testing seed variation and asymmetric custom maps"
for players in [2, 3, 7, 10]:
  var config = defaultConfig(7, players)
  config.width = 35
  config.height = 31
  let first = newWorld(config)
  first.assertMap()
  doAssert first.config.width == 35 and first.config.height == 31
  config.seed = 8
  let second = newWorld(config)
  second.assertMap()
  doAssert first.tiles != second.tiles
  var asymmetric = false
  for i, tile in first.tiles:
    if tile.kind != first.tiles[first.tiles.high - i].kind:
      asymmetric = true
      break
  doAssert asymmetric

echo "Testing maximum and rectangular map dimensions"
for dimensions in [(61, 61), (61, 17), (17, 61), (32, 29)]:
  var config = defaultConfig(3, 10)
  config.width = dimensions[0]
  config.height = dimensions[1]
  let world = newWorld(config)
  world.assertMap()
  doAssert newWorld(config) == world

echo "Testing configuration failures and impossible spawn spacing"
for players in [-1, 0, 1, 11, int.high]:
  var config = defaultConfig()
  config.players = players
  config.assertRejected()
for dimension in [-1, 0, 12, 62, int.high]:
  var config = defaultConfig()
  config.width = dimension
  config.assertRejected()
  config = defaultConfig()
  config.height = dimension
  config.assertRejected()
block:
  var rejected = false
  try:
    discard defaultConfig(-1)
  except GeneralsError:
    rejected = true
  doAssert rejected
for turns in [0, -1, 100_001]:
  var config = defaultConfig()
  config.maxTurns = turns
  config.assertRejected()
block:
  var config = defaultConfig(0, 10)
  config.width = 13
  config.height = 13
  config.assertRejected()

echo "Seeded map generation checks passed"
