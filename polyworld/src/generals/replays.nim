import
  std/[os, unicode],
  flatty, polyworld/[hashes, tapes],
  common, events, players, worlds

export tapes

const
  ReplayGame* = "generals"
  ReplayFormatVersion* = 3'u16
  ReplayGameVersion* = 3'u16
  LegacyMapVersion* = 1'u16
  ReplayMapVersion* = 2'u16
  MaxReplayTicks* = 100_000
  MaxReplayActions* = MaxReplayTicks * MaxPlayers
  MaxReplayChats* = 16_384
  MaxReplayBytes* = 64 * 1024 * 1024
  RosterReplayBytes = 32 * 1024 * 1024
  LegacyReplayBytes = 16 * 1024 * 1024
  ChatHeaderBytes = 16
  HalfFlag = 1'u32
  RawFlag = 2'u32

type
  ReplaySetup* = object
    mapVersion*: uint16
    mapHash*: uint64
    maximumTicks*: uint32
    roster*: Roster
  ReplayAction* = object
    tick*, player*, flags*: uint32
    source*, target*, row*, column*, direction*: int32
  ReplayChat* = object
    tick*: uint32
    player*: int32
    text*: string
  ReplayMessages* = object
    chats*: seq[ReplayChat]
  ReplayData* = ActionTape[ReplaySetup, ReplayAction, ReplayMessages, Config]
  ReplayRecorder* = TapeRecorder[
    ReplaySetup, ReplayAction, ReplayMessages, Config
  ]
  ReplayPlayer* = TapePlayer[
    ReplaySetup, ReplayAction, ReplayMessages, Config
  ]
  LegacySetup = object
    mapHash: uint64
    maximumTicks: uint32
  LegacyData = ActionTape[LegacySetup, ReplayAction, void, Config]
  LegacyRoster = object
    players: array[4, PlayerInfo]
    exposePlayerInfo: bool
  RosterSetup = object
    mapHash: uint64
    maximumTicks: uint32
    roster: LegacyRoster
  RosterData = ActionTape[RosterSetup, ReplayAction, ReplayMessages, Config]

proc fail(message: string) {.noreturn, raises: [GeneralsError].} =
  ## Raises an error at the Generals replay boundary.
  raise newException(GeneralsError, "Replay: " & message)

proc fromFlatty*(
    bytes: string,
    position: var int,
    messages: var ReplayMessages
) {.raises: [GeneralsError].} =
  ## Bounds chat counts and text bytes before Flatty can allocate them.
  var count: int
  bytes.fromFlatty(position, count)
  if count < 0 or count > MaxReplayChats:
    fail("decoded chat count exceeds the recording limit")
  if position > bytes.len or
    count > (bytes.len - position) div ChatHeaderBytes:
      fail("decoded chat entries exceed the remaining payload")
  messages.chats = newSeq[ReplayChat](count)
  for chat in messages.chats.mitems:
    bytes.fromFlatty(position, chat.tick)
    bytes.fromFlatty(position, chat.player)
    var textBytes: int
    bytes.fromFlatty(position, textBytes)
    if textBytes < 0 or textBytes > MaxChatCharacters * 4:
      fail("decoded chat text exceeds the byte limit")
    if position > bytes.len or textBytes > bytes.len - position:
      fail("decoded chat text exceeds the remaining payload")
    chat.text = bytes[position ..< position + textBytes]
    position += textBytes

proc stateHash*(world: World): uint64 {.raises: [].} =
  ## Hashes every authoritative field with portable Polyworld hashing.
  uint64(hashy(world))

proc initialWorld(
    config: Config,
    mapVersion = ReplayMapVersion
): World {.raises: [GeneralsError].} =
  ## Rebuilds the recorded generator with portable native integer fields.
  if config.seed > int32.high.int:
    fail("map seed exceeds the portable signed 32-bit range")
  case mapVersion
  of LegacyMapVersion:
    newWorldLegacy(config)
  of ReplayMapVersion:
    newWorld(config)
  else:
    fail("unsupported map generation version " & $mapVersion)

proc recordedRoster(roster: Roster, count: int): Roster {.
    raises: [GeneralsError].} =
  ## Preserves resolved public labels and fills only unnamed active seats.
  roster.validateRoster(count)
  result = defaultRoster()
  result.exposePlayerInfo = roster.exposePlayerInfo
  for player in 0 ..< count:
    result.players[player] = PlayerInfo(
      name: roster.displayName(player),
      mmr: roster.players[player].mmr
    )

