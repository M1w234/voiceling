# yaprflow — Local Dictation App (Patched Fork)

Local-first macOS menubar dictation app. Cloned from [tmoreton/yaprflow](https://github.com/tmoreton/yaprflow) (Apache-2.0) and patched with new push-to-talk modes. Local STT via Parakeet TDT 0.6B v2 on MLX. Swift / AppKit / Carbon hotkey API.

## Quick Status

| Thing | Where |
|-------|-------|
| Source | `~/yaprflow/` (this repo) |
| Built app | `~/yaprflow/build/Build/Products/Release/yaprflow.app` |
| Installed app | `/Applications/yaprflow.app` |
| Bundle ID | `com.tmoreton.yaprflow` (unchanged from upstream) |
| Saved hotkey config | `~/Library/Containers/com.tmoreton.yaprflow/Data/Library/Preferences/com.tmoreton.yaprflow.plist` |
| Speech model | `~/yaprflow/Models/parakeet-tdt-0.6b-v2/` (456 MB, gitignored) |
| Signing | Ad-hoc (no Tim's Developer ID cert). Gatekeeper quarantine stripped on install. |

## Rebuild Loop (after editing source)

One command:

```bash
cd ~/yaprflow && ./scripts/dev-build.sh
```

Quits running yaprflow, builds Release with ad-hoc signing, replaces `/Applications/yaprflow.app`, strips quarantine, relaunches. First build ~3 min; incremental builds ~30 sec.

Manual equivalent:
```bash
xcodebuild -project yaprflow.xcodeproj -scheme yaprflow -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
osascript -e 'tell application "yaprflow" to quit'
rm -rf /Applications/yaprflow.app
cp -R build/Build/Products/Release/yaprflow.app /Applications/
xattr -dr com.apple.quarantine /Applications/yaprflow.app
open /Applications/yaprflow.app
```

## Architecture (the parts that matter)

- **Sandboxed** (`yaprflow/yaprflow.entitlements`): app-sandbox + audio-input + network.client. Affects what hotkey APIs are usable.
- **Hotkey**: Carbon `RegisterEventHotKey` via `GlobalHotkey.swift`. Sandbox-safe. Supports chord press+release events (which we use for push-to-talk).
- **Synchronized file groups**: `yaprflow.xcodeproj` uses Xcode 16 `PBXFileSystemSynchronizedRootGroup` — new `.swift` files in `yaprflow/` are auto-picked-up by the project. No `.pbxproj` editing.
- **Speech pipeline**: `TranscriptionController` → `AudioCapture` → VAD (`FluidAudio`) → Parakeet ASR (MLX/CoreML mlmodelc bundles in `Models/`). Final text → clipboard.
- **Grammar mode (optional)**: `GrammarController` runs a small MLX LLM on the transcript before pasting.
- **Menu**: `AppDelegate.installStatusItem()` builds menu from custom NSView-based items (`HotkeyMenuItemView`, `HotkeyModeMenuItemView`, `StreamingModeMenuItemView`, etc.). All toggle-style items follow the same NSView pattern.

## Patches Applied (vs. upstream tmoreton/yaprflow)

| File | Change |
|------|--------|
| `HotkeyConfig.swift` | Added `HotkeyMode` enum (`tapToToggle` \| `holdToTalk`), back-compat `decodeIfPresent` for the `mode` field. Added F13–F19, arrow, Page/Home/End labels in `displayString`. |
| `GlobalHotkey.swift` | Installed `kEventHotKeyReleased` handler alongside the existing pressed handler. `onFire` → `onPressed` + `onReleased`. |
| `TranscriptionController.swift` | Added `desiredActive` flag + `setActive(_:)` method. Race-safe push-to-talk: `start()` re-checks `desiredActive` after each `await` and bails if user already released. |
| `AppDelegate.swift` | `wireHotkeyCallbacks(for:)` dispatches based on `config.mode`. Re-wires on `yaprflowHotkeyChanged`. |
| `HotkeyMenuItemView.swift` | Removed "must have a modifier" guard so picker accepts F-keys, Space, etc. Mode preserved when re-recording. |
| `HotkeyModeMenuItemView.swift` (new) | Toggle row in menu: "Tap to Toggle" ↔ "Hold to Talk". |

## Deferred Work (Layer 2)

After [Codex adversarial review](https://github.com/codex-ai) we deferred two features:

1. **Modifier-only trigger** (e.g. hold ⌘⇧ alone with no key). Needs `NSEvent.addGlobalMonitorForEvents(.flagsChanged)` which requires Accessibility permission via TCC. Also collides with every existing system shortcut that uses the same modifiers (⌘⇧4 screenshot etc.).
2. **Double-tap modifier to toggle**. Same Accessibility requirement + needs a state machine that watches `.keyDown` between modifier transitions to reject false positives (tap ⌘ then press ⌘C looks like a double-tap).

If we revisit, do it as a separate `.modifierHold` and `.modifierDoubleTap` mode behind an "Advanced" warning, with:
- AX prompt + re-check on app activation
- State machine: ignore taps if any non-modifier keyDown intervenes
- Max recording duration safety + manual "Stop" fallback
- Don't allow single ⌘ or single ⇧ as the trigger

## Constraints / Gotchas

- **No Developer ID cert** — must build with `CODE_SIGN_IDENTITY=-`. App runs locally but can't be distributed. Don't try to notarize or use `scripts/release.sh`.
- **Metal Toolchain** — Xcode 16+ ships without it by default. If a fresh Xcode install fails the first build with `cannot execute tool 'metal'`, run `xcodebuild -downloadComponent MetalToolchain` (~700 MB one-time).
- **Models** — `~/yaprflow/Models/parakeet-tdt-0.6b-v2/` must exist before build (Copy Models phase will fail otherwise). The upstream `scripts/fetch-models.sh` is broken in two ways on this machine: (1) the `models-v2` GitHub release tarball 404s, (2) it calls `hf` which on this Mac is the higgsfield CLI not HuggingFace. Use `huggingface-cli` directly:
  ```bash
  HF_HUB_DISABLE_XET=1 huggingface-cli download FluidInference/parakeet-tdt-0.6b-v2-coreml \
    --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
    --local-dir ~/yaprflow/Models/parakeet-tdt-0.6b-v2
  ```
- **First recording delay** — ~30s on a cold launch while the Parakeet Encoder compiles. `TranscriptionController.preload()` runs at launch to warm this in the background.
- **Mic permission** — granted in System Settings → Privacy → Microphone (yaprflow). Carries across builds since bundle ID is stable.

## Common Tasks

- **"Add a new hotkey mode / trigger"** — touch `HotkeyMode` enum + `GlobalHotkey` callbacks + `AppDelegate.wireHotkeyCallbacks` + add a UI affordance. Re-read the deferred-work section first.
- **"Improve the menu UI"** — copy the `StreamingModeMenuItemView` / `HotkeyModeMenuItemView` pattern. Custom NSView, layout in `setupLayout()`, refresh on Combine subscription, mutate AppState on `mouseDown`.
- **"Bump the speech model"** — update `scripts/fetch-models.sh` (or just download manually) + the `Models/` Copy Models phase reference in the .pbxproj.
- **"Make this push upstream"** — `git remote add fork <your-fork-url>`, push branch, open a PR to tmoreton/yaprflow. Re-test under their Developer ID signing path before submitting.

## Don't Bother

- Adding `NSAccessibilityUsageDescription` to Info.plist — that's a microphone-style usage string and isn't the right key for AX prompts (per Codex review).
- Trying to keep the app sandboxed AND adopt `NSEvent` global monitors without TCC permission. Doesn't work.
- Looking for a build cache shortcut — `xcodebuild` already caches SPM packages, MLX, etc. in `build/SourcePackages/`. Don't `git clean -fdx` that dir unless you want a fresh ~3 min build.
