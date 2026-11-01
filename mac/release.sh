#!/bin/bash
# Builds a release: the signed app (build.sh), notarized and stapled, inside a signed, notarized,
# stapled DMG at dist/Remote-Keeper.dmg. Needs the private ~/.config/remotekeeper/build.env (relay,
# app key and an App Store Connect API key for notarization).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
. "$HOME/.config/remotekeeper/build.env"
KEY="${RK_NOTARY_KEY/#\~/$HOME}"
notarize() { xcrun notarytool submit "$1" --key "$KEY" --key-id "$RK_NOTARY_KEY_ID" --issuer "$RK_NOTARY_ISSUER" --wait | grep -E "status:|id:" | tail -2; }

BUILD="${BUILD_DIR:-$HOME/Library/Developer/RemoteKeeper}"
APP="$BUILD/Remote Keeper.app"
VERSION=$(sed -n 's/^let keeperVersion = "\(.*\)"/\1/p' main.swift)
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$BUILD/app.zip"
notarize "$BUILD/app.zip"
xcrun stapler staple "$APP"
rm "$BUILD/app.zip"

echo "Making the DMG…"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Remote Keeper.app"
ln -s /Applications "$STAGE/Applications"
DMG="$BUILD/Remote-Keeper.dmg"
rm -f "$DMG"
hdiutil create -volname "Remote Keeper $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
mkdir -p ../dist
cp "$DMG" ../dist/Remote-Keeper.dmg
shasum -a 256 ../dist/Remote-Keeper.dmg
echo "Release ready: dist/Remote-Keeper.dmg ($VERSION)"
