import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "ComparisonLog")

/// Passive capture for side-by-side dictation studies (yaprflow vs Wispr
/// Flow running simultaneously). When enabled and a yaprflow session ends:
///
///   1. Our own raw transcript and delivered (post-grammar) text are logged
///      directly — no clipboard involvement.
///   2. The general pasteboard is polled for ~25 s and the FIRST string that
///      isn't one of ours is recorded as the other engine's output (Wispr
///      copies its transcript to the clipboard when it finishes).
///
/// One JSON line per dictation is appended to
/// `Application Support/yaprflow/comparison-log.jsonl`:
///   {"ts": ..., "raw": ..., "polished": ..., "other": ...}
/// `other` is null when nothing foreign appeared — either the second engine
/// wasn't running, or its output was byte-identical to ours (skipped by the
/// own-string filter; identical outputs carry no comparison signal anyway).
@MainActor
final class ComparisonLogger {
    static let shared = ComparisonLogger()

    private struct PendingEntry {
        let startedAt: Date
        let raw: String
        var polished: String?
        var other: String?
        /// Strings we ourselves may have written to the pasteboard this
        /// session — never attribute them to the other engine.
        var ownStrings: Set<String>
    }

    private struct LogLine: Encodable {
        let ts: Date
        let raw: String
        let polished: String?
        let other: String?
    }

    private let fileURL: URL
    private var pending: PendingEntry?
    private var watchTask: Task<Void, Never>?

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("yaprflow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("comparison-log.jsonl")
    }

    /// Call at session end with the raw (pre-grammar) transcript. Starts the
    /// pasteboard watch immediately — the other engine often finishes BEFORE
    /// our grammar pass does.
    func beginCapture(raw: String) {
        guard AppState.shared.comparisonLogMode, !raw.isEmpty else { return }
        finalizePending()
        pending = PendingEntry(
            startedAt: Date(),
            raw: raw,
            polished: nil,
            other: nil,
            ownStrings: [raw]
        )
        startWatcher()
    }

    /// Call when our final text is delivered (post-grammar or raw).
    func recordDelivered(_ text: String) {
        guard pending != nil else { return }
        pending?.polished = text
        pending?.ownStrings.insert(text)
    }

    /// Flush any open capture window (app quitting).
    func flush() {
        finalizePending()
    }

    private func startWatcher() {
        watchTask?.cancel()
        watchTask = Task { @MainActor in
            let pasteboard = NSPasteboard.general
            var lastChangeCount = pasteboard.changeCount
            let deadline = Date().addingTimeInterval(25)

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, var entry = pending else { return }

                let count = pasteboard.changeCount
                if count != lastChangeCount {
                    lastChangeCount = count
                    if entry.other == nil,
                       let string = pasteboard.string(forType: .string),
                       !string.isEmpty,
                       !entry.ownStrings.contains(string) {
                        entry.other = string
                        pending = entry
                        log.info("Captured foreign transcript (\(string.count, privacy: .public) chars)")
                    }
                }

                // Both sides captured — no reason to keep polling.
                if pending?.other != nil, pending?.polished != nil { break }
            }
            self.writePendingAndClear()
        }
    }

    private func finalizePending() {
        watchTask?.cancel()
        watchTask = nil
        writePendingAndClear()
    }

    private func writePendingAndClear() {
        guard let entry = pending else { return }
        pending = nil

        let line = LogLine(
            ts: entry.startedAt,
            raw: entry.raw,
            polished: entry.polished,
            other: entry.other
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            log.error("Could not append to comparison log")
        }
    }
}
