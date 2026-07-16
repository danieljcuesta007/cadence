#!/bin/zsh
# One-time: create a stable self-signed code-signing identity ("Cadence Dev Signing")
# in a dedicated keychain, so Cadence.app's designated requirement pins the CERTIFICATE
# instead of each build's hash — TCC grants (mic, Accessibility, Input Monitoring) then
# survive rebuilds. Ad-hoc signing resets them on every build (bit us live, 2026-07-16).
#
# The dedicated keychain uses a fixed password: it guards a local self-signed dev key
# with no external trust, and a known password is what makes signing scriptable
# (set-key-partition-list pre-authorizes codesign, so no GUI prompts per build).
# Idempotent: safe to re-run; does nothing if the identity already exists.
set -euo pipefail

IDENTITY="Cadence Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/cadence-signing.keychain-db"
KC_PASS="cadence-signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "identity already present: $IDENTITY"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 10-year self-signed cert with the codeSigning EKU (required for a signing identity).
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl pkcs12 -export -out "$WORK/identity.p12" -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" -passout "pass:$KC_PASS"

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KC_PASS" "$KEYCHAIN"
fi
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign
# Pre-authorize codesign for the key (no per-build GUI prompt).
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "$KC_PASS" \
    "$KEYCHAIN" > /dev/null

# Keep the login keychain first in the search list; append ours.
EXISTING=$(security list-keychains -d user | tr -d '" ')
security list-keychains -d user -s ${(f)EXISTING} "$KEYCHAIN"

# Trust the cert for code signing (user trust domain — no admin needed). This one step
# may show a system dialog asking for the LOGIN password: that's macOS confirming the
# trust-settings change, expected on first run only.
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" \
    || security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem"

echo "created identity: $IDENTITY (keychain: $KEYCHAIN)"
security find-identity -v -p codesigning | grep "$IDENTITY" || {
    echo "WARNING: identity not yet valid for codesigning — trust step may need the GUI" >&2
    exit 1
}
