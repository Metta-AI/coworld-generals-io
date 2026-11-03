## One fog-limited BASIC interface for standalone and process-hosted policies.
import std/math
import bassy, polyworld/[mailboxes, policyhosts]
import common, messages, players, policy_source, visions

export policy_source

type
  PolicyView* = object
    observation*: Observation
    width*, height*, tick*, maximumTicks*, general*: int
    armies*, lands*, buildCosts*: seq[int]
    eliminated*, rated*: seq[bool]
    skills*: seq[int32] # Published skill in hundredths, independent of star ranks.
  PolicyState* = ref object
    player*: int
    hub*: MessageHub
    view*: PolicyView
    pending*: Move
    building*: int
    submitted*: bool
    mailboxPulled*: int

proc policyLimits*(): Limits =
  ## The same decision and storage budgets apply in every BASIC runtime.
  result = defaultLimits()
  result.maxInstructions = 200_000
  result.maxWorkUnits = 400_000
  result.maxMemoryBytes = 4 * 1024 * 1024
  result.maxNativeMemoryBytes = 4 * 1024 * 1024
  result.maxSourceBytes = 256 * 1024
  result.maxCodeInstructions = 65_536
  result.maxPrintBytes = 4096
  result.maxPrintEvents = 128

proc prepareSource*(source: string, limits: var Limits): string =
  ## Enforces the public source cap before lowering call spellings.
  if source.len > limits.maxSourceBytes:
    raise newException(BasicError, "BASIC source exceeds the configured byte limit")
  result = policySource(source)
  limits.maxSourceBytes += max(0, result.len - source.len)

proc beginDecision*(state: PolicyState, view: PolicyView) =
  state.view = view
  state.pending = noMove()
  state.building = -1
  state.submitted = false
  state.mailboxPulled = 0

proc validTile(state: PolicyState, index: int): bool =
  index >= 0 and index < state.view.observation.visible.len

proc cell(state: PolicyState, row, column: int): int =
  if row < 0 or row >= state.view.height or column < 0 or column >= state.view.width:
    -1
  else:
    row * state.view.width + column

