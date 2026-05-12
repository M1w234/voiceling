import AppKit
import Combine

/// Menu row for the Screen Context toggle. Same three visible states as
/// Auto-Paste — Off / On / Needs Permission — because it gates on the same
/// macOS Accessibility permission.
///
/// Why a separate view instead of reusing AutoPasteMenuItemView: this feature
/// READS text from other apps' fields, which is a meaningfully different
/// privacy posture than synthesizing ⌘V. The label, icon, and tooltip should
/// reflect that. Same TCC entry, different user-facing promise.
@MainActor
final class ScreenContextMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Screen Context")
    private let stateField = NSTextField(labelWithString: "")
    private var cancellable: AnyCancellable?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        cancellable = AppState.shared.$screenContextMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // "doc.text.magnifyingglass" reads as "look at the doc near the
        // cursor" — distinct from Auto-Paste's "text.viewfinder" which
        // implies inserting into a target.
        iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        stateField.translatesAutoresizingMaskIntoConstraints = false
        stateField.font = NSFont.menuFont(ofSize: 0)
        stateField.textColor = .secondaryLabelColor
        stateField.alignment = .right
        addSubview(stateField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stateField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            stateField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16),
        ])
    }

    private func refresh() {
        let enabled = AppState.shared.screenContextMode
        if !enabled {
            stateField.stringValue = "Off"
            stateField.textColor = .secondaryLabelColor
        } else if AutoPaste.hasAccessibility {
            stateField.stringValue = "On"
            stateField.textColor = .secondaryLabelColor
        } else {
            stateField.stringValue = "Needs Permission"
            stateField.textColor = .systemOrange
        }
    }

    override func mouseDown(with event: NSEvent) {
        let enabled = AppState.shared.screenContextMode
        let trusted = AutoPaste.hasAccessibility

        if enabled && !trusted {
            // "Needs Permission" → re-prompt; fall back to System Settings
            // if the user previously denied (the synchronous prompt no
            // longer surfaces a dialog at that point).
            let nowTrusted = AutoPaste.promptForAccessibility()
            if !nowTrusted {
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

        refresh()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
