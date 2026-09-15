#!/bin/bash
set -euo pipefail

# Signs the update archive and folds it into the appcast Sparkle reads.
#
# The work is done by Sparkle's own `generate_appcast`, which ships in the same
# SwiftPM artifact the app links against. Using it rather than writing the XML
# by hand is deliberate: it reads CFBundleVersion, CFBundleShortVersionString
# and LSMinimumSystemVersion out of the archive itself, so the feed cannot claim
# a version the bundle does not report, and it verifies the archive's code
# signature before advertising it.
#
# The private key arrives on stdin from $SPARKLE_PRIVATE_KEY — never as an
# argument, which `sign_update` and `generate_appcast` no longer accept for
# modern keys and which would leak the key into the process list besides.
#
# Usage: SPARKLE_PRIVATE_KEY=... ./scripts/make-appcast.sh <version>

source "$(dirname "$0")/lib.sh"

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: $(basename "$0") <version>"
VERSION="${VERSION#v}"
OUT_DIR="$BUILD_DIR/appcast"

[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || die "SPARKLE_PRIVATE_KEY is not set. It is the EdDSA private key exported by Sparkle's generate_keys -x; see CONTRIBUTING.md."

ZIP_PATH="$(zip_path "$VERSION")"
[ -f "$ZIP_PATH" ] || die "$ZIP_PATH not found — run ./scripts/build-dmg.sh first"

GENERATE_APPCAST="$(sparkle_tool generate_appcast)"
[ -n "$GENERATE_APPCAST" ] || die "generate_appcast not found. Resolve packages first: xcodebuild -resolvePackageDependencies -project OpenBeam.xcodeproj -scheme OpenBeam -derivedDataPath .derived"

# ─── Assemble the input directory ─────────────────────────────────────
# generate_appcast works on a directory of archives and merges into any
# appcast.xml it finds there. The published feed is pulled in first so that
# releases it already advertises survive: CI keeps no state between runs, and a
# feed that forgot its history would strand anyone who skipped a version.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$ZIP_PATH" "$OUT_DIR/"

# A 404 means there is genuinely no feed yet; anything else — a Pages hiccup, a
# DNS blip — must not be mistaken for one, because merging into "nothing" quietly
# drops every release already advertised and strands anyone who skipped a version.
HTTP_CODE=$(curl -sS -o "$OUT_DIR/appcast.xml" -w '%{http_code}' "$SITE_URL/appcast.xml" || echo "000")
case "$HTTP_CODE" in
    200) echo "==> Merging into the published appcast ($(grep -c '<item>' "$OUT_DIR/appcast.xml" || echo 0) existing items)" ;;
    404) rm -f "$OUT_DIR/appcast.xml"; echo "==> No published appcast yet; starting a new one" ;;
    *)   rm -f "$OUT_DIR/appcast.xml"
         die "could not read $SITE_URL/appcast.xml (HTTP $HTTP_CODE). Refusing to publish a feed that would drop every existing release." ;;
esac

# ─── Sign and generate ────────────────────────────────────────────────
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    --link "$SITE_URL" \
    --maximum-versions 0 \
    "$OUT_DIR"

[ -f "$OUT_DIR/appcast.xml" ] || die "generate_appcast produced no appcast.xml"

grep -q "$APP_NAME-$VERSION.zip" "$OUT_DIR/appcast.xml" \
    || die "appcast.xml does not mention $APP_NAME-$VERSION.zip — the release would advertise nothing"

echo "==> Appcast written to $OUT_DIR/appcast.xml"
grep -o 'sparkle:version="[^"]*"' "$OUT_DIR/appcast.xml" | sed 's/^/    /'
