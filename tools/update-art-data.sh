#!/bin/sh
# Regenerate the shipped art indexes (wowapi/data/icons.txt, atlases.txt)
# from the community listfile and BlizzardInterfaceResources' AtlasInfo.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -sfL -o "$TMP/listfile.csv" https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv
curl -sfL -o "$TMP/AtlasInfo.lua" https://raw.githubusercontent.com/Ketho/BlizzardInterfaceResources/live/Resources/AtlasInfo.lua
LUA=$(command -v lua5.1 || command -v luajit)
"$LUA" "$ROOT/tools/gen-art-data.lua" "$TMP/listfile.csv" "$TMP/AtlasInfo.lua" "$ROOT/wowapi/data"
