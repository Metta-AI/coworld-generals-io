import
  std/os,
  polyworld/[configs, coworld],
  common, options, settings

proc hostedOptions*(): Options =
  ## Validates game settings before starting the shared file-policy host.
  result.settings = loadSettings(localPath(getEnv("COGAME_CONFIG_URI")))
  if result.settings.config.maxTurns > DefaultDurationTicks.int:
    raise newException(
      GeneralsError,
      "Hosted turn limit must not exceed " & $DefaultDurationTicks & "."
    )
  for path in result.settings.botFiles:
    if path.len > 0:
      raise newException(
        GeneralsError,
        "Hosted policies must come from the staged player seats."
      )
  result.settings.roster = result.settings.resolvedRoster()
  result.game = coworldOptions(0)
  if result.game.botGroups.len != result.settings.config.players:
    raise newException(GeneralsError, "Hosted player count does not match.")
  if result.game.headlessTickRate notin 0'i32 .. 10_000'i32:
    raise newException(
      GeneralsError,
      "Headless tick rate must be between 0 and 10000."
    )
  for player, group in result.game.botGroups:
    result.settings.botFiles[player] = group.path
  result.game.seed = result.settings.config.seed.int32
  result.game.maximumTicks = result.settings.config.maxTurns.int32
  result.game.seconds = result.game.maximumTicks div 2
  result.headless = true
  result.startGame = true
  result.humanPlayer = -1

proc hostedSource*(path: string, player: int): string =
  ## Loads a staged raw or ZIP policy with diagnostics confined to its seat.
  var bytes: string
  try:
    bytes = readPlayerSource(path)
  except CoworldError as error:
    rejectPlayer(player, error.msg)
  loadPlayerPolicy(bytes, player).source

proc finishHosted*(world: World) =
  ## Publishes binary winner scores after the standard replay is durable.
  var scores = newSeq[int](world.config.players)
  if world.winner >= 0:
    scores[world.winner] = 1
  finishCoworld(CoworldResults(
    scores: scores,
    ticks: world.turn.int32,
    seed: world.config.seed.int32,
    outcome: (if world.winner < 0: "draw" else: "victory")
  ))
