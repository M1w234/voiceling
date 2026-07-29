import AppKit
import Combine
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Overlay")

@MainActor
final class NotchOverlayWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotchOverlayWindowController()

    // Fixed window size. SwiftUI content sits inside (with its own padding
    // and rounded background) — the window's transparent backing means only
    // the SwiftUI pill is visible. Wide/tall enough for two transcript lines
    // plus the cancel/finish buttons without clipping the pill's edges.
    private static let initialWidth: CGFloat = 420
    private static let initialHeight: CGFloat = 72
    /// Distance from the bottom of the visible screen frame to the bottom of
    /// the overlay pill. visibleFrame already excludes the Dock, so this can
    /// sit low without colliding with it.
    private static let bottomMargin: CGFloat = 10

    private var mouseModeCancellable: AnyCancellable?
    /// Invalidates an older fade-out completion when a new session calls
    /// show() before that animation finishes.
    private var visibilityGeneration = 0

    convenience init() {
        let content = NotchOverlayView(state: AppState.shared)
        // NSHostingView (not controller) with first-mouse acceptance: the
        // window never becomes key, so without this the first click on the
        // pill's cancel/finish buttons would only focus, not press.
        // Deliberately NOT window-sizing from SwiftUI intrinsics — an idle/
        // empty body can produce a ~0×0 intrinsic and collapse the window.
        // The window keeps its fixed size; content centers inside.
        let host = FirstMouseHostingView(rootView: content)

        let window = NotchOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.initialWidth, height: Self.initialHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.alphaValue = 0

        self.init(window: window)
        window.delegate = self

        // Accept clicks ONLY while listening (the cancel/finish buttons are
        // showing). In every other state the window's transparent margins
        // must not eat clicks destined for whatever sits underneath.
        mouseModeCancellable = AppState.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak window] status in
                if case .listening = status {
                    window?.ignoresMouseEvents = false
                } else {
                    window?.ignoresMouseEvents = true
                }
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    func show() {
        visibilityGeneration += 1
        recenter()
        guard let window else {
            log.error("show(): window is nil")
            return
        }
        // Order front first (visibility never depends on the animation
        // completing), then fade alpha in. Skipping the fade made the pill
        // pop in harshly; 0.15s reads as smooth without feeling laggy.
        window.orderFrontRegardless()
        if window.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let window else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard self?.visibilityGeneration == generation else { return }
                window?.orderOut(nil)
            }
        })
    }

    func windowDidResize(_ notification: Notification) {
        recenter()
    }

    private func recenter() {
        guard let window, let screen = Self.preferredScreen() else { return }
        let w = window.frame.width
        let h = window.frame.height
        let x = screen.frame.midX - w / 2
        let y = screen.visibleFrame.minY + Self.bottomMargin
        let target = NSRect(x: x, y: y, width: w, height: h)
        if target != window.frame {
            window.setFrame(target, display: true)
        }
    }

    /// Prefer the primary (menu-bar / key-window) screen — predictable across
    /// sessions so the overlay always shows up in the same place. Falls back
    /// to the notched display, then the first available screen.
    private static func preferredScreen() -> NSScreen? {
        if let main = NSScreen.main { return main }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first
    }
}

private final class NotchOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that responds to the first click even though its window
/// never becomes key — required for the pill's cancel/finish buttons.
/// Concrete (not generic over Content): a generic NSHostingView subclass
/// crashes the Swift 6.2 release-mode SIL inliner while specializing the
/// implicit deinit, and we only ever host NotchOverlayView anyway.
private final class FirstMouseHostingView: NSHostingView<NotchOverlayView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: NotchOverlayView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
