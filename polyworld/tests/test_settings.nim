import
  std/[os, strutils],
  generals/[common, players, settings]

proc expectInvalid(bytes: string) =
  ## Requires malformed or unsupported engine settings to fail safely.
  var rejected = false
  try:
    discard parseSettings(bytes)
  except GeneralsError:
    rejected = true
  doAssert rejected,
    "Expected invalid config: " & bytes[0 ..< min(80, bytes.len)]

block:
  let
    settings = parseSettings("{}")
    roster = settings.resolvedRoster()
  doAssert settings.config == defaultConfig()
  doAssert roster.exposePlayerInfo
  doAssert roster.displayName(0) == "Player 1"
  doAssert roster.playerMmr(0) == -1

block:
  let
    settings = parseSettings("""{
      "players": [
        {"name": "Supplied", "mmr": 0, "bot": "bots/fallback.bas"},
        {"bot": "other.bas"}
      ],
      "seed": 8,
      "max_ticks": 99,
      "width": 15,
      "height": 17,
      "expose_player_info": false
    }""", getCurrentDir())
    roster = settings.resolvedRoster()
  doAssert settings.config == Config(
    width: 15, height: 17, players: 2, seed: 8, maxTurns: 99
  )
  doAssert settings.botFiles[0] == getCurrentDir() / "bots/fallback.bas"
  doAssert roster.displayName(0) == "Supplied"
  doAssert roster.displayName(1) == "other"
  doAssert roster.playerMmr(0) == 0
  doAssert roster.playerMmr(1) == -1
  doAssert not roster.exposePlayerInfo

block:
  let path = getTempDir() /
    ("generals-settings-" & $getCurrentProcessId() & ".json")
  writeFile(path, """{"seed": 3, "players": [{"bot":"first.bas"}, {}]}""")
  try:
    for arguments in [
      @["--seed=9", "--name=1:Chosen", "--config=" & path],
      @["--config=" & path, "--seed=9", "--name=1:Chosen"]
    ]:
      var settings = configuredSettings(arguments)
      for argument in arguments:
        doAssert settings.applySetting(argument)
      let roster = settings.resolvedRoster()
      doAssert settings.config.seed == 9
      doAssert roster.displayName(0) == "Chosen"
      doAssert settings.botFiles[0] == getTempDir() / "first.bas"
  finally:
    removeFile(path)

block:
  var settings = defaultSettings()
  for argument in [
    "--players=2", "--name=1:First", "--name=1:Last:Name",
    "--mmr=1:37", "--mmr=2:-1", "--player-info=off", "--bot=2:some.bas"
  ]:
    doAssert settings.applySetting(argument)
  let roster = settings.resolvedRoster()
  doAssert roster.displayName(0) == "Last:Name"
  doAssert roster.displayName(1) == "some"
  doAssert roster.playerMmr(0) == 37
  doAssert roster.playerMmr(1) == -1
  doAssert not roster.exposePlayerInfo
  doAssert not settings.applySetting("--headless")

block:
  let
    settings = parseSettings("""{
      "players": [{"name":"chosen.bas.bas"}, {"bot":"policy.bas.bas"}]
    }""")
    roster = settings.resolvedRoster()
  doAssert settings.roster.players[0].name == "chosen.bas.bas"
  doAssert settings.roster.players[1].name == ""
  doAssert roster.displayName(0) == "chosen.bas"
  doAssert roster.displayName(1) == "policy.bas"

block:
  for argument in [
    "--name=0:No", "--name=11:No", "--name=No", "--mmr=1:-2",
    "--mmr=1:2147483648", "--bot=1:", "--player-info=maybe",
    "--players=1", "--players=11", "--seed=-1", "--turns=0"
  ]:
    var
      settings = defaultSettings()
      rejected = false
    try:
      discard settings.applySetting(argument)
    except GeneralsError:
      rejected = true
    doAssert rejected, argument
  var
    settings = defaultSettings()
    rejected = false
  discard settings.applySetting("--players=2")
  discard settings.applySetting("--name=3:Absent")
  try:
    discard settings.resolvedRoster()
  except GeneralsError:
    rejected = true
  doAssert rejected

for bytes in [
  "{", "[]", "null", "{\"players\":[]}", "{\"players\":[{}]}",
  "{\"seed\":-1}", "{\"seed\":2147483648}", "{\"maxTicks\":0}",
  "{\"maxTicks\":100001}", "{\"width\":12}", "{\"height\":62}",
  "{\"players\":[{\"mmr\":-2},{}]}",
  "{\"players\":[{\"name\":\"" &
    repeat('a', MaxPlayerNameBytes + 1) & "\"},{}]}",
  "{\"players\":[{\"name\":\"\xff\"},{}]}",
  repeat(' ', MaxSettingsBytes + 1)
]:
  expectInvalid(bytes)

