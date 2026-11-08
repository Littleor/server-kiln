#!/usr/bin/env bash
# Produce signed, notarized universal DMG + ZIP. Does not upload to GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -n "${ASC_ENV:-}" ]; then source "$ASC_ENV"; fi
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
: "${ASC_AUTH_KEY_PATH:?Set ASC_AUTH_KEY_PATH (outside the checkout)}"
: "${ASC_AUTH_KEY_ID:?Set ASC_AUTH_KEY_ID}"
: "${ASC_AUTH_KEY_ISSUER_ID:?Set ASC_AUTH_KEY_ISSUER_ID}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application}"
PROFILE="${MAC_PROVISIONING_PROFILE:-ServerKiln macOS Developer ID}"
KEY="${ASC_AUTH_KEY_PATH/#\~/$HOME}"
VERSION="$(cat VERSION)"
BUILD="$(cat BUILD_NUMBER)"
OUT="$ROOT/build/release/v$VERSION"
[ ! -e "$OUT" ] || { echo "Output already exists: $OUT. Move it aside before rebuilding." >&2; exit 1; }
command -v xcodegen >/dev/null
[ -f "$KEY" ] || { echo 'App Store Connect key not found.' >&2; exit 1; }
scripts/check-public-tree.py
mkdir -p "$OUT" build/mac-icon
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_AUTH_KEY_ID"
      -authenticationKeyIssuerID "$ASC_AUTH_KEY_ISSUER_ID")
swift build --product ServerKiln --force-resolved-versions
"$(swift build --show-bin-path)/ServerKiln" --write-iconset "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o build/mac-icon/AppIcon.icns
xcodegen generate
# Xcode resolves the local package independently; seed the reviewed lockfile.
mkdir -p ServerKiln.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved ServerKiln.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project ServerKiln.xcodeproj -scheme ServerKiln-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/ServerKiln.xcarchive" \
  -derivedDataPath build/dd-release -onlyUsePackageVersionsFromResolvedFile \
  "${AUTH[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO archive
python3 - "$OUT/ExportOptions.plist" "$APPLE_TEAM_ID" "$PROFILE" "$IDENTITY" <<'PY'
import plistlib, sys
path, team, profile, identity = sys.argv[1:]
with open(path, 'wb') as out:
    plistlib.dump({'method': 'developer-id', 'destination': 'export', 'signingStyle': 'manual',
                  'signingCertificate': identity, 'teamID': team,
                  'provisioningProfiles': {'cn.littleor.serverkiln': profile},
                  'iCloudContainerEnvironment': 'Production'}, out)
PY
xcodebuild -exportArchive -archivePath "$OUT/ServerKiln.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}"
APP="$OUT/export/ServerKiln.app"
python3 scripts/check-release-app.py "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/ServerKiln" -verify_arch arm64 x86_64
# Staple the app as well as the DMG so the ZIP also works offline.
ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
xcrun notarytool submit "$STAGE/notarize.zip" --key "$KEY" --key-id "$ASC_AUTH_KEY_ID" \
  --issuer "$ASC_AUTH_KEY_ISSUER_ID" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
export ASC_AUTH_KEY_PATH ASC_AUTH_KEY_ID ASC_AUTH_KEY_ISSUER_ID
scripts/package-release.sh "$APP" "$OUT"
