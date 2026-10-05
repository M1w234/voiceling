# Voiceling — Local Dictation App

Local-first macOS menubar dictation app, part of the Deskling family. Originally forked from Yaprflow at its Apache-2.0 revision `3418f91` (see `NOTICE`); not affiliated with Yaprflow. Do not pull from or push to the Yaprflow repository — its later code is under a noncommercial license, and the name and icon are its owner's trademarks. Local STT via Parakeet TDT 0.6B v2 on MLX. Swift / AppKit / Carbon hotkey API.

## Quick Status

| Thing | Where |
|-------|-------|
| Source | `~/deskling/voiceling/` (this repo) |
| Built app | `~/deskling/voiceling/build.noindex/Build/Products/Release/Voiceling.app` |
| Installed app | `/Applications/Voiceling.app` |
| Bundle ID | `com.teamwong.voiceling` |
| Saved hotkey config | `~/Library/Containers/com.teamwong.voiceling/Data/Library/Preferences/com.teamwong.voiceling.plist` |
| Speech models | `~/deskling/voiceling/Models/parakeet-tdt-0.6b-v2/` plus `Models/silero-vad/` (gitignored) |
| Signing | Developer ID for releases; local self-signed identity for dev builds. |
| Friend build | Notarized `build/Voiceling.dmg` via `scripts/release.sh` |

## Rebuild Loop (after editing source)

One command:

```bash
cd ~/deskling/voiceling && ./scripts/dev-build.sh
```

Quits running Voiceling, builds Release, applies the stable local signing identity
when available, replaces `/Applications/Voiceling.app`, strips quarantine, and
relaunches. First build ~3 min; incremental builds ~30 sec.

Manual equivalent:
```bash
xcodebuild -project Voiceling.xcodeproj -scheme Voiceling -configuration Release \
  -derivedDataPath build.noindex CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
osascript -e 'tell application "Voiceling" to quit'
rm -rf /Applications/Voiceling.app
cp -R build.noindex/Build/Products/Release/Voiceling.app /Applications/
xattr -dr com.apple.quarantine /Applications/Voiceling.app
open /Applications/Voiceling.app
```

## Architecture (the parts that matter)

- **Sandboxed** (`Voiceling/Voiceling.entitlements`): app-sandbox + audio-input + network.client. Affects what hotkey APIs are usable.
- **Hotkeys**: key-based shortcuts use Carbon `RegisterEventHotKey` via
  `GlobalHotkey.swift`. Modifier-only shortcuts use a listen-only `CGEventTap`
  in `ModifierOnlyHotkey.swift` and require both Accessibility and Input
  Monitoring permission.
- **Synchronized file groups**: `Voiceling.xcodeproj` uses Xcode 16 `PBXFileSystemSynchronizedRootGroup` — new `.swift` files in `Voiceling/` are auto-picked-up by the project. No `.pbxproj` editing.
- **Speech pipeline**: `TranscriptionController` → `AudioCapture` → VAD (`FluidAudio`) → Parakeet ASR (MLX/CoreML mlmodelc bundles in `Models/`). Final text → clipboard.
- **Grammar mode (optional)**: `GrammarController` runs a small MLX LLM on the transcript before pasting.
- **Menu**: `AppDelegate.installStatusItem()` builds menu from custom NSView-based items (`HotkeyMenuItemView`, `HotkeyModeMenuItemView`, `StreamingModeMenuItemView`, etc.). All toggle-style items follow the same NSView pattern.

## Changes Since the Fork Point (`3418f91`)

| File | Change |
|------|--------|
| `HotkeyConfig.swift` | Added `HotkeyMode` enum (`tapToToggle` \| `holdToTalk`), back-compat `decodeIfPresent` for the `mode` field. Added F13–F19, arrow, Page/Home/End labels in `displayString`. |
| `GlobalHotkey.swift` | Installed `kEventHotKeyReleased` handler alongside the existing pressed handler. `onFire` → `onPressed` + `onReleased`. |
| `TranscriptionController.swift` | Added `desiredActive` flag + `setActive(_:)` method. Race-safe push-to-talk: `start()` re-checks `desiredActive` after each `await` and bails if user already released. |
| `AppDelegate.swift` | `wireHotkeyCallbacks(for:)` dispatches based on `config.mode`. Re-wires on `voicelingHotkeyChanged`. |
| `HotkeyMenuItemView.swift` | Removed "must have a modifier" guard so picker accepts F-keys, Space, etc. Mode preserved when re-recording. |
| `HotkeyModeMenuItemView.swift` (new) | Toggle row in menu: "Tap to Toggle" ↔ "Hold to Talk". |
| `ExternalHotkey.swift` / `ExternalHotkeyMenuItemView.swift` | Optional independent key-based trigger for programmable mice, with separate enable, shortcut, trigger-mode, and preserved primary-shortcut pause controls. |
| `ModifierOnlyHotkey.swift` | Side-aware modifier-only hold-to-talk plus double-tap-to-lock, with false-trigger rejection, Accessibility retry, and a 10-minute safety stop. |
| `Vocabulary.swift` | Deterministic personal-vocabulary replacements and built-in proper-noun casing. |
| `TextInsertion.swift` / history files | Clipboard-preserving insertion, dictation history, and guarded delivery to the original target app. |