proc buildPolicyHost*(state: PolicyState): Host =
  result = initPolicyHost(state.player)
  for name in PolicyData:
    discard result.addData("g" & name, 0)

  let nameProc: ContextHostProc = proc(runtime: Runtime, args: openArray[Value]): Value =
    let player = args[0].asInt.int
    var vm = runtime
    vm.putString(if player >= 0 and player < state.hub.count:
      state.hub.roster.queryName(player) else: "")
  for name in ["playerName$", "mailboxName$"]:
    discard result.addFunction(policyFunctionName(name, 1), 1, nameProc, 32)
  discard result.addFunction(policyFunctionName("sendChat", 2), 2,
    proc(runtime: Runtime, args: openArray[Value]): Value =
      runtime.withString(args[1], text):
        result = toValue(state.hub.queueMessage(state.player, args[0].asInt.int, text)), 256)
  discard result.addFunction(policyFunctionName("pullMailbox$", 0), 0,
    proc(runtime: Runtime, args: openArray[Value]): Value =
      let inbox = state.hub.inboxes[state.player]
      var vm = runtime
      result = vm.putString(if inbox.count > 0: inbox.messages[inbox.first] else: "")
      discard inbox.pop()
      state.mailboxPulled = min(MaxMailboxMessages + 1, state.mailboxPulled + 1), 256)

  template query(name: string, parameters: int, body: untyped) =
    discard result.addQuery(policyFunctionName(name, parameters), parameters,
      proc(args {.inject.}: openArray[int32]): int32 = body, 4)
  query("selfPlayer", 0): state.player.int32
  query("playerCount", 0): state.hub.count.int32
  query("playerInfoEnabled", 0): state.hub.roster.exposePlayerInfo.int32
  query("playerMmr", 1):
    if not state.hub.roster.exposePlayerInfo or args[0] < 0 or
        args[0] >= state.hub.count or not state.view.rated[args[0]]: return -1
    round(state.view.skills[args[0]].float64 / 100).int32
  query("playerRated", 1):
    if args[0] < 0 or args[0] >= state.hub.count: return 0
    state.view.rated[args[0]].int32
  query("playerSkill", 1):
    if args[0] < 0 or args[0] >= state.hub.count: return 0
    state.view.skills[args[0]]
  query("worldTick", 0): state.view.tick.int32
  query("worldTurn", 0): (state.view.tick div 2).int32
  query("width", 0): state.view.width.int32
  query("height", 0): state.view.height.int32
  query("tileCount", 0): state.view.observation.visible.len.int32
  query("selfGeneral", 0): state.view.general.int32
  query("visible", 1):
    if not state.validTile(args[0].int): return 0
    state.view.observation.visible[args[0]].int32
  query("terrain", 1):
    if not state.validTile(args[0].int): return -1
    state.view.observation.kinds[args[0]].int32
  query("owner", 1):
    if not state.validTile(args[0].int): return -1
    state.view.observation.owners[args[0]].int32
  query("army", 1):
    if not state.validTile(args[0].int): return 0
    state.view.observation.armies[args[0]].int32
  query("tileType", 2):
    let index = state.cell(args[0].int, args[1].int)
    if index < 0: return -1
    let kind = state.view.observation.kinds[index]
    (if kind == -2: 5 else: kind + 1).int32
  query("owner", 2):
    let index = state.cell(args[0].int, args[1].int)
    if index < 0: return -1
    let owner = state.view.observation.owners[index]
    (if owner < 0: 0 elif owner == state.player: 1 else: 2).int32
  query("visibleOwner", 2):
    let index = state.cell(args[0].int, args[1].int)
    if index < 0: return -1
    (state.view.observation.owners[index] + 1).int32
  query("army", 2):
    let index = state.cell(args[0].int, args[1].int)
    if index < 0: return -1
    state.view.observation.armies[index].int32
  query("buildCost", 2):
    let index = state.cell(args[0].int, args[1].int)
    if index < 0: return -1
    state.view.buildCosts[index].int32
  query("playerArmy", 1):
    if args[0] < 0 or args[0] >= state.hub.count: return -1
    state.view.armies[args[0]].int32
  query("playerLand", 1):
    if args[0] < 0 or args[0] >= state.hub.count: return -1
    state.view.lands[args[0]].int32
  query("playerEliminated", 1):
    if args[0] < 0 or args[0] >= state.hub.count: return -1
    state.view.eliminated[args[0]].int32
  query("mailboxId", 0): state.hub.inboxes[state.player].lastId
  query("mailboxCount", 0): state.hub.inboxes[state.player].count.int32
  query("mailboxSelf", 0): state.player.int32
  query("mailboxPlayers", 0): state.hub.count.int32
  discard result.addFunction(policyFunctionName("send", 3), 3,
    proc(args: openArray[int32]): int32 =
      let source = args[0].int
      let target = args[1].int
      if state.submitted or args[2] notin 0 .. 1 or
          not state.validTile(source) or not state.validTile(target): return 0
      let view = state.view
      if abs(source mod view.width - target mod view.width) +
          abs(source div view.width - target div view.width) != 1 or
          view.observation.owners[source] != state.player or
          view.observation.armies[source] <= 1 or
          view.observation.kinds[target] in [-2, Mountain.ord]: return 0
      state.pending = Move(source: source, target: target, half: args[2] != 0)
      state.submitted = true
      1, 16)
  discard result.addFunction(policyFunctionName("move", 4), 4,
    proc(args: openArray[int32]): int32 =
      if state.submitted or state.cell(args[0].int, args[1].int) < 0 or
          args[2] notin 0 .. 3 or args[3] notin 0 .. 1: return 0
      state.pending = actionMove(args[0].int, args[1].int, args[2].int, args[3] != 0)
      state.submitted = true
      1, 16)
  discard result.addFunction(policyFunctionName("buildCastle", 2), 2,
    proc(args: openArray[int32]): int32 =
      let index = state.cell(args[0].int, args[1].int)
      if state.submitted or index < 0 or state.view.buildCosts[index] <= 0: return 0
      state.building = index
      state.submitted = true
      1, 16)
  discard result.addFunction(policyFunctionName("pass", 0), 0,
    proc(args: openArray[int32]): int32 =
      if state.submitted: return 0
      state.submitted = true
      1, 16)

proc refreshPolicyData*(runtime: var Runtime, state: PolicyState) =
  ## Legacy scalar spellings are views of the same refreshed snapshot.
  let view = state.view
  for (name, value) in [("turn", view.tick), ("slot", state.player),
      ("height", view.height), ("width", view.width), ("max_turns", view.maximumTicks),
      ("my_land", view.observation.myLand), ("my_army", view.observation.myArmy),
      ("opp_land", view.observation.oppLand), ("opp_army", view.observation.oppArmy)]:
    runtime.setData("g" & name, value.int32)
