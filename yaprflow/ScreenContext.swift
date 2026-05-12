import AppKit
import ApplicationServices
import Foundation
import OSLog

// `nonisolated` because the project default is MainActor isolation and this
// logger is referenced from `ScreenContextCapture.captureSync` which must
// run on a background queue. Logger is Sendable so this is safe.
nonisolated private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "ScreenContext")

/// Snapshot of what the user was looking at when they fired the hotkey.
/// Carries at most ~700 chars of cursor-adjacent text plus the frontmost
/// app's localized name. Designed to be small, copyable, Sendable, and safe
/// to pass to a local LLM as reference data.
struct ScreenContext: Sendable {
    let appName: String?
    /// Up to ~500 chars immediately before the cursor / selection start.
    let textBeforeCursor: String?
    /// Up to ~200 chars immediately after the cursor / selection end.
    let textAfterCursor: String?
}

/// Synchronously captures screen context via the Accessibility C API.
///
/// MUST be called from a background DispatchQueue, never the main thread.
/// Every AX call is bounded by `AXUIElementSetMessagingTimeout`, but a hung
/// XPC peer can still take hundreds of milliseconds to time out — which is
/// unacceptable on the hotkey-press critical path that we want to keep
/// responsive even on a cold Slack window.
///
/// `nonisolated` because the project defaults to MainActor isolation, and
/// we explicitly do NOT want these AX C calls hopping to main.
nonisolated enum ScreenContextCapture {
    // Roughly mirrors Wispr Flow's hint window. Both sides fit comfortably
    // inside Qwen2.5-1.5B's 32K context alongside the transcript.
    private static let charsBefore = 500
    private static let charsAfter  = 200

    /// Cap on the focused field's reported length before we agree to a full
    /// `kAXValue` fallback read. Above this we refuse to pull the field
    /// across the AX boundary at all — pulling a 50k-char Cursor document
    /// just to throw most of it away is the worst case Codex flagged in v2.
    private static let maxFullValueChars = 4096

    /// Per-element AX messaging timeout. Multiple elements are read per
    /// capture, so worst-case total wall-clock is bounded by this × ~6.
    private static let axTimeout: Float = 0.1

    /// Default-deny these bundle IDs outright. Conservative on purpose: any
    /// app that commonly displays secrets (password managers, native mail/
    /// messages/keychain UIs) plus ALL browsers (a tab can be a bank, an
    /// email, a 1Password vault page). The intended v1 scope is native
    /// text editors, IDEs, Notes, TextEdit, code editors via AX.
    private static let denylistPrefixes: [String] = [
        "com.1password.",
        "com.bitwarden.",
        "com.lastpass.",
        "com.agilebits.",
        "com.dashlane.",
        "com.keepassxc.",
    ]
    private static let denylistExact: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        // Browsers — see comment above.
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",        // Arc
        "company.thebrowser.dia",            // Dia
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Roles we'll read text from. `AXWebArea` is deliberately omitted —
    /// "focused element" inside a web view can mean the entire page's text,
    /// which reopens the screen-scrape failure mode we're trying to avoid.
    private static let allowedRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]

    /// Capture context for the frontmost app. Returns nil if any privacy
    /// gate fails or no readable text near the cursor exists.
    static func captureSync(targetPID: pid_t, appName: String?) -> ScreenContext? {
        // Gate: bundle ID denylist.
        let bundleID = NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
        if let bid = bundleID, isDenylisted(bid) {
            log.info("Screen context skipped: \(bid, privacy: .public) is denylisted")
            return nil
        }

        let app = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(app, axTimeout)

        // Gate: focused element exists and is an AXUIElement.
        guard let focusedRef = copyAttribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axTimeout)

        // Gate: secure text field — refuse outright. Some password fields
        // happily return cleartext via kAXValue; we don't even ask.
        if let subrole = readStringAttr(element, kAXSubroleAttribute),
           subrole == "AXSecureTextField" {
            log.info("Screen context skipped: AXSecureTextField subrole")
            return nil
        }

        // Gate: role allowlist. Skip if missing or unexpected — better to
        // miss a custom-role editor than over-read a screen-reader-ish view.
        guard let role = readStringAttr(element, kAXRoleAttribute),
              allowedRoles.contains(role) else {
            return nil
        }

        // Cursor / selection range.
        guard let selRange = readCFRange(element, kAXSelectedTextRangeAttribute),
              selRange.location >= 0,
              selRange.length >= 0 else {
            return nil
        }
        let selStart = selRange.location
        let selEnd   = selRange.location + selRange.length

        // Number of characters — used to clamp "after" and as the gate
        // for a kAXValue fallback. -1 means unsupported/unknown.
        let totalCount = readIntAttr(element, kAXNumberOfCharactersAttribute) ?? -1

        // Plan A: parameterized-range reads, one for each side. These ask
        // the target app for just the chars we want — no whole-document
        // transfer across the AX boundary.
        let beforeStart = max(0, selStart - charsBefore)
        let beforeLen   = selStart - beforeStart
        let afterLen: Int = {
            if totalCount >= 0 { return max(0, min(charsAfter, totalCount - selEnd)) }
            return charsAfter
        }()

        var textBefore = readStringForRange(element, location: beforeStart, length: beforeLen)
        var textAfter  = readStringForRange(element, location: selEnd, length: afterLen)

        // Plan B: if parameterized reads aren't supported AND the field is
        // small, pull kAXValue once and slice it ourselves. Refuse if the
        // field is large or its size is unknown.
        if textBefore == nil && textAfter == nil {
            guard totalCount >= 0, totalCount <= maxFullValueChars else {
                log.info("Screen context skipped: parameterized read failed and field too large (\(totalCount, privacy: .public)) for kAXValue fallback")
                return nil
            }
            guard let full = readStringAttr(element, kAXValueAttribute) else {
                return nil
            }
            let (b, a) = sliceAroundCursor(full, selStart: selStart, selEnd: selEnd)
            textBefore = b
            textAfter  = a
        }

        // Truncate on Character boundaries — UTF-16 cuts can leave dangling
        // combining marks or split surrogate pairs.
        let trimmedBefore = textBefore.map { trimToLast($0, count: charsBefore) } ?? ""
        let trimmedAfter  = textAfter.map  { trimToFirst($0, count: charsAfter) } ?? ""

        if trimmedBefore.isEmpty && trimmedAfter.isEmpty {
            return nil
        }

        return ScreenContext(
            appName: appName,
            textBeforeCursor: trimmedBefore.isEmpty ? nil : trimmedBefore,
            textAfterCursor:  trimmedAfter.isEmpty  ? nil : trimmedAfter
        )
    }

    // MARK: - Gate helpers

    private static func isDenylisted(_ bundleID: String) -> Bool {
        if denylistExact.contains(bundleID) { return true }
        for prefix in denylistPrefixes where bundleID.hasPrefix(prefix) { return true }
        return false
    }

    // MARK: - AX read helpers
    //
    // These funnel every AX C call through a single nil/error path so the
    // caller can just chain `guard let` instead of repeating AXError
    // handling at every line.

    private static func copyAttribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }

    private static func readStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        guard let v = copyAttribute(element, attr) else { return nil }
        if let s = v as? String { return s }
        if let s = v as? NSAttributedString { return s.string }
        return nil
    }

    private static func readIntAttr(_ element: AXUIElement, _ attr: String) -> Int? {
        guard let v = copyAttribute(element, attr) else { return nil }
        return (v as? NSNumber)?.intValue
    }

    private static func readCFRange(_ element: AXUIElement, _ attr: String) -> CFRange? {
        guard let v = copyAttribute(element, attr) else { return nil }
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axValue = v as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func readStringForRange(
        _ element: AXUIElement,
        location: Int,
        length: Int
    ) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &ref
        )
        guard err == .success else { return nil }
        if let s = ref as? String { return s }
        if let s = ref as? NSAttributedString { return s.string }
        return nil
    }

    // MARK: - Slicing

    /// UTF-16-aware slice for the kAXValue fallback path. Returns (before,
    /// after) where the selection itself is dropped — the LLM doesn't need
    /// to see what the user is replacing.
    private static func sliceAroundCursor(_ s: String, selStart: Int, selEnd: Int) -> (String?, String?) {
        let utf16 = s.utf16
        guard selStart >= 0, selEnd >= selStart, selEnd <= utf16.count else {
            return (nil, nil)
        }
        let startU = utf16.index(utf16.startIndex, offsetBy: selStart)
        let endU   = utf16.index(utf16.startIndex, offsetBy: selEnd)
        // Snap inward to grapheme-cluster boundaries — if the UTF-16 offset
        // lands inside a surrogate pair, samePosition(in:) returns nil.
        guard let startIdx = startU.samePosition(in: s),
              let endIdx   = endU.samePosition(in: s) else {
            return (nil, nil)
        }
        let before = String(s[s.startIndex..<startIdx])
        let after  = String(s[endIdx..<s.endIndex])
        return (before, after)
    }

    private static func trimToLast(_ s: String, count: Int) -> String {
        guard s.count > count else { return s }
        return String(s.suffix(count))
    }

    private static func trimToFirst(_ s: String, count: Int) -> String {
        guard s.count > count else { return s }
        return String(s.prefix(count))
    }
}
