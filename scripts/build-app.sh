#!/usr/bin/env bash
# Build a universal, ad-hoc signed app; no Apple account is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo 'Usage: scripts/build-app.sh [debug|release]' >&2; exit 2 ;; esac
VERSION="$(cat VERSION)"
BUILD="$(cat BUILD_NUMBER)"
APP="$ROOT/dist/ServerKiln.app"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHS[@]}" --product ServerKiln --force-resolved-versions
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/ServerKiln"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/ServerKiln.app/Contents/MacOS" "$STAGE/ServerKiln.app/Contents/Resources"
CONTENTS="$STAGE/ServerKiln.app/Contents"
cp "$BIN" "$CONTENTS/MacOS/ServerKiln"
# SwiftPM links Sparkle dynamically. Bundle it and add a bundle-relative rpath.
mkdir -p "$CONTENTS/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/ServerKiln"
codesign --force --sign - "$CONTENTS/MacOS/ServerKiln"

"$CONTENTS/MacOS/ServerKiln" --write-iconset "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$CONTENTS/Resources"
done
cp LICENSE THIRD_PARTY_NOTICES.md "$CONTENTS/Resources/"
cp -R Resources/Licenses "$CONTENTS/Resources/"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ServerKiln</string>
  <key>CFBundleDisplayName</key><string>ServerKiln</string>
  <key>CFBundleIdentifier</key><string>cn.littleor.serverkiln</string>
  <key>CFBundleExecutable</key><string>ServerKiln</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$STAGE/ServerKiln.app"
codesign --verify --deep --strict "$STAGE/ServerKiln.app"
lipo "$CONTENTS/MacOS/ServerKiln" -verify_arch arm64 x86_64
mkdir -p dist
rm -rf "$APP"
mv "$STAGE/ServerKiln.app" "$APP"
echo "Built $APP ($VERSION, build $BUILD). iCloud requires the official signed build."
