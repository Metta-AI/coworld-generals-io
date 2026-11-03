## Private JSONL transport for the authoritative Polyworld simulation.
import std/[json, sequtils]
import generals/[common, worlds]

var world: World

proc snapshot(report: StepReport): JsonNode =
  result = %*{
    "turn": world.turn,
    "winner": world.winner,
    "width": world.config.width,
    "height": world.config.height,
    "alive": world.alive,
    "kinds": world.tiles.mapIt(it.kind.ord),
    "owners": world.tiles.mapIt(it.owner.int),
    "armies": world.tiles.mapIt(it.army),
    "executed": report.executed,
    "captured_by": report.capturedBy,
    "elimination_order": report.eliminationOrder,
    "damage": report.damage
  }

for line in stdin.lines:
  let request = parseJson(line)
  var report: StepReport
  case request["op"].getStr()
  of "new":
    let config = defaultConfig(request["seed"].getInt(), request["players"].getInt())
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
    report = world.step(moves, generalTrades = not building)
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
  stdout.writeLine($snapshot(report))
  stdout.flushFile()
