#!/bin/sh
# Fetch Ketho/BlizzardInterfaceResources and regenerate wowapi/data/resources.lua
# plus GlobalStrings. Pass locale codes to also fetch those GlobalStrings:
#   tools/update-resources.sh            (enUS only)
#   tools/update-resources.sh deDE frFR
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --depth 1 --filter=blob:none --sparse \
  https://github.com/Ketho/BlizzardInterfaceResources.git "$TMP/src"
cd "$TMP/src"
git sparse-checkout set Resources
SRC="BlizzardInterfaceResources $(git rev-parse --abbrev-ref HEAD) ($(git log -1 --format=%cs))"
LUA=$(command -v lua5.1 || command -v luajit)
"$LUA" "$ROOT/tools/gen-resources.lua" Resources "$SRC" > "$ROOT/wowapi/data/resources.lua"
for loc in enUS "$@"; do
  cp "Resources/GlobalStrings/$loc.lua" "$ROOT/wowapi/data/globalstrings_$loc.lua"
done
echo "Regenerated wowapi/data/resources.lua and GlobalStrings from $SRC"
