import AppKit
import Combine

@MainActor
final class StreamingModeMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "waveform", title: "Streaming")
        cancellable = AppState.shared.$streamingMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        stateField.stringValue = AppState.shared.streamingMode ? "On" : "Off"
    }

    override func rowClicked() {
        AppState.shared.streamingMode.toggle()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
