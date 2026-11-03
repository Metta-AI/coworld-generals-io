import
  std/strformat,
  benchy,
  generals/common

const
  Samples = 7
  ScanPasses = 20_000
  FogPasses = 2_000

type
  OriginalCell = object
    kind: TileKind
    owner: int
    army: int
  CompactCell = object
    army: int32
    owner: int8
    kind: uint8
  NativeBoard = object
    cells: seq[OriginalCell]
  ProductionBoard = object
    cells: seq[Tile]
  CompactBoard = object
    cells: seq[CompactCell]
  SplitBoard = object
    armies: seq[int32]
    owners: seq[int8]
    kinds: seq[uint8]
  WideSplitBoard = object
    armies: seq[int]
    owners: seq[int8]
    kinds: seq[uint8]
  PackedBoard = object
    cells: seq[uint64]

var checksum: int64

template owner(board: NativeBoard, i: int): int =
  ## Reads the original 24-byte cell's owner.
  board.cells[i].owner

template owner(board: ProductionBoard, i: int): int =
  ## Reads the current production cell's owner as a native integer.
  board.cells[i].owner.int

template owner(board: CompactBoard, i: int): int =
  ## Reads a compact cell's owner without changing integer arithmetic.
  board.cells[i].owner.int

template owner(board: SplitBoard | WideSplitBoard, i: int): int =
  ## Reads the dense owner array.
  board.owners[i].int

template owner(board: PackedBoard, i: int): int =
  ## Extracts a three-bit owner, with zero representing neutral land.
  ((board.cells[i] shr 34) and 7).int - 1

template army(board: NativeBoard, i: int): int =
  ## Reads the original 24-byte cell's army.
  board.cells[i].army

template army(board: ProductionBoard, i: int): int =
  ## Reads the current production cell's unchanged native army.
  board.cells[i].army

template army(board: CompactBoard, i: int): int =
  ## Reads the compact cell's signed reference-sized army.
  board.cells[i].army.int

template army(board: SplitBoard | WideSplitBoard, i: int): int =
  ## Reads the dense army array.
  board.armies[i].int

