import AppKit
import Combine

/// Menu row for the Screen Context toggle. Same three visible states as
/// Auto-Paste — Off / On / Needs Permission — because it gates on the same
/// macOS Accessibility permission. Separate class because this feature READS
/// text from other apps, a different privacy promise than synthesizing ⌘V.
@MainActor
final class ScreenContextMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "doc.text.magnifyingglass", title: "Screen Context")
        cancellable = AppState.shared.$screenContextMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var needsPermission: Bool {
        AppState.shared.screenContextMode && !AutoPaste.hasAccessibility
    }

    override func refresh() {
        if !AppState.shared.screenContextMode {
            stateField.stringValue = "Off"
        } else if AutoPaste.hasAccessibility {
            stateField.stringValue = "On"
        } else {
            stateField.stringValue = "Needs Permission"
        }
    }

    override func applyStateColor() {
        stateField.textColor = needsPermission ? .systemOrange : .secondaryLabelColor
    }

    override func rowClicked() {
        let enabled = AppState.shared.screenContextMode
        let trusted = AutoPaste.hasAccessibility

        if enabled && !trusted {
            if !AutoPaste.promptForAccessibility() {
                AutoPaste.openAccessibilitySettings()
            }
        } else if !enabled {
            AppState.shared.screenContextMode = true
            if !trusted {
                _ = AutoPaste.promptForAccessibility()
            }
        } else {
            AppState.shared.screenContextMode = false
        }

        reload()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
