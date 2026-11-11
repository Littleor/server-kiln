#!/usr/bin/env bash
# Prepare signed assets for a GitHub Release. Does not publish anything.
# Usage: scripts/prepare-mac-update.sh path/to/notarized.dmg path/to/ServerKiln.app output-dir
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$1"
APP="$2"
OUT="$3"
TOOLS="${SPARKLE_TOOLS_DIR:-$ROOT/build/sparkle-tools}"
ACCOUNT=cn.littleor.serverkiln.updates
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  mkdir -p "$TOOLS"
  curl --fail --location --retry 3 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz' -o "$TOOLS/Sparkle.tar.xz"
  python3 - "$TOOLS/Sparkle.tar.xz" <<'PY'
import hashlib,sys
assert hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest() == '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27', 'Sparkle tools checksum mismatch'
PY
  tar -xf "$TOOLS/Sparkle.tar.xz" -C "$TOOLS"
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist")
[ "$PUBLIC_KEY" = "$("$TOOLS/bin/generate_keys" --account "$ACCOUNT" -p)" ] || { echo 'Update signing key does not match the app.' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version.' >&2; exit 1; }
"$ROOT/scripts/check-mac-update-version.sh" "$VERSION" "$BUILD"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
python3 -I "$ROOT/scripts/verify-mac-update.py" dmg "$APP" "$DMG"
# generate_appcast lists every archive in the folder; leftovers would be
# published under this version's download URL.
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  echo "Output folder must be empty: $OUT" >&2; exit 1
fi
mkdir -p "$OUT"
ASSET="ServerKiln-$VERSION-universal.dmg"
cp "$DMG" "$OUT/$ASSET"
if [ -n "${MAC_RELEASE_NOTES:-}" ]; then
  cp "$MAC_RELEASE_NOTES" "$OUT/${ASSET%.dmg}.md"
fi
"$TOOLS/bin/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/Littleor/server-kiln/releases/download/v$VERSION/" \
  --link "https://github.com/Littleor/server-kiln/releases/tag/v$VERSION" "$OUT"
python3 -I "$ROOT/scripts/verify-mac-update.py" feed "$OUT" "$ASSET" "$VERSION" "$BUILD"
echo "Ready to upload together: $ASSET appcast.xml SHA256SUMS"