block:
  let invalidIntegers = [
    "18446744073709551617", "18446744073709551615",
    "-18446744073709551617", "9223372036854775808",
    "-9223372036854775809", repeat('9', 10_000),
    "+1", "01", "-01", "1_0", "1.0", "1e0", "--1", "- 1"
  ]
  for token in invalidIntegers:
    for field in ["seed", "maxTicks", "max_ticks", "width", "height"]:
      expectInvalid("{\"" & field & "\":" & token & "}")
    expectInvalid("{\"players\":[{\"mmr\":" & token & "},{}]}")
  let limits = parseSettings("""{
    "seed": 2147483647, "max_ticks": 100000, "width": 61, "height": 61,
    "players": [{"mmr": 2147483647}, {"mmr": -1}]
  }""")
  doAssert limits.config.seed == int32.high.int
  doAssert limits.config.maxTurns == 100_000
  doAssert limits.config.width == 61 and limits.config.height == 61
  doAssert limits.resolvedRoster().playerMmr(0) == int32.high
  doAssert limits.resolvedRoster().playerMmr(1) == -1
  let zeroes = parseSettings("""{
    "seed": 0, "max_ticks": 1, "width": 0, "height": 0,
    "players": [{"mmr": 0}, {}], "ignored": 1e200
  }""")
  doAssert zeroes.config.seed == 0 and zeroes.config.maxTurns == 1
  doAssert zeroes.autoWidth and zeroes.autoHeight
  doAssert zeroes.resolvedRoster().playerMmr(0) == 0
  doAssert zeroes.resolvedRoster().playerMmr(1) == -1

block:
  for (opening, closing) in [("[", "]"), ("{\"ignored\":", "}")]:
    let
      accepted = "{\"ignored\":" & repeat(opening, MaxSettingsDepth - 1) &
        "0" & repeat(closing, MaxSettingsDepth - 1) & "}"
      rejected = "{\"ignored\":" & repeat(opening, MaxSettingsDepth) &
        "0" & repeat(closing, MaxSettingsDepth) & "}"
    doAssert parseSettings(accepted).config == defaultConfig()
    expectInvalid(rejected)
  let hostile = "{\"ignored\":" & repeat('[', 200_000) & "0" &
    repeat(']', 200_000) & "}"
  doAssert hostile.len < MaxSettingsBytes
  expectInvalid(hostile)
  let quoted = "{\"ignored\":\"\\\"\\\\" &
    repeat("[{]}", MaxSettingsDepth * 2) & "\\\"\",\"seed\":7}"
  doAssert parseSettings(quoted).config.seed == 7
  for prefix in ["x\" ", "x[\" ", "x{\" ", "x:\" ", "x\v\" ", "x\f\" "]:
    let hidden = "{\"ignored\":[" & prefix & repeat('[', 200_000) &
      "0" & repeat(']', 200_000) & "]}"
    doAssert hidden.len < MaxSettingsBytes
    expectInvalid(hidden)
  for bytes in ["{\"ignored\":[}", "{\"ignored\":{]", "{\"ignored\":\"text}"]:
    expectInvalid(bytes)
  doAssert parseSettings("""{
    "ignored": [null, true, false, -1, 1.5, 2e3, "text", {"more": []}]
  }""").config == defaultConfig()

block:
  for arguments in [
    ["--seed=27", "--players=10"],
    ["--players=10", "--seed=27"]
  ]:
    var settings = defaultSettings()
    for argument in arguments:
      discard settings.applySetting(argument)
    doAssert settings.config == defaultConfig(27, 10)
    doAssert settings.autoWidth and settings.autoHeight
  var settings = parseSettings("{\"width\":31}")
  doAssert not settings.autoWidth and settings.autoHeight
  discard settings.applySetting("--players=10")
  discard settings.applySetting("--seed=27")
  doAssert settings.config.width == 31
  doAssert settings.config.height == defaultConfig(27, 10).height
  settings = parseSettings("{\"height\":29,\"width\":0}")
  doAssert settings.autoWidth and not settings.autoHeight
  discard settings.applySetting("--players=3")
  discard settings.applySetting("--seed=73")
  doAssert settings.config.width == defaultConfig(73, 3).width
  doAssert settings.config.height == 29

for count in 2 .. MaxPlayers:
  var settings = defaultSettings()
  doAssert settings.applySetting("--players=" & $count)
  doAssert settings.applySetting("--name=" & $count & ":Last")
  doAssert settings.applySetting("--mmr=" & $count & ":47")
  doAssert settings.applySetting("--bot=" & $count & ":last.bas")
  let roster = settings.resolvedRoster()
  doAssert settings.config.players == count
  doAssert roster.displayName(count - 1) == "Last"
  doAssert roster.playerMmr(count - 1) == 47
  doAssert settings.botFiles[count - 1].endsWith("last.bas")
  let configured = parseSettings(
    "{\"players\":[" & repeat("{},", count - 1) &
      "{\"name\":\"Final\",\"mmr\":39}]}"
  )
  doAssert configured.config.players == count
  doAssert configured.resolvedRoster().displayName(count - 1) == "Final"
  doAssert configured.resolvedRoster().playerMmr(count - 1) == 39
expectInvalid("{\"players\":[" & repeat("{},", MaxPlayers) & "{}]}")

echo "Settings tests passed."
