import
  std/[algorithm, json, monotimes, os, strutils, times],
  benchy,
  ../src/generals/[bots, common, worlds]

const
  ReplayVersion = 2
  FingerprintBasis = 14695981039346656037'u64
  FingerprintPrime = 1099511628211'u64

type
  Frame = object
    moves: seq[Move]
    fingerprint: string
  Replay = object
    config: Config
    initial: string
    frames: seq[Frame]
    winner: int
  Options = object
    record, replay, report, label, mode: string
    samples, repeats: int
  Statistics = object
    samples: seq[float64]
    minimum, median, mean: float64

proc mix(value: var uint64, item: SomeInteger) =
  ## Mixes a platform-independent integer into a deterministic state digest.
  let bits =
    when item is SomeUnsignedInt:
      uint64(item)
    else:
      cast[uint64](int64(item))
  value = (value xor bits) * FingerprintPrime

proc fingerprint(world: World): string =
  ## Digests every gameplay field outside the measured simulation loops.
  var value = FingerprintBasis
  for item in [
    world.config.width, world.config.height, world.config.players
  ]:
    value.mix(item)
  value.mix(world.config.seed)
  for item in [
    world.config.maxTurns, world.turn, world.winner,
    world.finished.ord
  ]:
    value.mix(item)
  for tile in world.tiles:
    value.mix(tile.kind.ord)
    value.mix(tile.owner.int)
    value.mix(tile.army.int)
  for general in world.generals:
    value.mix(general)
  for alive in world.alive:
    value.mix(alive.ord)
  value.toHex(16)

proc orders(world: World, moves: var seq[Move], scratch: var BotScratch) =
  ## Collects the real native bot decisions in their production seat order.
  for player in 0 ..< world.config.players:
    moves[player] = world.chooseMove(player, scratch)

proc capture(config: Config): Replay =
  ## Records a complete deterministic episode for later isolated replays.
  var
    world = newWorld(config)
    moves = newSeq[Move](config.players)
    scratch: BotScratch
  result.config = config
  result.initial = world.fingerprint()
  while not world.finished:
    world.orders(moves, scratch)
    world.tick(moves)
    result.frames.add Frame(
      moves: moves,
      fingerprint: world.fingerprint()
    )
  result.winner = world.winner

proc writeReplays(path: string, replays: seq[Replay]) =
  ## Writes the baseline moves and state digests without timing file access.
  var games = newJArray()
  for replay in replays:
    var frames = newJArray()
    for frame in replay.frames:
      var moves = newJArray()
      for move in frame.moves:
        moves.add %*{
          "source": move.source,
          "target": move.target,
          "half": move.half
        }
      frames.add %*{
        "moves": moves,
        "fingerprint": frame.fingerprint
      }
    games.add %*{
      "width": replay.config.width,
      "height": replay.config.height,
      "players": replay.config.players,
      "seed": $replay.config.seed,
      "maxTurns": replay.config.maxTurns,
      "initial": replay.initial,
      "frames": frames,
      "winner": replay.winner
    }
  let directory = path.parentDir()
  if directory.len > 0:
    createDir(directory)
  writeFile(path, $(%*{"format": ReplayVersion, "games": games}))

proc readReplays(path: string): seq[Replay] =
  ## Loads trusted local benchmark records with explicit format validation.
  let document = parseFile(path)
  if document["format"].getInt() != ReplayVersion:
    raise newException(GeneralsError, "Unsupported benchmark replay version.")
  for game in document["games"]:
    var replay = Replay(
      config: Config(
        width: game["width"].getInt(),
        height: game["height"].getInt(),
        players: game["players"].getInt(),
        seed: parseSeed(game["seed"].getStr()),
        maxTurns: game["maxTurns"].getInt()
      ),
      initial: game["initial"].getStr(),
      winner: game["winner"].getInt()
    )
    for entry in game["frames"]:
      var frame = Frame(fingerprint: entry["fingerprint"].getStr())
      for move in entry["moves"]:
        frame.moves.add Move(
          source: move["source"].getInt(),
          target: move["target"].getInt(),
          half: move["half"].getBool()
        )
      if frame.moves.len != replay.config.players:
        raise newException(GeneralsError, "Replay has incorrect seat count.")
      replay.frames.add(frame)
    if replay.frames.len == 0:
      raise newException(GeneralsError, "Benchmark replay has no frames.")
    result.add(replay)
  if result.len == 0:
    raise newException(GeneralsError, "Benchmark replay has no games.")

