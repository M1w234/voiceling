#!/usr/bin/env bash
# Create a code-signed DMG without submitting it for notarization.
# Usage: scripts/create-release-dmg.sh <path-to-app> [output-dmg]

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-app> [output-dmg]"
    echo "Example: $0 /path/to/Voiceling.app"
    exit 1
fi

APP="$1"
DMG="${2:-$(pwd)/Voiceling.dmg}"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-17530C078CB507252BC9CB8EEAA9143310583C56}"

if [ ! -d "$APP" ]; then
    echo "Error: .app not found: $APP"
    exit 1
fi

echo "==> Staging app..."
STAGE="$(mktemp -d -t voiceling-dmg.XXXXXX)"
RW_DMG="$STAGE/voiceling-rw.dmg"
MOUNT_DIR="$STAGE/mnt"
mkdir -p "$MOUNT_DIR"
trap '
    if mount | grep -q "$MOUNT_DIR"; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
    rm -rf "$STAGE"
' EXIT

ditto "$APP" "$STAGE/Voiceling.app"
SIZE_MB=$(( $(du -sm "$STAGE/Voiceling.app" | awk '{print $1}') + 50 ))

echo "==> Creating ${SIZE_MB}MB read-write DMG..."
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname Voiceling -ov "$RW_DMG"

echo "==> Attaching..."
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen

echo "==> Copying app into DMG..."
ditto "$STAGE/Voiceling.app" "$MOUNT_DIR/Voiceling.app"

echo "==> Adding /Applications shortcut..."
ln -s /Applications "$MOUNT_DIR/Applications"

echo "==> Detaching..."
hdiutil detach "$MOUNT_DIR" -quiet

echo "==> Converting to compressed read-only DMG..."
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo ""
echo "Done: $DMG"
du -sh "$DMG"
