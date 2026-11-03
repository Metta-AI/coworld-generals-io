import
  std/unicode,
  common

const
  MaxLogEntries* = 128
  MaxChatCharacters* = 140

type
  EventKind* = enum
    Notice, Chat, Capture, Victory, Draw
  LogEntry* = object
    kind*: EventKind
    turn*, player*, target*: int
    text*: string
  EventSnapshot* = object
    alive: array[MaxPlayers, bool]
    players, turn: int
    finished: bool
  MatchLog* = object
    entries*: seq[LogEntry]
    lastTurn: int
    ended: bool

proc append(log: var MatchLog, entry: LogEntry) {.raises: [].} =
  ## Retains only the newest bounded history of local messages and events.
  if log.entries.len >= MaxLogEntries:
    log.entries.delete(0)
  log.entries.add(entry)

proc resetLog*(log: var MatchLog) {.raises: [].} =
  ## Starts an independent local history with no events from the last match.
  log.entries.setLen(0)
  log.lastTurn = -1
  log.ended = false
  log.append(LogEntry(
    kind: Notice,
    player: -1,
    target: -1,
    text: "Chat is local to this match."
  ))

proc chatText(text: string): string {.raises: [GeneralsError].} =
  ## Normalizes whitespace and bounds chat without splitting Unicode text.
  if validateUtf8(text) != -1:
    raise newException(GeneralsError, "Chat text must contain valid UTF-8.")
  var
    characters = 0
    space = false
  for rune in text.runes:
    if rune.isWhiteSpace:
      space = result.len > 0
      continue
    if rune.int < 32 or rune.int in 127 .. 159:
      continue
    if characters >= MaxChatCharacters:
      break
    if space:
      if characters + 1 >= MaxChatCharacters:
        break
      result.add(' ')
      inc characters
      space = false
    result.add(rune.toUTF8())
    inc characters

proc addChat*(
    log: var MatchLog,
    player, turn: int,
    text: string
): bool {.raises: [GeneralsError].} =
  ## Adds nonempty local chat and reports whether a message was accepted.
  if player < 0 or player >= MaxPlayers:
    return false
  let message = chatText(text)
  if message.len == 0:
    return false
  log.append(LogEntry(
    kind: Chat,
    turn: max(0, turn),
    player: player,
    target: -1,
    text: message
  ))
  true

proc snapshotEvents*(world: World): EventSnapshot {.raises: [].} =
  ## Saves only the pre-tick status needed to recognize actual eliminations.
  assert world.config.players in 2 .. MaxPlayers
  assert world.alive.len == world.config.players
  result.players = world.config.players
  result.turn = world.turn
  result.finished = world.finished
  for player in 0 ..< result.players:
    result.alive[player] = world.alive[player]

proc target(world: World, move: Move): int {.raises: [].} =
  ## Resolves a command's destination without inferring combat success.
  var source, destination: int
  if move.raw:
    if move.direction notin 0 .. 3 or
      move.row < 0 or move.row >= world.config.height or
      move.column < 0 or move.column >= world.config.width:
        return -1
    const Directions = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    let
      direction = Directions[move.direction]
      x = move.column + direction[0]
      y = move.row + direction[1]
    if x < 0 or x >= world.config.width or
      y < 0 or y >= world.config.height:
        return -1
    source = move.row * world.config.width + move.column
    destination = y * world.config.width + x
  else:
    source = move.source
    destination = move.target
  if source < 0 or source >= world.tiles.len or
    destination < 0 or destination >= world.tiles.len:
      return -1
  let
    width = world.config.width
    distance = abs(source mod width - destination mod width) +
      abs(source div width - destination div width)
  if distance != 1:
    return -1
  destination

proc recordTick*(
    log: var MatchLog,
    before: EventSnapshot,
    after: World,
    moves: openArray[Move]
) {.raises: [].} =
  ## Records eliminations and one result without guessing ambiguous captors.
  if before.finished or log.ended or after.turn <= before.turn or
    after.turn <= log.lastTurn:
      return
  assert after.config.players == before.players
  log.lastTurn = after.turn
  var
    captures: array[MaxPlayers, LogEntry]
    pending: array[MaxPlayers, bool]
  for victim in 0 ..< before.players:
    if not before.alive[victim] or after.alive[victim]:
      continue
    var
      captor = -1
      attackers = 0
    for player in 0 ..< min(moves.len, before.players):
      if player != victim and before.alive[player] and
        after.target(moves[player]) == after.generals[victim]:
          captor = player
          inc attackers
    captures[victim] = LogEntry(
      kind: Capture,
      turn: after.turn,
      player: if attackers == 1: captor else: -1,
      target: victim
    )
    pending[victim] = true
  for position in 0 ..< before.players:
    var next = -1
    for victim in 0 ..< before.players:
      if not pending[victim]:
        continue
      var blocked = false
      for other in 0 ..< before.players:
        if pending[other] and captures[other].player == victim:
          blocked = true
          break
      if not blocked:
        next = victim
        break
    if next < 0:
      break
    log.append(captures[next])
    pending[next] = false
  if after.finished:
    log.append(LogEntry(
      kind: if after.winner >= 0: Victory else: Draw,
      turn: after.turn,
      player: after.winner,
      target: -1
    ))
    log.ended = true
