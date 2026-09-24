#!/bin/bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

SCHEME="OpenBeam"
CONFIG="Release"
DMG_DIR="$BUILD_DIR/dmg"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
BUILD_LOG="$BUILD_DIR/xcodebuild.log"

VERSION="$(marketing_version)"
ZIP_PATH="$(zip_path "$VERSION")"

# ─── Preflight ────────────────────────────────────────────────────────

# When building from a tag — which is how a release is produced — the tag is
# the version users see on the Releases page, and MARKETING_VERSION is the
# version the app reports about itself. If they disagree, a bug report naming
# a version cannot be traced to a build, so refuse rather than ship the drift.
TAG="${GITHUB_REF_NAME:-$(git -C "$PROJECT_DIR" describe --exact-match --tags 2>/dev/null || true)}"
if [[ "$TAG" == v* ]]; then
    if [ "$VERSION" != "${TAG#v}" ]; then
        echo "ERROR: tag $TAG does not match MARKETING_VERSION $VERSION"
        echo "       Releases are cut with ./scripts/release.sh <version>, which"
        echo "       bumps, commits and tags together so these cannot diverge."
        exit 1
    fi
    echo "==> Tag $TAG matches MARKETING_VERSION $VERSION"
fi

# Sparkle refuses to start when SUPublicEDKey is not a real key. Verified: the
# app then greets every launch with a modal "Unable to Check For Updates — the
# updater failed to start", keeps "Check for Updates…" greyed out for good, and
# can never update itself. A release must not ship that, so it refuses to build.
PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PROJECT_DIR/Info.plist" 2>/dev/null || true)
if [ -z "$PUBKEY" ] || [ "$PUBKEY" = "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ]; then
    echo "       Generate one once with Sparkle's generate_keys (see CONTRIBUTING.md)," >&2
    echo "       paste the printed public key into Info.plist, and keep the private" >&2
    echo "       half in the SPARKLE_PRIVATE_KEY secret." >&2
    die "SUPublicEDKey in Info.plist is not set to a real key. Sparkle would refuse to start."
fi

# The app polls SUFeedURL; CI publishes the feed under SITE_URL. If those two
# ever part company the app keeps asking an address nobody updates any more, and
# nothing else in the pipeline would notice.
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PROJECT_DIR/Info.plist" 2>/dev/null || true)
case "$FEED_URL" in
    "$SITE_URL"/*) ;;
    *) die "SUFeedURL ($FEED_URL) is not under SITE_URL ($SITE_URL); the app would poll a feed CI never publishes." ;;
esac

# Signed with OpenBeam's certificate when this Mac has it, which CI always does
# (import-signing-certificate.sh). A release must have it: one that went out
# ad-hoc would reset every user's permissions again, so a tag build refuses to
# go on without it. `find-identity` without -v, because the certificate is
# self-signed and so never "valid" in the trust sense — codesign does not care.
SIGN_SETTINGS=()
SIGNED=false
if security find-identity -p codesigning | grep -q "\"$SIGNING_IDENTITY\""; then
    SIGN_SETTINGS=(CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual)
    SIGNED=true
    echo "==> Signing with \"$SIGNING_IDENTITY\""
elif [[ "$TAG" == v* ]]; then
    die "\"$SIGNING_IDENTITY\" is not in any keychain; a release must not be signed ad hoc (see CONTRIBUTING.md)."
else
    echo "WARNING: \"$SIGNING_IDENTITY\" not found; signing ad hoc. Fine for a local test, not for a release."
fi

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
    -derivedDataPath "$DERIVED_DATA" \
    -onlyUsePackageVersionsFromResolvedFile \
    SYMROOT="$BUILD_DIR/sym" \
    ${SIGN_SETTINGS[@]+"${SIGN_SETTINGS[@]}"} \
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

# ─── Verify the code signature ───────────────────────────────────────
# Sparkle accepts an update from an ad-hoc build on its EdDSA signature alone,
# and from a signed one when the certificate also matches — but it always
# *rejects* an update whose own signature is broken. A seal damaged here would produce an update that every
# installed copy refuses, so it is caught before the archive is built.
# Note: never "fix" a failure here with `codesign --deep --force`. Xcode signs
# inside-out already; --deep re-seals nested bundles in the wrong order and
# causes exactly the rejection this guards against.
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | grep -q "satisfies its Designated Requirement"; then
    echo "ERROR: $APP_NAME.app does not have a valid code signature."
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" || true
    exit 1
fi
echo "==> Code signature OK"

# The point of the certificate: an identity tied to it rather than to this
# build's hash, so macOS still recognises the next update as the same app.
if $SIGNED && ! codesign -dr - "$APP_PATH" 2>&1 | grep -q 'certificate leaf'; then
    die "signed, but the designated requirement is not tied to \"$SIGNING_IDENTITY\"; permissions would not survive an update"
fi

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

# ─── Create the update archive ───────────────────────────────────────
# This is what the appcast points at. ditto preserves the framework version
# symlinks and the signature's extended attributes; `zip -r` does not, and the
# resulting archive fails Sparkle's signature check on arrival.
echo "==> Creating update archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)
ZIP_SIZE=$(du -h "$ZIP_PATH" | cut -f1 | xargs)
echo ""
echo "==> Done!"
echo "    $DMG_PATH ($DMG_SIZE) — drag $APP_NAME.app to Applications to install."
echo "    $ZIP_PATH ($ZIP_SIZE) — the archive Sparkle downloads."
