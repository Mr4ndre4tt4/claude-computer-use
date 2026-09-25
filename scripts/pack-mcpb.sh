#!/bin/sh
# Packs everything Cowork (and other Claude desktop surfaces) needs into cowork/:
#   cowork/mac-computer-use.mcpb        desktop extension with the MCP server bundled inside
#   cowork/mac-computer-use-skill.zip   the usage skill, worded for the extension, for upload
# The Claude Code plugin (.claude-plugin/, bin/, skills/) is not touched.
# Run scripts/build.sh first so bin/computer-use-server is current.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)"
OUT="$ROOT/cowork"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Extension: manifest + bundled binary, launched through ${__dirname}.
mkdir -p "$STAGE/ext/server"
cp "$ROOT/bin/computer-use-server" "$STAGE/ext/server/computer-use-server"
chmod 755 "$STAGE/ext/server/computer-use-server"
sed "s/__VERSION__/$VERSION/" "$ROOT/mcpb/manifest.template.json" > "$STAGE/ext/manifest.json"
rm -f "$OUT/mac-computer-use.mcpb"
(cd "$STAGE/ext" && zip -qr -X "$OUT/mac-computer-use.mcpb" manifest.json server)

# Skill: same SKILL.md, but naming the extension's tools instead of the plugin's.
mkdir -p "$STAGE/skill/mac-computer-use"
sed -e 's/^description: (Computer use plugin, macOS)/description: (Mac Computer Use extension, macOS)/' \
    -e 's/^Tools come from the `mac` MCP server of this plugin (`mcp__plugin_computer-use_mac__\*`)\./Tools come from the **Mac Computer Use** desktop extension (MCP server `mac-computer-use`)./' \
    "$ROOT/skills/mac-computer-use/SKILL.md" > "$STAGE/skill/mac-computer-use/SKILL.md"
grep -q "Mac Computer Use\*\* desktop extension" "$STAGE/skill/mac-computer-use/SKILL.md" \
  || { echo "pack-mcpb: skill header not rewritten; update the sed patterns" >&2; exit 1; }
rm -f "$OUT/mac-computer-use-skill.zip"
(cd "$STAGE/skill" && zip -qr -X "$OUT/mac-computer-use-skill.zip" mac-computer-use)

echo "packed cowork/mac-computer-use.mcpb and cowork/mac-computer-use-skill.zip ($VERSION)" >&2
