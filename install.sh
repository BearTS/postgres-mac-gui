#!/usr/bin/env bash
#
# Builds Postgres Manager from source and installs it to /Applications.
#
#   ./install.sh
#
# Requires: macOS 14.4+, and either Xcode or the Command Line Tools
# (`xcode-select --install`). Nothing else — no Apple Developer account,
# no certificates, no Homebrew needed to build.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PostgresManager"
APP_DIR="build/${APP_NAME}.app"
DESTINATION="/Applications/${APP_NAME}.app"

echo "Postgres Manager — build and install"
echo

if ! command -v swift >/dev/null 2>&1; then
    echo "error: the Swift toolchain was not found." >&2
    echo "       Install the Command Line Tools with:  xcode-select --install" >&2
    exit 1
fi

REQUIRED_MAJOR=14
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt "$REQUIRED_MAJOR" ]; then
    echo "error: macOS ${REQUIRED_MAJOR}.4 or newer is required (found $(sw_vers -productVersion))." >&2
    exit 1
fi

Scripts/build-app.sh release

if [ -d "$DESTINATION" ]; then
    echo "==> Replacing existing $DESTINATION"
    # Quit a running copy first, or the replace fails while it holds its own binary open.
    osascript -e 'quit app "PostgresManager"' 2>/dev/null || true
    sleep 1
    rm -rf "$DESTINATION"
fi

echo "==> Installing to $DESTINATION"
cp -R "$APP_DIR" /Applications/

# A locally built app is never quarantined, but clear it anyway in case this tree
# itself came out of a downloaded archive.
xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true

echo
echo "Installed. Opening it now — look for the database icon in your menu bar."
open "$DESTINATION"
