#!/usr/bin/env bash
#
# Packages build/PostgresManager.app into a drag-to-Applications disk image.
#
# Usage: Scripts/make-dmg.sh [output.dmg]
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PostgresManager"
APP_DIR="build/${APP_NAME}.app"
VOLUME_NAME="Postgres Manager"
OUTPUT="${1:-build/${APP_NAME}.dmg}"
STAGING="build/dmg-staging"

if [ ! -d "$APP_DIR" ]; then
    echo "error: $APP_DIR not found. Run Scripts/build-app.sh first." >&2
    exit 1
fi

echo "==> Staging disk image contents"
rm -rf "$STAGING" "$OUTPUT"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
# The Applications symlink is what makes the window a drag-and-drop install.
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/Read Me.txt" <<'TXT'
Postgres Manager
================

1. Drag Postgres Manager to the Applications folder.
2. Open it. The icon appears in your menu bar (there is no Dock icon until you
   open a window).

First launch
------------
This app is ad-hoc signed rather than notarised, because it is built from source
with no Apple Developer account. macOS will therefore refuse the first launch of
a downloaded copy. To allow it, either:

  * Right-click the app in Applications and choose Open, then confirm; or
  * Run:  xattr -dr com.apple.quarantine "/Applications/PostgresManager.app"

Building it yourself avoids this entirely — see the repository README.
TXT

echo "==> Creating $OUTPUT"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    -fs HFS+ \
    "$OUTPUT" >/dev/null

rm -rf "$STAGING"
echo "==> Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
