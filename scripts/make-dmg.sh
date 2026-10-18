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

# Ad-hoc builds leave the hardened runtime off: with it, macOS only loads frameworks signed by the app's own team, and
# ad-hoc code has no team, so the app was killed at launch ("different Team IDs" loading wavpack.framework). The
# hardened runtime is only needed for notarization, which needs a Developer ID anyway.
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO)
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    echo "==> Signing with $DEVELOPER_ID_IDENTITY"
    # No injected base entitlements: they add get-task-allow (debugging), which notarization rejects.
    SIGNING=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp
             CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

xcodebuild -project Groovelight.xcodeproj -scheme Groovelight -configuration Release \
    -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${SIGNING[@]}" \
    clean build | grep -E "error:|warning: .*deprecated|\*\* BUILD" || true
[ -d "$APP" ] || { echo "Build failed: $APP not found" >&2; exit 1; }
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
    # Notarization needs every piece of code signed with the Developer ID, a secure timestamp and the hardened runtime.
    # Xcode re-signs embedded frameworks but not the helpers inside Sparkle (they keep Sparkle's own signature), so
    # everything is signed again from the inside out, as Sparkle's documentation describes; the app keeps its
    # entitlements.
    echo "==> Signing nested code for notarization"
    sign() { codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp --options runtime "$@"; }
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    if [ -d "$SPARKLE" ]; then
        sign "$SPARKLE/XPCServices/Installer.xpc"
        sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
        sign "$SPARKLE/Autoupdate"
        sign "$SPARKLE/Updater.app"
    fi
    for framework in "$APP"/Contents/Frameworks/*.framework; do sign "$framework"; done
    # The command line tool (no entitlements: it is not sandboxed, it asks the app to do the work).
    sign --identifier dev.irwingbraga.groovelight.cli "$APP/Contents/Helpers/groovelight"
    sign --preserve-metadata=entitlements,requirements "$APP"
fi
codesign --verify --deep --strict "$APP"
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ] && codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    echo "The app still requests get-task-allow, which notarization rejects" >&2
    exit 1
fi
# The frameworks must load: a broken signature only shows at launch, so check what dyld will check.
for framework in "$APP"/Contents/Frameworks/*.framework; do
    codesign --verify --strict "$framework" || { echo "Invalid signature: $framework" >&2; exit 1; }
done
# The command line tool runs (and reads the app's version beside it).
"$APP/Contents/Helpers/groovelight" --version || { echo "The command line tool does not run" >&2; exit 1; }

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
        NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
        RESULT=$(xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait 2>&1) || true
        echo "$RESULT"
        if ! grep -q "status: Accepted" <<< "$RESULT"; then
            # Apple's log names each file it rejected and why.
            SUBMISSION=$(sed -n 's/^ *id: //p' <<< "$RESULT" | head -1)
            [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" "${NOTARY[@]}" || true
            echo "Notarization failed" >&2
            exit 1
        fi
        xcrun stapler staple "$DMG"
    fi
fi

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "dmg=$DMG" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
