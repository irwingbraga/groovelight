#!/bin/bash
# Builds Groovelight (Release) and packages it as a drag-to-install DMG in build/.
#
#   scripts/make-dmg.sh                 # version from MARKETING_VERSION in project.yml
#   VERSION=0.2.0 scripts/make-dmg.sh   # explicit version (CI passes the tag)
#
# Signing is ad-hoc unless these are set (then the app is signed with Developer ID and the hardened runtime):
#   DEVELOPER_ID_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)", in a keychain the build can use
# Notarization (needs Developer ID signing) runs when these are set too:
#   NOTARY_KEY_PATH         App Store Connect API key (.p8)
#   NOTARY_KEY_ID           its key id
#   NOTARY_ISSUER_ID        its issuer id
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

VERSION="${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || { echo "No version found" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

DERIVED=build/Release
APP="$DERIVED/Build/Products/Release/Groovelight.app"
STAGING=build/dmg
DMG="build/Groovelight-$VERSION.dmg"

echo "==> Groovelight $VERSION ($BUILD_NUMBER) with $(xcodebuild -version | head -1)"
xcodegen generate --quiet

SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    echo "==> Signing with $DEVELOPER_ID_IDENTITY"
    SIGNING=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

xcodebuild -project Groovelight.xcodeproj -scheme Groovelight -configuration Release \
    -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${SIGNING[@]}" \
    clean build | grep -E "error:|warning: .*deprecated|\*\* BUILD" || true
[ -d "$APP" ] || { echo "Build failed: $APP not found" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

echo "==> Packaging $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Groovelight $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    codesign --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG"
    if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
        echo "==> Notarizing"
        xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "dmg=$DMG" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
