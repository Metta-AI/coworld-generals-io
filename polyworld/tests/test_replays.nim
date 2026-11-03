import
  std/[os, strutils],
  flatty,
  ../src/generals/[bots, common, players, replays, worlds]

type
  LegacyTestSetup = object
    mapHash: uint64
    maximumTicks: uint32
  LegacyTestData = ActionTape[
    LegacyTestSetup, ReplayAction, void, Config
  ]
  RosterTestRoster = object
    players: array[4, PlayerInfo]
    exposePlayerInfo: bool
  RosterTestSetup = object
    mapHash: uint64
    maximumTicks: uint32
    roster: RosterTestRoster
  RosterTestData = ActionTape[
    RosterTestSetup, ReplayAction, ReplayMessages, Config
  ]

template expectReplayError(body: untyped) =
  ## Requires malformed input to fail at the Generals error boundary.
  block:
    var failed = false
    try:
      body
    except GeneralsError:
      failed = true
    doAssert failed, "Expected a Generals replay error"

proc snapshot(world: World): World =
  ## Copies every sequence so expected states cannot share live mutations.
  result = World(
    config: world.config,
    turn: world.turn,
    winner: world.winner,
    finished: world.finished,
    tiles: newSeq[Tile](world.tiles.len),
    generals: newSeq[int](world.generals.len),
    alive: newSeq[bool](world.alive.len)
  )
  for i, tile in world.tiles:
    result.tiles[i] = tile
  for i, general in world.generals:
    result.generals[i] = general
  for i, alive in world.alive:
    result.alive[i] = alive

proc rawMove(world: World, move: Move): Move =
  ## Expresses an adjacent bot command using the reference action geometry.
  let delta = move.target - move.source
  var direction = -1
  if delta == -world.config.width:
    direction = 0
  elif delta == world.config.width:
    direction = 1
  elif delta == -1:
    direction = 2
  elif delta == 1:
    direction = 3
  doAssert direction >= 0
  actionMove(
    move.source div world.config.width,
    move.source mod world.config.width,
    direction,
    move.half
  )

proc recordedMatch(players: int): tuple[data: ReplayData, states: seq[World]] =
  ## Records real bot games with raw, half, rejected, and passing commands.
  var config = defaultConfig(7, players)
  config.maxTurns = 2000
  var
    world = newWorld(config)
    moves = newSeq[Move](players)
    scratch: BotScratch
  let recorder = newReplayRecorder(world)
  result.states.add(world.snapshot())
  while not world.finished:
    for player in 0 ..< players:
      moves[player] = chooseMove(world, player, scratch)
      if moves[player] != noMove() and world.turn mod 7 == 0:
        moves[player] = rawMove(world, moves[player])
      if moves[player] != noMove() and world.turn mod 11 == 0:
        moves[player].half = true
    case world.turn
    of 0:
      moves[0] = actionMove(2, 2, 3, true)
      moves[1] = Move(source: -1, target: -1, half: true)
    of 1:
      moves[0] = Move(
        source: -7,
        target: 99,
        raw: true,
        row: 2,
        column: 2,
        direction: 9
      )
      moves[1] = actionMove(-3, -9, 0, true)
    of 2:
      moves[0] = Move(source: 0, target: world.tiles.len + 3)
    else:
      discard
    world.tick(moves)
    recorder.recordTick(world, moves)
    result.states.add(world.snapshot())
  result.data = recorder.data
  doAssert result.data.header.setup.maximumTicks == uint32(config.maxTurns)
  doAssert result.data.hashes.len == world.turn
  echo "Recorded ", players, " players, ", world.turn, " ticks, ",
    result.data.actions.len, " actions"

echo "Testing standard Polyworld action tapes and exact lockstep playback"
var
  sample: ReplayData
  conquests = 0
