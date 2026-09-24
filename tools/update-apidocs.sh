#!/bin/sh
# Fetch the latest Blizzard API documentation and regenerate wowapi/data/apidocs.lua.
#   tools/update-apidocs.sh [branch]      (default: live)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRANCH=${1:-live}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$BRANCH" \
  https://github.com/Gethe/wow-ui-source.git "$TMP/src"
cd "$TMP/src"
git sparse-checkout set Interface/AddOns/Blizzard_APIDocumentationGenerated \
  Interface/AddOns/Blizzard_FrameXMLBase Interface/AddOns/Blizzard_SharedXMLBase
SRC="wow-ui-source $BRANCH: $(git log -1 --format=%s)"
LUA=$(command -v lua5.1 || command -v luajit)
"$LUA" "$ROOT/tools/gen-apidocs.lua" Interface/AddOns/Blizzard_APIDocumentationGenerated "$SRC" > "$ROOT/wowapi/data/apidocs.lua"
W=Interface/AddOns
"$LUA" "$ROOT/tools/gen-constants.lua" "$SRC" $W/Blizzard_FrameXMLBase/Constants.lua \
  $W/Blizzard_FrameXMLBase/Shared/Constants.lua $(ls $W/Blizzard_SharedXMLBase/*Constants*.lua 2>/dev/null) \
  > "$ROOT/wowapi/data/constants.lua"
echo "Regenerated wowapi/data/apidocs.lua and constants.lua from $SRC"
