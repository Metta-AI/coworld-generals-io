import
  std/[os, strutils],
  bassy, polyworld/mailboxes,
  ../src/generals/[brains, common, events, messages, players, worlds]

proc testWorld(): World =
  ## Creates a known board with visible movement and private distant terrain.
  var config = defaultConfig(7, 2)
  config.width = 13
  config.height = 13
  result = newWorld(config)
  for tile in result.tiles.mitems:
    tile = Tile(kind: Plain, owner: -1)
  result.generals = @[28, 140]
  result.tiles[28] = Tile(kind: General, owner: 0, army: 10)
  result.tiles[140] = Tile(kind: General, owner: 1, army: 10)
  result.tiles[29] = Tile(kind: Plain, owner: 1, army: 2)
  result.tiles[15] = Tile(kind: Mountain, owner: -1)
  result.tiles[112] = Tile(kind: City, owner: 1, army: 77)
  result.tiles[113] = Tile(kind: Mountain, owner: -1)
  result.tiles[114] = Tile(kind: Plain, owner: 1, army: 99)

proc testRoster(): Roster =
  ## Creates distinguishable public names and valid zero and nonzero ranks.
  result = defaultRoster()
  result.players[0] = PlayerInfo(name: "Alice", mmr: 37)
  result.players[1] = PlayerInfo(name: "Bob", mmr: 0)
  result = result.resolveRoster(default(BotFiles), 2)

template expectBrainError(body: untyped) =
  ## Requires invalid source or host setup to fail at the game boundary.
  block:
    var failed = false
    try:
      body
    except GeneralsError:
      failed = true
    doAssert failed, "Expected a Generals BASIC error"

echo "Testing BASIC player metadata, fog, and current in-game time"
block:
  var world = testWorld()
  let
    hub = newMessageHub(testRoster(), 2)
    brain = newBrain("""
      calls = calls + 1
      self = selfPlayer()
      count = playerCount()
      enabled = playerInfoEnabled()
      name$ = playerName$(0)
      alias$ = mailboxName$(1)
      badName$ = playerName$(-1)
      inactiveName$ = playerName$(2)
      mmr = playerMmr(0)
      zeroMmr = playerMmr(1)
      invalidMmr = playerMmr(2)
      tick = worldTick()
      turn = worldTurn()
      wide = width()
      high = height()
      tiles = tileCount()
      home = selfGeneral()
      homeOwner = owner(home)
      homeArmy = army(home)
      shown = visible(home)
      hiddenCity = terrain(112)
      hiddenMountain = terrain(113)
      hiddenPlain = terrain(114)
      hiddenOwner = owner(112)
      hiddenArmy = army(112)
      enemyHome = terrain(140)
      offVisible = visible(-1)
      offTerrain = terrain(99999)
      offOwner = owner(-1)
      offArmy = army(tileCount())
    """, 0, hub)
  doAssert brain.decide(world) == noMove()
  doAssert not brain.failed
  doAssert brain.runtime.getGlobal("self") == 0
  doAssert brain.runtime.getGlobal("count") == 2
  doAssert brain.runtime.getGlobal("enabled") == 1
  doAssert brain.runtime.getStringGlobal("name$") == "Alice"
  doAssert brain.runtime.getStringGlobal("alias$") == "Bob"
  doAssert brain.runtime.getStringGlobal("badName$") == ""
  doAssert brain.runtime.getStringGlobal("inactiveName$") == ""
  doAssert brain.runtime.getGlobal("mmr") == 37
  doAssert brain.runtime.getGlobal("zeroMmr") == 0
  doAssert brain.runtime.getGlobal("invalidMmr") == -1
  doAssert brain.runtime.getGlobal("tick") == 0
  doAssert brain.runtime.getGlobal("turn") == 0
  doAssert brain.runtime.getGlobal("wide") == 13
  doAssert brain.runtime.getGlobal("high") == 13
  doAssert brain.runtime.getGlobal("tiles") == 169
  doAssert brain.runtime.getGlobal("home") == 28
  doAssert brain.runtime.getGlobal("homeOwner") == 0
  doAssert brain.runtime.getGlobal("homeArmy") == 10
  doAssert brain.runtime.getGlobal("shown") == 1
  doAssert brain.runtime.getGlobal("hiddenCity") == -2
  doAssert brain.runtime.getGlobal("hiddenMountain") == -2
  doAssert brain.runtime.getGlobal("hiddenPlain") == -1
  doAssert brain.runtime.getGlobal("hiddenOwner") == -1
  doAssert brain.runtime.getGlobal("hiddenArmy") == 0
  doAssert brain.runtime.getGlobal("enemyHome") == -1
  doAssert brain.runtime.getGlobal("offVisible") == 0
  doAssert brain.runtime.getGlobal("offTerrain") == -1
  doAssert brain.runtime.getGlobal("offOwner") == -1
  doAssert brain.runtime.getGlobal("offArmy") == 0
  world.tick([noMove(), noMove()])
  world.tick([noMove(), noMove()])
  doAssert brain.decide(world) == noMove()
  doAssert brain.runtime.getGlobal("calls") == 2
  doAssert brain.runtime.getGlobal("tick") == 2
  doAssert brain.runtime.getGlobal("turn") == 1
  doAssert brain.runtime.getGlobal("homeArmy") == 11
  hub.roster.players[0].mmr = 42
  discard brain.decide(world)
  doAssert brain.runtime.getGlobal("mmr") == 42
  hub.roster.exposePlayerInfo = false
  discard brain.decide(world)
  doAssert brain.runtime.getGlobal("enabled") == 0
  doAssert brain.runtime.getStringGlobal("name$") == ""
  doAssert brain.runtime.getStringGlobal("alias$") == ""
  doAssert brain.runtime.getGlobal("mmr") == -1
  doAssert brain.runtime.getGlobal("zeroMmr") == -1
  doAssert brain.runtime.getGlobal("tick") == 2

