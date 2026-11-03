## Private JSONL transport for the authoritative Polyworld simulation.
import std/[json, sequtils]
import generals/common
import polyworld_hosted

var world: World

proc snapshot(report: StepReport): JsonNode =
  result = %*{
    "hash": world.hostedHash(),
    "turn": world.turn,
    "winner": world.winner,
    "width": world.config.width,
    "height": world.config.height,
    "alive": world.alive,
    "kinds": world.tiles.mapIt(it.kind.ord),
    "owners": world.tiles.mapIt(it.owner.int),
    "armies": world.tiles.mapIt(it.army),
    "executed": report.executed,
    "captured_by": report.capturedBy,
    "elimination_order": report.eliminationOrder,
    "damage": report.damage
  }

for line in stdin.lines:
  let request = parseJson(line)
  var report: StepReport
  report = world.applyHosted(request)
  stdout.writeLine($snapshot(report))
  stdout.flushFile()
