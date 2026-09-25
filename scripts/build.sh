#!/bin/sh
# Builds a universal (arm64 + x86_64) release binary into bin/computer-use-server.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/server"
# Build outside ~/Documents: iCloud/File Provider syncing corrupts SwiftPM's build database there.
SCRATCH="${CU_BUILD_DIR:-${TMPDIR:-/tmp}/claude-computer-use-build}"
if swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" >&2; then
  OUT="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)"
else
  echo "[computer-use] universal build failed, building for this Mac only" >&2
  swift build -c release --scratch-path "$SCRATCH" >&2
  OUT="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"
fi
cp "$OUT/computer-use-server" "$ROOT/bin/computer-use-server"
codesign --force --sign - "$ROOT/bin/computer-use-server" >/dev/null 2>&1 || true
echo "built $ROOT/bin/computer-use-server" >&2
