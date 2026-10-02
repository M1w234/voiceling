// Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.

import AppKit

/// Menu row for action items (Copy Transcript / Copy Summary / Show History).
/// Uses the shared `MenuRowView` for layout + hover highlighting; the trailing
/// state field carries the shortcut hint. Rows can be conditionally enabled
/// via `isEnabled` (e.g. no transcript yet → dimmed, non-highlighting).
@MainActor
final class IconActionMenuItemView: MenuRowView {
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private let isEnabledProvider: () -> Bool

    init(
        symbolName: String,
        title: String,
        shortcut: String? = nil,
        target: AnyObject,
        action: Selector,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.actionTarget = target
        self.action = action
        self.isEnabledProvider = isEnabled
        super.init(symbolName: symbolName, title: title)
        stateField.stringValue = shortcut ?? ""
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isRowEnabled: Bool { isEnabledProvider() }

    override func applyStateColor() {
        // Shortcut hint sits a shade lighter than a normal state value.
        stateField.textColor = .tertiaryLabelColor
    }

    override func rowClicked() {
        guard let target = actionTarget else { return }
        NSApp.sendAction(action, to: target, from: self)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
