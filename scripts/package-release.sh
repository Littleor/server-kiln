#!/usr/bin/env bash
# Resume packaging from an already signed, notarized and stapled app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -n "${ASC_ENV:-}" ]; then source "$ASC_ENV"; fi
: "${ASC_AUTH_KEY_PATH:?Set ASC_AUTH_KEY_PATH}"
: "${ASC_AUTH_KEY_ID:?Set ASC_AUTH_KEY_ID}"
: "${ASC_AUTH_KEY_ISSUER_ID:?Set ASC_AUTH_KEY_ISSUER_ID}"
VERSION="$(cat VERSION)"
BUILD="$(cat BUILD_NUMBER)"
APP="${1:?Usage: scripts/package-release.sh /absolute/path/ServerKiln.app /absolute/output/path}"
OUT="${2:?Specify the output directory}"
case "$APP:$OUT" in /*:/*) ;; *) echo 'Use absolute paths.' >&2; exit 2 ;; esac
KEY="${ASC_AUTH_KEY_PATH/#\~/$HOME}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application}"
DMG="ServerKiln-$VERSION-universal.dmg"
ZIP="ServerKiln-$VERSION-universal.zip"
for file in "$DMG" "$ZIP" SHA256SUMS; do
  [ ! -e "$OUT/$file" ] || { echo "Refusing to replace $OUT/$file" >&2; exit 1; }
done
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/ServerKiln" -verify_arch arm64 x86_64
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/volume"
ditto "$APP" "$STAGE/volume/ServerKiln.app"
ln -s /Applications "$STAGE/volume/Applications"
hdiutil create -volname ServerKiln -srcfolder "$STAGE/volume" -format UDZO "$STAGE/$DMG"
codesign --sign "$IDENTITY" --timestamp "$STAGE/$DMG"
xcrun notarytool submit "$STAGE/$DMG" --key "$KEY" --key-id "$ASC_AUTH_KEY_ID" \
  --issuer "$ASC_AUTH_KEY_ISSUER_ID" --wait
xcrun stapler staple "$STAGE/$DMG"
xcrun stapler validate "$STAGE/$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGE/$DMG"
ditto -c -k --keepParent "$APP" "$STAGE/$ZIP"
(cd "$STAGE" && shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS)
mv "$STAGE/$DMG" "$STAGE/$ZIP" "$STAGE/SHA256SUMS" "$OUT/"
echo "Release artifacts: $OUT"
