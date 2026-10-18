#!/bin/zsh
# Packs the Claude Desktop extension (Groovelight-<version>.mcpb): the manifest, the app's icon and a launcher that
# runs the installed app's own `groovelight mcp`, so the extension never needs its own copy of the tool.
#   scripts/make-mcpb.sh path/to/Groovelight.app [output folder]
set -euo pipefail
APP="${1:?usage: scripts/make-mcpb.sh path/to/Groovelight.app [output folder]}"
OUT="${2:-build}"
ROOT="${0:A:h:h}"
MCPB="@anthropic-ai/mcpb@2.1.2"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/extension/" "$STAGE/"
plutil -replace version -string "$VERSION" "$STAGE/manifest.json"
sips -s format png --resampleHeightWidth 512 512 "$APP/Contents/Resources/Groovelight.icns" --out "$STAGE/icon.png" > /dev/null
chmod +x "$STAGE/server/groovelight-mcp"

mkdir -p "$OUT"
FILE="$OUT/Groovelight-$VERSION.mcpb"
npx --yes "$MCPB" validate "$STAGE/manifest.json"
npx --yes "$MCPB" pack "$STAGE" "$FILE"
echo "==> $FILE"
