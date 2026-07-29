# yaprflow — Setup

**yaprflow** is a privacy-first, on-device dictation app for macOS. Hold a
hotkey, talk, and your words are transcribed and pasted — entirely locally,
nothing sent to the cloud.

**Compatibility:** Apple-silicon Mac (M1 or newer) running macOS 14 Sonoma or
later. This build does not run on Intel Macs.

---

## Easiest install

Download `yaprflow-team-install.zip` from the
[latest release](https://github.com/M1w234/yaprflow-mw/releases/latest), unzip
it, and double-click **Install yaprflow.command**. Then continue at Step 2 below
for the one-time macOS permissions.

## Install it with Claude Code (or Codex)

Open Claude Code (or Codex) anywhere, and say:

> Read SETUP.md from https://github.com/M1w234/yaprflow-mw and set up yaprflow on my Mac — do the command-line steps for me and walk me through the permission clicks. Adapt to whatever macOS shows.

The agent then follows the steps below. (You can also just do them yourself.)

---

## Steps

**Agent: run the shell steps for the user; guide them through the clicks they must do themselves. This is a real, self-contained app — the ~450 MB speech model is bundled, so there's no separate model download and it runs offline.**

### 0. Download the prebuilt app
No building required — grab the ready-to-run app from the latest release:
```bash
cd ~/Downloads
curl -L -o yaprflow-team-install.zip \
  https://github.com/M1w234/yaprflow-mw/releases/latest/download/yaprflow-team-install.zip
rm -rf yaprflow-team-install
unzip -o yaprflow-team-install.zip
cd yaprflow-team-install
```

### 1. Install and clear the download quarantine
```bash
osascript -e 'tell application "yaprflow" to quit' 2>/dev/null || true
rm -rf /Applications/yaprflow.app
cp -R yaprflow.app /Applications/
# yaprflow isn't from the App Store, so macOS quarantines it. This clears that:
xattr -dr com.apple.quarantine /Applications/yaprflow.app
open /Applications/yaprflow.app
```

### 2. If macOS says it "can't be opened" / "cannot check for malicious software"
Expected — the app isn't notarized by Apple (it's a personal team build, not from the App Store). It's safe; it just isn't signed by a paid Apple developer account.
- **Fix:** open **System Settings → Privacy & Security**, scroll to the bottom, click **"Open Anyway"** next to the yaprflow message, confirm.
- If there's no "Open Anyway" button, re-run the `xattr -dr com.apple.quarantine …` line, then `open` it again.

### 3. Grant Microphone access
- The first time you start a recording, macOS asks → click **Allow**.
- Or manually: **System Settings → Privacy & Security → Microphone → turn on yaprflow.**

### 4. Grant Accessibility access (required for the hotkey + auto-paste)
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```
- If **yaprflow** is listed, turn it **on**. If not, click **➕**, choose **Applications → yaprflow**, turn it on.
- The hotkey comes alive within a few seconds — no restart needed.

### 5. Use it
- **Hold ⌥⇧ (Option+Shift) and talk**, then release → your words paste in.
- Or **double-tap ⌥⇧** to lock recording on; tap again to stop.
- A first-launch welcome window covers a couple of options (streaming, grammar, auto-paste). Defaults are fine.

### 6. Optional — use the Globe 🌐 key instead (MacBook laptops only)

**Agent: ask first — "Are you on a MacBook laptop, and would you rather use the 🌐 (Globe/Fn) key at the bottom-left as your dictation key instead of ⌥⇧?" If no, or they're on a desktop / external keyboard with no Globe key, SKIP this step — you're done.**

If yes, free the Globe key from its default job first (on most Macs it opens the Emoji picker, which would fight the paste):

1. Open Keyboard settings and set **"Press 🌐 key to" → "Do Nothing"** (applies immediately):
   ```bash
   open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
   ```
   While there, if macOS **Dictation** is on and bound to the Globe key, turn it off (Keyboard → Dictation) so it doesn't collide.
2. Point yaprflow at it: open the yaprflow menu (search "yaprflow" in Spotlight → Enter — the menu pops up at your cursor), click **Shortcut**, then **press 🌐 twice** to set it.
3. Test: hold 🌐 and talk — no emoji picker should appear.

---

## Common issues (agent: adapt to whichever applies)

- **Can't find the menu-bar icon** (common on notched laptops — it overflows and hides): you don't need it to dictate, but to open the menu, **search "yaprflow" in Spotlight → Enter** and it pops up at your cursor. Or ⌘-drag menu-bar icons to make room.
- **Hotkey does nothing:** almost always Accessibility (Step 4) isn't granted. Grant it, wait ~5s.
- **App will not open on an Intel Mac:** this build requires Apple silicon (M1 or newer).
- **No text / nothing transcribed:** check Microphone (Step 3). The very first recording after install can take ~30s while the model warms up (one-time).
- **Is my voice going to the cloud?** No — transcription runs entirely on your Mac; the model is bundled in the app.
- **Change settings/hotkey/sounds later:** open the menu (icon or the Spotlight trick) — shortcut, dictation mode, grammar, auto-paste, sounds, clipboard history (⌃⌥V), and personal vocabulary are all there.