proc validateAction(action: ReplayAction, players: int) {.
    raises: [GeneralsError].} =
  ## Checks command metadata without rejecting ordinary illegal moves.
  if action.player >= uint32(players):
    fail("action references an unknown player")
  if action.flags > HalfFlag + RawFlag:
    fail("action contains unsupported move flags")
  if (action.flags and RawFlag) != 0 and action.direction in 0 .. 3:
    if action.row in [int32.low, int32.high] or
      action.column in [int32.low, int32.high]:
        fail("raw action coordinates exceed the portable range")

proc actionMove(action: ReplayAction): Move {.raises: [].} =
  ## Restores all submitted move fields, including rejected commands.
  Move(
    source: int(action.source),
    target: int(action.target),
    half: (action.flags and HalfFlag) != 0,
    raw: (action.flags and RawFlag) != 0,
    row: int(action.row),
    column: int(action.column),
    direction: int(action.direction)
  )

proc replayAction(move: Move, tick, player: int): ReplayAction {.
    raises: [GeneralsError].} =
  ## Converts the runtime command to fixed-width, padding-free tape fields.
  let values = [move.source, move.target, move.row, move.column, move.direction]
  for value in values:
    if value < int32.low.int or value > int32.high.int:
      fail("move field exceeds the portable signed 32-bit range")
  result = ReplayAction(
    tick: uint32(tick),
    player: uint32(player),
    source: int32(move.source),
    target: int32(move.target),
    row: int32(move.row),
    column: int32(move.column),
    direction: int32(move.direction)
  )
  if move.half:
    result.flags = result.flags or HalfFlag
  if move.raw:
    result.flags = result.flags or RawFlag

proc validateChat(chat: ReplayChat, count, duration: int) {.
    raises: [GeneralsError].} =
  ## Checks accepted public chat without modifying its text or timestamp.
  if chat.player < 0 or chat.player >= count:
    fail("chat references an unknown player")
  if chat.tick > uint32(duration):
    fail("chat is outside the recorded duration")
  if chat.text.len == 0 or chat.text.len > MaxChatCharacters * 4 or
    not chat.text.validUtf8():
      fail("chat must contain bounded, valid UTF-8 text")
  var
    characters = 0
    space = true
  for rune in chat.text.runes:
    if rune.int < 32 or rune.int in 127 .. 159:
      fail("chat contains control characters")
    if rune.isWhiteSpace:
      if rune.int != 32 or space:
        fail("chat whitespace must already be normalized")
      space = true
    else:
      space = false
    inc characters
    if characters > MaxChatCharacters:
      fail("chat exceeds the character limit")
  if space:
    fail("chat text must already be normalized")

proc validate(data: ReplayData): World {.raises: [GeneralsError].} =
  ## Validates the versioned setup and bounded, ordered action stream.
  try:
    data.header.requireTapeVersion(ReplayFormatVersion, ReplayGameVersion)
  except ReplayError as error:
    fail(error.msg)
  result = initialWorld(data.config, data.header.setup.mapVersion)
  data.header.setup.roster.validateRoster(data.config.players)
  if data.header.setup.maximumTicks != uint32(data.config.maxTurns):
    fail("configuration and setup have different turn limits")
  if data.header.setup.mapHash != result.stateHash():
    fail("generated map does not match its recorded fingerprint")
  if data.hashes.len > data.config.maxTurns:
    fail("hashes exceed the configured duration")
  if data.actions.len > MaxReplayActions or
    data.actions.len > data.hashes.len * data.config.players:
      fail("action count exceeds the recorded duration")
  var
    lastTick = 0'u32
    players = 0'u32
  for action in data.actions:
    action.validateAction(data.config.players)
    if action.tick == 0 or action.tick > uint32(data.hashes.len):
      fail("action is outside the recorded duration")
    if action.tick < lastTick:
      fail("actions move backward in time")
    if action.tick != lastTick:
      players = 0
    let mask = 1'u32 shl action.player
    if (players and mask) != 0:
      fail("player has multiple commands in one tick")
    players = players or mask
    lastTick = action.tick
  if data.metrics.chats.len > MaxReplayChats:
    fail("public chat exceeds the recording limit")
  lastTick = 0
  for chat in data.metrics.chats:
    chat.validateChat(data.config.players, data.hashes.len)
    if chat.tick < lastTick:
      fail("chat messages move backward in time")
    lastTick = chat.tick

