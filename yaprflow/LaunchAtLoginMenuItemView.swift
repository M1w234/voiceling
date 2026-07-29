import AppKit
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "LaunchAtLogin")

@MainActor
final class LaunchAtLoginMenuItemView: MenuRowView {
    init() {
        super.init(symbolName: "power", title: "Launch at Login")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        // Re-read on every menu open (base calls reload() from
        // viewDidMoveToWindow) so the toggle reflects changes made in System
        // Settings → Login Items since it was last shown.
        switch SMAppService.mainApp.status {
        case .enabled:          stateField.stringValue = "On"
        case .requiresApproval: stateField.stringValue = "Needs approval"
        default:                stateField.stringValue = "Off"
        }
    }

    override func applyStateColor() {
        stateField.textColor = (SMAppService.mainApp.status == .requiresApproval)
            ? .systemOrange
            : .secondaryLabelColor
    }

    override func rowClicked() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            log.error("Toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
