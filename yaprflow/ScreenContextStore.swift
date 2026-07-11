import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "ScreenContextStore")

/// Holds the latest screen-context capture for the active recording session.
///
/// Capture runs on a GCD background queue (NOT Swift's cooperative executor
/// — Codex finding: detached Tasks are the wrong pool for blocking AX C
/// calls). The polish path reads whatever is currently in `current` and never
/// waits for AX. If the capture hasn't returned yet by the time grammar
/// finishes, polish just runs with `context: nil`.
@MainActor
final class ScreenContextStore {
    private var current: (sessionID: UUID, context: ScreenContext?)?

    /// Fire capture for `sessionID`. Result lands in `current` whenever AX
    /// returns — could be 10 ms, could be 600 ms, could be never (if a peer
    /// AX server is wedged). The polish path doesn't wait for it.
    ///
    /// If a prior session's capture is still in flight, this overwrites the
    /// slot with the new session marker. The old capture's eventual completion
    /// is dropped on the floor by `publish`'s session-ID guard.
    func startCapture(sessionID: UUID, targetPID: pid_t, appName: String?) {
        // Mark the slot as "this session, no result yet" before any guard so
        // that if pre-checks fail, `contextIfReady` still correctly returns
        // nil for THIS session (rather than a leftover result from session N-1).
        current = (sessionID, nil)

        // Cheap MainActor-only pre-checks before paying the queue hop.
        guard AutoPaste.hasAccessibility else {
            log.info("Screen context skipped: Accessibility not granted")
            return
        }
        guard !AutoPaste.isSecureInputEnabled else {
            log.info("Screen context skipped: secure event input active")
            return
        }

        log.info("Screen context capture dispatched for \(appName ?? "(unknown)", privacy: .public) pid=\(targetPID, privacy: .public)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ScreenContextCapture.captureSync(
                targetPID: targetPID,
                appName: appName
            )
            DispatchQueue.main.async { [weak self] in
                self?.publish(sessionID: sessionID, context: result)
            }
        }
    }

    /// Whatever's been captured for `sessionID` so far. Returns nil if the
    /// capture hasn't completed yet, was overwritten by a newer session, or
    /// never produced a useful result.
    func contextIfReady(for sessionID: UUID) -> ScreenContext? {
        guard let cur = current, cur.sessionID == sessionID else { return nil }
        return cur.context
    }

    /// Forget any stored context. Called when the user disables the feature
    /// from the menu so a stale-but-permitted snapshot can't be picked up by
    /// a future session that finds Screen Context re-enabled.
    func clear() {
        current = nil
    }

    private func publish(sessionID: UUID, context: ScreenContext?) {
        // Only publish if the slot still belongs to OUR session. A newer
        // startCapture() may have already replaced the marker; in that case
        // our result is stale and must be dropped silently.
        guard let cur = current, cur.sessionID == sessionID else {
            log.info("Dropping screen context: session no longer active")
            return
        }
        if let ctx = context {
            log.info("Screen context published: app=\(ctx.appName ?? "?", privacy: .public) before=\(ctx.textBeforeCursor?.count ?? 0, privacy: .public)ch after=\(ctx.textAfterCursor?.count ?? 0, privacy: .public)ch")
        } else {
            log.info("Screen context published: nil (all gates failed or no readable text)")
        }
        current = (sessionID, context)
    }
}