for players in [2, 4]:
  let
    recorded = recordedMatch(players)
    bytes = recorded.data.encodeReplay()
    header = bytes.replayFileHeader()
    data = bytes.decodeReplay()
    player = newReplayPlayer(data)
  var
    world = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
  doAssert header.game == ReplayGame
  doAssert header.formatVersion == ReplayFileVersion
  doAssert header.gameVersion == ReplayGameVersion
  doAssert data == recorded.data
  doAssert world == recorded.states[0]
  while player.replayTick(world, moves):
    doAssert world == recorded.states[world.turn]
    doAssert world.stateHash() == data.hashes[world.turn - 1]
    if world.turn == 1:
      doAssert moves[0] == actionMove(2, 2, 3, true)
      doAssert moves[1] == Move(source: -1, target: -1, half: true)
    if world.turn == 2:
      doAssert moves[0].raw and moves[0].direction == 9
      doAssert moves[0].source == -7 and moves[0].target == 99
      doAssert moves[1] == actionMove(-3, -9, 0, true)
    for unused in players ..< MaxPlayers:
      doAssert moves[unused] == noMove()
  doAssert world == recorded.states[^1]
  doAssert world.finished
  doAssert not player.replayTick(world, moves)
  for alive in world.alive:
    if not alive:
      inc conquests

  # Restoring a historical world also restores the shared action cursor.
  let seekTurn = min(37, data.hashes.len)
  world = recorded.states[seekTurn].snapshot()
  player.syncCursor(uint32(seekTurn))
  while player.replayTick(world, moves):
    doAssert world == recorded.states[world.turn]
  doAssert world == recorded.states[^1]
  world = newReplayWorld(data)
  player.syncCursor(0)
  for tick in 1 .. seekTurn:
    doAssert player.replayTick(world, moves)
    doAssert world == recorded.states[tick]
  if players == 2:
    sample = data
doAssert conquests > 0, "Replays must cover actual general captures"

echo "Testing empty recordings and initial map isolation"
block:
  var world = newWorld(defaultConfig(2, 2))
  let
    initial = world.snapshot()
    recorder = newReplayRecorder(world)
    data = recorder.data.encodeReplay().decodeReplay()
    player = newReplayPlayer(data)
  var moves: array[MaxPlayers, Move]
  doAssert data.actions.len == 0 and data.hashes.len == 0
  doAssert not player.replayTick(world, moves)
  world.tiles[world.generals[0]].army += 100
  doAssert newReplayWorld(data) == initial
  expectReplayError:
    discard newReplayRecorder(world)
  world = initial.snapshot()
  world.tick([noMove(), noMove()])
  expectReplayError:
    discard newReplayRecorder(world)

echo "Testing pass omission, recording bounds, and atomic invalid commands"
block:
  var config = defaultConfig(5, 2)
  config.maxTurns = 2
  var world = newWorld(config)
  let recorder = newReplayRecorder(world)
  world.tick([noMove(), noMove()])
  expectReplayError:
    recorder.recordTick(world, [noMove()])
  doAssert recorder.data.hashes.len == 0
  recorder.recordTick(world, [noMove(), noMove()])
  doAssert recorder.data.actions.len == 0
  expectReplayError:
    recorder.recordTick(world, [noMove(), noMove()])
  world.tick([noMove(), noMove()])
  let invalid = Move(raw: true, row: int32.high.int, direction: 0)
  expectReplayError:
    recorder.recordTick(world, [invalid, noMove()])
  doAssert recorder.data.hashes.len == 1
  doAssert recorder.data.actions.len == 0
  when sizeof(int) > sizeof(int32):
    let oversized = Move(source: int32.high.int + 1, target: 0)
    expectReplayError:
      recorder.recordTick(world, [oversized, noMove()])
    expectReplayError:
      discard newReplayRecorder(
        newWorld(defaultConfig(int32.high.int + 1, 2))
      )
  recorder.recordTick(world, [noMove(), noMove()])
  doAssert recorder.data.hashes.len == 2
  inc world.turn
  expectReplayError:
    recorder.recordTick(world, [noMove(), noMove()])

