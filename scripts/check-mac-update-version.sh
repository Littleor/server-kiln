#!/usr/bin/env bash
# Sparkle offers an update only when CFBundleVersion is higher than the
# installed build. Refuse a Mac release whose build number would not be, or
# whose version is older than the published feed.
# Usage: scripts/check-mac-update-version.sh <version> <build>
set -euo pipefail
VERSION="$1"
BUILD="$2"
FEED="${MAC_UPDATE_FEED:-https://github.com/Littleor/server-kiln/releases/latest/download/appcast.xml}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "Build number must be an integer: $BUILD" >&2; exit 1; }
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
CODE=$(curl -sSL --retry 3 -o "$TMP" -w '%{http_code}' "$FEED") || { echo "Could not reach $FEED" >&2; exit 1; }
if [ "$CODE" = 404 ]; then
  echo "No published appcast yet; build $BUILD will be the first update-enabled release."
  exit 0
fi
[ "$CODE" = 200 ] || { echo "Unexpected HTTP $CODE from $FEED" >&2; exit 1; }
python3 -I - "$TMP" "$VERSION" "$BUILD" <<'PY'
import sys, xml.etree.ElementTree as ET
SP = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
feed, version, build = sys.argv[1], sys.argv[2], int(sys.argv[3])
items = [(int(i.findtext(SP + 'version')), i.findtext(SP + 'shortVersionString') or '0')
         for i in ET.parse(feed).iter('item')]
assert items, 'Published appcast has no items'
pub_build, pub_version = max(items)
key = lambda v: tuple(int(p) for p in v.split('.'))
if build <= pub_build:
    sys.exit(f'Build {build} must be higher than published build {pub_build} ({pub_version}); '
             'Sparkle would report "up to date". Pass a higher build number.')
if key(version) < key(pub_version):
    sys.exit(f'Version {version} is older than published {pub_version}.')
print(f'Update check OK: {pub_version} ({pub_build}) -> {version} ({build})')
PY
