import
  std/unicode,
  polyworld/mailboxes,
  common, events, players

const GlobalMailbox* = -2'i32

type
  PendingMessage* = object
    target*: int
    text*: string
  MessageHub* = ref object
    roster*: Roster
    count*: int
    inboxes*: array[MaxPlayers, Mailbox]
    pending: array[MaxPlayers, PendingMessage]

proc newMessageHub*(roster: Roster, count: int): MessageHub {.
    raises: [GeneralsError].} =
  ## Allocates one bounded inbox for every seat in the supplied roster.
  if count notin 2 .. MaxPlayers:
    raise newException(
      GeneralsError,
      "Mailboxes require 2 to " & $MaxPlayers & " players."
    )
  roster.validateRoster(count)
  result = MessageHub(roster: roster, count: count)
  for player in 0 ..< count:
    result.inboxes[player] = newMailbox()

proc cleanText(text: openArray[char]): string {.raises: [].} =
  ## Normalizes bounded UTF-8 chat with the same character limit as the UI.
  if text.len == 0 or text.len > MaxChatBytes:
    return
  var source = newString(text.len)
  for i, character in text:
    source[i] = character
  if not source.validUtf8():
    return
  var
    characters = 0
    space = false
  for rune in source.runes:
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

proc queueMessage*(
    hub: MessageHub,
    sender, target: int,
    text: openArray[char]
): int32 {.raises: [].} =
  ## Queues one message per seat for delivery after every policy has decided.
  if hub == nil or sender < 0 or sender >= hub.count or
    (target != GlobalMailbox and (target < 0 or target >= hub.count)) or
    hub.pending[sender].text.len > 0:
      return 0
  let message = cleanText(text)
  if message.len == 0:
    return 0
  hub.pending[sender] = PendingMessage(target: target, text: message)
  if target == GlobalMailbox:
    hub.count.int32
  else:
    1'i32

proc mailboxName(hub: MessageHub, player: int): string {.raises: [].} =
  ## Resolves a public sender without bypassing disabled identity queries.
  if hub.roster.exposePlayerInfo:
    hub.roster.displayName(player)
  else:
    "Player " & $(player + 1)

proc takeMessage*(hub: MessageHub, sender: int): PendingMessage =
  ## Transfers an order to the local match or the hosted episode broker.
  result = hub.pending[sender]
  hub.pending[sender] = PendingMessage()

proc deliverMessages*(hub: MessageHub, log: var MatchLog, turn: int) {.
    raises: [GeneralsError].} =
  ## Delivers queued traffic in seat order and logs only global messages.
  if hub == nil:
    return
  for sender in 0 ..< hub.count:
    let pending = hub.takeMessage(sender)
    if pending.text.len == 0:
      continue
    let text = hub.mailboxName(sender) & ": " & pending.text
    if pending.target == GlobalMailbox:
      for player in 0 ..< hub.count:
        discard hub.inboxes[player].push(GlobalMailbox, text)
      discard log.addChat(sender, turn, pending.text)
    else:
      discard hub.inboxes[pending.target].push(sender.int32, text)

proc eventText*(hub: MessageHub, entry: LogEntry): string {.raises: [].} =
  ## Formats shared capture and result events without exposing hidden names.
  if hub == nil:
    return
  var text: string
  case entry.kind
  of Capture:
    if entry.target < 0 or entry.target >= hub.count:
      return
    if entry.player >= 0 and entry.player < hub.count:
      text = hub.mailboxName(entry.player) & " captured " &
        hub.mailboxName(entry.target) & "."
    else:
      text = hub.mailboxName(entry.target) & " was captured."
  of Victory:
    if entry.player < 0 or entry.player >= hub.count:
      return
    text = hub.mailboxName(entry.player) & " wins!"
  of Draw:
    text = "The game ended in a draw."
  of Notice, Chat:
    return
  "[Game] " & text & " (tick " & $max(entry.turn, 0) & ")"

proc broadcastEvent*(hub: MessageHub, entry: LogEntry) {.raises: [].} =
  ## Prioritizes global game events over the oldest queued mailbox message.
  let text = hub.eventText(entry)
  if text.len == 0:
    return
  for player in 0 ..< hub.count:
    let inbox = hub.inboxes[player]
    if inbox.count == MaxMailboxMessages:
      inbox.first = (inbox.first + 1) mod MaxMailboxMessages
      dec inbox.count
    discard inbox.push(GlobalMailbox, text)
