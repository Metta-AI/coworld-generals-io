#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../../.." && pwd)"
output="${1:?expected binary output directory}"
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$root/polyworld/.deps}"
sh "$root/polyworld/tools/fetch_deps.sh"
mkdir -p "$output"
paths=(--path:"$root/integrations/softmax" --path:"$root/polyworld/src")
for dependency in polyworld flatty bassy fixxy zippy; do
  paths+=(--path:"$POLYWORLD_DEPS/$dependency/src")
done
nim c --skipParentCfg:on -d:release -d:flatty64 -d:softmaxReplay --mm:arc \
  "${paths[@]}" -o:"$output/generals-polyworld" "$root/integrations/softmax/polyworld_bridge.nim"
native=(-d:bassyNative)
if [[ "${GENERALS_BASIC_NATIVE_STRICT:-0}" == 1 ]]; then
  native+=(-d:bassyNativeStrict)
fi
nim c --skipParentCfg:on -d:release --mm:arc "${native[@]}" \
  "${paths[@]}" -o:"$output/generals-basic" "$root/integrations/softmax/basic_worker.nim"
