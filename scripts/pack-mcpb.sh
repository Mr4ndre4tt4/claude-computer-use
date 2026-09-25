#!/bin/sh
# Packs the MCP server as a self-contained Claude desktop extension (dist/mac-computer-use.mcpb),
# for Claude surfaces that install local MCP servers as extensions (e.g. Cowork).
# The binary ships inside the bundle; run scripts/build.sh first so bin/ is current.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/server" "$ROOT/dist"
cp "$ROOT/bin/computer-use-server" "$STAGE/server/computer-use-server"
chmod 755 "$STAGE/server/computer-use-server"
sed "s/__VERSION__/$VERSION/" "$ROOT/mcpb/manifest.template.json" > "$STAGE/manifest.json"
OUT="$ROOT/dist/mac-computer-use.mcpb"
rm -f "$OUT"
(cd "$STAGE" && zip -qr -X "$OUT" manifest.json server)
echo "packed $OUT ($VERSION)" >&2
