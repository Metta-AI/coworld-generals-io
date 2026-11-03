version = "0.1.0"
author = "Polyworld contributors"
description = "A local Generals strategy game with Polyworld Silky UI."
license = "MIT"
srcDir = "src"
bin = @["generals"]

requires "nim >= 2.2.10"
requires "https://github.com/Metta-AI/polyworld"
requires "silky", "pixie", "windy", "vmath", "chroma", "opengl", "flatty"
requires "fluffy >= 1.0.0", "benchy >= 0.1.0"
requires "jsony"
requires "mummy", "webby", "curly", "libcurl"
requires "https://github.com/treeform/bassy"

task test, "Check the game and test rules, fog, controls, and bots":
  exec "nim check src/generals.nim"
  exec "nim r tests/tests.nim"

task run, "Build and open the local game":
  exec "nim c -d:release -o:out/generals src/generals.nim"
  exec "./out/generals"

task simulate, "Run a deterministic match without a graphics window":
  exec "nim c -d:release -d:headless -o:out/generals-sim src/generals.nim"
  exec "./out/generals-sim --headless"

task reference, "Compare every tick against the pinned Python reference":
  exec "nim check tools/reference_runner.nim"
  exec "python3 tools/check_reference.py"

task benchmark, "Measure native bots and recorded rules-only replays":
  exec "nim check tests/bench_simulation.nim"
  exec "nim c -d:release -o:out/bench-simulation tests/bench_simulation.nim"
  exec "./out/bench-simulation --record=out/benchmark-replays.json"
