#!/usr/bin/env bash
# One-time move from the old Yaprflow build (com.teamwong.yaprflow) to
# Voiceling (com.teamwong.voiceling). Both apps are sandboxed, so Voiceling
# cannot read the old container itself; this script copies across:
#   - settings (UserDefaults; "yaprflow.*" keys renamed to "voiceling.*")
#   - History, Vocabulary, comparison log and imported sounds
#   - the downloaded Polish grammar model (APFS clone, no extra disk space)
# macOS privacy permissions cannot be copied and must be granted again.
#
# Usage: launch Voiceling once and quit it, quit Yaprflow, then run
#   scripts/migrate-from-yaprflow.sh
# The old Yaprflow data is left untouched. Anything already in Voiceling's
# container is backed up next to it before being replaced.

set -euo pipefail

OLD_ID="com.teamwong.yaprflow"
NEW_ID="com.teamwong.voiceling"
OLD="$HOME/Library/Containers/$OLD_ID/Data/Library"
NEW="$HOME/Library/Containers/$NEW_ID/Data/Library"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ ! -d "$OLD" ]; then
    echo "No Yaprflow data found at $OLD — nothing to migrate."
    exit 0
fi
if [ ! -d "$NEW" ]; then
    echo "❌ Voiceling has not run yet. Open Voiceling once, quit it, then run this again." >&2
    exit 1
fi
for app in yaprflow Voiceling; do
    if pgrep -x "$app" >/dev/null 2>&1; then
        echo "❌ $app is running. Quit it from the menu bar, then run this again." >&2
        exit 1
    fi
done

echo "==> Settings"
OLD_PREFS="$OLD/Preferences/$OLD_ID"
NEW_PREFS="$NEW/Preferences/$NEW_ID"
if [ -f "$OLD_PREFS.plist" ]; then
    if [ -f "$NEW_PREFS.plist" ]; then
        cp "$NEW_PREFS.plist" "$NEW_PREFS.pre-migration-$STAMP.plist"
    fi
    # `defaults export` emits an XML plist; string values are entity-escaped,
    # so only real <key> elements can match.
    defaults export "$OLD_PREFS" - \
        | sed 's|<key>yaprflow\.|<key>voiceling.|' \
        | defaults import "$NEW_PREFS" -
    echo "    $(defaults read "$NEW_PREFS" | grep -c '"voiceling\.') settings copied"
else
    echo "    none found"
fi

copy_dir() {  # copy_dir <source> <destination> <label>
    local src="$1" dest="$2" label="$3"
    if [ ! -d "$src" ]; then
        echo "    $label: none found"
        return
    fi
    if [ -e "$dest" ]; then
        mv "$dest" "$dest.pre-migration-$STAMP"
    fi
    mkdir -p "$(dirname "$dest")"
    cp -Rc "$src" "$dest"   # -c clones on APFS: instant, no duplicate disk use
    echo "    $label: copied"
}

echo "==> Data"
copy_dir "$OLD/Application Support/yaprflow" "$NEW/Application Support/Voiceling" "History, Vocabulary, sounds"
copy_dir "$OLD/Caches/$OLD_ID/models" "$NEW/Caches/$NEW_ID/models" "Polish grammar model"
copy_dir "$OLD/Application Support/FluidAudio" "$NEW/Application Support/FluidAudio" "Speech model cache"

cat <<'EOF'

✅ Migrated. Before opening Voiceling:
   1. Turn off Launch at Login in Yaprflow (or remove Yaprflow from
      System Settings → General → Login Items) so the two apps don't fight
      over the same shortcut.
   2. Open Voiceling and grant Microphone, Accessibility and Input Monitoring
      again when asked — macOS ties those to the app, not to your data.
EOF
