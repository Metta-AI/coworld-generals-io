## Isolated hosted transport for the shared Polyworld BASIC host and limits.
import std/[json, os, math]
import bassy, polyworld/[policies, mailboxes]
import generals/[common, messages, players, policy_api]
import policy_messages

when not defined(bassyNative):
  {.error: "Build hosted BASIC workers with build_polyworld_runtime.sh (bassyNative required).".}

if paramStr(1) == "--messages":
  serveMessages()
  quit(0)

let path = paramStr(1)
doAssert getFileSize(path) <= MaxPackageBytes, "BASIC policy exceeds 16 MiB"
let policy = readPolicy(path)
# Policies compile before any secret or board data enters the process.
let hub = newMessageHub(defaultRoster(), MaxPlayers)
let state = PolicyState(hub: hub, pending: noMove(), building: -1)
let host = buildPolicyHost(state)
var limits = policyLimits()
let source = prepareSource(policy.source, limits)
let program = compile(source, host, limits)
var runtime = initRuntime(program, host, policyLimits())
stdout.writeLine("{\"kind\":\"ready\"}")
stdout.flushFile()

proc printer(event: PrintEvent) =
  case event.kind
  of TextPrint: stderr.write(event.text)
  of ValuePrint: stderr.write($event.value)
  of FixedPrint: stderr.write($event.fixedValue)
  of NewlinePrint: stderr.write("\n")

for line in stdin.lines:
  let observation = parseJson(line)
  state.player = observation["slot"].getInt()
  hub.count = observation["players"].len
  for player, name in observation["players"].getElems():
    hub.roster.players[player].name = name.getStr()
  let width = observation["width"].getInt()
  let height = observation["height"].getInt()
  var view = PolicyView(width: width, height: height, tick: observation["turn"].getInt(),
    maximumTicks: observation["max_turns"].getInt(), general: -1,
    buildCosts: newSeq[int](width * height), armies: newSeq[int](hub.count),
    lands: newSeq[int](hub.count), eliminated: newSeq[bool](hub.count),
    rated: newSeq[bool](hub.count), skills: newSeq[int32](hub.count))
  for row in 0 ..< height:
    for column in 0 ..< width:
      let kind = observation["type_grid"][row][column].getInt()
      let owner = observation["visible_owner_grid"][row][column].getInt() - 1
      view.observation.visible.add(kind in 1 .. 4)
      view.observation.kinds.add(if kind == 5: -2 else: kind - 1)
      view.observation.owners.add(owner)
      view.observation.armies.add(observation["army_grid"][row][column].getInt())
      if owner == state.player and kind == 4:
        view.general = row * width + column
      if observation["ruleset"].getStr() == "build_castles":
        view.buildCosts[row * width + column] = observation["build_cost_grid"][row][column].getInt()
  view.observation.myLand = observation["my_land"].getInt()
  view.observation.myArmy = observation["my_army"].getInt()
  view.observation.oppLand = observation["opp_land"].getInt()
  view.observation.oppArmy = observation["opp_army"].getInt()
  for player in 0 ..< hub.count:
    view.armies[player] = observation["public_scores"]["army"][player].getInt()
    view.lands[player] = observation["public_scores"]["land"][player].getInt()
    view.eliminated[player] = observation["public_scores"]["eliminated"][player].getBool()
  if observation["player_ratings"].kind != JNull:
    for player in observation["player_ratings"]["players"].getElems():
      if player["score"].kind != JNull:
        let slot = player["slot"].getInt()
        view.rated[slot] = true
        view.skills[slot] = round(player["score"].getFloat() * 100).int32
  let inbox = hub.inboxes[state.player]
  inbox.first = 0
  inbox.count = 0
  inbox.lastId = observation["mailbox"]["last_id"].getInt().int32
  for message in observation["mailbox"]["messages"].getElems():
    doAssert inbox.push(message["id"].getInt().int32, message["text"].getStr())
  state.beginDecision(view)
  runtime.restart()
  runtime.refreshPolicyData(state)
  discard runtime.run(printer)
  stderr.flushFile()
  var action = @[1, 0, 0, 0, 0]
  let move = state.pending
  if state.building >= 0:
    action = @[2, state.building div width, state.building mod width, 0, 0]
  elif move.raw:
    action = @[0, move.row, move.column, move.direction, move.half.int]
  elif move.source >= 0:
    let delta = move.target - move.source
    let direction = if delta == -width: 0 elif delta == width: 1 elif delta == -1: 2 else: 3
    action = @[0, move.source div width, move.source mod width, direction, move.half.int]
  let message = hub.takeMessage(state.player)
  let chat = if message.text.len == 0: newJNull() else:
    %*{"target": message.target, "text": message.text}
  stdout.writeLine($(%*{"kind": "action", "action": action,
    "mailbox_pulled": state.mailboxPulled, "chat": chat}))
  stdout.flushFile()
