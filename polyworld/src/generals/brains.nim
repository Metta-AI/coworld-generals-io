import
  bassy,
  polyworld/policies,
  common, messages, players, policy_api, visions

export policy_api

when defined(coworld):
  import polyworld/coworld

type Brain* = ref object
  runtime*: Runtime
  player*: int
  failed*: bool
  error*: string
  state: PolicyState

proc newBrain*(source: string, player: int, hub: MessageHub): Brain =
  ## Compiles a bounded BASIC policy using the common Polyworld host facade.
  if hub == nil or player < 0 or player >= hub.count:
    raise newException(GeneralsError, "BASIC player is outside the roster.")
  let
    state = PolicyState(player: player, hub: hub, pending: noMove(), building: -1)
  result = Brain(player: player, state: state)
  try:
    let
      host = buildPolicyHost(state)
    var limits = policyLimits()
    let
      prepared = prepareSource(source, limits)
      program =
        when defined(coworld):
          compilePlayer(prepared, host, limits, player)
        else:
          compile(prepared, host, limits)
    result.runtime = initRuntime(program, host, limits)
  except BasicError as error:
    when defined(coworld):
      rejectPlayer(player, error.msg)
    else:
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
  var view = PolicyView(
    observation: world.observed(brain.player), width: world.config.width,
    height: world.config.height, tick: world.turn, maximumTicks: world.config.maxTurns,
    general: world.generals[brain.player],
    armies: newSeq[int](world.config.players), lands: newSeq[int](world.config.players),
    eliminated: newSeq[bool](world.config.players),
    rated: newSeq[bool](world.config.players), skills: newSeq[int32](world.config.players),
    buildCosts: newSeq[int](world.tiles.len))
  for tile in world.tiles:
    if tile.owner >= 0:
      inc view.lands[tile.owner]
      view.armies[tile.owner] += tile.army
  for player in 0 ..< world.config.players:
    view.eliminated[player] = not world.alive[player]
    let mmr = brain.state.hub.roster.queryMmr(player)
    view.rated[player] = mmr >= 0
    view.skills[player] = if mmr >= 0: mmr * 100 else: 0
  brain.state.beginDecision(view)
  try:
    brain.runtime.restart()
    brain.runtime.refreshPolicyData(brain.state)
    when defined(coworld):
      discard brain.runtime.run(playerPrinter(brain.player))
    else:
      discard brain.runtime.run()
    result = brain.state.pending
  except BasicError as error:
    brain.failed = true
    brain.error = error.msg
    when defined(coworld):
      playerError(brain.player, error.msg)
    else:
      stderr.writeLine("BASIC player " & $(brain.player + 1) & ": " & error.msg)
