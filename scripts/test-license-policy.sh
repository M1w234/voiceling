#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voiceling-license-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc \
    -module-cache-path "$TEST_DIR/module-cache" \
    -parse-as-library \
    "$REPO_ROOT/Voiceling/LicensePolicy.swift" \
    "$REPO_ROOT/scripts/test-license-policy.swift" \
    -o "$TEST_DIR/test-license-policy"

"$TEST_DIR/test-license-policy"
