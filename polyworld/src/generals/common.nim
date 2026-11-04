const
  DefaultPlayers* = 4
  DefaultTurns* = 4_000
  TickSeconds* = 0.5
  MaxPlayers* = 10

type
  GeneralsError* = object of CatchableError
  TileKind* = enum
    Plain, Mountain, City, General
  Tile* = object
    kind*: TileKind
    owner*: int8
    army*: int
  Config* = object
    width*, height*, players*, maxTurns*: int
    seed*: uint64
  World* = object
    config*: Config
    tiles*: seq[Tile]
    generals*: seq[int]
    alive*: seq[bool]
    turn*, winner*: int
    finished*: bool
  Move* = object
    source*, target*: int
    half*: bool
    raw*: bool
    row*, column*, direction*: int
  StepReport* = object
    executed*: seq[bool]
    capturedBy*: seq[int]
    eliminationOrder*: seq[int]
    damage*: seq[seq[int]]

proc parseSeed*(text: string): uint64 {.raises: [GeneralsError].} =
  ## Parses an exact unsigned 64-bit decimal seed without wrapping.
  if text.len == 0 or (text.len > 1 and text[0] == '0'):
    raise newException(GeneralsError, "Seed must be an unsigned decimal integer.")
  for digit in text:
    if digit notin '0' .. '9':
      raise newException(GeneralsError, "Seed must be an unsigned decimal integer.")
    let value = uint64(ord(digit) - ord('0'))
    if result > (uint64.high - value) div 10:
      raise newException(GeneralsError, "Seed exceeds 18446744073709551615.")
    result = result * 10 + value

proc mapRandom*(seed: uint64): uint64 {.raises: [].} =
  ## Seeds the map's private 64-bit stream without discarding any seed bits.
  seed

proc nextRandom*(random: var uint64, maximum: int): int {.raises: [].} =
  ## Draws a bounded integer with portable unsigned SplitMix64 arithmetic.
  assert maximum > 0
  random += 0x9e37_79b9_7f4a_7c15'u64
  var value = random
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value = value xor (value shr 31)
  int(value mod maximum.uint64)

proc defaultDimensions*(
    seed: SomeInteger,
    players: int
): tuple[width, height: int] =
  ## Chooses seeded classic dimensions that grow with the FFA player count.
  if players notin 2 .. MaxPlayers:
    raise newException(GeneralsError, "A match needs 2 to 10 players.")
  when seed is SomeSignedInt:
    if seed < 0:
      raise newException(GeneralsError, "Map seed must not be negative.")
  var random = mapRandom(uint64(seed))
  let
    base = uint64(32 + 2 * min(8, players) + max(0, players - 6))
    scale = uint64(8 + players)
    denominator = 65_536'u64 * 65_536'u64
  for side in 0 .. 1:
    let
      draw = random.nextRandom(65_536).uint64
      size = int((base * denominator + draw * draw * scale +
        denominator) div (2 * denominator))
    if side == 0:
      result.width = size
    else:
      result.height = size

proc defaultConfig*(
    seed: SomeInteger = 1,
    players = DefaultPlayers
): Config =
  ## Creates a standard local match with a bounded simulation duration.
  let dimensions = defaultDimensions(seed, players)
  Config(
    width: dimensions.width,
    height: dimensions.height,
    players: players,
    seed: uint64(seed),
    maxTurns: DefaultTurns
  )

proc noMove*(): Move =
  ## Creates an explicit pass that never selects a board tile.
  Move(source: -1, target: -1)

proc actionMove*(row, column, direction: int, half = false): Move =
  ## Retains reference action geometry, including an off-board destination.
  if direction < 0 or direction > 3:
    raise newException(GeneralsError, "Move direction must be 0 to 3.")
  Move(
    source: -1,
    target: -1,
    half: half,
    raw: true,
    row: row,
    column: column,
    direction: direction
  )
