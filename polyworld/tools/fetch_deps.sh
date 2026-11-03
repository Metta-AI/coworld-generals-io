#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dependencies=${POLYWORLD_DEPS:-"$project/.deps"}
mkdir -p "$dependencies"

while read -r name url revision; do
  directory="$dependencies/$name"
  if [ ! -d "$directory" ]; then
    git clone --filter=blob:none --no-checkout "$url" "$directory"
    git -C "$directory" checkout --detach "$revision"
  elif [ "$(git -C "$directory" rev-parse HEAD)" != "$revision" ]; then
    echo "$name is at another revision. Leaving it unchanged." >&2
    echo "Use an empty POLYWORLD_DEPS directory for pinned dependencies." >&2
    exit 1
  fi
done < "$project/dependencies.lock"

echo "Dependencies ready in $dependencies"
