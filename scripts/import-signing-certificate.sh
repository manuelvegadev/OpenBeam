#!/bin/bash
set -euo pipefail

# Puts OpenBeam's code signing certificate where codesign and Xcode find it:
# a keychain of its own, unlocked, first on the search list. For CI, where the
# certificate arrives as two secrets; on a Mac that already has it in its login
# keychain there is nothing to do.
#
#   SIGNING_CERTIFICATE_P12        the .p12, base64-encoded
#   SIGNING_CERTIFICATE_PASSWORD   its password
#
# The certificate is self-signed and not trusted by anything, which codesign
# does not mind: what it needs is a private key it can reach without a prompt.

source "$(dirname "$0")/lib.sh"

: "${SIGNING_CERTIFICATE_P12:?set SIGNING_CERTIFICATE_P12 to the base64 of the .p12}"
: "${SIGNING_CERTIFICATE_PASSWORD:?set SIGNING_CERTIFICATE_PASSWORD}"

KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openbeam-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12="$(mktemp)"
trap 'rm -f "$P12"' EXIT

printf '%s' "$SIGNING_CERTIFICATE_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"   # stays unlocked for the whole job
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -f pkcs12 -k "$KEYCHAIN" -P "$SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
# Without this, the first use of the key waits on a "codesign wants to use
# your key" dialog that nobody on a CI runner will ever click.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# shellcheck disable=SC2046  # the existing keychains are one path per line, no spaces
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$SIGNING_IDENTITY\"" \
    || die "the imported certificate is not \"$SIGNING_IDENTITY\""
echo "==> \"$SIGNING_IDENTITY\" ready in $KEYCHAIN"
