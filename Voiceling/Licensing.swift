import AppKit
import Combine
import OSLog
import Security
import SwiftUI

private let log = Logger(subsystem: "com.teamwong.voiceling", category: "License")

/// Trial, Deskling inclusion and signed license keys. The rules live in LicensePolicy.swift;
/// this applies them and stores the record. Keys are verified on this Mac, so licensing
/// never goes online.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var status: LicenseStatus
    @Published private(set) var record: LicenseRecord
    /// The outcome of an activation that arrived through a voiceling:// link.
    @Published var notice: String?

    private init() {
        let record = LicenseStorage.load() ?? LicenseRecord(trialStarted: Date())
        LicenseStorage.save(record)                       // pins the trial start on first launch
        self.record = record
        self.status = LicensePolicy.status(record, now: Date())
    }

    var canDictate: Bool {
        refresh()
        return status.canDictate
    }

    func refresh() {
        let next = LicensePolicy.status(record, now: Date())
        if next != status { status = next }
    }

    /// Called when this Mac's Deskling service accepts Voiceling. Voiceling is free with a Deskling.
    func noteDesklingConnected() {
        guard record.desklingSeen == nil else { return }
        log.info("Deskling service found; Voiceling is included")
        update { $0.desklingSeen = Date() }
    }

    /// Returns nil on success, or a message to show.
    func activate(key rawKey: String) -> String? {
        let key = rawKey.filter { !$0.isWhitespace }
        guard !key.isEmpty else { return "Paste your license key." }
        guard LicenseKey.verify(key) != nil else {
            return "That isn't a valid Voiceling license key. Copy it again from your purchase page."
        }
        update { $0.licenseKey = key }
        log.info("License key activated")
        return nil
    }

    /// Handles voiceling://activate?key=… from the purchase page.
    func handle(url: URL) {
        guard url.scheme == "voiceling", url.host == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" })?.value else { return }
        notice = activate(key: key) ?? "Voiceling is activated. Thank you!"
        LicenseWindowController.shared.show()
    }

    /// Shown when a shortcut is pressed after the trial has ended. Nothing records.
    func presentTrialEnded() {
        AppState.shared.status = .error("Your Voiceling trial has ended")
        NotchOverlayWindowController.shared.show()
        LicenseWindowController.shared.show()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if case .error = AppState.shared.status {
                AppState.shared.status = .idle
                NotchOverlayWindowController.shared.hide()
            }
        }
    }

    private func update(_ change: (inout LicenseRecord) -> Void) {
        change(&record)
        LicenseStorage.save(record)
        refresh()
    }
}

/// The record lives in the login keychain so reinstalling doesn't restart the trial, with a
/// defaults copy as a fallback if the keychain is unavailable.
private enum LicenseStorage {
    static let service = "com.teamwong.voiceling.license"
    static let account = "record"
    static let defaultsKey = "voiceling.licenseRecord"

    static func load() -> LicenseRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let record = try? JSONDecoder().decode(LicenseRecord.self, from: data) {
            return record
        }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LicenseRecord.self, from: data)
    }

    static func save(_ record: LicenseRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            if added != errSecSuccess { log.error("Keychain save failed: \(added)") }
        } else if status != errSecSuccess {
            log.error("Keychain update failed: \(status)")
        }
    }
}

@MainActor
final class LicenseWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LicenseWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Voiceling License"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: LicenseView())
        hosting.view.frame = window.contentLayoutRect
        window.contentView = hosting.view
    }

    func show() {
        guard let window else { return }
        LicenseManager.shared.refresh()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

struct LicenseView: View {
    @ObservedObject private var manager = LicenseManager.shared
    @State private var keyDraft = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image("VoicelingMark")
                    .resizable()
                    .frame(width: 46, height: 46)
                    .foregroundStyle(Color(red: 0.8, green: 0.949, blue: 0.541))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.067, green: 0.102, blue: 0.082)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }

            switch manager.status {
            case .includedWithDeskling:
                EmptyView()
            case .licensed:
                EmptyView()
            case .trial, .expired:
                Button {
                    if let url = LicenseConfig.checkoutURL { NSWorkspace.shared.open(url) }
                } label: {
                    Text("Buy Voiceling for \(LicenseConfig.price)").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(LicenseConfig.checkoutURL == nil)
                .help(LicenseConfig.checkoutURL == nil ? "Purchasing opens soon." : "Opens checkout in your browser.")
                HStack {
                    TextField("License key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(activate)
                    Button("Activate", action: activate)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let message = message ?? manager.notice {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(manager.status == .licensed ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("License keys are checked on this Mac. Voiceling never goes online for licensing, and your audio and words never leave this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 440, height: 330, alignment: .topLeading)
    }

    private var title: String {
        switch manager.status {
        case .includedWithDeskling: return "Included with your Deskling"
        case .licensed: return "Licensed"
        case .trial(let days): return "Free trial: \(days) \(days == 1 ? "day" : "days") left"
        case .expired: return "Your free trial has ended"
        }
    }

    private var subtitle: String {
        switch manager.status {
        case .includedWithDeskling: return "Voiceling is yours. No license needed."
        case .licensed: return "Thank you for buying Voiceling. Your key works on all your Macs."
        case .trial: return "Then \(LicenseConfig.price), once. Free with any Deskling."
        case .expired: return "Keep dictating for \(LicenseConfig.price), once. Free with any Deskling."
        }
    }

    private func activate() {
        manager.notice = nil
        message = manager.activate(key: keyDraft)
        if message == nil { keyDraft = "" }
    }
}
