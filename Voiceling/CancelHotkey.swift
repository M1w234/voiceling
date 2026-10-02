import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.teamwong.voiceling", category: "CancelHotkey")

/// Escape-to-cancel for an active dictation session. Registered ONLY while a
/// recording is live and unregistered the moment it ends — while registered,
/// Carbon routes bare Esc presses to us instead of the frontmost app, which
/// is exactly the Wispr behaviour (Esc discards the dictation) but would be
/// hostile if left active outside a session.
///
/// Filters events by EventHotKeyID like every Carbon handler in this app —
/// see the gotcha in CLAUDE.md.
@MainActor
final class CancelHotkey {
    static let shared = CancelHotkey()

    nonisolated(unsafe) static var onPressed: (@Sendable () -> Void)?

    /// 'YPrE'
    static let signature: OSType = 0x59_50_72_45

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func register() {
        guard hotKeyRef == nil else { return }
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 3)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            log.error("RegisterEventHotKey for Esc failed: \(status, privacy: .public)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == CancelHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let handler = CancelHotkey.onPressed
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}
