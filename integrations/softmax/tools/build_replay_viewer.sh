#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../../.." && pwd)"
output="${1:?expected output bundle directory}"
source="${GENERALS_POLYWORLD_VIEWER:-}"
if [[ -z "$source" ]]; then
  scratch=$(mktemp -d)
  container=$(docker create --platform "linux/${GENERALS_ARCH:-amd64}" --entrypoint /bin/true "generals-polyworld-game:${GENERALS_ARCH:-amd64}")
  trap 'docker rm "$container" >/dev/null; rm -rf "$scratch"' EXIT
  docker cp "$container:/app/polyworld-viewer" "$scratch/viewer"
  source="$scratch/viewer"
fi
python3 - "$source" "$output" "$root" <<'PY'
import shutil
import sys
from pathlib import Path
source, output, root = (Path(value).resolve() for value in sys.argv[1:])
allowed = (root / 'polyworld/out', root / 'integrations/softmax/dist')
if (source == output or source in output.parents or output in source.parents or
        output == root or output in root.parents or
        root in output.parents and not any(path in output.parents for path in allowed)):
    raise SystemExit('refusing to overwrite replay sources')
if output.exists():
    shutil.rmtree(output)
shutil.copytree(source, output)
PY
