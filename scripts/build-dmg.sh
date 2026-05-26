#!/bin/bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────
APP_NAME="OpenBeam"
SCHEME="OpenBeam"
CONFIG="Release"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/OpenBeam.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
BUILD_LOG="$BUILD_DIR/xcodebuild.log"

VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed 's/.*= *\(.*\);/\1/' | xargs)

# ─── Preflight ────────────────────────────────────────────────────────
if [ ! -f "$PROJECT_DIR/NDI/libndi.dylib" ]; then
    echo "ERROR: NDI SDK not found at NDI/libndi.dylib"
    echo "Install the NDI SDK from https://ndi.video/for-developers/ndi-sdk/"
    echo "then run: cp /Library/NDI\\ SDK\\ for\\ Apple/lib/macOS/libndi.dylib NDI/"
    exit 1
fi

echo "==> Building $APP_NAME $VERSION (Release)..."

# ─── Clean & Build ────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    SYMROOT="$BUILD_DIR/sym" \
    build \
    > "$BUILD_LOG" 2>&1 || {
    echo "ERROR: Build failed. Last 50 lines:"
    tail -50 "$BUILD_LOG"
    exit 1
}

echo "==> Build succeeded"

# ─── Locate the built app (deterministic path) ──────────────────────
BUILT_APP="$BUILD_DIR/sym/$CONFIG/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: $APP_NAME.app not found at expected path: $BUILT_APP"
    echo "Searching build dir..."
    find "$BUILD_DIR" -name "$APP_NAME.app" -type d
    exit 1
fi

cp -R "$BUILT_APP" "$APP_PATH"
echo "==> App: $APP_PATH"

# ─── Verify dylib is embedded ────────────────────────────────────────
if [ ! -f "$APP_PATH/Contents/Frameworks/libndi.dylib" ]; then
    echo "ERROR: libndi.dylib not found in app bundle Frameworks/"
    exit 1
fi

echo "==> libndi.dylib embedded OK"

# ─── Create DMG ──────────────────────────────────────────────────────
echo "==> Creating DMG..."

rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_DIR"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)
echo ""
echo "==> Done! $DMG_PATH ($DMG_SIZE)"
echo "    Drag $APP_NAME.app to Applications to install."