echo "Testing file round trips and bounded malformed input"
block:
  let
    path = "out/test-replays-" & $getCurrentProcessId() & ".replay"
    bytes = sample.encodeReplay()
  defer:
    if fileExists(path):
      removeFile(path)
  saveReplay(path, sample)
  doAssert loadReplay(path) == sample
  expectReplayError:
    discard loadReplay(path & ".missing")
  expectReplayError:
    saveReplay("", sample)
  expectReplayError:
    discard loadReplay("")
  expectReplayError:
    discard decodeReplay(newString(MaxReplayBytes + 1))
  for length in [0, 1, ReplayMagic.len, 30, 90, bytes.len - 1]:
    expectReplayError:
      discard decodeReplay(bytes[0 ..< min(length, bytes.len)])
  expectReplayError:
    discard decodeReplay(bytes & "trailing")
  var empty = newReplayRecorder(newWorld(sample.config)).data
  let
    emptyBytes = empty.encodeReplay()
    actionLengthOffset = emptyBytes.len - 24
  var malformed = emptyBytes
  for i in 0 ..< 8:
    malformed[actionLengthOffset + i] = char(255)
  expectReplayError:
    discard decodeReplay(malformed)

echo "Testing chat allocation bounds before decoding untrusted metadata"
block:
  for count in [-1, MaxReplayChats + 1, 1_000_000]:
    let payload = count.toFlatty() & newString(max(0, count))
    var
      decoded: ReplayMessages
      position = 0
      failure: string
    try:
      payload.fromFlatty(position, decoded)
    except GeneralsError as error:
      failure = error.msg
    doAssert failure.contains("decoded chat count exceeds")
    doAssert decoded.chats.len == 0
  var
    decoded: ReplayMessages
    position = 0
  expectReplayError:
    MaxReplayChats.toFlatty().fromFlatty(position, decoded)
  doAssert decoded.chats.len == 0
  let
    oversized = ReplayMessages(chats: @[
      ReplayChat(tick: 0, player: 0, text: "x".repeat(561))
    ])
    payload = oversized.toFlatty()
  position = 0
  var failure: string
  try:
    payload.fromFlatty(position, decoded)
  except GeneralsError as error:
    failure = error.msg
  doAssert failure.contains("decoded chat text exceeds the byte limit")
  doAssert decoded.chats.len == 1 and decoded.chats[0].text.len == 0
  let
    empty = newReplayRecorder(newWorld(sample.config)).data.encodeReplay()
    malicious = empty[0 ..< empty.len - 8] &
      1_000_000.toFlatty() & newString(1_000_000)
  failure = ""
  try:
    discard malicious.decodeReplay()
  except GeneralsError as error:
    failure = error.msg
  doAssert failure.contains("decoded chat count exceeds")

