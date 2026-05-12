import AppKit
import OSLog
import SwiftUI

private let hotkeyLog = Logger(subsystem: "com.tmoreton.yaprflow", category: "Hotkey")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        registerHotkey()

        // Warm the ASR + VAD models in the background so the first hotkey press
        // doesn't block on the ~30s Encoder compile. On first launch this also
        // starts downloading the encoder from GitHub Releases in parallel with
        // the onboarding flow.
        TranscriptionController.shared.preload()

        // Preload the grammar model in the background if the user has enabled
        // grammar mode (either via onboarding or from a prior session).
        if AppState.shared.grammarMode {
            GrammarController.shared.preload()
        }

        if !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(
            forName: .yaprflowHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let config = AppState.shared.hotkey
                self.wireHotkeyCallbacks()
                GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yaprflow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let shortcutItem = NSMenuItem()
        shortcutItem.view = HotkeyMenuItemView()
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let streamingItem = NSMenuItem()
        streamingItem.view = StreamingModeMenuItemView()
        streamingItem.toolTip = "Show live partials while you speak. Turn off for single-shot mode — more accurate on longer dictations, but no text appears until you stop."
        menu.addItem(streamingItem)

        let grammarItem = NSMenuItem()
        grammarItem.view = GrammarModeMenuItemView()
        grammarItem.toolTip = "Run each transcript through an on-device LLM for grammar and punctuation correction."
        menu.addItem(grammarItem)

        let autoPasteItem = NSMenuItem()
        autoPasteItem.view = AutoPasteMenuItemView()
        autoPasteItem.toolTip = "After transcription, automatically paste into the focused text field. Requires Accessibility permission (System Settings → Privacy & Security → Accessibility)."
        menu.addItem(autoPasteItem)

        let screenContextItem = NSMenuItem()
        screenContextItem.view = ScreenContextMenuItemView()
        screenContextItem.toolTip = "Reads a short window of text near your cursor (≈700 chars) and feeds it to the on-device grammar polish so it can spell proper nouns and brand names already on screen. Browsers, mail, messages, and password managers are skipped automatically. Stays on your Mac."
        menu.addItem(screenContextItem)

        let soundEffectsItem = NSMenuItem()
        soundEffectsItem.view = SoundEffectsMenuItemView()
        soundEffectsItem.toolTip = "Play a short system sound when recording starts and stops."
        menu.addItem(soundEffectsItem)

        let launchAtLoginItem = NSMenuItem()
        launchAtLoginItem.view = LaunchAtLoginMenuItemView()
        launchAtLoginItem.toolTip = "Open Yaprflow automatically when you log in to your Mac."
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // Copy text: original first, then corrected if grammar mode was on.
        // Custom view so the icon lines up with Shortcut/Streaming/Grammar above.
        let copyItem = NSMenuItem()
        copyItem.view = IconActionMenuItemView(
            symbolName: "doc.on.clipboard",
            title: "Copy Transcript",
            target: self,
            action: #selector(copyTranscript),
            isEnabled: {
                !AppState.shared.lastTranscript.isEmpty
                    || !AppState.shared.lastOriginalTranscript.isEmpty
            }
        )
        menu.addItem(copyItem)

        // Summarize on demand
        let summarizeItem = NSMenuItem()
        summarizeItem.view = IconActionMenuItemView(
            symbolName: "text.alignleft",
            title: "Copy Summary",
            target: self,
            action: #selector(copySummary),
            isEnabled: { !AppState.shared.lastTranscript.isEmpty }
        )
        menu.addItem(summarizeItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item
    }

    /// Copies original first, then corrected if available (overwrites clipboard)
    @objc private func copyTranscript() {
        let original = AppState.shared.lastOriginalTranscript
        let corrected = AppState.shared.lastTranscript

        let pb = NSPasteboard.general
        pb.clearContents()

        // Put original first
        if !original.isEmpty {
            pb.setString(original, forType: .string)
        }

        // Overwrite with corrected if available and different
        if !corrected.isEmpty && corrected != original {
            pb.setString(corrected, forType: .string)
        }
    }

    /// Generates and copies a summary of the last transcript (on-demand)
    @objc private func copySummary() {
        let text = AppState.shared.lastTranscript
        guard !text.isEmpty else { return }

        // Show overlay and loading state
        NotchOverlayWindowController.shared.show()
        AppState.shared.status = .summarizing

        Task { @MainActor in
            do {
                let summary = try await GrammarController.shared.summarize(text: text)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summary, forType: .string)

                // Show completion
                AppState.shared.status = .copied

                // Auto-hide after delay
                try? await Task.sleep(for: .seconds(2.0))
                if AppState.shared.status == .copied {
                    AppState.shared.status = .idle
                    NotchOverlayWindowController.shared.hide()
                }
            } catch {
                // Silent fail — hide overlay
                AppState.shared.status = .idle
                NotchOverlayWindowController.shared.hide()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyTranscript) {
            return !AppState.shared.lastTranscript.isEmpty || !AppState.shared.lastOriginalTranscript.isEmpty
        }
        if menuItem.action == #selector(copySummary) {
            return !AppState.shared.lastTranscript.isEmpty
        }
        return true
    }

    private func registerHotkey() {
        let config = AppState.shared.hotkey
        wireHotkeyCallbacks()
        GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
    }

    private func wireHotkeyCallbacks() {
        // Reset state machine on every (re)wire so re-recording the hotkey
        // mid-session can't leave a stale lock or pending double-tap window.
        isLocked = false
        lastPressDownTime = nil

        GlobalHotkey.onPressed = { [weak self] in
            Task { @MainActor in self?.handlePress() }
        }
        GlobalHotkey.onReleased = { [weak self] in
            Task { @MainActor in self?.handleRelease() }
        }
    }

    // MARK: - Hybrid hold-to-talk + double-tap-to-lock state machine

    /// Maximum press-down to press-down gap that's recognized as a double-
    /// tap. Tuned tight enough that ordinary hold-to-talk usage (which is
    /// almost always >350 ms between distinct presses) doesn't accidentally
    /// engage the lock, but loose enough that a deliberate quick double-tap
    /// reliably triggers.
    private static let doubleTapInterval: CFTimeInterval = 0.35

    /// True while a recording is in "locked" mode — initiated by a double-
    /// tap, stays on through the release of the second press, and stays on
    /// until the user taps once more to stop.
    private var isLocked = false

    /// Timestamp of the most recent press-down. Used by the next press-down
    /// to decide whether this is the second half of a double-tap. Kept
    /// across the press_up of the first tap (release doesn't clear it) so
    /// the gesture is "press-release-press" not "press-press."
    private var lastPressDownTime: CFTimeInterval?

    private func handlePress() {
        let now = CACurrentMediaTime()

        // A locked recording is stopped by any subsequent press. Act on
        // press-down (not release) so the stop fires at the moment the
        // user clicks, with no perceptible lag.
        if isLocked {
            hotkeyLog.info("press: locked → stop")
            TranscriptionController.shared.setActive(false)
            isLocked = false
            lastPressDownTime = nil
            return
        }

        // Two interpretations are possible for this press: hold-to-talk
        // start, OR the second half of a double-tap. We can't yet tell
        // which — so we always start recording (hold-to-talk semantics)
        // and, if the gap from the previous press-down is short enough,
        // promote to locked. The brief overlap (~50–200 ms of audio
        // captured before the lock) is in front of any real speech and
        // gets trimmed by VAD.
        let gap = lastPressDownTime.map { now - $0 } ?? -1
        let withinDoubleTap = lastPressDownTime
            .map { now - $0 < Self.doubleTapInterval } ?? false

        if withinDoubleTap {
            hotkeyLog.info("press: double-tap (gap=\(gap, format: .fixed(precision: 3))s) → lock")
            TranscriptionController.shared.setActive(true)
            isLocked = true
            lastPressDownTime = nil
        } else {
            hotkeyLog.info("press: hold-to-talk start (gap=\(gap, format: .fixed(precision: 3))s)")
            TranscriptionController.shared.setActive(true)
            lastPressDownTime = now
        }
    }

    private func handleRelease() {
        // Locked recording stays running after release.
        if isLocked {
            hotkeyLog.info("release: locked, recording continues")
            return
        }
        // Hold-to-talk semantics: release stops. We deliberately leave
        // `lastPressDownTime` set — a press_down inside the double-tap
        // window after this release is what completes the gesture.
        hotkeyLog.info("release: hold-to-talk stop")
        TranscriptionController.shared.setActive(false)
    }
}
