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
    width*, height*, players*, seed*, maxTurns*: int
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

proc mapRandom*(seed: int): uint32 {.raises: [].} =
  ## Seeds the map's private random stream without global random state.
  result = uint32(seed and 0xffff_ffff) xor 0xa3c5_9ac3'u32
  if result == 0:
    result = 1

proc nextRandom*(random: var uint32, maximum: int): int {.raises: [].} =
  ## Draws one bounded integer using a fixed xorshift32 sequence.
  assert maximum > 0
  random = random xor (random shl 13)
  random = random xor (random shr 17)
  random = random xor (random shl 5)
  int(random mod maximum.uint32)

proc defaultDimensions*(seed, players: int): tuple[width, height: int] =
  ## Chooses seeded classic dimensions that grow with the FFA player count.
  if players notin 2 .. MaxPlayers:
    raise newException(GeneralsError, "A match needs 2 to 10 players.")
  var random = mapRandom(seed)
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

proc defaultConfig*(seed = 1, players = DefaultPlayers): Config =
  ## Creates a standard local match with a bounded simulation duration.
  let dimensions = defaultDimensions(seed, players)
  Config(
    width: dimensions.width,
    height: dimensions.height,
    players: players,
    seed: seed,
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
