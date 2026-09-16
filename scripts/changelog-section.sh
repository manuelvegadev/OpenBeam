#!/bin/bash
set -euo pipefail

# Prints one version's section of CHANGELOG.md, without its heading.
#
# The release notes on GitHub are a copy of that section rather than a second,
# different text: a release page only exists inside GitHub, while the file
# travels with the repository and with the source tarball. Generated notes were
# what this replaced — they list commit subjects, including the `chore(build)`
# bump and every refactor, which is noise to someone deciding whether to update.
#
# Usage: ./scripts/changelog-section.sh 2.4.0

source "$(dirname "$0")/lib.sh"

VERSION="${1:-}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || die "usage: $(basename "$0") <version>   (e.g. 2.4.0)"

CHANGELOG="$PROJECT_DIR/CHANGELOG.md"
[ -f "$CHANGELOG" ] || die "no CHANGELOG.md at $CHANGELOG"

# From the heading for this version to whatever ends it — the next version, or
# the block of compare links at the foot of the file for the oldest one — then
# the blank lines that leaves at either end.
SECTION="$(awk -v version="## [$VERSION]" '
    index($0, version) == 1 { found = 1; next }
    found && (/^## / || /^\[[^]]+\]: /) { exit }
    found { print }
' "$CHANGELOG")"

SECTION="$(printf '%s' "$SECTION" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba')"

[ -n "$SECTION" ] || die "CHANGELOG.md has no entry for $VERSION; write one before releasing"

printf '%s\n' "$SECTION"
