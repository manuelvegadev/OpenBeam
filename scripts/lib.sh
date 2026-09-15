#!/bin/bash
# Shared by build-dmg.sh, make-appcast.sh and release.sh.
#
# These values are the seams between the three scripts: build-dmg.sh writes the
# archive make-appcast.sh signs, and both look for Sparkle's tools in the same
# resolved-packages directory. Spelled once, they cannot drift apart into the
# kind of failure where one script reports a missing file and the other reports
# that packages need resolving — which is the same mistake wearing two hats.

APP_NAME="OpenBeam"
REPO="manuelvegadev/OpenBeam"
SITE_URL="https://manuelvegadev.github.io/OpenBeam"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$PROJECT_DIR/OpenBeam.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
# Outside BUILD_DIR, which is deleted on every run: keeping it there would make
# CI re-download Sparkle's 10 MB artifact for every single build.
DERIVED_DATA="$PROJECT_DIR/.derived"

die() { echo "ERROR: $*" >&2; exit 1; }

# The version the project reports about itself.
marketing_version() {
    grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed 's/.*= *\(.*\);/\1/' | xargs
}

# The update archive for a version. Both scripts derive the name from here
# rather than each spelling out the same formula.
zip_path() { echo "$BUILD_DIR/$APP_NAME-$1.zip"; }

# Sparkle ships its tools inside the resolved SwiftPM artifact. The path within
# it has moved between Xcode releases, so it is found rather than spelled out.
sparkle_tool() {
    find "$DERIVED_DATA/SourcePackages/artifacts" -type f -perm -111 -name "$1" 2>/dev/null | head -1
}
