import AppKit
import Combine

@MainActor
final class HotkeyModeMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "hand.tap", title: "Trigger")
        cancellable = AppState.shared.$hotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        let config = AppState.shared.hotkey
        if config.isModifierOnly {
            // Modifier-only bindings always have both hold AND double-tap-to-lock
            // active — the per-mode toggle doesn't apply.
            stateField.stringValue = "Hold + Double-tap"
        } else {
            switch config.mode {
            case .tapToToggle: stateField.stringValue = "Tap to Toggle"
            case .holdToTalk:  stateField.stringValue = "Hold to Talk"
            }
        }
    }

    override func applyStateColor() {
        // Modifier-only shows a fixed, non-actionable descriptor — dim it.
        stateField.textColor = AppState.shared.hotkey.isModifierOnly
            ? .tertiaryLabelColor
            : .secondaryLabelColor
    }

    override var isRowEnabled: Bool {
        // Mode toggle has no effect on modifier-only bindings.
        !AppState.shared.hotkey.isModifierOnly
    }

    override func rowClicked() {
        var config = AppState.shared.hotkey
        config.mode = (config.mode == .tapToToggle) ? .holdToTalk : .tapToToggle
        AppState.shared.hotkey = config
        config.save()
        NotificationCenter.default.post(name: .voicelingHotkeyChanged, object: nil)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
