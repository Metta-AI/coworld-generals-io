' Reads public player metadata and the current in-game clock.
myName$ = playerName$(selfPlayer())
myMmr = playerMmr(selfPlayer())
turn = worldTurn()
tick = worldTick()

' Receives global game events and messages from other players.
while mailboxCount() > 0
  lastMessage$ = pullMailbox$()
  lastSender = mailboxId()
wend
if greeted = 0 then
  greeted = 1
  accepted = sendChat(-2, "Ready to explore.")
end if

' Chooses one adjacent move using only the fog-limited board queries.
bestSource = -1
bestTarget = -1
bestScore = -2147483647
source = 0
while source < tileCount()
  if owner(source) = selfPlayer() and army(source) > 1 then
    direction = 0
    while direction < 4
      target = source - width()
      if direction = 1 then target = source + width()
      if direction = 2 then target = source - 1
      if direction = 3 then target = source + 1
      valid = target >= 0 and target < tileCount()
      if direction >= 2 and valid <> 0 then
        valid = source \ width() = target \ width()
      end if
      if valid <> 0 and visible(target) <> 0 and terrain(target) <> 1 then
        score = army(source) - army(target)
        if owner(target) <> selfPlayer() then
          score = score + 100
          if terrain(target) = 3 then score = score + 10000
          if terrain(target) = 2 then score = score + 30
        else
          score = score - 20
        end if
        if score > bestScore then
          bestScore = score
          bestSource = source
          bestTarget = target
        end if
      end if
      direction = direction + 1
    wend
  end if
  source = source + 1
wend
if bestSource >= 0 then
  accepted = send(bestSource, bestTarget, 0)
end if
