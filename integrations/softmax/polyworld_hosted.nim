## Shared hosted transitions for the process engine and native replay viewer.
import std/[json, sequtils, strutils]
import generals/[common, worlds]

type
  HostedAction* = array[5, int32]
  HostedEventKind* = enum
    StepEvent, SurrenderEvent, NeutralizeEvent
  HostedEvent* = object
    kind*: HostedEventKind
    slots*: uint8

proc newHostedWorld*(seed, players: int, building: bool): World =
  ## Creates the shared hosted map, including the castle-building preset.
  var config = defaultConfig(seed and 0x7fff_ffff, players)
  config.maxTurns = 100_000
  result = newWorld(config)
  if building:
    for tile in result.tiles.mitems:
      if tile.kind == City:
        tile.kind = Plain
        tile.army = 0

proc applyHostedEvent*(
    world: var World,
    event: HostedEvent,
    actions: openArray[HostedAction],
    building: bool
): StepReport =
  ## Applies the same typed commands during authoritative play and replay.
  case event.kind
  of StepEvent:
    var moves: seq[Move]
    for player, action in actions:
      case action[0]
      of 0:
        moves.add actionMove(action[1].int, action[2].int,
          action[3].int, action[4] == 1)
      of 1, 2:
        moves.add noMove()
      else:
        raise newException(GeneralsError, "Unknown action kind")
      if action[0] == 2:
        doAssert building
        let cell = world.index(action[2].int, action[1].int)
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
    # Hosted turns still advance when a surrender has just decided the winner.
    world.winner = -1
    result = world.step(moves, generalTrades = not building)
    # Hosted rules pay income on the terminal capture tick too.
    if world.winner >= 0 and world.turn mod 2 == 0:
      for tile in world.tiles.mitems:
        if tile.owner >= 0:
          if tile.kind in {City, General}: inc tile.army
          if world.turn mod 50 == 0: inc tile.army
  of SurrenderEvent, NeutralizeEvent:
    for player in 0 ..< world.config.players:
      if (event.slots and (1'u8 shl player)) == 0:
        continue
      if event.kind == SurrenderEvent:
        world.alive[player] = false
      else:
        for tile in world.tiles.mitems:
          if tile.owner == player:
            tile.owner = -1
            if tile.kind == General: tile.kind = City
    let remaining = toSeq(0 ..< world.config.players).filterIt(world.alive[it])
    world.winner = if remaining.len == 1: remaining[0] else: -1

proc applyHosted*(world: var World, request: JsonNode): StepReport =
  ## Decodes only the private process boundary; recordings store typed commands.
  let op = request["op"].getStr()
  if op == "new":
    world = newHostedWorld(
      int(request["seed"].getBiggestInt() and 0x7fff_ffff'i64),
      request["players"].getInt(), request["ruleset"].getStr() == "build_castles")
    return
  var event: HostedEvent
  var actions: seq[HostedAction]
  case op
  of "step":
    event.kind = StepEvent
    for action in request["actions"].getElems():
      var entry: HostedAction
      for index in 0 ..< entry.len:
        entry[index] = action[index].getInt().int32
      actions.add(entry)
  of "surrender", "neutralize":
    event.kind = if op == "surrender": SurrenderEvent else: NeutralizeEvent
    for entry in request["slots"]:
      let player = entry.getInt()
      doAssert player in 0 ..< world.config.players
      event.slots = event.slots or (1'u8 shl player)
  else:
    raise newException(GeneralsError, "Unknown engine command")
  world.applyHostedEvent(event, actions, request["ruleset"].getStr() == "build_castles")

proc hostedHashValue*(world: World): uint64 =
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
  hash

proc hostedHash*(world: World): string =
  world.hostedHashValue().toHex(16)
