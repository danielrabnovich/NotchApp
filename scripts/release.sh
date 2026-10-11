#!/bin/bash
# Publishes a NotchApp release the app's updater picks up (Settings → About, and a daily check).
#   scripts/release.sh 1.1.0 "What's new, first line shows in the notch"
# Builds with that version, zips the app and creates GitHub release v<version> with the zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-NotchApp $VERSION}"
REPO="danielrabnovich/NotchApp"
# Builds count up with each release, from the tags so far.
BUILD=$(( $(git tag -l 'v*' | wc -l) + 2 ))

if git rev-parse "v$VERSION" >/dev/null 2>&1; then echo "✗ v$VERSION already exists"; exit 1; fi
if [ -n "$(git status --porcelain)" ]; then echo "✗ Commit or stash your changes first"; exit 1; fi

VERSION="$VERSION" BUILD="$BUILD" ./build.sh
ZIP="build/NotchApp-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/NotchApp.app "$ZIP"

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" -R "$REPO" --title "NotchApp $VERSION" --notes "$NOTES"
echo "✓ Released NotchApp $VERSION (build $BUILD)"
