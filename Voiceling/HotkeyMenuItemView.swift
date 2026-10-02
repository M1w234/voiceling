// Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMenuItemView: MenuRowView {
    private var isRecording = false {
        didSet {
            if isRecording { installFlagsMonitor() } else { removeFlagsMonitor() }
        }
    }

    /// Highest modifier mask seen during the current recording session. Used
    /// to commit a modifier-only binding when the user releases all modifiers
    /// without pressing a non-modifier key.
    private var recordedFlags: NSEvent.ModifierFlags = []
    private var sawNonModifierKey: Bool = false
    private var pollTimer: Timer?
    private var lastPolledFlags: NSEvent.ModifierFlags = []
    /// A modifier-only chord captured once, awaiting a confirming second
    /// press. Guards against accidental rebinds: a single stray ⌘⇧ while the
    /// recorder happens to be armed no longer silently replaces the hotkey —
    /// the user must press the SAME chord twice.
    private var pendingCarbonMods: UInt32 = 0
    /// Same confirm-twice guard for KEY-based captures (e.g. ⌘V). Without it,
    /// pressing paste while the recorder was accidentally armed instantly
    /// rebound the hotkey to ⌘V. nil = nothing staged.
    private var pendingKeyConfig: HotkeyConfig?

    init() {
        super.init(symbolName: "keyboard", title: "Shortcut")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHotkeyChanged),
            name: .voicelingHotkeyChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    // No deinit: the selector-based NotificationCenter observer is auto-removed
    // on dealloc (zeroing-weak since macOS 10.11), and pollTimer is stopped by
    // viewDidMoveToWindow / pollModifierFlags' window check when the menu
    // closes. (A @MainActor subclass can't declare a nonisolated deinit here.)

    /// The menu can close while recording is armed (user clicks away). The
    /// poll timer must not outlive the menu: left running, the next bare
    /// modifier press-and-release anywhere in macOS would silently commit a
    /// new modifier-only binding. `window == nil` is the close signal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isRecording {
            cancelRecording()
        }
    }

    private func cancelRecording() {
        isRecording = false
        recordedFlags = []
        sawNonModifierKey = false
        pendingCarbonMods = 0
        pendingKeyConfig = nil
        reload()
    }

    override func refresh() {
        if isRecording {
            if let keyCfg = pendingKeyConfig {
                titleField.stringValue = "Press \(keyCfg.displayString) again to set"
            } else if pendingCarbonMods != 0 {
                let cfg = HotkeyConfig(
                    keyCode: HotkeyConfig.modifierOnlyKeyCode,
                    modifiers: pendingCarbonMods
                )
                titleField.stringValue = "Press \(cfg.displayString) again to set"
            } else {
                titleField.stringValue = "Press a shortcut…"
            }
            stateField.stringValue = "esc"
        } else {
            titleField.stringValue = "Shortcut"
            stateField.stringValue = AppState.shared.hotkey.displayString
        }
    }

    override func applyStateColor() {
        stateField.textColor = AppState.shared.keyboardShortcutEnabled
            ? .secondaryLabelColor
            : .tertiaryLabelColor
    }

    /// Blue "Press a shortcut…" while recording (unless the row is also
    /// hovered, in which case the base's white-on-accent wins).
    override func titleColor(enabled: Bool, highlighted: Bool) -> NSColor {
        if isRecording && !highlighted { return .systemBlue }
        return super.titleColor(enabled: enabled, highlighted: highlighted)
    }

    @objc private func onHotkeyChanged() {
        reload()
    }

    override func rowClicked() {
        if !isRecording {
            recordedFlags = []
            sawNonModifierKey = false
        }
        isRecording.toggle()
        reload()
        window?.makeFirstResponder(self)
    }

    /// NSMenu's event tracking loop swallows `.flagsChanged` events before
    /// they reach `NSEvent.addLocalMonitorForEvents`, so we can't observe
    /// modifier transitions reactively while the menu is open. Instead we
    /// poll `NSEvent.modifierFlags` (a synchronous class method that returns
    /// the current global modifier state — no event delivery needed) on a
    /// Timer registered in `.common` run-loop modes, which includes
    /// `.eventTracking` where NSMenu runs.
    private func installFlagsMonitor() {
        guard pollTimer == nil else { return }
        lastPolledFlags = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let timer = Timer(timeInterval: 0.020, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollModifierFlags()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func removeFlagsMonitor() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollModifierFlags() {
        guard isRecording else { return }
        // Belt-and-braces alongside viewDidMoveToWindow: never keep polling
        // after the menu has closed.
        guard window != nil else {
            cancelRecording()
            return
        }
        let current = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard current != lastPolledFlags else { return }
        lastPolledFlags = current

        // Track the strongest modifier set seen.
        recordedFlags.formUnion(current)

        // All modifiers released. Commit modifier-only binding if the user
        // never pressed a non-modifier key during this recording.
        if current.isEmpty && !recordedFlags.isEmpty && !sawNonModifierKey {
            let carbonMods = carbonModifiers(from: recordedFlags)
            // A single standard modifier is too easy to hit during normal
            // typing — holding ⌘ for 200 ms while thinking about a shortcut
            // would start dictation. Require a chord of at least two. Fn / 🌐
            // alone is exempt: it's a dedicated key, not a chord you hold
            // while typing (the natural dictation key on Mac laptops).
            guard carbonMods == HotkeyConfig.fnBit || carbonMods.nonzeroBitCount >= 2 else {
                recordedFlags = []
                return
            }

            // First capture (or a different chord than last time): stage it
            // and ask for a confirming repeat. Prevents accidental rebinds.
            guard pendingCarbonMods == carbonMods else {
                pendingCarbonMods = carbonMods
                recordedFlags = []
                reload()
                return
            }

            // Confirmed — same chord pressed twice. Commit.
            let newConfig = HotkeyConfig(
                keyCode: HotkeyConfig.modifierOnlyKeyCode,
                modifiers: carbonMods,
                mode: AppState.shared.hotkey.mode
            )
            AppState.shared.hotkey = newConfig
            newConfig.save()
            NotificationCenter.default.post(name: .voicelingHotkeyChanged, object: nil)

            isRecording = false
            recordedFlags = []
            pendingCarbonMods = 0
            reload()
            enclosingMenuItem?.menu?.cancelTracking()
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command)  { mods |= UInt32(cmdKey) }
        if flags.contains(.option)   { mods |= UInt32(optionKey) }
        if flags.contains(.control)  { mods |= UInt32(controlKey) }
        if flags.contains(.shift)    { mods |= UInt32(shiftKey) }
        if flags.contains(.function) { mods |= HotkeyConfig.fnBit }  // Fn / 🌐 key
        return mods
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return handle(event: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event: event) else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.subtracting(.capsLock).isEmpty {
            isRecording = false
            recordedFlags = []
            reload()
            enclosingMenuItem?.menu?.cancelTracking()
            return true
        }

        // Mark that the user pressed a non-modifier key — disqualifies the
        // modifier-only commit path in pollModifierFlags.
        sawNonModifierKey = true

        let candidate = HotkeyConfig(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(from: flags),
            mode: AppState.shared.hotkey.mode
        )

        // Confirm-twice guard: stage the first capture, commit only when the
        // SAME key+modifiers are pressed again. Stops an accidental keypress
        // (e.g. ⌘V while the row is armed) from instantly rebinding.
        guard pendingKeyConfig?.keyCode == candidate.keyCode,
              pendingKeyConfig?.modifiers == candidate.modifiers else {
            pendingKeyConfig = candidate
            pendingCarbonMods = 0
            reload()
            return true
        }

        let newConfig = candidate
        pendingKeyConfig = nil
        AppState.shared.hotkey = newConfig
        newConfig.save()
        NotificationCenter.default.post(name: .voicelingHotkeyChanged, object: nil)

        isRecording = false
        recordedFlags = []
        reload()
        enclosingMenuItem?.menu?.cancelTracking()
        return true
    }
}