## Advanced Hotkey Safety

Modifier-only hold and double-tap are implemented. Preserve these invariants
when changing them:

- Require Accessibility and Input Monitoring, distinguish their guidance, and
  retry event-tap installation after the user grants them.
- Ignore a tap when any non-modifier keyDown or extra modifier intervenes.
- Preserve side-aware matching so ordinary shortcuts on the other keyboard side
  do not trigger dictation.
- Keep the max recording duration and Esc/on-screen cancel fallbacks.
- Do not allow a single standard modifier as the trigger. Globe/Fn is the
  deliberate exception.
- Never leave both user-facing trigger paths disabled. If the external shortcut
  is turned off, conflicts, or fails registration while the primary shortcut is
  paused, reactivate the saved primary shortcut automatically.

## Constraints / Gotchas

- **Developer ID release identity** — releases use Michael's Team Wong
  Developer ID Application certificate (`QFHS76RR9M`). Xcode can submit an
  archive interactively; future headless releases also require the one-time
  `notary-yaprflow-mw` Keychain profile. Keep app-specific passwords and API
  keys out of the repository.
- **Apple silicon only** — the MLX dependencies and distributed executable
  target arm64. Friend-facing docs must say M1 or newer and macOS 14+.
- **Metal Toolchain** — Xcode 16+ ships without it by default. If a fresh Xcode install fails the first build with `cannot execute tool 'metal'`, run `xcodebuild -downloadComponent MetalToolchain` (~700 MB one-time).
- **Models** — the Parakeet ASR and Silero VAD models under `~/deskling/voiceling/Models/`
  must exist before a fully offline build. `scripts/fetch-models.sh` downloads
  both with `huggingface-cli` and
  deliberately rejects the unrelated Higgsfield executable that also uses the
  name `hf`. Manual equivalent:
  ```bash
  HF_HUB_DISABLE_XET=1 huggingface-cli download FluidInference/parakeet-tdt-0.6b-v2-coreml \
    --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
    --local-dir ~/deskling/voiceling/Models/parakeet-tdt-0.6b-v2
  ```
- **First recording delay** — ~30s on a cold launch while the Parakeet Encoder compiles. `TranscriptionController.preload()` runs at launch to warm this in the background.
- **Mic permission** — granted in System Settings → Privacy → Microphone
  (Voiceling). The Team Wong bundle ID is stable across signed releases.

## Common Tasks

- **"Add a new hotkey mode / trigger"** — touch `HotkeyMode` enum +
  `GlobalHotkey`/`ModifierOnlyHotkey` callbacks +
  `AppDelegate.wireHotkeyCallbacks` + add a UI affordance. Re-read the advanced
  hotkey safety section first.
- **"Publish a friend build"** — bump `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION`, then run `scripts/release.sh <version> --publish`.
  The release path signs, notarizes, staples, and Gatekeeper-checks the DMG
  before publishing it.
- **"Improve the menu UI"** — copy the `StreamingModeMenuItemView` / `HotkeyModeMenuItemView` pattern. Custom NSView, layout in `setupLayout()`, refresh on Combine subscription, mutate AppState on `mouseDown`.
- **"Bump the speech model"** — update `scripts/fetch-models.sh` (or just download manually) + the `Models/` Copy Models phase reference in the .pbxproj.

## Don't Bother

- Adding `NSAccessibilityUsageDescription` to Info.plist — that's a microphone-style usage string and isn't the right key for AX prompts (per Codex review).
- Removing the Accessibility gate from modifier-only hotkeys. The listen-only
  `CGEventTap` requires the user's explicit TCC grant.
- Looking for a build cache shortcut — `xcodebuild` already caches SPM packages, MLX, etc. in `build.noindex/SourcePackages/`. Don't `git clean -fdx` that dir unless you want a fresh ~3 min build.
