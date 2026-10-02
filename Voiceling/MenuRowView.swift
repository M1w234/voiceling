import AppKit

/// Shared base for the status-menu's custom rows. Solves the thing that made
/// the menu feel dead: view-based `NSMenuItem`s don't get the stock hover
/// highlight, so every toggle row just sat there flat. This provides:
///
///   - the standard **icon · title · trailing-state** layout, and
///   - native-feeling **hover highlighting** (rounded accent fill, white text
///     and icon) driven by a tracking area that works inside NSMenu's event-
///     tracking run loop.
///
/// Subclasses override `rowClicked()`, and usually `refresh()` (set the
/// trailing text) plus optionally `isRowEnabled` / `applyStateColor()`.
///
/// **Refresh-on-open for free:** NSMenu moves a view-based item into a carrier
/// window each time the menu opens, so `viewDidMoveToWindow` fires and calls
/// `reload()` — which is why permission-dependent rows (Auto-Paste, Screen
/// Context, Launch at Login) re-read their external state on every open
/// without needing a separate notification observer.
@MainActor
class MenuRowView: NSView {
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let stateField = NSTextField(labelWithString: "")

    private var trackingArea: NSTrackingArea?
    private(set) var isHighlighted = false

    init(symbolName: String, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        autoresizingMask = [.width]
        setupBaseLayout(symbolName: symbolName, title: title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    // MARK: - Subclass contract

    /// Return false to render the row inert — no highlight, no click, dimmed
    /// text (e.g. "Copy Summary" with no transcript yet).
    var isRowEnabled: Bool { true }

    /// Set `stateField.stringValue` (and call `applyStateColor()` implicitly
    /// via `reload()`) to reflect current state. Called on every menu open.
    func refresh() {}

    /// Handle a click on an enabled row.
    func rowClicked() {}

    /// Color the trailing state text in the NON-highlighted, enabled case.
    /// Override for special colors (e.g. orange "Needs Permission").
    func applyStateColor() {
        stateField.textColor = .secondaryLabelColor
    }

    /// Title text color. Override for special cases (e.g. the shortcut
    /// recorder's blue "Press a shortcut…"). Default: dimmed when disabled,
    /// white when highlighted, label color otherwise.
    func titleColor(enabled: Bool, highlighted: Bool) -> NSColor {
        if !enabled { return .disabledControlTextColor }
        return highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    /// Refresh content then recolor. Subclasses call this from their state
    /// subscriptions.
    final func reload() {
        refresh()
        updateColors()
    }

    // MARK: - Layout

    private func setupBaseLayout(symbolName: String, title: String) {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.stringValue = title
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

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stateField.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16),
        ])
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard isRowEnabled else { return }
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHighlighted = false
        reload()
    }

    private func setHighlighted(_ highlighted: Bool) {
        guard isHighlighted != highlighted else { return }
        isHighlighted = highlighted
        updateColors()
        needsDisplay = true
    }

    private func updateColors() {
        let enabled = isRowEnabled
        titleField.textColor = titleColor(enabled: enabled, highlighted: isHighlighted)
        guard enabled else {
            iconView.contentTintColor = .disabledControlTextColor
            stateField.textColor = .disabledControlTextColor
            return
        }
        if isHighlighted {
            iconView.contentTintColor = .selectedMenuItemTextColor
            stateField.textColor = .selectedMenuItemTextColor
        } else {
            iconView.contentTintColor = nil
            applyStateColor()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted, isRowEnabled else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isRowEnabled else { return }
        rowClicked()
    }
}
