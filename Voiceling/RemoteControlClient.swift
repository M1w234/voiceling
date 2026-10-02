import Combine
import Foundation
import OSLog

private let remoteLog = Logger(
    subsystem: "com.teamwong.voiceling", category: "RoundRemote")

/// Outbound-only localhost client for the Deskling desk display.
/// It publishes coarse state and receives a five-command vocabulary. Audio,
/// transcripts, app names and focused-field details never leave this process.
/// The `/api/yaprflow/*` routes keep their pre-rename names because the
/// installed Deskling service and firmware speak them; rename all three together.
@MainActor
final class RemoteControlClient: ObservableObject {
    static let shared = RemoteControlClient()

    /// True while the bridge has accepted this client's registration and its
    /// status publishes are succeeding. Drives the menu's Deskling status row.
    @Published private(set) var isConnected = false

    private let baseURL = URL(string: "http://127.0.0.1:8737")!
    private var clientID = UUID().uuidString
    private var loopTask: Task<Void, Never>?
    private var lastAcknowledgedSequence = 0

    private init() {}

    func start() {
        guard loopTask == nil else { return }
        // A fresh token makes the bridge drop commands queued before the
        // user turned Deskling off, so re-enabling cannot replay them.
        clientID = UUID().uuidString
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.cycle()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stops polling only. A recording the desk display started keeps going
    /// and ends through the normal shortcuts.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isConnected = false
    }

    private func cycle() async {
        // stop() can land while a request is in flight. A cancelled loop must
        // not revive the connection state or execute a late command.
        if !isConnected {
            let accepted = await post(
                path: "/api/yaprflow/client", body: ["client": clientID]) != nil
            guard accepted, !Task.isCancelled else { return }
            isConnected = true
            remoteLog.info("Deskling bridge connected")
            LicenseManager.shared.noteDesklingConnected()
        }

        let published = await publishStatus()
        guard !Task.isCancelled else { return }
        guard published else {
            isConnected = false
            return
        }
        guard let response = await get(
            path: "/api/yaprflow/command",
            query: ["client": clientID,
                    "after": String(lastAcknowledgedSequence)]),
              !Task.isCancelled,
              let command = response["command"] as? [String: Any],
              let sequence = command["seq"] as? Int,
              let name = command["command"] as? String,
              sequence > lastAcknowledgedSequence else { return }

        execute(name)
        // Every command is one-shot from the relay's point of view. Recording
        // start/stop are desired-state operations; submit has its own stronger
        // one-shot insertion receipt, so a network retry cannot submit twice.
        lastAcknowledgedSequence = sequence
        _ = await publishStatus()
    }

    private func execute(_ command: String) {
        let controller = TranscriptionController.shared
        switch command {
        case "start": controller.setActive(true)
        case "stop": controller.setActive(false)
        case "toggle_lock": controller.toggle()
        case "cancel": controller.cancel()
        case "submit": controller.submitLastInsertion()
        default:
            remoteLog.error("Deskling sent an unsupported command")
        }
    }

    private func publishStatus() async -> Bool {
        let controller = TranscriptionController.shared
        let status = AppState.shared.status
        let canSubmit = controller.canRemoteSubmit
        let stateName: String
        if canSubmit { stateName = "inserted" }
        else {
            switch status {
            case .idle: stateName = "idle"
            case .preparing: stateName = "preparing"
            case .listening: stateName = "listening"
            case .finishing, .correcting, .summarizing: stateName = "processing"
            case .inserted, .copied, .captured, .learned: stateName = "saved"
            case .error: stateName = "error"
            }
        }
        return await post(path: "/api/yaprflow/status", body: [
            "client": clientID,
            "state": stateName,
            "canSubmit": canSubmit,
            "ackSeq": lastAcknowledgedSequence,
        ]) != nil
    }

    private func post(path: String, body: [String: Any]) async -> [String: Any]? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = data
        return await perform(request)
    }

    private func get(path: String, query: [String: String]) async -> [String: Any]? {
        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }
        return await perform(URLRequest(url: url))
    }

    private func perform(_ request: URLRequest) async -> [String: Any]? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { return nil }
            return object
        } catch {
            return nil
        }
    }
}
