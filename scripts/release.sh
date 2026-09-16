#!/bin/bash
set -euo pipefail

# Cuts a release: bumps MARKETING_VERSION in every build configuration, commits
# that bump on its own, and tags it. Pushing the tag is what actually publishes
# — the release workflow builds the DMG from it — so that step stays manual
# unless --push is given.
#
# Usage: ./scripts/release.sh <version> [--push]
#        ./scripts/release.sh 1.0.2

source "$(dirname "$0")/lib.sh"

PBXPROJ="$PROJECT/project.pbxproj"

# ─── Arguments ────────────────────────────────────────────────────────
VERSION="${1:-}"
PUSH=false
[ "${2:-}" = "--push" ] && PUSH=true

[ -n "$VERSION" ] || die "usage: $(basename "$0") <version> [--push]   (e.g. 1.0.2)"

VERSION="${VERSION#v}"                      # tolerate a leading v
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version must be MAJOR.MINOR.PATCH, got '$VERSION'"

TAG="v$VERSION"

cd "$PROJECT_DIR"

# ─── Preflight ────────────────────────────────────────────────────────
[ -n "$(git status --porcelain)" ] && die "working tree is not clean; commit or stash first"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    && die "tag $TAG already exists"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "WARNING: releasing from '$BRANCH', not main."
    read -r -p "Continue? [y/N] " reply
    [ "$reply" = "y" ] || [ "$reply" = "Y" ] || die "aborted"
fi

# The release notes come from CHANGELOG.md, so a missing section is a release
# that would be published with nothing to read. Caught here rather than in CI,
# where the tag is already pushed and the failure is irreversible.
"$PROJECT_DIR/scripts/changelog-section.sh" "$VERSION" >/dev/null \
    || die "write the CHANGELOG.md entry for $VERSION first"

CURRENT="$(marketing_version)"
COUNT="$(grep -c 'MARKETING_VERSION' "$PBXPROJ")"
[ "$COUNT" -ge 1 ] || die "no MARKETING_VERSION found in project.pbxproj"

echo "==> $CURRENT -> $VERSION  ($COUNT build configuration(s))"

# ─── Bump every configuration ─────────────────────────────────────────
# Debug and Release each carry their own copy; they must not diverge, or a
# debug build would identify itself differently from the shipped one.
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/" "$PBXPROJ"

REMAINING="$(grep 'MARKETING_VERSION' "$PBXPROJ" | grep -vc "= $VERSION;" || true)"
[ "$REMAINING" -eq 0 ] || die "$REMAINING MARKETING_VERSION entries did not update; pbxproj left dirty for inspection"

plutil -lint "$PBXPROJ" >/dev/null || die "project.pbxproj is malformed after the bump"

# ─── Commit and tag ───────────────────────────────────────────────────
git add "$PBXPROJ"
git commit -q -m "chore(build): release $TAG"
git tag -a "$TAG" -m "OpenBeam $TAG"

echo "==> committed and tagged $TAG"

if $PUSH; then
    git push origin "$BRANCH"
    git push origin "$TAG"
    echo "==> pushed. The release workflow is building the DMG."
else
    echo ""
    echo "    Nothing has been published yet. To publish:"
    echo "      git push origin $BRANCH && git push origin $TAG"
    echo ""
    echo "    Pushing the tag triggers .github/workflows/release.yml, which builds"
    echo "    the DMG and creates the GitHub Release."
fi