proc newReplayRecorder*(
    world: World,
    roster = defaultRoster()
): ReplayRecorder {.raises: [GeneralsError].} =
  ## Starts an action-only recording from an unchanged generated match.
  if world.turn != 0 or world != initialWorld(world.config):
    fail("recording must start from the generated world at turn zero")
  new(result)
  result.data.header = TapeHeader[ReplaySetup](
    formatVersion: ReplayFormatVersion,
    gameVersion: ReplayGameVersion,
    setup: ReplaySetup(
      mapVersion: ReplayMapVersion,
      mapHash: world.stateHash(),
      maximumTicks: uint32(world.config.maxTurns),
      roster: recordedRoster(roster, world.config.players)
    )
  )
  result.data.config = world.config

proc recordTick*(
    recorder: ReplayRecorder,
    worldAfter: World,
    moves: openArray[Move]
) {.raises: [GeneralsError].} =
  ## Records submitted commands and the resulting authoritative tick hash.
  if recorder == nil:
    return
  if worldAfter.config != recorder.data.config:
    fail("world configuration changed during recording")
  if moves.len != worldAfter.config.players:
    fail("recording requires one move for every player")
  if worldAfter.turn != recorder.data.hashes.len + 1 or
    worldAfter.turn > worldAfter.config.maxTurns:
      fail("recording requires the next completed simulation tick")
  var
    actions: array[MaxPlayers, ReplayAction]
    count = 0
  for player, move in moves:
    if move == noMove():
      continue
    let action = replayAction(move, worldAfter.turn, player)
    action.validateAction(worldAfter.config.players)
    actions[count] = action
    inc count
  if recorder.data.actions.len + count > MaxReplayActions:
    fail("action limit exceeded")
  try:
    for i in 0 ..< count:
      recorder.data.actions.appendAction(actions[i], MaxReplayActions)
    recorder.data.hashes.appendHash(
      worldAfter.stateHash(),
      recorder.data.header.setup.maximumTicks,
      MaxReplayTicks
    )
  except ReplayError as error:
    fail(error.msg)

proc recordChat*(
    recorder: ReplayRecorder,
    player, turn: int,
    text: string
): bool {.raises: [GeneralsError].} =
  ## Keeps the first bounded public chat history without interrupting play.
  if recorder == nil:
    return false
  if player < 0 or player >= recorder.data.config.players or
    turn < 0 or turn > recorder.data.hashes.len:
      fail("chat player or turn is outside the recorded match")
  let chat = ReplayChat(tick: uint32(turn), player: int32(player), text: text)
  chat.validateChat(recorder.data.config.players, recorder.data.hashes.len)
  if recorder.data.metrics.chats.len > 0 and
    chat.tick < recorder.data.metrics.chats[^1].tick:
      fail("chat messages move backward in time")
  if recorder.data.metrics.chats.len >= MaxReplayChats:
    return false
  recorder.data.metrics.chats.add(chat)
  true

proc newReplayWorld*(data: ReplayData): World {.raises: [GeneralsError].} =
  ## Regenerates and verifies the initial world without running any bots.
  data.validate()

proc newReplayPlayer*(data: ReplayData): ReplayPlayer {.
    raises: [GeneralsError].} =
  ## Creates a shared Polyworld cursor over a validated Generals tape.
  discard data.validate()
  initTapePlayer(data)

proc replayTick*(
    player: ReplayPlayer,
    world: var World,
    moves: var array[MaxPlayers, Move]
): bool {.raises: [GeneralsError].} =
  ## Applies the next recorded tick and rejects any simulation divergence.
  for move in moves.mitems:
    move = noMove()
  if player == nil:
    return false
  if world.config != player.data.config or world.turn < 0:
    fail("playback world does not match the recorded configuration")
  if world.turn > player.data.hashes.len:
    fail("playback world is past the recorded duration")
  if world.turn == player.data.hashes.len:
    return false
  if world.finished:
    fail("simulation ended before the recorded duration")
  let tick = uint32(world.turn + 1)
  var
    action: ReplayAction
    players = 0'u32
  try:
    while player.takeActionAt(tick, action):
      action.validateAction(world.config.players)
      let mask = 1'u32 shl action.player
      if (players and mask) != 0:
        fail("player has multiple commands in one tick")
      players = players or mask
      moves[int(action.player)] = action.actionMove()
  except ReplayError as error:
    fail(error.msg)
  world.tick(moves.toOpenArray(0, world.config.players - 1))
  if world.turn != int(tick) or
    world.stateHash() != player.data.hashes[int(tick) - 1]:
      fail("simulation diverged at tick " & $tick)
  true