proc verify(replays: seq[Replay]) =
  ## Checks original bot actions and all state digests before any timing.
  var checked = 0
  for replay in replays:
    var
      world = newWorld(replay.config)
      moves = newSeq[Move](replay.config.players)
      scratch: BotScratch
    if world.fingerprint() != replay.initial:
      raise newException(GeneralsError, "Initial benchmark board changed.")
    for i, frame in replay.frames:
      world.orders(moves, scratch)
      if moves != frame.moves:
        raise newException(
          GeneralsError,
          "Bot decisions changed at tick " & $i & ", seed " &
            $replay.config.seed & ", players " & $replay.config.players & "."
        )
      world.tick(moves)
      if world.fingerprint() != frame.fingerprint:
        raise newException(
          GeneralsError,
          "Simulation changed at tick " & $i & ", seed " &
            $replay.config.seed & ", players " & $replay.config.players & "."
        )
      inc checked
    if not world.finished or world.winner != replay.winner:
      raise newException(GeneralsError, "Benchmark terminal outcome changed.")
  echo "Verified original actions and states for ", checked, " ticks."

proc prepare(replays: seq[Replay], repeats: int): seq[World] =
  ## Allocates all starting worlds before the benchmark clock begins.
  result = newSeq[World](replays.len * repeats)
  for i in 0 ..< result.len:
    result[i] = newWorld(replays[i mod replays.len].config)

proc runBots(batch: var seq[World]) =
  ## Runs full native episodes without recording, validation, or reporting.
  var
    moves: array[MaxPlayers, Move]
    scratch: BotScratch
  for world in batch.mitems:
    let players = world.config.players
    while not world.finished:
      for player in 0 ..< players:
        moves[player] = world.chooseMove(player, scratch)
      world.tick(moves.toOpenArray(0, players - 1))

proc runRules(batch: var seq[World], replays: seq[Replay]) =
  ## Runs the same production ticks with recorded native moves and no bots.
  for i, world in batch.mpairs:
    for frame in replays[i mod replays.len].frames:
      world.tick(frame.moves)

proc consume(batch: seq[World], replays: seq[Replay]): string =
  ## Keeps measured results observable and validates final states afterward.
  var combined = FingerprintBasis
  for i, world in batch:
    let digest = world.fingerprint()
    if digest != replays[i mod replays.len].frames[^1].fingerprint:
      raise newException(GeneralsError, "Timed benchmark result changed.")
    for character in digest:
      combined.mix(character.ord)
  combined.toHex(16)

proc statistics(samples: seq[float64]): Statistics =
  ## Reports all samples and their median without discarding slow samples.
  result.samples = samples
  var ordered = samples
  ordered.sort()
  result.minimum = ordered[0]
  result.median = ordered[ordered.len div 2]
  if ordered.len mod 2 == 0:
    result.median =
      (ordered[ordered.len div 2 - 1] + ordered[ordered.len div 2]) / 2
  for sample in samples:
    result.mean += sample
  result.mean /= samples.len.float64

proc benchmark(
    mode: string,
    replays: seq[Replay],
    samples, repeats: int
): JsonNode =
  ## Measures warmed batches while excluding setup, hashes, and JSON work.
  var
    warm = prepare(replays, 1)
    durations: seq[float64]
    digest = ""
    ticks = 0
  for replay in replays:
    ticks += replay.frames.len
  if mode == "bots":
    runBots(warm)
  else:
    runRules(warm, replays)
  discard consume(warm, replays)
  for sample in 0 ..< samples:
    var
      batch = prepare(replays, repeats)
      elapsed = 0.0
    timeIt mode & " sample " & $(sample + 1), 1:
      let started = getMonoTime()
      if mode == "bots":
        runBots(batch)
      else:
        runRules(batch, replays)
      elapsed =
        (getMonoTime() - started).inNanoseconds.float64 / 1.0e9
    durations.add(elapsed)
    digest = consume(batch, replays)
  let
    summary = statistics(durations)
    totalTicks = ticks * repeats
    matches = replays.len * repeats
  %*{
    "mode": mode,
    "samplesSeconds": summary.samples,
    "minimumSeconds": summary.minimum,
    "medianSeconds": summary.median,
    "meanSeconds": summary.mean,
    "ticksPerSample": totalTicks,
    "matchesPerSample": matches,
    "medianTicksPerSecond": totalTicks.float64 / summary.median,
    "medianMatchesPerSecond": matches.float64 / summary.median,
    "medianNanosecondsPerTick": summary.median * 1.0e9 / totalTicks.float64,
    "checksum": digest
  }

