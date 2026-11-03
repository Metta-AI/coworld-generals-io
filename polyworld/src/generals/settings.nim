import
  std/[os, strutils],
  jsony,
  common, players

const
  MaxSettingsBytes* = 1024 * 1024
  MaxSettingsDepth* = 64
  MaxBotPathBytes = 4096

type
  EngineInteger = distinct int64
  Settings* = object
    config*: Config
    roster*: Roster
    botFiles*: BotFiles
    autoWidth*, autoHeight*: bool
    changedSeats: set[0 .. MaxPlayers - 1]
  EnginePlayer = object
    name, bot: string
    mmr: EngineInteger = EngineInteger(-1)
  EngineConfig = object
    players: seq[EnginePlayer]
    seed, maxTicks, width, height: EngineInteger
    exposePlayerInfo: bool

proc parseHook(bytes: string, index: var int, value: var EngineInteger) =
  ## Parses JSON integer tokens with checked signed 64-bit accumulation.
  let
    token = parseSymbol(bytes, index)
    first = if token.len > 0 and token[0] == '-': 1 else: 0
  if first == token.len:
    raise newException(JsonError, "Expected a JSON integer.")
  if token[first] == '0' and token.len - first > 1:
    raise newException(JsonError, "Leading zero in JSON integer.")
  for i in first ..< token.len:
    if token[i] notin {'0' .. '9'}:
      raise newException(JsonError, "Expected a JSON integer.")
  try:
    value = EngineInteger(parseBiggestInt(token))
  except ValueError:
    raise newException(JsonError, "JSON integer exceeds signed 64-bit range.")

proc defaultSettings*(): Settings =
  ## Creates the same unnamed roster and board settings as a local match.
  Settings(
    config: defaultConfig(),
    roster: defaultRoster(),
    autoWidth: true,
    autoHeight: true
  )

proc newHook(player: var EnginePlayer) =
  ## Preserves unknown MMR when a JSON player record omits that field.
  player = EnginePlayer(mmr: EngineInteger(-1))

proc newHook(config: var EngineConfig) =
  ## Fills omitted JSON fields from the native game defaults.
  config = EngineConfig(
    players: newSeq[EnginePlayer](DefaultPlayers),
    seed: EngineInteger(1),
    maxTicks: EngineInteger(DefaultTurns),
    exposePlayerInfo: true
  )

proc renameHook(config: var EngineConfig, fieldName: var string) =
  ## Accepts the engine's snake case aliases for shared configuration fields.
  var
    name: string
    upper = false
  for character in fieldName:
    if character == '_':
      upper = true
    else:
      name.add(if upper: character.toUpperAscii else: character)
      upper = false
  fieldName = name

proc boundedNumber*(
    value, name: string,
    minimum, maximum: int
): int =
  ## Parses bounded CLI numbers into game-specific errors.
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(GeneralsError, "Invalid " & name & ": " & value)
  if result < minimum or result > maximum:
    raise newException(
      GeneralsError,
      name & " must be between " & $minimum & " and " & $maximum & "."
    )

proc checked(value: EngineInteger, name: string, minimum, maximum: int): int =
  ## Rejects out-of-range JSON numbers before converting to native integers.
  let number = value.int64
  if number < minimum.int64 or number > maximum.int64:
    raise newException(
      GeneralsError,
      name & " must be between " & $minimum & " and " & $maximum & "."
    )
  number.int

proc botPath(path, directory: string): string =
  ## Resolves a bounded bot path relative to its configuration source.
  if path.len == 0:
    return ""
  if path.len > MaxBotPathBytes or '\0' in path:
    raise newException(GeneralsError, "Bot path is invalid or too long.")
  normalizedPath(absolutePath(path, directory))

proc refreshDimensions(settings: var Settings) =
  ## Recomputes only dimensions not explicitly supplied by the engine config.
  let defaults = defaultConfig(settings.config.seed, settings.config.players)
  if settings.autoWidth:
    settings.config.width = defaults.width
  if settings.autoHeight:
    settings.config.height = defaults.height

proc resolvedRoster*(settings: Settings): Roster =
  ## Validates active CLI seats and applies the shared name fallback policy.
  if settings.config.players notin 2 .. MaxPlayers:
    raise newException(
      GeneralsError,
      "Choose 2 to " & $MaxPlayers & " players."
    )
  for seat in settings.changedSeats:
    if seat >= settings.config.players:
      raise newException(
        GeneralsError,
        "Player seat " & $(seat + 1) & " is outside this match."
      )
  resolveRoster(settings.roster, settings.botFiles, settings.config.players)

proc validateDepth(bytes: string) {.raises: [GeneralsError].} =
  ## Bounds nested containers before Jsony recursively skips unknown fields.
  var
    depth = 0
    closings: array[MaxSettingsDepth, char]
    quoted = false
    escaped = false
    scalar = false
  proc invalidStructure() {.noreturn, raises: [GeneralsError].} =
    ## Rejects malformed token boundaries before the permissive JSON parser.
    raise newException(GeneralsError, "Invalid config JSON structure.")
  for character in bytes:
    if quoted:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        quoted = false
    else:
      case character
      of '"':
        if scalar:
          invalidStructure()
        quoted = true
      of '{', '[':
        if scalar:
          invalidStructure()
        if depth == MaxSettingsDepth:
          raise newException(
            GeneralsError,
            "Config exceeds the " & $MaxSettingsDepth &
              " level nesting limit."
          )
        closings[depth] = if character == '{': '}' else: ']'
        inc depth
      of '}', ']':
        if depth == 0 or closings[depth - 1] != character:
          invalidStructure()
        dec depth
        scalar = false
      of ':':
        if scalar:
          invalidStructure()
      of ',', ' ', '\n', '\t', '\r':
        scalar = false
      else:
        scalar = true
  if quoted or depth != 0:
    invalidStructure()