echo "Testing BASIC orders are bounded, ownership-checked, and deferred"
block:
  var world = testWorld()
  world.tiles[12] = Tile(kind: Plain, owner: 0, army: 10)
  let
    before = world
    hub = newMessageHub(testRoster(), 2)
    brain = newBrain("""
      off = send(-1, 0, 0)
      remote = send(140, 139, 0)
      diagonal = send(28, 42, 0)
      wrapped = send(12, 13, 0)
      mountain = send(28, 15, 0)
      badHalf = send(28, 29, 2)
      accepted = send(28, 29, 1)
      duplicate = send(28, 27, 0)
    """, 0, hub)
  let move = brain.decide(world)
  doAssert not brain.failed
  doAssert move == Move(source: 28, target: 29, half: true)
  doAssert world == before
  for name in ["off", "remote", "diagonal", "wrapped", "mountain",
    "badHalf", "duplicate"]:
      doAssert brain.runtime.getGlobal(name) == 0
  doAssert brain.runtime.getGlobal("accepted") == 1
  world.tick([move, noMove()])
  doAssert world.tiles[29].owner == 0
  doAssert brain.decide(world) == Move(source: 28, target: 29, half: true)
  world.tiles[28].army = 1
  doAssert brain.decide(world) == noMove()
  world.alive[0] = false
  doAssert brain.decide(world) == noMove()

echo "Testing BASIC mailbox routing and shared global capture notices"
block:
  let
    world = testWorld()
    hub = newMessageHub(testRoster(), 2)
    sender = newBrain("""
      if sent = 0 then
        sent = sendChat(1, "hello")
        duplicate = sendChat(-2, "extra")
      end if
    """, 0, hub)
    receiver = newBrain("""
      self = mailboxSelf()
      players = mailboxPlayers()
      count = mailboxCount()
      message$ = pullMailbox$()
      sender = mailboxId()
    """, 1, hub)
  var log: MatchLog
  log.resetLog()
  discard sender.decide(world)
  doAssert sender.runtime.getGlobal("sent") == 1
  doAssert sender.runtime.getGlobal("duplicate") == 0
  discard receiver.decide(world)
  doAssert receiver.runtime.getGlobal("count") == 0
  doAssert receiver.runtime.getGlobal("sender") == NoMailboxId
  hub.deliverMessages(log, 0)
  discard receiver.decide(world)
  doAssert receiver.runtime.getGlobal("self") == 1
  doAssert receiver.runtime.getGlobal("players") == 2
  doAssert receiver.runtime.getGlobal("count") == 1
  doAssert receiver.runtime.getGlobal("sender") == 0
  doAssert receiver.runtime.getStringGlobal("message$") == "Alice: hello"
  discard receiver.decide(world)
  doAssert receiver.runtime.getStringGlobal("message$") == ""
  doAssert receiver.runtime.getGlobal("sender") == NoMailboxId
  hub.broadcastEvent(LogEntry(kind: Capture, turn: 51, player: 0, target: 1))
  discard receiver.decide(world)
  doAssert receiver.runtime.getGlobal("sender") == GlobalMailbox
  let notice = receiver.runtime.getStringGlobal("message$")
  doAssert "Alice captured Bob" in notice and "51" in notice
  hub.roster.exposePlayerInfo = false
  hub.broadcastEvent(LogEntry(kind: Capture, turn: 52, player: 0, target: 1))
  discard receiver.decide(world)
  let hidden = receiver.runtime.getStringGlobal("message$")
  doAssert "Player 1 captured Player 2" in hidden
  doAssert "Alice" notin hidden and "Bob" notin hidden
  let broadcaster = newBrain("sent = sendChat(-2, \"hello all\")", 0, hub)
  discard broadcaster.decide(world)
  doAssert broadcaster.runtime.getGlobal("sent") == 2
  hub.deliverMessages(log, 1)
  discard receiver.decide(world)
  doAssert receiver.runtime.getGlobal("sender") == GlobalMailbox
  doAssert receiver.runtime.getStringGlobal("message$") ==
    "Player 1: hello all"

