import
  std/strutils,
  polyworld/configs,
  common

const MaxPlayerNameBytes* = 128

type
  PlayerInfo* = object
    name*: string
    mmr*: int32 = -1
  BotFiles* = array[MaxPlayers, string]
  Roster* = object
    players*: array[MaxPlayers, PlayerInfo]
    exposePlayerInfo*: bool = true

proc defaultRoster*(): Roster {.raises: [].} =
  ## Creates unnamed seats with unknown star ranks and public bot queries.
  result.exposePlayerInfo = true
  for player in result.players.mitems:
    player.mmr = -1

proc validUtf8*(value: string): bool {.raises: [].} =
  ## Accepts canonical UTF-8 scalar values without allocating decoded text.
  var i = 0
  while i < value.len:
    let first = value[i].ord
    if first <= 0x7f:
      inc i
      continue
    let width =
      case first
      of 0xc2 .. 0xdf:
        2
      of 0xe0 .. 0xef:
        3
      of 0xf0 .. 0xf4:
        4
      else:
        return false
    if value.len - i < width:
      return false
    for j in 1 ..< width:
      if value[i + j].ord notin 0x80 .. 0xbf:
        return false
    let second = value[i + 1].ord
    if (first == 0xe0 and second < 0xa0) or
      (first == 0xed and second >= 0xa0) or
      (first == 0xf0 and second < 0x90) or
      (first == 0xf4 and second >= 0x90):
        return false
    i += width
  true

proc validateCount(count: int) {.raises: [GeneralsError].} =
  ## Rejects metadata that cannot fit the game's fixed player slots.
  if count < 1 or count > MaxPlayers:
    raise newException(
      GeneralsError,
      "Player metadata requires between 1 and " & $MaxPlayers & " seats."
    )

proc cleanName(value: string): string {.raises: [GeneralsError].} =
  ## Normalizes supplied labels before applying filename and seat fallbacks.
  if not value.validUtf8():
    raise newException(GeneralsError, "Player name must be valid UTF-8.")
  for character in value:
    result.add:
      if character.ord < 32 or character.ord == 127:
        ' '
      else:
        character
  result = strutils.strip(result)

proc validateRoster*(roster: Roster, count: int) {.
    raises: [GeneralsError].} =
  ## Checks bounded public metadata without changing names or unknown ranks.
  validateCount(count)
  for i, player in roster.players:
    if not player.name.validUtf8():
      raise newException(
        GeneralsError,
        "Player " & $(i + 1) & " name must be valid UTF-8."
      )
    if player.name.len > MaxPlayerNameBytes:
      raise newException(
        GeneralsError,
        "Player " & $(i + 1) & " name exceeds " &
          $MaxPlayerNameBytes & " UTF-8 bytes."
      )
    for character in player.name:
      if character.ord < 32 or character.ord == 127:
        raise newException(
          GeneralsError,
          "Player " & $(i + 1) & " name contains control characters."
        )
    if player.mmr < -1:
      raise newException(
        GeneralsError,
        "Player " & $(i + 1) & " MMR must be -1 or a nonnegative star rank."
      )

proc resolveRoster*(roster: Roster, files: BotFiles, count: int): Roster {.
    raises: [GeneralsError].} =
  ## Resolves supplied labels, BASIC basenames, then numbered player labels.
  validateCount(count)
  result = defaultRoster()
  result.exposePlayerInfo = roster.exposePlayerInfo
  for i in 0 ..< count:
    var name = cleanName(roster.players[i].name)
    if name.len == 0 or name.toLowerAscii() == ".bas":
      let path = files[i]
      name = cleanName(path[path.rfind({'/', '\\'}) + 1 .. ^1])
    result.players[i] = PlayerInfo(
      name: PlayerConfig(name: name).displayName(i),
      mmr: roster.players[i].mmr
    )
  result.validateRoster(count)

proc displayName*(roster: Roster, player: int): string {.raises: [].} =
  ## Returns the resolved UI label without stripping its suffix a second time.
  if player < 0 or player >= MaxPlayers:
    return ""
  if roster.players[player].name.len > 0:
    roster.players[player].name
  else:
    PlayerConfig().displayName(player)

proc playerMmr*(roster: Roster, player: int): int32 {.raises: [].} =
  ## Returns the supplied star rank or unknown for an invalid seat.
  if player < 0 or player >= MaxPlayers:
    return -1
  roster.players[player].mmr

proc queryName*(roster: Roster, player: int): string {.raises: [].} =
  ## Exposes roster labels to bots only when the match flag permits it.
  if roster.exposePlayerInfo:
    roster.displayName(player)
  else:
    ""

proc queryMmr*(roster: Roster, player: int): int32 {.raises: [].} =
  ## Exposes star ranks to bots only when the match flag permits it.
  if roster.exposePlayerInfo:
    roster.playerMmr(player)
  else:
    -1
