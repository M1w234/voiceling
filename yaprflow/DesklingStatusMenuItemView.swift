import AppKit
import Combine

/// Read-only row under the Deskling submenu. Reports whether the local bridge
/// has accepted this app's registration; it never starts or stops polling.
@MainActor
final class DesklingStatusMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "link", title: "Status")
        // The default 240 pt row truncates "Waiting for Deskling service".
        setFrameSize(NSSize(width: 300, height: frame.height))
        cancellable = RemoteControlClient.shared.$isConnected
            .combineLatest(AppState.shared.$desklingRemoteEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isRowEnabled: Bool { false }

    override func refresh() {
        if !AppState.shared.desklingRemoteEnabled {
            stateField.stringValue = "Off"
        } else if RemoteControlClient.shared.isConnected {
            stateField.stringValue = "Connected"
        } else {
            stateField.stringValue = "Waiting for Deskling service"
        }
    }
}
