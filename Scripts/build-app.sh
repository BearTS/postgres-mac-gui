#!/usr/bin/env bash
#
# Builds PostgresManager.app. No Xcode required — SwiftPM compiles the binary and this script
# assembles the bundle around it.
#
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="PostgresManager"
BUNDLE_ID="dev.anujp.postgresmanager"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
BIN=".build/${CONFIG}/PostgresManagerApp"

# Version: a git tag when building from one, otherwise the short SHA.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '0.1.0')"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product PostgresManagerApp

if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Generating app icon"
    swift Scripts/make-icon.swift Resources
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

sed -e "s|@VERSION@|${VERSION}|g" -e "s|@BUILD@|${BUILD_NUMBER}|g" \
    Resources/Info.plist > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" > /dev/null

# SwiftPM emits resource bundles next to the binary when a target declares resources. None do
# today, but copying them keeps Bundle.module working if that ever changes.
for bundle in ".build/${CONFIG}/"*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$CONTENTS/Resources/"
done

echo "==> Signing (ad-hoc)"
# Ad-hoc signing needs no certificate and no Apple Developer account, so this repository
# carries no secrets. macOS requires arm64 binaries to be signed; ad-hoc satisfies that.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /'

# Nudge LaunchServices into re-reading Info.plist.
touch "$APP_DIR"

echo "==> Built $APP_DIR (version ${VERSION}, build ${BUILD_NUMBER})"
