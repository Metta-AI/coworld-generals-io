import
  bassy,
  polyworld/[mailboxes, policies, policyhosts],
  common, messages, players, visions

type
  BrainState = ref object
    player: int
    hub: MessageHub
    world: World
    observation: Observation
    pending: Move
    submitted: bool
  Brain* = ref object
    runtime*: Runtime
    player*: int
    failed*: bool
    error*: string
    state: BrainState

proc policyLimits*(): Limits =
  ## Bounds one decision and persistent BASIC storage independently per seat.
  result = defaultLimits()
  result.maxInstructions = 200_000
  result.maxWorkUnits = 400_000
  result.maxMemoryBytes = 4 * 1024 * 1024
  result.maxNativeMemoryBytes = 4 * 1024 * 1024
  result.maxSourceBytes = 256 * 1024
  result.maxCodeInstructions = 65_536
  result.maxPrintBytes = 4096
  result.maxPrintEvents = 128

proc validTile(state: BrainState, index: int): bool {.raises: [].} =
  ## Keeps all board queries inside the current fog-limited observation.
  index >= 0 and index < state.observation.visible.len

proc submit(state: BrainState, source, target, half: int): int32 =
  ## Accepts one owned cardinal move without mutating the shared world.
  if state.submitted or half notin 0 .. 1 or
    not state.validTile(source) or not state.validTile(target):
      return 0
  let
    observation = state.observation
    width = state.world.config.width
    distance = abs(source mod width - target mod width) +
      abs(source div width - target div width)
  if distance != 1 or observation.owners[source] != state.player or
    observation.armies[source] <= 1 or
    observation.kinds[target] in [-2, Mountain.ord]:
      return 0
  state.pending = Move(source: source, target: target, half: half != 0)
  state.submitted = true
  1

proc buildHost(state: BrainState): Host =
  ## Binds shared BASIC services to refreshed observations and bounded orders.
  result = initPolicyHost(state.player)
  let
    nameProc: ContextHostProc = proc(
        runtime: Runtime,
        args: openArray[Value]
    ): Value =
      ## Copies an allowed roster label into this runtime's string storage.
      let player = args[0].asInt.int
      var vm = runtime
      vm.putString(
        if player >= 0 and player < state.hub.count:
          state.hub.roster.queryName(player)
        else:
          ""
      )
    sendChatProc: ContextHostProc = proc(
        runtime: Runtime,
        args: openArray[Value]
    ): Value =
      ## Queues text until every seat has finished deciding for this tick.
      runtime.withString(args[1], text):
        result = toValue(state.hub.queueMessage(
          state.player,
          args[0].asInt.int,
          text
        ))
    pullMailboxProc: ContextHostProc = proc(
        runtime: Runtime,
        args: openArray[Value]
    ): Value =
      ## Copies and consumes the oldest message, including empty-mail status.
      let inbox = state.hub.inboxes[state.player]
      var vm = runtime
      result = vm.putString(
        if inbox.count > 0: inbox.messages[inbox.first] else: ""
      )
      discard inbox.pop()
  discard result.addFunction("playerName$", 1, nameProc, 32)
  discard result.addFunction("mailboxName$", 1, nameProc, 32)
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  template query(name: string, parameters: int, body: untyped) =
    ## Registers a read-only scalar query with explicit argument bounds.
    discard result.addQuery(
      name,
      parameters,
      proc(args {.inject.}: openArray[int32]): int32 =
        ## Returns one bounded fact from the current decision snapshot.
        body,
      4
    )
  query("selfPlayer", 0):
    state.player.int32
  query("playerCount", 0):
    state.hub.count.int32
  query("playerInfoEnabled", 0):
    state.hub.roster.exposePlayerInfo.int32
  query("playerMmr", 1):
    if args[0] < 0 or args[0] >= state.hub.count:
      return -1
    state.hub.roster.queryMmr(args[0].int)
  query("worldTick", 0):
    state.world.turn.int32
  query("worldTurn", 0):
    (state.world.turn div 2).int32
  query("width", 0):
    state.world.config.width.int32
  query("height", 0):
    state.world.config.height.int32
  query("tileCount", 0):
    state.world.tiles.len.int32
  query("selfGeneral", 0):
    if state.player >= state.world.generals.len:
      return -1
    state.world.generals[state.player].int32
  query("visible", 1):
    if not state.validTile(args[0].int):
      return 0
    state.observation.visible[args[0]].int32
  query("terrain", 1):
    if not state.validTile(args[0].int):
      return -1
    state.observation.kinds[args[0]].int32
  query("owner", 1):
    if not state.validTile(args[0].int):
      return -1
    state.observation.owners[args[0]].int32
  query("army", 1):
    if not state.validTile(args[0].int):
      return 0
    state.observation.armies[args[0]].int32
  query("mailboxId", 0):
    state.hub.inboxes[state.player].lastId
  query("mailboxCount", 0):
    state.hub.inboxes[state.player].count.int32
  query("mailboxSelf", 0):
    state.player.int32
  query("mailboxPlayers", 0):
    state.hub.count.int32
  discard result.addFunction(
    "send",
    3,
    proc(args: openArray[int32]): int32 =
      ## Submits one legal geometric command for later simultaneous resolution.
      state.submit(args[0].int, args[1].int, args[2].int),
    16
  )

proc newBrain*(source: string, player: int, hub: MessageHub): Brain =
  ## Compiles a bounded BASIC policy using the common Polyworld host facade.
  if hub == nil or player < 0 or player >= hub.count:
    raise newException(GeneralsError, "BASIC player is outside the roster.")
  let
    state = BrainState(player: player, hub: hub, pending: noMove())
    limits = policyLimits()
  result = Brain(player: player, state: state)
  try:
    let
      host = buildHost(state)
      program = compile(source, host, limits)
    result.runtime = initRuntime(program, host, limits)
  except BasicError as error:
    raise newException(
      GeneralsError,
      "Cannot compile BASIC player " & $(player + 1) & ": " & error.msg
    )

proc readSource*(path: string): string =
  ## Loads raw BASIC or a bounded Polyworld policy package from a local file.
  try:
    result = readPolicy(path).source
  except PolicyError, IOError, OSError:
    raise newException(
      GeneralsError,
      "Cannot load BASIC policy: " & getCurrentExceptionMsg()
    )

proc decide*(brain: Brain, world: World): Move =
  ## Refreshes fog and runs one decision while preserving private VM memory.
  result = noMove()
  if brain == nil or brain.failed or world.finished or
    brain.player < 0 or brain.player >= world.alive.len or
    not world.alive[brain.player]:
      return
  if world.config.players != brain.state.hub.count:
    raise newException(GeneralsError, "BASIC roster does not match the world.")
  brain.state.world = world
  brain.state.observation = world.observed(brain.player)
  brain.state.pending = noMove()
  brain.state.submitted = false
  try:
    brain.runtime.restart()
    discard brain.runtime.run()
    result = brain.state.pending
  except BasicError as error:
    brain.failed = true
    brain.error = error.msg
    stderr.writeLine("BASIC player " & $(brain.player + 1) & ": " & error.msg)
