#!/usr/bin/env bash
# Rebuild the landlock-run launcher from the DSH checkout's audited C source.
# Used when the image is rebuilt/rebuilt-variant, so the workspace-write
# sandbox fix survives image updates without shipping a stale binary.
#
# Usage:  ./build.sh        (source is at /opt/dsh-src)
#         SRC=/path/to/main.c ./build.sh   (override source path)
set -euo pipefail

SRC="${SRC:-/opt/dsh-src/native/landlock-run/packages/entry/src/main.c}"
OUT="$(cd "$(dirname "$0")" && pwd)/bin/landlock-run"

if [ ! -f "$SRC" ]; then
  echo "error: source not found at $SRC (set SRC to override)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "building $OUT from $SRC"
gcc -O2 -std=c11 -static -o "$OUT" "$SRC"

echo "verifying probe..."
"$OUT" --probe
echo "build OK: $(file -b "$OUT" | cut -d, -f1-2)"
