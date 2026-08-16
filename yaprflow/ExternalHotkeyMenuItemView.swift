import AppKit
import Carbon.HIToolbox
import Combine

/// Key-based shortcut recorder for programmable mouse software. Unlike the
/// primary recorder, this intentionally never captures a modifier-only chord.
@MainActor
final class ExternalHotkeyShortcutMenuItemView: MenuRowView {
    private var isRecording = false
    private var pendingKeyCode: UInt32?
    private var pendingModifiers: UInt32 = 0
    private var validationMessage: String?
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "keyboard", title: "Shortcut")
        cancellable = AppState.shared.$externalHotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && isRecording {
            cancelRecording()
        }
    }

    override func refresh() {
        if isRecording {
            if let validationMessage {
                titleField.stringValue = validationMessage
            } else if let pendingKeyCode {
                let candidate = HotkeyConfig(
                    keyCode: pendingKeyCode,
                    modifiers: pendingModifiers
                )
                titleField.stringValue = "Press \(candidate.shortcutDisplayString) again to set"
            } else {
                titleField.stringValue = "Press a shortcut…"
            }
            stateField.stringValue = "esc"
        } else {
            titleField.stringValue = "Shortcut"
            let config = AppState.shared.externalHotkey
            stateField.stringValue = config.conflicts(with: AppState.shared.hotkey)
                ? "Conflict"
                : config.shortcutDisplayString
        }
    }

    override func applyStateColor() {
        stateField.textColor = AppState.shared.externalHotkey
            .conflicts(with: AppState.shared.hotkey)
            ? .systemOrange
            : .secondaryLabelColor
    }

    override func titleColor(enabled: Bool, highlighted: Bool) -> NSColor {
        if isRecording && !highlighted {
            return validationMessage == nil ? .systemBlue : .systemOrange
        }
        return super.titleColor(enabled: enabled, highlighted: highlighted)
    }

    override func rowClicked() {
        if isRecording {
            cancelRecording()
        } else {
            isRecording = true
            pendingKeyCode = nil
            pendingModifiers = 0
            validationMessage = nil
            reload()
            window?.makeFirstResponder(self)
        }
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
            cancelRecording()
            enclosingMenuItem?.menu?.cancelTracking()
            return true
        }

        let keyCode = UInt32(event.keyCode)
        let modifiers = carbonModifiers(from: flags)

        let primary = AppState.shared.hotkey
        if !primary.isModifierOnly,
           primary.keyCode == keyCode,
           primary.modifiers == modifiers {
            pendingKeyCode = nil
            pendingModifiers = 0
            validationMessage = "Already used by main shortcut"
            reload()
            return true
        }

        validationMessage = nil
        guard pendingKeyCode == keyCode, pendingModifiers == modifiers else {
            pendingKeyCode = keyCode
            pendingModifiers = modifiers
            reload()
            return true
        }

        var config = AppState.shared.externalHotkey
        config.keyCode = keyCode
        config.modifiers = modifiers
        AppState.shared.externalHotkey = config
        config.save()
        NotificationCenter.default.post(name: .yaprflowExternalHotkeyChanged, object: nil)

        isRecording = false
        pendingKeyCode = nil
        pendingModifiers = 0
        reload()
        enclosingMenuItem?.menu?.cancelTracking()
        return true
    }

    private func cancelRecording() {
        isRecording = false
        pendingKeyCode = nil
        pendingModifiers = 0
        validationMessage = nil
        reload()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

@MainActor
final class ExternalHotkeyModeMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "hand.tap", title: "Trigger")
        cancellable = AppState.shared.$externalHotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        switch AppState.shared.externalHotkey.mode {
        case .tapToToggle:
            stateField.stringValue = "Tap to Toggle"
        case .holdToTalk:
            stateField.stringValue = "Hold to Talk"
        }
    }

    override func rowClicked() {
        var config = AppState.shared.externalHotkey
        config.mode = config.mode == .tapToToggle ? .holdToTalk : .tapToToggle
        AppState.shared.externalHotkey = config
        config.save()
        NotificationCenter.default.post(name: .yaprflowExternalHotkeyChanged, object: nil)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

/// Lets another app temporarily own the saved primary shortcut without
/// deleting or changing it. This row is intentionally available only while
/// the independent external trigger is registered and ready.
@MainActor
final class KeyboardShortcutActivationMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "keyboard.badge.ellipsis", title: "Keyboard Shortcut")
        cancellable = AppState.shared.$keyboardShortcutEnabled
            .combineLatest(AppState.shared.$externalHotkey)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isRowEnabled: Bool {
        let external = AppState.shared.externalHotkey
        return external.enabled
            && !external.conflicts(with: AppState.shared.hotkey)
            && ExternalHotkey.shared.isRegistered
    }

    override func refresh() {
        let external = AppState.shared.externalHotkey
        if !external.enabled {
            stateField.stringValue = "External Off"
        } else if external.conflicts(with: AppState.shared.hotkey)
            || !ExternalHotkey.shared.isRegistered {
            stateField.stringValue = "Unavailable"
        } else {
            stateField.stringValue = AppState.shared.keyboardShortcutEnabled
                ? "Active"
                : "Paused"
        }
    }

    override func applyStateColor() {
        stateField.textColor = AppState.shared.keyboardShortcutEnabled
            ? .secondaryLabelColor
            : .tertiaryLabelColor
    }

    override func rowClicked() {
        AppState.shared.keyboardShortcutEnabled.toggle()
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
