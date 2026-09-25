#!/bin/sh
# One-step setup of Mac Computer Use for Cowork: opens the extension installer in the Claude
# app and shows the skill zip to upload. Rebuilds and repacks first when run from a checkout
# with sources (otherwise uses the files shipped in this folder).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
if [ -x "$ROOT/scripts/pack-mcpb.sh" ]; then
  [ -x "$ROOT/bin/computer-use-server" ] || "$ROOT/scripts/build.sh"
  "$ROOT/scripts/pack-mcpb.sh"
fi
echo "1/3  Abrindo o instalador da extensão no app Claude: clique em Instalar."
open "$DIR/mac-computer-use.mcpb"
sleep 1
echo "2/3  Mostrando a skill no Finder: envie mac-computer-use-skill.zip em Ajustes → Capacidades → Skills."
open -R "$DIR/mac-computer-use-skill.zip"
echo "3/3  Feche o Claude por completo, abra de novo e peça no Cowork: \"rode check_permissions\"."
