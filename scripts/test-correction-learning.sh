#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voiceling-correction-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc \
    -module-cache-path "$TEST_DIR/module-cache" \
    -parse-as-library \
    "$REPO_ROOT/Voiceling/CorrectionInference.swift" \
    "$REPO_ROOT/Voiceling/Vocabulary.swift" \
    "$REPO_ROOT/scripts/test-correction-learning.swift" \
    -o "$TEST_DIR/test-correction-learning"

"$TEST_DIR/test-correction-learning"