echo "Testing BASIC access from the highest FFA player seat"
block:
  let world = newWorld(defaultConfig(seed = 7, players = MaxPlayers))
  var roster = defaultRoster()
  roster.players[MaxPlayers - 1] = PlayerInfo(name: "Last", mmr: 51)
  roster = resolveRoster(roster, default(BotFiles), MaxPlayers)
  let
    hub = newMessageHub(roster, MaxPlayers)
    brain = newBrain("""
      self = selfPlayer()
      players = playerCount()
      name$ = playerName$(self)
      mmr = playerMmr(self)
      home = selfGeneral()
      homeOwner = owner(home)
      sent = sendChat(-2, "hello everyone")
      message$ = pullMailbox$()
      sender = mailboxId()
    """, MaxPlayers - 1, hub)
  discard brain.decide(world)
  doAssert not brain.failed
  doAssert brain.runtime.getGlobal("self") == (MaxPlayers - 1).int32
  doAssert brain.runtime.getGlobal("players") == MaxPlayers.int32
  doAssert brain.runtime.getStringGlobal("name$") == "Last"
  doAssert brain.runtime.getGlobal("mmr") == 51
  doAssert brain.runtime.getGlobal("home") == world.generals[^1].int32
  doAssert brain.runtime.getGlobal("homeOwner") == (MaxPlayers - 1).int32
  doAssert brain.runtime.getGlobal("sent") == MaxPlayers.int32
  var log: MatchLog
  hub.deliverMessages(log, 0)
  discard brain.decide(world)
  doAssert brain.runtime.getStringGlobal("message$") == "Last: hello everyone"
  doAssert brain.runtime.getGlobal("sender") == GlobalMailbox

echo "Testing BASIC compile, memory, and instruction boundaries"
block:
  let
    world = testWorld()
    hub = newMessageHub(testRoster(), 2)
  expectBrainError:
    discard newBrain("x = 1", -1, hub)
  expectBrainError:
    discard newBrain("x = 1", 2, hub)
  expectBrainError:
    discard newBrain("x = unknownFunction()", 0, hub)
  expectBrainError:
    discard newBrain(newString(policyLimits().maxSourceBytes + 1), 0, hub)
  var memoryFailed = false
  try:
    discard newBrain("dim oversized(1000000)", 0, hub)
  except GeneralsError as error:
    memoryFailed = "memory" in error.msg.toLowerAscii()
  doAssert memoryFailed, "Oversized BASIC arrays must hit the memory limit"
  let brain = newBrain("while 1\n  count = count + 1\nwend", 0, hub)
  doAssert brain.decide(world) == noMove()
  doAssert brain.failed and brain.error.len > 0
  let error = brain.error
  doAssert brain.decide(world) == noMove()
  doAssert brain.error == error
  doAssert decide(nil, world) == noMove()
  expectBrainError:
    discard readSource("out/missing-brain-" & $getCurrentProcessId() & ".bas")

echo "Testing the runnable BASIC scout example"
block:
  let
    world = testWorld()
    hub = newMessageHub(testRoster(), 2)
    brain = newBrain(readSource("examples/scout.bas"), 0, hub)
    move = brain.decide(world)
  doAssert not brain.failed
  doAssert move.source >= 0
  doAssert world.tiles[move.source].owner == 0

echo "BASIC player checks passed"
