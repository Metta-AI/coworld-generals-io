import
  std/[strutils, unicode],
  polyworld/mailboxes,
  ../src/generals/[common, events, messages, players]

proc roster(): Roster =
  ## Creates distinct real labels that reveal accidental identity leaks.
  result = defaultRoster()
  for i, name in ["Alpha", "Beta", "Gamma", "Delta"]:
    result.players[i] = PlayerInfo(name: name, mmr: int32(37 + i))

proc take(inbox: Mailbox): tuple[id: int32, text: string] =
  ## Reads a mailbox exactly as the BASIC string host does.
  if inbox.count == 0:
    return (NoMailboxId, "")
  result.text = inbox.messages[inbox.first]
  result.id = inbox.pop()

echo "Testing delayed global and direct bot messages"
block:
  let hub = newMessageHub(roster(), 4)
  var log: MatchLog
  log.resetLog()
  doAssert hub.queueMessage(2, -2, "  hello\n world\x01  ") == 4
  doAssert hub.queueMessage(0, 2, "private") == 1
  doAssert hub.queueMessage(2, 0, "duplicate") == 0
  for player in 0 ..< hub.count:
    doAssert hub.inboxes[player].count == 0
  hub.deliverMessages(log, 12)
  doAssert log.entries.len == 2
  doAssert log.entries[^1].kind == Chat
  doAssert log.entries[^1].player == 2
  doAssert log.entries[^1].turn == 12
  doAssert log.entries[^1].text == "hello world"
  doAssert hub.inboxes[2].take() == (0'i32, "Alpha: private")
  doAssert hub.inboxes[2].lastId == 0
  for player in 0 ..< hub.count:
    doAssert hub.inboxes[player].take() == (-2'i32, "Gamma: hello world")
  doAssert hub.inboxes[2].lastId == GlobalMailbox
  doAssert hub.queueMessage(2, 0, "next tick") == 1
  hub.deliverMessages(log, 13)
  doAssert hub.inboxes[0].take() == (2'i32, "Gamma: next tick")
  doAssert log.entries.len == 2
  hub.deliverMessages(log, 14)
  doAssert log.entries.len == 2
  doAssert hub.inboxes[0].count == 0

echo "Testing bounded mailbox text and invalid addresses"
block:
  let hub = newMessageHub(roster(), 2)
  var log: MatchLog
  for sender in [-1, 2, 4]:
    doAssert hub.queueMessage(sender, -2, "invalid sender") == 0
  for target in [-3, -1, 2, 4]:
    doAssert hub.queueMessage(0, target, "invalid target") == 0
  for text in [
    "", " \t\n", "\xff", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    "\xc0\x80", "\xe0\x80\x80", repeat("a", MaxChatBytes + 1)
  ]:
    doAssert hub.queueMessage(0, -2, text) == 0
  doAssert hub.queueMessage(0, -2, repeat("é", 150)) == 2
  hub.deliverMessages(log, 1)
  let first = hub.inboxes[0].take()
  doAssert first.id == GlobalMailbox
  doAssert first.text == "Alpha: " & repeat("é", MaxChatCharacters)
  doAssert log.entries[^1].text.runeLen == MaxChatCharacters
  doAssert hub.queueMessage(0, 0, "self") == 1
  hub.deliverMessages(log, 2)
  doAssert hub.inboxes[0].take() == (0'i32, "Alpha: self")

echo "Testing gated identity in messages and shared game events"
block:
  var hidden = roster()
  hidden.exposePlayerInfo = false
  let hub = newMessageHub(hidden, 4)
  var log: MatchLog
  doAssert hub.queueMessage(0, -2, "hello") == 4
  hub.deliverMessages(log, 1)
  let capture = LogEntry(kind: Capture, turn: 51, player: 0, target: 1)
  doAssert hub.eventText(capture) ==
    "[Game] Player 1 captured Player 2. (tick 51)"
  hub.broadcastEvent(capture)
  hub.broadcastEvent(LogEntry(
    kind: Capture, turn: 52, player: -1, target: 2
  ))
  hub.broadcastEvent(LogEntry(kind: Victory, turn: 53, player: 0))
  hub.broadcastEvent(LogEntry(kind: Draw, turn: 54))
  hub.broadcastEvent(LogEntry(kind: Chat, text: "ignored"))
  hub.broadcastEvent(LogEntry(kind: Notice, text: "ignored"))
  hub.broadcastEvent(LogEntry(kind: Capture, target: 9))
  hub.broadcastEvent(LogEntry(kind: Victory, player: -1))
  for player in 0 ..< hub.count:
    doAssert hub.inboxes[player].count == 5
    for expected in [
      "Player 1: hello",
      "[Game] Player 1 captured Player 2. (tick 51)",
      "[Game] Player 3 was captured. (tick 52)",
      "[Game] Player 1 wins! (tick 53)",
      "[Game] The game ended in a draw. (tick 54)"
    ]:
      doAssert hub.inboxes[player].take() == (GlobalMailbox, expected)

echo "Testing system notices survive full inboxes"
block:
  let hub = newMessageHub(roster(), 2)
  for player in 0 ..< hub.count:
    let inbox = hub.inboxes[player]
    doAssert inbox.push(1, "previously read")
    discard inbox.take()
    for i in 0 ..< MaxMailboxMessages:
      doAssert inbox.push(0, "spam " & $i)
    doAssert inbox.lastId == 1
  let entry = LogEntry(kind: Capture, turn: 8, player: 1, target: 0)
  hub.broadcastEvent(entry)
  for player in 0 ..< hub.count:
    let inbox = hub.inboxes[player]
    doAssert inbox.count == MaxMailboxMessages
    doAssert inbox.lastId == 1
    doAssert inbox.take() == (0'i32, "spam 1")
    for i in 2 ..< MaxMailboxMessages:
      doAssert inbox.take() == (0'i32, "spam " & $i)
    doAssert inbox.take() == (
      GlobalMailbox,
      "[Game] Beta captured Alpha. (tick 8)"
    )
    doAssert inbox.count == 0

echo "Testing every FFA mailbox and highest player seat"
for count in 2 .. MaxPlayers:
  let
    players = resolveRoster(defaultRoster(), default(BotFiles), count)
    hub = newMessageHub(players, count)
    last = count - 1
  var log: MatchLog
  doAssert hub.queueMessage(last, GlobalMailbox, "all") == count.int32
  doAssert hub.queueMessage(0, last, "private") == 1
  hub.deliverMessages(log, 17)
  for player in 0 ..< count:
    if player == last:
      doAssert hub.inboxes[player].take() == (0'i32, "Player 1: private")
    doAssert hub.inboxes[player].take() == (
      GlobalMailbox, "Player " & $count & ": all"
    )
    doAssert hub.inboxes[player].count == 0
  let capture = LogEntry(kind: Capture, player: last, target: 0, turn: 18)
  hub.broadcastEvent(capture)
  for player in 0 ..< count:
    doAssert hub.inboxes[player].take() == (
      GlobalMailbox,
      "[Game] Player " & $count & " captured Player 1. (tick 18)"
    )
  doAssert hub.queueMessage(count, GlobalMailbox, "invalid") == 0

for count in [0, 1, MaxPlayers + 1]:
  var rejected = false
  try:
    discard newMessageHub(defaultRoster(), count)
  except GeneralsError:
    rejected = true
  doAssert rejected

echo "Bot mailbox checks passed"
