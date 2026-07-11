import AppKit
import Combine

@MainActor
final class GrammarModeMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "text.badge.checkmark", title: "Grammar")
        cancellable = AppState.shared.$grammarMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refresh() {
        stateField.stringValue = AppState.shared.grammarMode ? "On" : "Off"
    }

    override func rowClicked() {
        AppState.shared.grammarMode.toggle()
        // Kick off the model download in the background when the user flips
        // grammar on — otherwise it wouldn't start until their next dictation.
        if AppState.shared.grammarMode {
            GrammarController.shared.preload()
        }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
