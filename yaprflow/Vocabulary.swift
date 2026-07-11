import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "Vocabulary")

/// One dictionary entry: the correct spelling plus the phrases the ASR keeps
/// mis-hearing it as ("yaprflow" ← "yapper flow", "yabber flow").
struct VocabularyEntry: Codable {
    /// Preferred spelling — what should appear in transcripts.
    var term: String
    /// Phrases the ASR produces instead. Matched case-insensitively as whole
    /// words and replaced with `term` before any other processing.
    var misheard: [String]
}

private struct VocabularyFile: Codable {
    var entries: [VocabularyEntry]
}

/// The user's personal dictionary — the "memory" for words the ASR keeps
/// getting wrong. Two mechanisms, both fed from one JSON file the user can
/// edit directly (menu → "Vocabulary…"):
///
///   1. **Deterministic replacement**: `misheard` phrases are swapped for
///      the correct `term` in the raw transcript. Works even with grammar
///      mode off; zero model involvement.
///   2. **LLM hinting**: the list of preferred terms rides along in the
///      grammar-polish prompt, so the model fixes *near*-misses the exact
///      replacement list doesn't cover.
///
/// The file is re-read at each recording start when its mtime changes, so
/// hand edits apply without relaunching.
@MainActor
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var entries: [VocabularyEntry] = []

    private let fileURL: URL
    private var loadedModificationDate: Date?
    /// Compiled (regex, replacement) pairs, longest misheard phrase first so
    /// overlapping phrases can't partially clobber each other.
    private var compiled: [(NSRegularExpression, String)] = []

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
        self.fileURL = dir.appendingPathComponent("vocabulary.json")

        if !fm.fileExists(atPath: fileURL.path) {
            seedDefaultFile()
        }
        reloadIfChanged()
    }

    /// Preferred spellings for the grammar prompt; nil when the dictionary
    /// is empty so the JSON payload stays minimal.
    var promptTerms: [String]? {
        let terms = entries.map(\.term)
        return terms.isEmpty ? nil : terms
    }

    /// Replace known mis-hearings with their preferred terms.
    func applyReplacements(to text: String) -> String {
        var result = text
        for (regex, term) in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }

    /// Re-read the file if it changed on disk (hand edits, external tools).
    /// Called at each recording start — a tiny stat + occasional small read.
    func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard mtime != loadedModificationDate else { return }
        loadedModificationDate = mtime

        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(VocabularyFile.self, from: data) else {
            log.error("vocabulary.json unreadable or malformed — keeping previous entries")
            return
        }
        entries = file.entries
        compile()
        log.info("Vocabulary loaded: \(self.entries.count, privacy: .public) terms")
    }

    /// Open the JSON in the user's default editor for .json files.
    func openInEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    private func compile() {
        var pairs: [(String, String)] = []
        for entry in entries {
            for phrase in entry.misheard where !phrase.isEmpty {
                pairs.append((phrase, entry.term))
            }
        }
        // Longest phrases first: "yapper flow app" must win over "yapper flow".
        pairs.sort { $0.0.count > $1.0.count }
        compiled = pairs.compactMap { phrase, term in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, term)
        }
    }

    private func seedDefaultFile() {
        let seed = VocabularyFile(entries: [
            VocabularyEntry(term: "yaprflow", misheard: ["yapper flow", "yabber flow", "yaper flow", "yapperflow"]),
            VocabularyEntry(term: "Wispr Flow", misheard: ["whisper flow", "whisperflow", "wisper flow"]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(seed) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        log.info("Seeded vocabulary.json")
    }
}
