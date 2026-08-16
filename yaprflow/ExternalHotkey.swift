import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "ExternalHotkey")

/// Independent Carbon hotkey for programmable mice and other remapping tools.
/// Keeping its registration separate means the primary shortcut can continue
/// using ModifierOnlyHotkey while this key-based shortcut is active.
@MainActor
final class ExternalHotkey {
    static let shared = ExternalHotkey()

    nonisolated(unsafe) static var onPressed: (@Sendable () -> Void)?
    nonisolated(unsafe) static var onReleased: (@Sendable () -> Void)?

    /// 'YPrX'. Every Carbon handler on the application target sees every
    /// registered hotkey event, so this signature must be unique and filtered.
    static let signature: OSType = 0x59_50_72_58

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregisterHotKey()
        guard installEventHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 4)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            isRegistered = true
            return true
        } else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            isRegistered = false
            return false
        }
    }

    func unregister() {
        unregisterHotKey()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        isRegistered = false
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let status = InstallEventHandler(
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
                guard err == noErr, hotKeyID.signature == ExternalHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let handler: (@Sendable () -> Void)?
                switch Int(GetEventKind(event)) {
                case kEventHotKeyPressed:
                    handler = ExternalHotkey.onPressed
                case kEventHotKeyReleased:
                    handler = ExternalHotkey.onReleased
                default:
                    handler = nil
                }
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
        }
        return status == noErr && eventHandlerRef != nil
    }
}
