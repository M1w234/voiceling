import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "AudioDucking")

/// Mutes system output while dictating so music/video doesn't bleed into the
/// mic (and the ASR doesn't transcribe your podcast). Wispr Flow calls this
/// "ducking".
///
/// Uses the CoreAudio HAL directly: save the default output device's virtual
/// main volume, set it to 0, restore on stop. Falls back to the device mute
/// property for devices that don't expose a virtual volume (some HDMI /
/// DisplayPort outputs).
///
/// **Restore is polite:** if the user manually changed the volume mid-
/// recording (i.e. it's no longer at the ducked value), we leave their
/// setting alone rather than snapping back.
@MainActor
final class AudioDucking {
    static let shared = AudioDucking()

    /// 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume.
    /// Spelled as a raw FourCC because the named constant lives in the
    /// deprecated AudioHardwareService header; the property itself is alive
    /// and well on the HAL.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    private enum Method {
        case volume(saved: Float32)
        case mute
    }

    /// Non-nil while ducked. Carries what we changed so restore() can undo
    /// exactly that and nothing else.
    private var active: (device: AudioObjectID, method: Method)?

    private init() {}

    func duck() {
        guard active == nil else { return }
        guard let device = Self.defaultOutputDevice() else {
            log.info("Ducking skipped: no default output device")
            return
        }

        if let current = Self.getFloat(device, selector: Self.virtualMainVolume),
           Self.setFloat(device, selector: Self.virtualMainVolume, value: 0) {
            active = (device, .volume(saved: current))
            log.info("Ducked output volume (was \(current, privacy: .public))")
            return
        }

        // Volume not available/settable — try the mute switch.
        if Self.setMute(device, muted: true) {
            active = (device, .mute)
            log.info("Ducked output via mute property")
            return
        }

        log.info("Ducking unavailable on this output device")
    }

    func restore() {
        guard let (device, method) = active else { return }
        active = nil

        switch method {
        case .volume(let saved):
            // Leave the user's setting alone if they adjusted volume while
            // we were ducked.
            let current = Self.getFloat(device, selector: Self.virtualMainVolume)
            if let current, current > 0.001 {
                log.info("Skipping volume restore: user changed volume while ducked")
                return
            }
            _ = Self.setFloat(device, selector: Self.virtualMainVolume, value: saved)
            log.info("Restored output volume to \(saved, privacy: .public)")
        case .mute:
            _ = Self.setMute(device, muted: false)
            log.info("Unmuted output")
        }
    }

    // MARK: - HAL helpers

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func getFloat(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> Float32? {
        var address = outputAddress(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func setFloat(_ device: AudioObjectID, selector: AudioObjectPropertySelector, value: Float32) -> Bool {
        var address = outputAddress(selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var v = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
        ) == noErr
    }

    @discardableResult
    private static func setMute(_ device: AudioObjectID, muted: Bool) -> Bool {
        var address = outputAddress(kAudioDevicePropertyMute)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var v: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v
        ) == noErr
    }
}
