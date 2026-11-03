## Trusted episode broker using Polyworld's actual mailbox and chat rules.
import std/json
import polyworld/mailboxes
import generals/[events, messages, players]

proc serveMessages*() =
  var hub: MessageHub
  var log: MatchLog
  for line in stdin.lines:
    let request = parseJson(line)
    var accepted = 0
    var chats = newJArray()
    var events = newJArray()
    case request["op"].getStr()
    of "new":
      var roster = defaultRoster()
      for player, name in request["names"].getElems():
        roster.players[player].name = name.getStr()
      hub = newMessageHub(roster, request["names"].len)
    of "queue":
      accepted = hub.queueMessage(request["slot"].getInt(),
        request["target"].getInt(), request["text"].getStr()).int
    of "consume":
      for index in 0 ..< request["count"].getInt():
        discard hub.inboxes[request["slot"].getInt()].pop()
    of "flush":
      log.entries.setLen(0)
      hub.deliverMessages(log, request["turn"].getInt())
      for entry in log.entries:
        chats.add(%*{"tick": entry.turn, "player": entry.player, "text": entry.text})
    of "event":
      let kind = case request["kind"].getStr()
        of "capture": Capture
        of "victory": Victory
        of "draw": Draw
        else: raise newException(ValueError, "Unknown game event")
      let entry = LogEntry(kind: kind,
        turn: request["turn"].getInt(), player: request["slot"].getInt(),
        target: request["target"].getInt())
      hub.broadcastEvent(entry)
      events.add(%*{"tick": entry.turn, "kind": request["kind"].getStr(),
        "player": entry.player, "target": entry.target, "text": hub.eventText(entry)})
    else:
      raise newException(ValueError, "Unknown mailbox operation")
    var mailboxes = newJArray()
    for player in 0 ..< hub.count:
      if request["op"].getStr() == "queue" or
          (request["op"].getStr() == "consume" and player != request["slot"].getInt()):
        continue
      let inbox = hub.inboxes[player]
      var messages = newJArray()
      for offset in 0 ..< inbox.count:
        let index = (inbox.first + offset) mod MaxMailboxMessages
        messages.add(%*{"id": inbox.ids[index], "text": inbox.messages[index]})
      mailboxes.add(%*{"slot": player,
        "mailbox": {"last_id": inbox.lastId, "messages": messages}})
    stdout.writeLine($(%*{"accepted": accepted, "mailboxes": mailboxes,
      "chats": chats, "events": events}))
    stdout.flushFile()