proc parseSettings*(bytes: string, directory = getCurrentDir()): Settings =
  ## Reads bounded engine JSON while retaining names for later CLI overrides.
  if bytes.len > MaxSettingsBytes:
    raise newException(GeneralsError, "Config exceeds the 1 MiB size limit.")
  validateDepth(bytes)
  var config: EngineConfig
  try:
    config = bytes.fromJson(EngineConfig)
  except JsonError as error:
    raise newException(GeneralsError, "Invalid config JSON: " & error.msg)
  if config.players.len notin 2 .. MaxPlayers:
    raise newException(
      GeneralsError,
      "Config requires 2 to " & $MaxPlayers & " player entries."
    )
  result = defaultSettings()
  result.config = Config(
    seed: checked(config.seed, "Seed", 0, int32.high.int),
    maxTurns: checked(config.maxTicks, "Turn limit", 1, 100_000),
    width: checked(config.width, "Map width", 0, 61),
    height: checked(config.height, "Map height", 0, 61),
    players: config.players.len
  )
  result.autoWidth = config.width.int64 == 0
  result.autoHeight = config.height.int64 == 0
  if not result.autoWidth:
    discard checked(config.width, "Map width", 13, 61)
  if not result.autoHeight:
    discard checked(config.height, "Map height", 13, 61)
  result.refreshDimensions()
  result.roster.exposePlayerInfo = config.exposePlayerInfo
  for i, player in config.players:
    result.roster.players[i] = PlayerInfo(
      name: player.name,
      mmr: checked(player.mmr, "MMR", -1, int32.high.int).int32
    )
    result.botFiles[i] = botPath(player.bot, directory)
  discard result.resolvedRoster()

proc loadSettings*(path: string): Settings =
  ## Loads one bounded engine config and resolves bot paths beside that file.
  if path.len == 0:
    raise newException(GeneralsError, "Config path is empty.")
  try:
    if getFileSize(path) > MaxSettingsBytes:
      raise newException(GeneralsError, "Config exceeds the 1 MiB size limit.")
    result = parseSettings(readFile(path), absolutePath(path).parentDir)
  except IOError, OSError:
    raise newException(
      GeneralsError,
      "Cannot read config: " & getCurrentExceptionMsg()
    )

proc configuredSettings*(arguments: openArray[string]): Settings =
  ## Loads the last config flag before any explicit CLI options are applied.
  result = defaultSettings()
  var path = ""
  for argument in arguments:
    if argument.startsWith("--config="):
      path = argument[9 .. ^1]
      if path.len == 0:
        raise newException(GeneralsError, "Config path is empty.")
  if path.len > 0:
    result = loadSettings(path)

proc seatValue(value: string): tuple[seat: int, value: string] =
  ## Splits one CLI seat assignment without changing colons in names or paths.
  let separator = value.find(':')
  if separator < 1:
    raise newException(
      GeneralsError,
      "Use SEAT:VALUE with seats numbered 1-" & $MaxPlayers & "."
    )
  result.seat = boundedNumber(value[0 ..< separator], "Seat", 1, MaxPlayers) - 1
  result.value = value[separator + 1 .. ^1]

proc applySetting*(settings: var Settings, argument: string): bool =
  ## Applies one CLI override and reports whether it belongs to match settings.
  result = true
  if argument.startsWith("--config="):
    discard
  elif argument.startsWith("--seed="):
    settings.config.seed = boundedNumber(
      argument[7 .. ^1], "Seed", 0, int32.high.int
    )
    settings.refreshDimensions()
  elif argument.startsWith("--players="):
    settings.config.players = boundedNumber(
      argument[10 .. ^1], "Players", 2, MaxPlayers
    )
    settings.refreshDimensions()
  elif argument.startsWith("--turns="):
    settings.config.maxTurns = boundedNumber(
      argument[8 .. ^1], "Turn limit", 1, 100_000
    )
  elif argument.startsWith("--name="):
    let assignment = seatValue(argument[7 .. ^1])
    settings.roster.players[assignment.seat].name = assignment.value
    settings.changedSeats.incl(assignment.seat)
  elif argument.startsWith("--mmr="):
    let assignment = seatValue(argument[6 .. ^1])
    settings.roster.players[assignment.seat].mmr = boundedNumber(
      assignment.value, "MMR", -1, int32.high.int
    ).int32
    settings.changedSeats.incl(assignment.seat)
  elif argument.startsWith("--bot="):
    let assignment = seatValue(argument[6 .. ^1])
    if assignment.value.len == 0:
      raise newException(GeneralsError, "Bot path is empty.")
    settings.botFiles[assignment.seat] = botPath(
      assignment.value,
      getCurrentDir()
    )
    settings.changedSeats.incl(assignment.seat)
  elif argument.startsWith("--player-info="):
    case argument[14 .. ^1]
    of "on":
      settings.roster.exposePlayerInfo = true
    of "off":
      settings.roster.exposePlayerInfo = false
    else:
      raise newException(GeneralsError, "Player info must be on or off.")
  else:
    result = false
