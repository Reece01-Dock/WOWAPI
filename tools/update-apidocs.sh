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
MODULES="Blizzard_FrameXMLBase Blizzard_SharedXMLBase Blizzard_SharedXML Blizzard_FrameXMLUtil Blizzard_FrameXML
  Blizzard_ActionBar Blizzard_UnitFrame Blizzard_ChatFrameBase Blizzard_UIParent Blizzard_UIPanels_Game
  Blizzard_ItemButton Blizzard_GameTooltip Blizzard_Colors"
git sparse-checkout set Interface/AddOns/Blizzard_APIDocumentationGenerated $(for m in $MODULES; do echo "Interface/AddOns/$m"; done)
SRC="wow-ui-source $BRANCH: $(git log -1 --format=%s)"
LUA=$(command -v lua5.1 || command -v luajit)
"$LUA" "$ROOT/tools/gen-apidocs.lua" Interface/AddOns/Blizzard_APIDocumentationGenerated "$SRC" > "$ROOT/wowapi/data/apidocs.lua"
W=Interface/AddOns
# constants: base files first, then every mainline/shared FrameXML Lua file
FILES="$W/Blizzard_FrameXMLBase/Constants.lua $W/Blizzard_FrameXMLBase/Shared/Constants.lua"
FILES="$FILES $(for m in $MODULES; do find "$W/$m" -name '*.lua'; done | grep -viE '/(Classic|Vanilla|TBC|Wrath|Cata|Mists|Glue)[^/]*/' | sort)"
"$LUA" "$ROOT/tools/gen-constants.lua" "$SRC" $FILES > "$ROOT/wowapi/data/constants.lua"
echo "Regenerated wowapi/data/apidocs.lua and constants.lua from $SRC"
