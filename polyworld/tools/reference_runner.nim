import
  std/[json, strutils],
  generals/[bots, common, visions, worlds]

proc configFromJson(value: JsonNode): Config =
  ## Reads a reference-test configuration without any runtime service.
  result = defaultConfig(
    value["seed"].getInt(),
    value["players"].getInt()
  )
  if value.hasKey("width"):
    result.width = value["width"].getInt()
  if value.hasKey("height"):
    result.height = value["height"].getInt()
  result.maxTurns = value["maxTurns"].getInt()

proc worldFromJson(value: JsonNode): World =
  ## Loads identical oracle starting data directly into the production world.
  result.config = configFromJson(value["config"])
  let config = result.config
  if config.width < 1 or config.width > 61 or
    config.height < 1 or config.height > 61 or
    config.players notin 2 .. MaxPlayers or config.maxTurns < 1:
      raise newException(GeneralsError, "Invalid reference configuration.")
  if value["tiles"].len != config.width * config.height or
    value["generals"].len != config.players or
    value["alive"].len != config.players:
      raise newException(GeneralsError, "Reference state dimensions differ.")
  for entry in value["tiles"]:
    let
      kind = entry["kind"].getInt()
      owner = entry["owner"].getInt()
      army = entry["army"].getInt()
    if kind < ord(low(TileKind)) or kind > ord(high(TileKind)) or
      owner < -1 or owner >= config.players or army < 0:
        raise newException(GeneralsError, "Invalid reference tile.")
    result.tiles.add Tile(kind: TileKind(kind), owner: owner.int8, army: army)
  for position in value["generals"]:
    result.generals.add position.getInt()
  for alive in value["alive"]:
    result.alive.add alive.getBool()
  result.turn = value["turn"].getInt()
  result.winner = value["winner"].getInt()
  result.finished = value["finished"].getBool()

proc snapshot(world: World): JsonNode =
  ## Reports production state and every player's fog-masked observation.
  var
    tiles = newJArray()
    scores = newJArray()
    observations = newJArray()
  for tile in world.tiles:
    tiles.add %*{
      "kind": ord(tile.kind),
      "owner": tile.owner,
      "army": tile.army
    }
  for player in 0 ..< world.config.players:
    let
      score = world.totals(player)
      observation = world.observed(player)
    scores.add %*{"land": score.land, "army": score.army}
    observations.add %*{
      "visible": observation.visible,
      "kinds": observation.kinds,
      "owners": observation.owners,
      "armies": observation.armies,
      "myLand": observation.myLand,
      "myArmy": observation.myArmy,
      "oppLand": observation.oppLand,
      "oppArmy": observation.oppArmy
    }
  %*{
    "turn": world.turn,
    "winner": world.winner,
    "finished": world.finished,
    "tiles": tiles,
    "generals": world.generals,
    "alive": world.alive,
    "totals": scores,
    "observations": observations
  }

proc movesFromJson(world: World, value: JsonNode): seq[Move] =
  ## Accepts native moves or the reference's bounded classic action format.
  if value.hasKey("actions"):
    for action in value["actions"]:
      if action.kind != JArray or action.len != 5:
        raise newException(GeneralsError, "Actions need five integers.")
      let
        kind = action[0].getInt()
        row = action[1].getInt()
        column = action[2].getInt()
        direction = action[3].getInt()
        split = action[4].getInt()
      if kind notin [0, 1] or row < 0 or row >= world.config.height or
        column < 0 or column >= world.config.width or
        direction notin 0 .. 3 or split notin [0, 1]:
          raise newException(GeneralsError, "Invalid classic action.")
      result.add(
        if kind == 1:
          noMove()
        else:
          actionMove(row, column, direction, split == 1)
      )
  else:
    for move in value["moves"]:
      result.add Move(
        source: move["source"].getInt(),
        target: move["target"].getInt(),
        half: move["half"].getBool()
      )
  if result.len != world.config.players:
    raise newException(GeneralsError, "Supply one action for every player.")

proc main() =
  ## Runs a local line-oriented test bridge around the real Nim engine.
  var
    world: World
    scratch: BotScratch
    ready = false
  for line in stdin.lines:
    if line.strip().len == 0:
      continue
    let request = parseJson(line)
    var response: JsonNode
    case request["op"].getStr()
    of "init":
      world = worldFromJson(request)
      ready = true
      response = world.snapshot()
    of "new":
      world = newWorld(configFromJson(request["config"]))
      ready = true
      response = world.snapshot()
      response["config"] = %world.config
    of "step", "tick":
      if not ready:
        raise newException(GeneralsError, "Initialize a reference world first.")
      let moves = world.movesFromJson(request)
      if request["op"].getStr() == "step":
        world.step(moves)
      else:
        world.tick(moves)
      response = world.snapshot()
    of "choose":
      if not ready:
        raise newException(GeneralsError, "Initialize a reference world first.")
      var moves = newJArray()
      for player in 0 ..< world.config.players:
        let move = world.chooseMove(player, scratch)
        moves.add %*{
          "source": move.source,
          "target": move.target,
          "half": move.half
        }
      response = %*{"moves": moves}
    else:
      raise newException(GeneralsError, "Unknown reference command.")
    stdout.writeLine($response)
    stdout.flushFile()

try:
  main()
except GeneralsError as error:
  quit("Generals reference runner: " & error.msg, 1)
except JsonParsingError, ValueError, KeyError, IOError:
  let error = newException(GeneralsError, getCurrentExceptionMsg())
  quit("Generals reference runner: " & error.msg, 1)
