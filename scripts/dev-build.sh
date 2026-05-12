#!/usr/bin/env bash
# Local dev build + install. Ad-hoc signed, replaces /Applications/yaprflow.app,
# strips Gatekeeper quarantine, relaunches. For when you're iterating on source.
# For a Developer ID release build, use scripts/release.sh instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Release/yaprflow.app"
DEST="/Applications/yaprflow.app"

cd "$ROOT"

if [ ! -d "$ROOT/Models/parakeet-tdt-0.6b-v2/Encoder.mlmodelc" ]; then
    echo "❌ Speech model missing. See CLAUDE.md → Constraints / Gotchas for the download command." >&2
    exit 1
fi

# Detect whether the local self-signed identity is set up. We can't pass it
# straight to xcodebuild — SPM packages without a development team blow up
# when CODE_SIGNING_ALLOWED=YES. Instead we build everything unsigned (same
# as before) and re-sign just the final .app afterwards with `codesign`,
# which only touches our bundle.
LOCAL_SIGN_IDENTITY="Yaprflow Local Dev"
HAS_LOCAL_SIGN_IDENTITY=false
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_SIGN_IDENTITY"; then
    HAS_LOCAL_SIGN_IDENTITY=true
    echo "==> Building yaprflow (Release; will re-sign with '$LOCAL_SIGN_IDENTITY')…"
else
    echo "==> Building yaprflow (Release, ad-hoc)…"
    echo "    Run ./scripts/setup-local-signing.sh once to get stable AX permissions."
fi

xcodebuild \
    -project yaprflow.xcodeproj \
    -scheme yaprflow \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

if [ ! -d "$APP" ]; then
    echo "❌ Build succeeded but .app not found at $APP" >&2
    exit 1
fi

# Re-sign the .app with the stable local identity if available. Doing this
# AFTER the build (instead of via xcodebuild) so SPM dependencies stay
# unsigned and we only stamp our own bundle. Entitlements have to be re-
# applied explicitly because the unsigned build doesn't embed them.
if [ "$HAS_LOCAL_SIGN_IDENTITY" = true ]; then
    echo "==> Re-signing .app with '$LOCAL_SIGN_IDENTITY'…"
    codesign --force --deep --options runtime \
        --sign "$LOCAL_SIGN_IDENTITY" \
        --entitlements "$ROOT/yaprflow/yaprflow.entitlements" \
        "$APP"
fi

echo "==> Quitting running yaprflow…"
osascript -e 'tell application "yaprflow" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Launching…"
open "$DEST"

echo ""
echo "✅ Done. Look for the waveform icon in the menu bar."
