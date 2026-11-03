## Shared hosted transitions for the process engine and native replay viewer.
import std/[json, sequtils, strutils]
import generals/[common, worlds]

type HostedEvent* = object
  command*, hash*: string

proc applyHosted*(world: var World, request: JsonNode): StepReport =
  case request["op"].getStr()
  of "new":
    # Keep the map seed portable to WebAssembly's signed native integer.
    let seed = int(request["seed"].getBiggestInt() and 0x7fff_ffff'i64)
    var config = defaultConfig(seed, request["players"].getInt())
    config.maxTurns = 100_000
    world = newWorld(config)
    if request["ruleset"].getStr() == "build_castles":
      for tile in world.tiles.mitems:
        if tile.kind == City:
          tile.kind = Plain
          tile.army = 0
  of "step":
    var moves: seq[Move]
    let building = request["ruleset"].getStr() == "build_castles"
    for player, action in request["actions"].getElems():
      case action[0].getInt()
      of 0:
        moves.add actionMove(action[1].getInt(), action[2].getInt(),
          action[3].getInt(), action[4].getInt() == 1)
      of 1, 2:
        moves.add noMove()
      else:
        raise newException(GeneralsError, "Unknown action kind")
      if action[0].getInt() == 2:
        doAssert building
        let cell = world.index(action[2].getInt(), action[1].getInt())
        var cost = 35
        for i, tile in world.tiles:
          if tile.owner == player and tile.kind in {City, General}:
            let distance = abs(i mod world.config.width - cell mod world.config.width) +
              abs(i div world.config.width - cell div world.config.width)
            cost += max(0, 14 - 2 * distance)
        if world.alive[player] and world.tiles[cell].owner == player and
            world.tiles[cell].kind == Plain and world.tiles[cell].army >= cost:
          world.tiles[cell].army -= cost
          world.tiles[cell].kind = City
    doAssert moves.len == world.config.players
    # A surrender can decide the winner before this tick's moves. Hosted turns
    # still advance once; native post-win replay stepping has a different clock.
    world.winner = -1
    result = world.step(moves, generalTrades = not building)
    # The hosted rules pay income on the terminal capture tick too.
    if world.winner >= 0 and world.turn mod 2 == 0:
      for tile in world.tiles.mitems:
        if tile.owner >= 0:
          if tile.kind in {City, General}: inc tile.army
          if world.turn mod 50 == 0: inc tile.army
  of "surrender", "neutralize":
    for entry in request["slots"]:
      let player = entry.getInt()
      doAssert player in 0 ..< world.config.players
      if request["op"].getStr() == "surrender":
        world.alive[player] = false
      else:
        for tile in world.tiles.mitems:
          if tile.owner == player:
            tile.owner = -1
            if tile.kind == General: tile.kind = City
    let remaining = toSeq(0 ..< world.config.players).filterIt(world.alive[it])
    world.winner = if remaining.len == 1: remaining[0] else: -1
  else:
    raise newException(GeneralsError, "Unknown engine command")

proc hostedHash*(world: World): string =
  ## Hash fixed-width values identically in native and WebAssembly builds.
  var hash = 14695981039346656037'u64
  template add(value: untyped) =
    block:
      var word = cast[uint64](int64(value))
      for i in 0 ..< 8:
        hash = (hash xor (word and 255)) * 1099511628211'u64
        word = word shr 8
  for value in [world.config.width, world.config.height, world.config.players,
                world.config.seed, world.config.maxTurns, world.turn, world.winner]:
    add(value)
  add(world.finished.int)
  for tile in world.tiles:
    add(tile.kind.ord)
    add(tile.owner.int)
    add(tile.army)
  for general in world.generals: add(general)
  for alive in world.alive: add(alive.int)
  hash.toHex(16)