template army(board: PackedBoard, i: int): int =
  ## Extracts the low 32-bit army field.
  (board.cells[i] and 0xffff_ffff'u64).int

template kind(board: NativeBoard, i: int): int =
  ## Reads the original 24-byte cell's terrain.
  board.cells[i].kind.ord

template kind(board: ProductionBoard, i: int): int =
  ## Reads the current production cell's terrain.
  board.cells[i].kind.ord

template kind(board: CompactBoard, i: int): int =
  ## Reads a compact cell's terrain.
  board.cells[i].kind.int

template kind(board: SplitBoard | WideSplitBoard, i: int): int =
  ## Reads the dense terrain array.
  board.kinds[i].int

template kind(board: PackedBoard, i: int): int =
  ## Extracts the two-bit terrain field.
  ((board.cells[i] shr 32) and 3).int

proc setArmy(board: var NativeBoard, i, value: int) {.inline.} =
  ## Stores an army using the original 24-byte representation.
  board.cells[i].army = value

proc setArmy(board: var ProductionBoard, i, value: int) {.inline.} =
  ## Stores an army using the current production representation.
  board.cells[i].army = value

proc setArmy(board: var CompactBoard, i, value: int) {.inline.} =
  ## Stores an army using the compact representation.
  board.cells[i].army = value.int32

proc setArmy(board: var SplitBoard, i, value: int) {.inline.} =
  ## Stores an army in its separate reference-sized array.
  board.armies[i] = value.int32

proc setArmy(board: var WideSplitBoard, i, value: int) {.inline.} =
  ## Stores an army in its separate native-sized array.
  board.armies[i] = value

proc setArmy(board: var PackedBoard, i, value: int) {.inline.} =
  ## Replaces only the low army bits of a packed cell.
  board.cells[i] = (board.cells[i] and not 0xffff_ffff'u64) or value.uint64

proc setOwner(board: var NativeBoard, i, value: int) {.inline.} =
  ## Stores an owner using the original 24-byte representation.
  board.cells[i].owner = value

proc setOwner(board: var ProductionBoard, i, value: int) {.inline.} =
  ## Stores a known fixed-domain owner in the current production cell.
  board.cells[i].owner = value.int8

proc setOwner(board: var CompactBoard, i, value: int) {.inline.} =
  ## Stores an owner using the compact representation.
  board.cells[i].owner = value.int8

proc setOwner[T: SplitBoard | WideSplitBoard](board: var T,
    i, value: int) {.inline.} =
  ## Stores an owner in its separate byte array.
  board.owners[i] = value.int8

proc setOwner(board: var PackedBoard, i, value: int) {.inline.} =
  ## Replaces only the owner bits of a packed cell.
  board.cells[i] = (board.cells[i] and not (7'u64 shl 34)) or
    ((value + 1).uint64 shl 34)

proc initialize[T](count: int): T =
  ## Creates the same deterministic mixed owned board in every layout.
  when T is NativeBoard:
    result.cells = newSeq[OriginalCell](count)
  elif T is ProductionBoard:
    result.cells = newSeq[Tile](count)
  elif T is CompactBoard:
    result.cells = newSeq[CompactCell](count)
  elif T is PackedBoard:
    result.cells = newSeq[uint64](count)
  else:
    when T is SplitBoard:
      result.armies = newSeq[int32](count)
    else:
      result.armies = newSeq[int](count)
    result.owners = newSeq[int8](count)
    result.kinds = newSeq[uint8](count)
  for i in 0 ..< count:
    let
      terrain = if i mod 19 == 0: 2 else: 0
      player = (i * 13 + i div 17) mod 5 - 1
    result.setArmy(i, 100 + i mod 97)
    result.setOwner(i, player)
    when T is NativeBoard or T is ProductionBoard:
      result.cells[i].kind = TileKind(terrain)
    elif T is CompactBoard:
      result.cells[i].kind = terrain.uint8
    elif T is PackedBoard:
      result.cells[i] = result.cells[i] or (terrain.uint64 shl 32)
    else:
      result.kinds[i] = terrain.uint8

proc totals[T](board: T, count, player: int): int64 {.noinline.} =
  ## Performs the production public-score scan without allocating output.
  for i in 0 ..< count:
    if board.owner(i) == player:
      result += 1 + board.army(i).int64

proc grow[T](board: var T, count, turn: int) {.noinline.} =
  ## Performs the production income scan with identical phase conditions.
  for i in 0 ..< count:
    if board.owner(i) < 0:
      continue
    if turn mod 2 == 0 and board.kind(i) in {2, 3}:
      board.setArmy(i, board.army(i) + 1)
    if turn mod 50 == 0:
      board.setArmy(i, board.army(i) + 1)

proc capture[T](board: var T, count, player, victim: int) {.noinline.} =
  ## Transfers and halves a victim's cells as in the production capture scan.
  for i in 0 ..< count:
    if board.owner(i) == victim:
      board.setOwner(i, player)
      board.setArmy(i, (board.army(i) + 1) div 2)

proc reveal[T](board: T, visible: var seq[bool], width, height,
    player: int): int64 {.noinline.} =
  ## Reveals the same neighboring cells as the production visibility scan.
  zeroMem(addr visible[0], visible.len)
  for i in 0 ..< width * height:
    if board.owner(i) != player:
      continue
    let
      x = i mod width
      y = i div width
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let
          column = x + dx
          row = y + dy
        if column >= 0 and row >= 0 and column < width and row < height:
          visible[row * width + column] = true
  for value in visible:
    result += value.int

proc runLayout[T](label: string, width, height: int): int64 =
  ## Benchmarks identical scans and publishes a checksum after each layout.
  let
    count = width * height
    before = checksum
  var
    board = initialize[T](count)
    visible = newSeq[bool](count)
  timeIt label & " totals", Samples:
    for iteration in 0 ..< ScanPasses:
      checksum += board.totals(count, iteration mod 4)
  timeIt label & " growth", Samples:
    for iteration in 0 ..< ScanPasses:
      board.grow(count, iteration)
    checksum += board.totals(count, 0)
  timeIt label & " capture", Samples:
    for iteration in 0 ..< ScanPasses:
      board.capture(count, iteration mod 2, 1 - iteration mod 2)
    checksum += board.totals(count, 0)
  board = initialize[T](count)
  timeIt label & " fog", Samples:
    for iteration in 0 ..< FogPasses:
      checksum += board.reveal(visible, width, height, iteration mod 4)
  result = checksum - before
  echo "Checksum ", label, ": ", result

proc main() =
  ## Reports isolated board-scan costs, not complete engine throughput.
  echo "Board scan kernels. Samples=", Samples, " scans=", ScanPasses,
    " fog scans=", FogPasses
  echo "Cell bytes: original=", sizeof(OriginalCell),
    " production=", sizeof(Tile), " compact=", sizeof(CompactCell),
    " split=6 wideSplit=", sizeof(int) + 2, " packed=8"
  for dimensions in [(23, 19), (61, 61)]:
    echo &"Dimensions: {dimensions[0]}x{dimensions[1]}"
    let expected =
      runLayout[NativeBoard]("original24", dimensions[0], dimensions[1])
    doAssert runLayout[ProductionBoard](
      "production", dimensions[0], dimensions[1]
    ) == expected
    doAssert runLayout[CompactBoard](
      "compact", dimensions[0], dimensions[1]
    ) == expected
    doAssert runLayout[SplitBoard](
      "split32", dimensions[0], dimensions[1]
    ) == expected
    doAssert runLayout[WideSplitBoard](
      "split64", dimensions[0], dimensions[1]
    ) == expected
    doAssert runLayout[PackedBoard](
      "packed", dimensions[0], dimensions[1]
    ) == expected
  echo "Final checksum: ", checksum

main()
