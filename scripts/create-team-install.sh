#!/usr/bin/env bash
# Legacy self-signed installer. Prefer scripts/release.sh for friend releases.
# Validate and package the self-contained friend build used by older releases.
#
# Usage:
#   scripts/create-team-install.sh [path-to-Voiceling.app] [output-directory]
#
# The app must already be built and signed. `scripts/dev-build.sh` produces a
# suitable local build. This script deliberately fails if the app's embedded
# version does not match the Xcode project, preventing a stale binary from being
# uploaded under a newer tag.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build.noindex/Build/Products/Release/Voiceling.app}"
OUTPUT_DIR="${2:-$ROOT/build/team-install}"
STAGING_DIR="$OUTPUT_DIR/voiceling-team-install"
ZIP_PATH="$OUTPUT_DIR/voiceling-team-install.zip"

if [[ ! -d "$APP" ]]; then
    echo "error: app not found: $APP" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PROJECT_VERSION="$(
    xcodebuild -project "$ROOT/Voiceling.xcodeproj" -scheme Voiceling \
        -configuration Release -showBuildSettings 2>/dev/null |
        awk -F' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }'
)"

if [[ -z "$PROJECT_VERSION" || "$APP_VERSION" != "$PROJECT_VERSION" ]]; then
    echo "error: app version '$APP_VERSION' does not match project version '${PROJECT_VERSION:-unknown}'" >&2
    exit 1
fi

EXECUTABLE="$APP/Contents/MacOS/Voiceling"
if ! file "$EXECUTABLE" | grep -q 'arm64'; then
    echo "error: app executable does not contain arm64: $EXECUTABLE" >&2
    exit 1
fi

MODEL_DIR="$APP/Contents/Resources/Models/parakeet-tdt-0.6b-v2"
VAD_MODEL="$APP/Contents/Resources/Models/silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc"
for required in \
    "$MODEL_DIR/parakeet_vocab.json" \
    "$MODEL_DIR/Preprocessor.mlmodelc/model.mil" \
    "$MODEL_DIR/Encoder.mlmodelc/model.mil" \
    "$MODEL_DIR/Encoder.mlmodelc/weights/weight.bin" \
    "$MODEL_DIR/Decoder.mlmodelc/model.mil" \
    "$MODEL_DIR/JointDecision.mlmodelc/model.mil"; do
    if [[ ! -f "$required" ]]; then
        echo "error: bundled speech model is incomplete; missing $required" >&2
        exit 1
    fi
done
ENCODER_WEIGHT="$MODEL_DIR/Encoder.mlmodelc/weights/weight.bin"
ENCODER_WEIGHT_SIZE="$(stat -f '%z' "$ENCODER_WEIGHT")"
if (( ENCODER_WEIGHT_SIZE <= 100000000 )); then
    echo "error: bundled encoder weight is truncated ($ENCODER_WEIGHT_SIZE bytes)" >&2
    exit 1
fi
if [[ ! -f "$VAD_MODEL/model.mil" ]]; then
    echo "error: bundled voice-detection model is missing: $VAD_MODEL" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"

rm -rf "$STAGING_DIR"
rm -f "$ZIP_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP" "$STAGING_DIR/Voiceling.app"
cp "$ROOT/SETUP.md" "$STAGING_DIR/INSTALL.md"
cp "$ROOT/scripts/install-team-build.command" "$STAGING_DIR/Install Voiceling.command"
chmod +x "$STAGING_DIR/Install Voiceling.command"

ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR" "$ZIP_PATH"

echo "Created Voiceling $APP_VERSION friend build:"
du -sh "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