proc bounded(value, name: string, maximum: int): int =
  ## Parses positive benchmark counts as game-specific boundary errors.
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(GeneralsError, "Invalid benchmark " & name & ".")
  if result < 1 or result > maximum:
    raise newException(GeneralsError, "Benchmark " & name & " is out of range.")

proc options(): Options =
  ## Reads explicit benchmark workload and artifact paths from the command.
  result = Options(
    report: "out/benchmark.json",
    label: "local",
    mode: "all",
    samples: 5,
    repeats: 100
  )
  for argument in commandLineParams():
    if argument.startsWith("--record="):
      result.record = argument[9 .. ^1]
    elif argument.startsWith("--replay="):
      result.replay = argument[9 .. ^1]
    elif argument.startsWith("--report="):
      result.report = argument[9 .. ^1]
    elif argument.startsWith("--label="):
      result.label = argument[8 .. ^1]
    elif argument.startsWith("--mode="):
      result.mode = argument[7 .. ^1]
    elif argument.startsWith("--samples="):
      result.samples = bounded(argument[10 .. ^1], "samples", 100)
    elif argument.startsWith("--repeats="):
      result.repeats = bounded(argument[10 .. ^1], "repeats", 1000)
    elif argument in ["--help", "-h"]:
      echo "bench_simulation --record=PATH | --replay=PATH"
      echo "  --mode=all|bots|rules|verify|record  Default all."
      echo "  --samples=5 --repeats=100         Rules repeats per sample."
      echo "  --report=out/benchmark.json --label=local"
      quit(0)
    else:
      raise newException(GeneralsError, "Unknown benchmark flag: " & argument)
  if result.mode notin ["all", "bots", "rules", "verify", "record"]:
    raise newException(GeneralsError, "Unknown benchmark mode.")
  if (result.record.len > 0) == (result.replay.len > 0):
    raise newException(GeneralsError, "Choose one record or replay path.")
  if result.mode == "record" and result.record.len == 0:
    raise newException(GeneralsError, "Record mode needs a record path.")

proc main() =
  ## Records or checks the workload, then measures the requested pipelines.
  let settings = options()
  var replays: seq[Replay]
  if settings.record.len > 0:
    for players in [2, 4]:
      for seed in [7, 23]:
        echo "Recording ", players, " players, seed ", seed, "."
        replays.add capture(defaultConfig(seed, players))
    writeReplays(settings.record, replays)
    echo "Recorded baseline: ", settings.record
  else:
    replays = readReplays(settings.replay)
  if settings.mode == "record":
    return
  replays.verify()
  if settings.mode == "verify":
    return
  var measurements = newJArray()
  if settings.mode in ["all", "bots"]:
    measurements.add benchmark("bots", replays, settings.samples, 1)
  if settings.mode in ["all", "rules"]:
    measurements.add benchmark(
      "rules", replays, settings.samples, settings.repeats
    )
  var games = newJArray()
  for replay in replays:
    games.add %*{
      "width": replay.config.width,
      "height": replay.config.height,
      "players": replay.config.players,
      "seed": $replay.config.seed,
      "ticks": replay.frames.len,
      "winner": replay.winner
    }
  let report = %*{
    "label": settings.label,
    "nimVersion": NimVersion,
    "platform": hostOS & "-" & hostCPU,
    "release": defined(release),
    "danger": defined(danger),
    "tileBytes": sizeof(Tile),
    "setupIncluded": false,
    "verification": "Original bot decisions and per-tick state fingerprints.",
    "games": games,
    "measurements": measurements
  }
  if settings.report.parentDir().len > 0:
    createDir(settings.report.parentDir())
  writeFile(settings.report, report.pretty() & "\n")
  echo report.pretty()
  echo "Report: ", settings.report

try:
  main()
except GeneralsError as error:
  quit("Generals benchmark: " & error.msg, 1)
except JsonParsingError, ValueError, KeyError, IOError:
  let error = newException(GeneralsError, getCurrentExceptionMsg())
  quit("Generals benchmark: " & error.msg, 1)
