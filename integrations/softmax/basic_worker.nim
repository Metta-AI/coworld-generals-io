## A persistent, metered BASIC seat. Only fog-filtered observations enter this process.
import std/[json, os, math], bassy, polyworld/policies

when not defined(bassyNative):
  {.error: "Build hosted BASIC workers with build_polyworld_runtime.sh (bassyNative required).".}

const SourceLimit = 256 * 1024

var
  observation: JsonNode
  action = @[1, 0, 0, 0, 0]
  selected = false
  host = initHost()

for name in ["turn", "slot", "height", "width", "max_turns", "my_land", "my_army", "opp_land", "opp_army"]:
  discard host.addData(name, 0)

proc addGridQuery(name, field: string) =
  discard host.addFunction(name, 2, proc(args: openArray[int32]): int32 =
    let row = int(args[0])
    let col = int(args[1])
    if row < 0 or row >= observation["height"].getInt or
       col < 0 or col >= observation["width"].getInt:
      return -1
    if field == "build_cost_grid" and observation["ruleset"].getStr != "build_castles":
      return 0
    int32(observation[field][row][col].getInt)
  )

for pair in [("tileType", "type_grid"), ("owner", "owner_grid"),
             ("visibleOwner", "visible_owner_grid"), ("army", "army_grid"),
             ("buildCost", "build_cost_grid")]:
  addGridQuery(pair[0], pair[1])

proc addPublicQuery(scoreField: string) =
  discard host.addFunction("player" & scoreField, 1, proc(args: openArray[int32]): int32 =
    let slot = int(args[0])
    if slot < 0 or slot >= observation["players"].len:
      return -1
    let value = observation["public_scores"][scoreField][slot]
    if scoreField == "eliminated": int32(value.getBool) else: int32(value.getInt)
  )

for field in ["army", "land", "eliminated"]:
  addPublicQuery(field)

proc addSkillQuery(name: string, rated: bool) =
  discard host.addFunction(name, 1, proc(args: openArray[int32]): int32 =
    let slot = int(args[0])
    if slot < 0 or slot >= observation["players"].len:
      return 0
    let ratings = observation["player_ratings"]
    if ratings.kind == JNull:
      return 0
    for player in ratings["players"].getElems():
      if player["slot"].getInt == slot and player["score"].kind != JNull:
        return if rated: 1 else: int32(round(player["score"].getFloat * 100))
    0
  )

addSkillQuery("playerRated", true)
addSkillQuery("playerSkill", false)

discard host.addFunction("move", 4, proc(args: openArray[int32]): int32 =
  if selected or args[0] < 0 or args[0] >= observation["height"].getInt or
     args[1] < 0 or args[1] >= observation["width"].getInt or
     args[2] < 0 or args[2] > 3 or args[3] < 0 or args[3] > 1:
    return 0
  action = @[0, int(args[0]), int(args[1]), int(args[2]), int(args[3])]
  selected = true
  1
)
discard host.addFunction("buildCastle", 2, proc(args: openArray[int32]): int32 =
  if selected or observation["ruleset"].getStr != "build_castles" or
     args[0] < 0 or args[0] >= observation["height"].getInt or
     args[1] < 0 or args[1] >= observation["width"].getInt:
    return 0
  action = @[2, int(args[0]), int(args[1]), 0, 0]
  selected = true
  1
)
discard host.addFunction("pass", 0, proc(args: openArray[int32]): int32 =
  if selected: return 0
  selected = true
  1
)

var limits = defaultLimits()
limits.maxSourceBytes = SourceLimit
limits.maxCodeInstructions = 100_000
limits.maxMemoryBytes = 8 * 1024 * 1024
limits.maxArrayElements = 100_000
limits.maxInstructions = 200_000
limits.maxWorkUnits = 200_000
limits.maxPrintBytes = 4096
limits.maxPrintEvents = 256

let path = paramStr(1)
doAssert getFileSize(path) <= MaxPackageBytes, "BASIC policy exceeds 16 MiB"
let policy = readPolicy(path)
let program = compile(policy.source, host, limits)
var runtime = initRuntime(program, host, limits)
stdout.writeLine("{\"kind\":\"ready\"}")
stdout.flushFile()

proc printer(event: PrintEvent) =
  case event.kind
  of TextPrint: stderr.write(event.text)
  of ValuePrint: stderr.write($event.value)
  of FixedPrint: stderr.write($event.fixedValue)
  of NewlinePrint: stderr.write("\n")

var line: string
while stdin.readLine(line):
  observation = parseJson(line)
  action = @[1, 0, 0, 0, 0]
  selected = false
  runtime.restart()
  for name in ["turn", "slot", "height", "width", "max_turns", "my_land", "my_army", "opp_land", "opp_army"]:
    runtime.setData(name, int32(observation[name].getInt))
  discard runtime.run(printer)
  stderr.flushFile()
  stdout.writeLine($(%*{"kind": "action", "action": action}))
  stdout.flushFile()
