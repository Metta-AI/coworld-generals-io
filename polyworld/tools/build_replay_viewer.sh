#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build_replay_viewer.sh ABSOLUTE_OUTPUT_DIRECTORY}"
output="$(python3 - "$root" "$output" <<'PY'
import sys
from pathlib import Path

root, output = Path(sys.argv[1]), Path(sys.argv[2])
allowed = [root / name for name in ("out", "build", "dist")]
if not output.is_absolute() or ".." in output.parts:
    sys.exit("Replay output must be an absolute build directory")
if not any(directory in output.parents for directory in allowed):
    sys.exit("Replay output must be below project out/, build/, or dist/")
if any(directory.is_symlink() for directory in (output, *output.parents)):
    sys.exit("Replay output must not contain a symlink")
print(output.resolve())
PY
)"
export EM_CACHE="${EM_CACHE:-$root/out/emscripten-cache}"
export GENERALS_WEB="$root/out/web"
mkdir -p "$EM_CACHE"
cd "$root"
nim c --skipParentCfg:on -d:release -d:emscripten -d:replayViewer \
  src/generals_viewer.nim
rm -rf "$output"
mkdir -p "$output/licenses"
cp "$GENERALS_WEB/generals.html" "$output/index.html"
for suffix in js wasm data; do
  cp "$GENERALS_WEB/generals.$suffix" "$output/generals.$suffix"
done
cp LICENSE "$output/LICENSE"
cp assets/licenses/* assets/fonts/OFL-*.txt "$output/licenses/"
cp assets/transport/LICENSE.art "$output/licenses/transport-art.txt"
dependencies="${POLYWORLD_DEPS:-$root/.deps}"
if [[ ! -d "$dependencies" ]]; then
  dependencies="$(dirname "$root")"
fi
while read -r name url revision; do
  for license in "$dependencies/$name"/[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*; do
    if [[ -f "$license" ]]; then
      cp "$license" "$output/licenses/$name-$(basename "$license")"
    fi
  done
done < "$root/dependencies.lock"
