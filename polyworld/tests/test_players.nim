import
  std/strutils,
  generals/[common, players]

template expectPlayerError(body: untyped) =
  ## Requires invalid public metadata to fail as a game-specific error.
  block:
    var failed = false
    try:
      body
    except GeneralsError:
      failed = true
    doAssert failed, "Expected a player metadata error"

echo "Testing player identities and supplied star ranks"

block:
  for value in [
    "", "ASCII\0", "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80",
    "\xed\x9f\xbf", "\xee\x80\x80", "\xef\xbf\xbf",
    "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf", "雪の将軍"
  ]:
    doAssert value.validUtf8()
  for value in [
    "\x80", "\xc0\x80", "\xc1\xbf", "\xc2", "\xc2\x7f",
    "\xe0\x80\x80", "\xe0\x9f\xbf", "\xe1\x80",
    "\xed\xa0\x80", "\xed\xbf\xbf", "\xf0\x8f\xbf\xbf",
    "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xf0\x90\x80",
    "\xf8\x88\x80\x80\x80", "\xfe", "\xff"
  ]:
    doAssert not value.validUtf8()
    var roster = defaultRoster()
    roster.players[0].name = value
    expectPlayerError:
      roster.validateRoster(2)
    expectPlayerError:
      discard resolveRoster(roster, default(BotFiles), 2)

block:
  let roster = defaultRoster()
  doAssert roster.exposePlayerInfo
  for i in 0 ..< MaxPlayers:
    doAssert roster.displayName(i) == "Player " & $(i + 1)
    doAssert roster.queryName(i) == roster.displayName(i)
    doAssert roster.playerMmr(i) == -1
    doAssert roster.queryMmr(i) == -1
  for invalid in [-1, MaxPlayers, int.high]:
    doAssert roster.displayName(invalid) == ""
    doAssert roster.queryName(invalid) == ""
    doAssert roster.playerMmr(invalid) == -1
    doAssert roster.queryMmr(invalid) == -1

block:
  var
    roster = defaultRoster()
    files: BotFiles
  roster.players[0] = PlayerInfo(name: "  Alice  ", mmr: 37)
  roster.players[1] = PlayerInfo(name: "\n\t\0", mmr: 0)
  roster.players[2] = PlayerInfo(name: " .BAS ", mmr: int32.high)
  files[0] = "/private/bots/ignored.bas"
  files[1] = "/private/bots/expander.bas"
  files[2] = "C:\\private\\bots\\defender.BAS"
  let resolved = resolveRoster(roster, files, MaxPlayers)
  doAssert resolved.displayName(0) == "Alice"
  doAssert resolved.displayName(1) == "expander"
  doAssert resolved.displayName(2) == "defender"
  doAssert resolved.displayName(3) == "Player 4"
  doAssert resolved.playerMmr(0) == 37
  doAssert resolved.playerMmr(1) == 0
  doAssert resolved.playerMmr(2) == int32.high
  doAssert resolved.playerMmr(3) == -1
  doAssert roster.players[0].name == "  Alice  "
  resolved.validateRoster(MaxPlayers)

block:
  var
    roster = defaultRoster()
    files: BotFiles
  roster.players[0].name = "supplied.bas.bas"
  files[1] = "/bots/file.bas.bas"
  let resolved = resolveRoster(roster, files, 2)
  doAssert resolved.players[0].name == "supplied.bas"
  doAssert resolved.displayName(0) == "supplied.bas"
  doAssert resolved.queryName(0) == "supplied.bas"
  doAssert resolved.players[1].name == "file.bas"
  doAssert resolved.displayName(1) == "file.bas"
  doAssert resolved.queryName(1) == "file.bas"

block:
  var
    roster = defaultRoster()
    files: BotFiles
  roster.players[0] = PlayerInfo(name: "雪の将軍\tAlpha\x7f", mmr: 42)
  roster.players[1] = PlayerInfo(name: "Player 2", mmr: 0)
  roster.players[2] = PlayerInfo(name: "Unused", mmr: 100)
  roster.exposePlayerInfo = false
  files[1] = "different.bas"
  let resolved = resolveRoster(roster, files, 2)
  doAssert resolved.displayName(0) == "雪の将軍 Alpha"
  doAssert resolved.displayName(1) == "Player 2"
  doAssert resolved.players[2].name == ""
  doAssert resolved.players[2].mmr == -1
  doAssert resolved.playerMmr(0) == 42
  doAssert not resolved.exposePlayerInfo
  for i in 0 ..< MaxPlayers:
    doAssert resolved.queryName(i) == ""
    doAssert resolved.queryMmr(i) == -1

block:
  var
    roster = defaultRoster()
    files: BotFiles
  roster.players[0].name = "a".repeat(MaxPlayerNameBytes)
  doAssert resolveRoster(roster, files, 2).players[0].name.len ==
    MaxPlayerNameBytes
  roster.players[0].name.add('a')
  expectPlayerError:
    discard resolveRoster(roster, files, 2)
  roster.players[0].name = "雪".repeat(43)
  expectPlayerError:
    discard resolveRoster(roster, files, 2)
  roster.players[0].name = "\xff"
  expectPlayerError:
    discard resolveRoster(roster, files, 2)
  roster.players[0].name = ""
  files[0] = "/bots/\xff.bas"
  expectPlayerError:
    discard resolveRoster(roster, files, 2)
  files[0] = ""
  roster.players[0].mmr = -2
  expectPlayerError:
    discard resolveRoster(roster, files, 2)
  roster.players[0].mmr = -1
  roster.players[0].name = "bad\nname"
  expectPlayerError:
    roster.validateRoster(2)
  for count in [-1, 0, MaxPlayers + 1]:
    expectPlayerError:
      discard resolveRoster(roster, files, count)

echo "Player identity checks passed"
