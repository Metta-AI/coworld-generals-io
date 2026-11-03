import
  std/[json, os],
  generals/profiles

static:
  doAssert ProfileEnabled
  doAssert ProfileTracePath.len > 0

proc measured(value: int): int {.measure, raises: [].} =
  ## Exercises measured early returns while preserving declared effects.
  if value == 0:
    return 1
  value

proc checkProfiles() =
  ## Verifies the actual recorder cap and idempotent capture completion.
  echo "Testing bounded Fluffy captures"
  startProfileTrace()
  for i in 0 ..< 10_005:
    doAssert measured(i) == max(1, i)
  finishProfileTrace()
  finishProfileTrace()
  let trace = parseFile(ProfileTracePath)
  doAssert trace["traceEvents"].len == 10_000
  doAssert fileExists(ProfileTracePath)
  echo "Fluffy capture checks passed"

checkProfiles()
