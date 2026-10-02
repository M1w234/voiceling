#!/bin/bash
# Legacy self-signed installer. Prefer the notarized GitHub Release DMG.
# Friend-facing installer bundled by create-team-install.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/Voiceling.app"
DEST_APP="/Applications/Voiceling.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Voiceling.app is not next to this installer."
    read -n 1 -s -r -p "Press any key to close."
    exit 1
fi

echo "Installing Voiceling…"
osascript -e 'tell application "Voiceling" to quit' 2>/dev/null || true
for _ in {1..20}; do
    if ! pgrep -x Voiceling >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
if pgrep -x Voiceling >/dev/null 2>&1; then
    echo "Voiceling is still running. Quit it from the menu bar, then run this installer again."
    read -n 1 -s -r -p "Press any key to close."
    exit 1
fi

rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
open "$DEST_APP"

cat <<'EOF'

Installed Voiceling.

Two one-time permissions are still required:
  1. Microphone: allow it when macOS asks.
  2. Accessibility: System Settings → Privacy & Security → Accessibility,
     then enable Voiceling. This powers the default hotkey and auto-paste.

Use it: hold Option+Shift and talk, then release.
See INSTALL.md in this folder for troubleshooting.
EOF

read -n 1 -s -r -p "Press any key to close this window."
echo