echo "Testing game and tape versions and malformed action metadata"
block:
  let bytes = sample.encodeReplay()
  expectReplayError:
    discard decodeReplay(encodeReplayFile("galcon", ReplayGameVersion, sample))
  expectReplayError:
    discard decodeReplay(encodeReplayFile(
      ReplayGame,
      ReplayGameVersion + 1,
      sample
    ))
  var changed = bytes.decodeReplay()
  changed.header.formatVersion += 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.gameVersion += 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapVersion = ReplayMapVersion + 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapVersion = 0
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.maximumTicks += 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapHash = changed.header.setup.mapHash xor 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.config.width = int.high
  expectReplayError:
    discard newReplayPlayer(changed)
  when sizeof(int) > sizeof(int32):
    changed = bytes.decodeReplay()
    changed.config.seed = int32.high.int + 1
    expectReplayError:
      discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].player = uint32(changed.config.players)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].flags = 4
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].row = int32.low
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].tick = 0
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[^1].tick = uint32(changed.hashes.len + 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].tick = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions.insert(changed.actions[0], 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.hashes.setLen(changed.config.maxTurns + 1)
  expectReplayError:
    discard newReplayPlayer(changed)

echo "Testing replay divergence and stale cursors"
block:
  var data = sample.encodeReplay().decodeReplay()
  data.hashes[0] = data.hashes[0] xor 1
  let player = newReplayPlayer(data)
  var
    world = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
  expectReplayError:
    discard player.replayTick(world, moves)
  let goodPlayer = newReplayPlayer(sample)
  world = newReplayWorld(sample)
  world.turn = 1
  expectReplayError:
    discard goodPlayer.replayTick(world, moves)
  world = newReplayWorld(sample)
  world.finished = true
  expectReplayError:
    discard goodPlayer.replayTick(world, moves)

echo "Testing public roster metadata without BASIC paths or sources"
block:
  let world = newWorld(defaultConfig(8, 2))
  var
    roster = defaultRoster()
    files: BotFiles
  files[0] = "/private/local/bots/Explorer.bas"
  files[1] = "/private/local/bots/unused.bas"
  roster.players[0].mmr = 37
  roster.players[1] = PlayerInfo(name: "  Commander  ", mmr: 0)
  roster.players[3] = PlayerInfo(name: "Inactive", mmr: 8)
  roster.exposePlayerInfo = false
  let
    resolved = resolveRoster(roster, files, 2)
    recorder = newReplayRecorder(world, resolved)
    bytes = recorder.data.encodeReplay()
    data = bytes.decodeReplay()
    stored = data.header.setup.roster
  doAssert stored == resolved
  doAssert stored.players[0] == PlayerInfo(name: "Explorer", mmr: 37)
  doAssert stored.players[1] == PlayerInfo(name: "Commander", mmr: 0)
  doAssert stored.players[3] == PlayerInfo(name: "", mmr: -1)
  doAssert not stored.exposePlayerInfo
  doAssert stored.queryName(0) == "" and stored.queryMmr(0) == -1
  doAssert not bytes.contains("/private/local/")
  doAssert not bytes.contains(".bas")
  roster.players[0].name = "Changed later"
  doAssert recorder.data.header.setup.roster == resolved
  doAssert newReplayWorld(data) == world
  doAssert newReplayWorld(data).stateHash() == world.stateHash()
  roster = defaultRoster()
  let generic = newReplayRecorder(world, roster).data.header.setup.roster
  doAssert generic.players[0] == PlayerInfo(name: "Player 1", mmr: -1)
  doAssert generic.players[1] == PlayerInfo(name: "Player 2", mmr: -1)
  doAssert generic.exposePlayerInfo
  for invalidName in [
    "x".repeat(MaxPlayerNameBytes + 1), "\xff", "\xed\xa0\x80",
    "\xf4\x90\x80\x80", "\xe0\x81\x81"
  ]:
    roster = defaultRoster()
    roster.players[0].name = invalidName
    expectReplayError:
      discard newReplayRecorder(world, roster)
  roster = defaultRoster()
  roster.players[0].mmr = -2
  expectReplayError:
    discard newReplayRecorder(world, roster)
  files[0] = "/private/local/bots/literal.bas.bas"
  roster = resolveRoster(defaultRoster(), files, 2)
  doAssert roster.players[0].name == "literal.bas"
  doAssert newReplayRecorder(world, roster).data.header.setup.roster == roster
  var changed = bytes.decodeReplay()
  changed.header.setup.roster.players[0].name = "bad\nname"
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.roster.players[0].mmr = -2
  expectReplayError:
    discard newReplayPlayer(changed)
  var malformed = bytes
  let gateOffset =
    ReplayMagic.len + 6 + ReplayGame.len +
    recorder.data.header.toFlatty().len - 1
  malformed[gateOffset] = char(2)
  expectReplayError:
    discard decodeReplay(malformed)

echo "Testing public chat metadata, ordering, normalization, and caps"
block:
  var
    config = defaultConfig(4, 2)
    world: World
  config.maxTurns = 1
  world = newWorld(config)
  let recorder = newReplayRecorder(world)
  doAssert recorder.recordChat(0, 0, "Ready 🌟")
  world.tick([noMove(), noMove()])
  recorder.recordTick(world, [noMove(), noMove()])
  let expectedHash = world.stateHash()
  doAssert recorder.recordChat(1, 1, "Good game")
  doAssert recorder.recordChat(0, 1, "🌟".repeat(140))
  let data = recorder.data.encodeReplay().decodeReplay()
  doAssert data.metrics.chats == recorder.data.metrics.chats
  doAssert data.metrics.chats[0] == ReplayChat(
    tick: 0,
    player: 0,
    text: "Ready 🌟"
  )
  doAssert data.actions.len == 0
  doAssert data.hashes == @[expectedHash]
  let player = newReplayPlayer(data)
  var
    replay = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
  doAssert player.replayTick(replay, moves)
  doAssert replay == world
  for invalidText in [
    "", " leading", "trailing ", "two  spaces", "line\nbreak",
    "control\x01", "\xff", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    "\xe0\x81\x81", "🌟".repeat(141)
  ]:
    expectReplayError:
      discard recorder.recordChat(0, 1, invalidText)
  expectReplayError:
    discard recorder.recordChat(2, 1, "Unknown player")
  expectReplayError:
    discard recorder.recordChat(-1, 1, "Unknown player")
  expectReplayError:
    discard recorder.recordChat(0, 2, "Future")
  expectReplayError:
    discard recorder.recordChat(0, -1, "Negative")
  expectReplayError:
    discard recorder.recordChat(0, 0, "Backward")
  let bytes = data.encodeReplay()
  var changed = bytes.decodeReplay()
  changed.metrics.chats[0].player = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.metrics.chats[0].tick = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.metrics.chats[1].tick = 0
  changed.metrics.chats[0].tick = 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.metrics.chats[0].text = "bad\nchat"
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.metrics.chats.setLen(MaxReplayChats + 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  var boundedWorld = newWorld(config)
  let bounded = newReplayRecorder(boundedWorld)
  for i in 0 ..< MaxReplayChats:
    doAssert bounded.recordChat(i mod 2, 0, "Public")
  doAssert not bounded.recordChat(0, 0, "Budget exhausted")
  doAssert bounded.data.metrics.chats.len == MaxReplayChats
  boundedWorld.tick([noMove(), noMove()])
  bounded.recordTick(boundedWorld, [noMove(), noMove()])
  doAssert not bounded.recordChat(0, 1, "Still exhausted")
  let boundedData = bounded.data.encodeReplay().decodeReplay()
  doAssert boundedData.metrics.chats.len == MaxReplayChats
  doAssert boundedData.hashes.len == 1
  expectReplayError:
    discard bounded.recordChat(-1, 0, "Still invalid")

echo "Testing all FFA seat counts, player ten, and map version retention"
for count in 2 .. MaxPlayers:
  var
    config = defaultConfig(19, count)
    roster = defaultRoster()
  config.maxTurns = 64
  for i in 0 ..< count:
    roster.players[i] = PlayerInfo(name: "Commander " & $(i + 1), mmr: int32(i))
  var
    world = newWorld(config)
    scratch: BotScratch
    moves = newSeq[Move](count)
  let recorder = newReplayRecorder(world, roster)
  doAssert recorder.data.header.setup.mapVersion == ReplayMapVersion
  doAssert recorder.recordChat(count - 1, 0, "Last seat ready")
  while not world.finished:
    for i in 0 ..< count:
      moves[i] = chooseMove(world, i, scratch)
    world.tick(moves)
    recorder.recordTick(world, moves)
  let
    data = recorder.data.encodeReplay().decodeReplay()
    player = newReplayPlayer(data)
  var
    replay = newReplayWorld(data)
    replayMoves: array[MaxPlayers, Move]
    lastPlayerActed = false
  doAssert data.header.setup.roster == roster
  doAssert data.metrics.chats[0].player == int32(count - 1)
  for action in data.actions:
    if action.player == uint32(count - 1):
      lastPlayerActed = true
  doAssert lastPlayerActed
  while player.replayTick(replay, replayMoves):
    discard
  doAssert replay == world
  var invalid = data
  invalid.header.setup.mapVersion = LegacyMapVersion
  expectReplayError:
    discard newReplayWorld(invalid)

echo "Testing exact legacy v1 and v2 layouts with their original maps"
block:
  let config = Config(
    width: 23,
    height: 19,
    players: 4,
    seed: 7,
    maxTurns: 4000
  )
  var
    original = newWorldLegacy(config)
    legacy = LegacyTestData(
      header: TapeHeader[LegacyTestSetup](
        formatVersion: 1,
        gameVersion: 1,
        setup: LegacyTestSetup(
          mapHash: original.stateHash(),
          maximumTicks: uint32(config.maxTurns)
        )
      ),
      config: config
    )
    scratch: BotScratch
    commands: array[4, Move]
  # This fingerprint comes from an unchanged version 1 recording.
  doAssert legacy.header.setup.mapHash == 3432510669'u64
  for tick in 1 .. 128:
    for i in 0 ..< 4:
      commands[i] = chooseMove(original, i, scratch)
      if commands[i] != noMove():
        legacy.actions.add(ReplayAction(
          tick: uint32(tick),
          player: uint32(i),
          flags: uint32(commands[i].half),
          source: int32(commands[i].source),
          target: int32(commands[i].target)
        ))
    original.tick(commands)
    legacy.hashes.add(original.stateHash())
  let
    bytes = encodeReplayFile(ReplayGame, 1, legacy)
    data = bytes.decodeReplay()
    player = newReplayPlayer(data)
  doAssert bytes.replayFileHeader().gameVersion == 1
  doAssert data.header.gameVersion == ReplayGameVersion
  doAssert data.header.formatVersion == ReplayFormatVersion
  doAssert data.header.setup.mapVersion == LegacyMapVersion
  doAssert data.config == legacy.config
  doAssert data.actions == legacy.actions
  doAssert data.hashes == legacy.hashes
  doAssert data.header.setup.roster.players[0] ==
    PlayerInfo(name: "Player 1", mmr: -1)
  doAssert data.header.setup.roster.exposePlayerInfo
  doAssert data.metrics.chats.len == 0
  let upgraded = data.encodeReplay().decodeReplay()
  doAssert upgraded == data
  doAssert data.encodeReplay().replayFileHeader().gameVersion ==
    ReplayGameVersion
  var
    world = newReplayWorld(upgraded)
    moves: array[MaxPlayers, Move]
  while player.replayTick(world, moves):
    doAssert world.stateHash() == legacy.hashes[world.turn - 1]
  doAssert world == original
  expectReplayError:
    discard decodeReplay(bytes & "trailing")
  expectReplayError:
    discard decodeReplay(bytes[0 ..< bytes.len - 1])
  legacy.header.formatVersion = 2
  expectReplayError:
    discard decodeReplay(encodeReplayFile(ReplayGame, 1, legacy))
  legacy.header.formatVersion = 1
  legacy.header.gameVersion = 2
  expectReplayError:
    discard decodeReplay(encodeReplayFile(ReplayGame, 1, legacy))
  var versionTwo = RosterTestData(
    header: TapeHeader[RosterTestSetup](
      formatVersion: 2,
      gameVersion: 2,
      setup: RosterTestSetup(
        mapHash: legacy.header.setup.mapHash,
        maximumTicks: legacy.header.setup.maximumTicks
      )
    ),
    config: config,
    actions: legacy.actions,
    hashes: legacy.hashes,
    metrics: ReplayMessages(chats: @[
      ReplayChat(tick: 0, player: 3, text: "Original roster"),
      ReplayChat(tick: 128, player: 0, text: "End of recording")
    ])
  )
  for i in 0 ..< 4:
    versionTwo.header.setup.roster.players[i] =
      PlayerInfo(name: "Legacy " & $(i + 1), mmr: int32(i * 10))
  let
    rosterBytes = encodeReplayFile(ReplayGame, 2, versionTwo)
    rosterData = rosterBytes.decodeReplay()
    rosterPlayer = newReplayPlayer(rosterData)
  doAssert rosterData.header.setup.mapVersion == LegacyMapVersion
  doAssert rosterData.header.setup.roster.players[3] ==
    PlayerInfo(name: "Legacy 4", mmr: 30)
  doAssert not rosterData.header.setup.roster.exposePlayerInfo
  for i in 4 ..< MaxPlayers:
    doAssert rosterData.header.setup.roster.players[i] ==
      PlayerInfo(name: "", mmr: -1)
  doAssert rosterData.metrics == versionTwo.metrics
  doAssert rosterData.encodeReplay().decodeReplay() == rosterData
  world = newReplayWorld(rosterData)
  while rosterPlayer.replayTick(world, moves):
    discard
  doAssert world == original
  expectReplayError:
    discard decodeReplay(rosterBytes & "trailing")
  expectReplayError:
    discard decodeReplay(rosterBytes[0 ..< rosterBytes.len - 1])
  versionTwo.header.gameVersion = 1
  expectReplayError:
    discard decodeReplay(encodeReplayFile(ReplayGame, 2, versionTwo))

echo "All replay checks passed"
