import AppKit
import Combine
import OSLog
import Security
import SwiftUI

private let log = Logger(subsystem: "com.teamwong.voiceling", category: "License")

/// Trial, Deskling inclusion and Lemon Squeezy license keys. The rules live in
/// LicensePolicy.swift; this applies them, stores the record and talks to the license API.
/// The only network traffic is a license key check; audio and text never leave the Mac.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var status: LicenseStatus
    @Published private(set) var record: LicenseRecord

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

    /// Re-checks a stored key in the background when it is due. Never locks out offline users.
    func revalidateIfDue() {
        guard LicensePolicy.needsRevalidation(record, now: Date()),
              let key = record.licenseKey else { return }
        Task {
            var form = ["license_key": key]
            if let instance = record.instanceID { form["instance_id"] = instance }
            guard let response = try? await Self.post("validate", form) else { return }
            switch LicensePolicy.check(response) {
            case .accepted:
                update { $0.lastValidated = Date() }
            case .rejected, .wrongProduct:
                log.notice("Stored license is no longer valid; returning to trial rules")
                update { $0.licenseKey = nil; $0.instanceID = nil; $0.lastValidated = nil }
            }
        }
    }

    /// Called when this Mac's Deskling service accepts Voiceling. Voiceling is free with a Deskling.
    func noteDesklingConnected() {
        guard record.desklingSeen == nil else { return }
        log.info("Deskling service found; Voiceling is included")
        update { $0.desklingSeen = Date() }
    }

    /// Returns nil on success, or a message to show.
    func activate(key rawKey: String) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter your license key." }
        guard LicenseConfig.storeID != 0 else { return "Voiceling licenses aren't on sale yet." }
        let response: LicenseAPIResponse
        do {
            response = try await Self.post("activate", ["license_key": key, "instance_name": "Voiceling for Mac"])
        } catch {
            return "Couldn't reach the license server. Check your connection and try again."
        }
        switch LicensePolicy.check(response) {
        case .accepted(let instanceID):
            guard let instanceID else { return "The license server didn't confirm this Mac. Try again." }
            update { $0.licenseKey = key; $0.instanceID = instanceID; $0.lastValidated = Date() }
            return nil
        case .wrongProduct:
            // Free the activation slot this created on someone else's product.
            if let id = response.instance?.id {
                _ = try? await Self.post("deactivate", ["license_key": key, "instance_id": id])
            }
            return "That key isn't for Voiceling."
        case .rejected(let message):
            return message
        }
    }

    /// Frees this Mac's activation so the key can move to another Mac.
    func deactivate() async -> String? {
        guard let key = record.licenseKey, let instance = record.instanceID else { return nil }
        do {
            let response = try await Self.post("deactivate", ["license_key": key, "instance_id": instance])
            guard response.deactivated == true else {
                return response.error ?? "Couldn't deactivate this Mac. Try again."
            }
        } catch {
            return "Couldn't reach the license server. Check your connection and try again."
        }
        update { $0.licenseKey = nil; $0.instanceID = nil; $0.lastValidated = nil }
        return nil
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

    private static func post(_ action: String, _ form: [String: String]) async throws -> LicenseAPIResponse {
        var request = URLRequest(url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/\(action)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try LicenseAPIResponse.decode(data)
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
    @State private var busy = false
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
                Button("Deactivate on This Mac…") { run { await manager.deactivate() } }
                    .disabled(busy)
                    .help("Frees this Mac's activation so you can use your key on another Mac.")
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
                        .disabled(busy || keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if busy { ProgressView().controlSize(.small) }
            if let message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("Voiceling only goes online to activate or check a license key. Your audio and words never leave this Mac.")
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
        case .licensed: return "Thank you for buying Voiceling."
        case .trial: return "Then \(LicenseConfig.price), once. Free with any Deskling."
        case .expired: return "Keep dictating for \(LicenseConfig.price), once. Free with any Deskling."
        }
    }

    private func activate() {
        let key = keyDraft
        run {
            let error = await manager.activate(key: key)
            if error == nil { keyDraft = "" }
            return error
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        busy = true
        message = nil
        Task { @MainActor in
            message = await action()
            busy = false
        }
    }
}