proc encodeReplay*(data: ReplayData): string {.raises: [GeneralsError].} =
  ## Encodes the standard Polyworld envelope and validated action tape.
  discard data.validate()
  try:
    result = encodeReplayFile(
      ReplayGame,
      ReplayGameVersion,
      data,
      MaxReplayBytes
    )
  except ReplayError as error:
    fail(error.msg)

proc decodeReplay*(bytes: string): ReplayData {.raises: [GeneralsError].} =
  ## Reads exact historical layouts and preserves their map generation.
  try:
    if bytes.len > MaxReplayBytes:
      fail("recording exceeds the file size limit")
    let header = bytes.replayFileHeader()
    case header.gameVersion
    of 1:
      let legacy = decodeReplayFile(
        ReplayGame,
        1,
        bytes,
        LegacyData,
        LegacyReplayBytes
      )
      legacy.header.requireTapeVersion(1, 1)
      if encodeReplayFile(ReplayGame, 1, legacy, LegacyReplayBytes) != bytes:
        fail("legacy recording has trailing or noncanonical bytes")
      result.header = TapeHeader[ReplaySetup](
        formatVersion: ReplayFormatVersion,
        gameVersion: ReplayGameVersion,
        setup: ReplaySetup(
          mapVersion: LegacyMapVersion,
          mapHash: legacy.header.setup.mapHash,
          maximumTicks: legacy.header.setup.maximumTicks,
          roster: recordedRoster(defaultRoster(), legacy.config.players)
        )
      )
      result.config = legacy.config
      result.actions = legacy.actions
      result.hashes = legacy.hashes
    of 2:
      let legacy = decodeReplayFile(
        ReplayGame,
        2,
        bytes,
        RosterData,
        RosterReplayBytes
      )
      legacy.header.requireTapeVersion(2, 2)
      if encodeReplayFile(ReplayGame, 2, legacy, RosterReplayBytes) != bytes:
        fail("legacy recording has trailing or noncanonical bytes")
      var roster = defaultRoster()
      roster.exposePlayerInfo = legacy.header.setup.roster.exposePlayerInfo
      for i, player in legacy.header.setup.roster.players:
        roster.players[i] = player
      result.header = TapeHeader[ReplaySetup](
        formatVersion: ReplayFormatVersion,
        gameVersion: ReplayGameVersion,
        setup: ReplaySetup(
          mapVersion: LegacyMapVersion,
          mapHash: legacy.header.setup.mapHash,
          maximumTicks: legacy.header.setup.maximumTicks,
          roster: roster
        )
      )
      result.config = legacy.config
      result.actions = legacy.actions
      result.hashes = legacy.hashes
      result.metrics = legacy.metrics
    of ReplayGameVersion:
      result = decodeReplayFile(
        ReplayGame,
        ReplayGameVersion,
        bytes,
        ReplayData,
        MaxReplayBytes
      )
      if encodeReplayFile(
        ReplayGame,
        ReplayGameVersion,
        result,
        MaxReplayBytes
      ) != bytes:
        fail("recording has trailing or noncanonical bytes")
    else:
      fail("unsupported gameplay version " & $header.gameVersion)
  except ReplayError, FlattyError, ValueError, IndexDefect, RangeDefect:
    fail("cannot decode recording: " & getCurrentExceptionMsg())
  discard result.validate()

proc saveReplay*(path: string, data: ReplayData) {.
    raises: [GeneralsError].} =
  ## Saves a validated tape using the shared Polyworld file format.
  if path.len == 0:
    fail("output path is empty")
  let bytes = data.encodeReplay()
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path, bytes)
  except IOError, OSError:
    fail("cannot save recording: " & getCurrentExceptionMsg())

proc loadReplay*(path: string): ReplayData {.raises: [GeneralsError].} =
  ## Checks the file size before reading and decoding the recording.
  if path.len == 0:
    fail("input path is empty")
  try:
    if getFileSize(path) > MaxReplayBytes:
      fail("recording exceeds the file size limit")
    result = decodeReplay(readFile(path))
  except IOError, OSError:
    fail("cannot load recording: " & getCurrentExceptionMsg())
