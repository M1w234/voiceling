import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var startSoundPickerMenu: NSMenu?
    private var stopSoundPickerMenu: NSMenu?
    private var statusIconCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        _ = NotchOverlayWindowController.shared
        registerHotkey()
        registerHistoryHotkey()

        // Eagerly instantiate the history store so its Combine subscription
        // on `AppState.$lastTranscript` is live before the first dictation.
        _ = ClipboardHistoryStore.shared

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
                self.registerHotkey()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
        ModifierOnlyHotkey.shared.unregister()
        HistoryHotkey.shared.unregister()
        CancelHotkey.shared.unregister()
        // Never leave the system muted behind us if we quit mid-recording.
        AudioDucking.shared.restore()
        // History saves are debounced 300 ms — flush so a dictation finished
        // right before quit isn't lost.
        ClipboardHistoryStore.shared.flushPendingSave()
    }

    private func registerHistoryHotkey() {
        HistoryHotkey.onPressed = {
            Task { @MainActor in
                ClipboardHistoryWindowController.shared.toggle()
            }
        }
        HistoryHotkey.shared.register()
    }

    @objc private func showHistory() {
        ClipboardHistoryWindowController.shared.show()
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

        let triggerItem = NSMenuItem()
        triggerItem.view = HotkeyModeMenuItemView()
        triggerItem.toolTip = "Tap to Toggle: press once to start, again to stop. Hold to Talk: hold the shortcut while you speak, release to stop."
        menu.addItem(triggerItem)

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

        let preserveClipboardItem = NSMenuItem()
        preserveClipboardItem.view = ToggleMenuItemView(
            symbolName: "list.clipboard",
            title: "Preserve Clipboard",
            publisher: AppState.shared.$preserveClipboardMode.eraseToAnyPublisher(),
            get: { AppState.shared.preserveClipboardMode },
            set: { AppState.shared.preserveClipboardMode = $0 }
        )
        preserveClipboardItem.toolTip = "With Auto-Paste on, insert transcripts directly into the focused field (Accessibility write, or synthetic typing) instead of pasting via the clipboard — whatever you had copied stays put. Falls back to the clipboard if the field doesn't accept insertion."
        menu.addItem(preserveClipboardItem)

        let duckItem = NSMenuItem()
        duckItem.view = ToggleMenuItemView(
            symbolName: "speaker.slash",
            title: "Mute While Dictating",
            publisher: AppState.shared.$duckWhileRecording.eraseToAnyPublisher(),
            get: { AppState.shared.duckWhileRecording },
            set: { newValue in
                AppState.shared.duckWhileRecording = newValue
                // Live-apply when toggled mid-recording.
                if TranscriptionController.shared.isRecording {
                    if newValue {
                        AudioDucking.shared.duck()
                    } else {
                        AudioDucking.shared.restore()
                    }
                }
            }
        )
        duckItem.toolTip = "Mute system audio output while recording so music or video doesn't bleed into the mic. Volume is restored when you stop (unless you changed it yourself mid-recording)."
        menu.addItem(duckItem)

        let soundsItem = NSMenuItem(title: "Sound Effects", action: nil, keyEquivalent: "")
        soundsItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        soundsItem.submenu = buildSoundsSubmenu()
        soundsItem.toolTip = "Toggle start/stop chimes and pick which system sounds to use."
        menu.addItem(soundsItem)

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

        // Clipboard history — opens the floating panel. Also bound to ⌃⌥V
        // as a global hotkey (see `registerHistoryHotkey`).
        let historyItem = NSMenuItem()
        historyItem.view = IconActionMenuItemView(
            symbolName: "clock.arrow.circlepath",
            title: "Show History…",
            shortcut: "⌃⌥V",
            target: self,
            action: #selector(showHistory)
        )
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item

        // Swap the menu bar icon to a red record dot while the mic is live —
        // the overlay pill is easy to miss (especially in lock mode), and a
        // persistent "recording" indicator in the menu bar is the honest
        // signal that audio is being captured.
        statusIconCancellable = AppState.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusIcon(for: status)
            }
    }

    private func updateStatusIcon(for status: TranscriptionStatus) {
        guard let button = statusItem?.button else { return }
        if case .listening = status {
            let image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "Yaprflow — recording"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            )
            image?.isTemplate = false
            button.image = image
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yaprflow")
            image?.isTemplate = true
            button.image = image
        }
    }

    /// Copies the corrected transcript when grammar mode produced one,
    /// otherwise the raw original.
    @objc private func copyTranscript() {
        let original = AppState.shared.lastOriginalTranscript
        let corrected = AppState.shared.lastTranscript
        let text = corrected.isEmpty ? original : corrected
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
                let summary = try await GrammarController.shared.summarize(text: text) { msg in
                    // Fresh installs may need the model download first —
                    // show its progress instead of a frozen "Summarizing…".
                    AppState.shared.status = .correcting(msg)
                }
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
        if menuItem.action == #selector(resetSoundsToDefaults) {
            return AppState.shared.startSoundName != SoundEffect.defaultStartName
                || AppState.shared.stopSoundName != SoundEffect.defaultStopName
        }
        return true
    }

    // MARK: - Sound Effects submenu

    /// Builds the "Sound Effects" submenu: an Enabled toggle, two sound-picker
    /// submenus (start / stop), and a reset action. Built once at launch and
    /// kept alive for the app's lifetime — checkmark state is maintained
    /// imperatively by the action handlers so we don't need to rebuild.
    private func buildSoundsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleSoundsEnabled(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = AppState.shared.soundEffectsEnabled ? .on : .off
        submenu.addItem(enabledItem)

        submenu.addItem(NSMenuItem.separator())

        let startPicker = buildSoundPickerMenu(forStart: true)
        self.startSoundPickerMenu = startPicker
        let startParent = NSMenuItem(title: "Start Sound", action: nil, keyEquivalent: "")
        startParent.submenu = startPicker
        submenu.addItem(startParent)

        let stopPicker = buildSoundPickerMenu(forStart: false)
        self.stopSoundPickerMenu = stopPicker
        let stopParent = NSMenuItem(title: "Stop Sound", action: nil, keyEquivalent: "")
        stopParent.submenu = stopPicker
        submenu.addItem(stopParent)

        submenu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(
            title: "Reset to Defaults",
            action: #selector(resetSoundsToDefaults),
            keyEquivalent: ""
        )
        resetItem.target = self
        submenu.addItem(resetItem)

        return submenu
    }

    private func buildSoundPickerMenu(forStart: Bool) -> NSMenu {
        let menu = NSMenu()
        let current = forStart
            ? AppState.shared.startSoundName
            : AppState.shared.stopSoundName
        let selector: Selector = forStart
            ? #selector(selectStartSound(_:))
            : #selector(selectStopSound(_:))
        for name in SoundEffect.availableSounds() {
            let item = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == current) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleSoundsEnabled(_ sender: NSMenuItem) {
        AppState.shared.soundEffectsEnabled.toggle()
        sender.state = AppState.shared.soundEffectsEnabled ? .on : .off
    }

    @objc private func selectStartSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppState.shared.startSoundName = name
        refreshSoundCheckmarks(in: sender.menu, current: name)
        // Bypass the enabled gate so users can audition while picking, even
        // with chimes turned off overall.
        SoundEffect.preview(name)
    }

    @objc private func selectStopSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppState.shared.stopSoundName = name
        refreshSoundCheckmarks(in: sender.menu, current: name)
        SoundEffect.preview(name)
    }

    @objc private func resetSoundsToDefaults() {
        AppState.shared.startSoundName = SoundEffect.defaultStartName
        AppState.shared.stopSoundName = SoundEffect.defaultStopName
        refreshSoundCheckmarks(in: startSoundPickerMenu, current: SoundEffect.defaultStartName)
        refreshSoundCheckmarks(in: stopSoundPickerMenu, current: SoundEffect.defaultStopName)
    }

    private func refreshSoundCheckmarks(in menu: NSMenu?, current: String) {
        guard let menu else { return }
        for item in menu.items {
            if let name = item.representedObject as? String {
                item.state = (name == current) ? .on : .off
            }
        }
    }

    private func registerHotkey() {
        let config = AppState.shared.hotkey

        // Exactly one backend active at a time.
        if config.isModifierOnly {
            GlobalHotkey.shared.unregister()
            guard config.isValid else { return }
            wireModifierOnlyCallbacks()
            ModifierOnlyHotkey.shared.register(modifiers: config.modifiers)
        } else {
            ModifierOnlyHotkey.shared.unregister()
            wireHotkeyCallbacks(for: config.mode)
            GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
        }
    }

    /// Modifier-only bindings always support both hold-to-talk and
    /// double-tap-to-lock simultaneously. `ModifierOnlyHotkey` handles the
    /// gesture state internally and only fires onStart / onStop on actual
    /// recording-state transitions, so wiring is symmetric and idempotent.
    private func wireModifierOnlyCallbacks() {
        ModifierOnlyHotkey.onStart = {
            Task { @MainActor in
                TranscriptionController.shared.setActive(true)
            }
        }
        ModifierOnlyHotkey.onStop = {
            Task { @MainActor in
                TranscriptionController.shared.setActive(false)
            }
        }
    }

    private func wireHotkeyCallbacks(for mode: HotkeyMode) {
        switch mode {
        case .tapToToggle:
            GlobalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.toggle()
                }
            }
            GlobalHotkey.onReleased = nil
        case .holdToTalk:
            GlobalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(true)
                }
            }
            GlobalHotkey.onReleased = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(false)
                }
            }
        }
    }
}
