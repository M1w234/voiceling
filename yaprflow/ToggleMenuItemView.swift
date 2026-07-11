import AppKit
import Combine

/// Generic On/Off menu row backed by closures. Use this for new boolean
/// toggles instead of cloning another view class.
@MainActor
final class ToggleMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?
    private let getValue: () -> Bool
    private let setValue: (Bool) -> Void

    init(
        symbolName: String,
        title: String,
        publisher: AnyPublisher<Bool, Never>,
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void
    ) {
        self.getValue = get
        self.setValue = set
        super.init(symbolName: symbolName, title: title)

        cancellable = publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        stateField.stringValue = getValue() ? "On" : "Off"
    }

    override func rowClicked() {
        setValue(!getValue())
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
