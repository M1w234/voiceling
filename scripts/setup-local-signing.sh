#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate so dev builds
# have a stable code-directory signature. macOS TCC (Accessibility, mic, etc.)
# binds permission to that signature, so without a stable identity every
# ad-hoc rebuild invalidates the grant and the user has to re-approve.
#
# Idempotent — safe to re-run. Does NOT require sudo (cert lives in the user's
# login keychain).

set -euo pipefail

IDENTITY="Yaprflow Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Code-signing identity '$IDENTITY' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate…"

cat > "$TMP/req.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ext
[req_dn]
CN = $IDENTITY
[v3_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" \
    -out    "$TMP/cert.pem" \
    -config "$TMP/req.cnf"

# Bundle key + cert into PKCS#12 for keychain import. Explicitly request the
# legacy PBE algorithms and SHA-1 MAC — modern OpenSSL 3.x defaults to AES-256
# / SHA-256, which the macOS Security framework rejects during `security
# import` ("MAC verification failed"). A throwaway password keeps it simple;
# we tear the .p12 down right after import so it's not a real secret.
PKCS_PASS="yaprflow-setup"
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey  "$TMP/key.pem" \
    -in     "$TMP/cert.pem" \
    -name   "$IDENTITY" \
    -out    "$TMP/bundle.p12" \
    -password "pass:$PKCS_PASS"

echo "==> Importing into login keychain…"
security import "$TMP/bundle.p12" \
    -k "$KEYCHAIN" \
    -P "$PKCS_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A >/dev/null

# Mark the cert as trusted for code signing in the user's trust store.
# Without this, the identity exists in the keychain but `find-identity -v -p
# codesigning` reports CSSMERR_TP_NOT_TRUSTED and xcodebuild refuses to use
# it. User-only trust — no sudo, no system-wide effect.
echo "==> Adding code-signing trust…"
security add-trusted-cert \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$TMP/cert.pem" >/dev/null 2>&1 || {
        echo "⚠️  add-trusted-cert returned non-zero — may have prompted for keychain access."
        echo "    Re-run if the verification below fails."
    }

# Allow codesign and security to use the private key without prompting for
# keychain access on every build. The empty `-k ""` after `-s` means "use
# the keychain's existing password" (login keychain is unlocked at login).
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,security: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> Verifying…"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "❌ Identity import failed — '$IDENTITY' is not visible to codesign." >&2
    echo "    Current identities:" >&2
    security find-identity -p codesigning | head -20 >&2
    exit 1
fi

echo ""
echo "✅ '$IDENTITY' is set up."
echo ""
echo "Next:"
echo "  1. Run: ./scripts/dev-build.sh  (now signs with this identity)"
echo "  2. Reset stale TCC entry, then grant AX one more time:"
echo "       tccutil reset Accessibility com.teamwong.yaprflow"
echo "     → click Auto-Paste in the yaprflow menu, grant in System Settings."
echo "  3. Future rebuilds should keep the grant — same cert, same signature,"
echo "     same TCC requirement."
