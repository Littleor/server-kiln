#!/usr/bin/env bash
# Upload validated artifacts to a draft. Publishing is an explicit separate step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
TAG="v$VERSION"
REPO=Littleor/server-kiln
OUT="$ROOT/build/release/$TAG"
DMG="$OUT/ServerKiln-$VERSION-universal.dmg"
ZIP="$OUT/ServerKiln-$VERSION-universal.zip"
test -z "$(git status --porcelain)" || { echo 'Commit or remove working-tree changes first.' >&2; exit 1; }
test "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)"
test "$(git ls-remote origin "refs/tags/$TAG^{}" | cut -f1)" = "$(git rev-parse HEAD)"
scripts/check-public-tree.py --history
scripts/check-docs.py
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  test "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft)" = true \
    || { echo 'Refusing to modify an already published release.' >&2; exit 1; }
else
  gh release create "$TAG" --repo "$REPO" --verify-tag --draft \
    --title "ServerKiln $VERSION" --notes-file "docs/releases/$TAG.md"
fi
gh release upload "$TAG" --repo "$REPO" "$DMG" "$ZIP" "$OUT/appcast.xml" "$OUT/SHA256SUMS"
echo "Draft ready: https://github.com/$REPO/releases"
