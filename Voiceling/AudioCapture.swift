// Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.

@preconcurrency import AVFoundation

enum AudioCaptureError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone available"
        }
    }
}

nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false
    private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void

    /// Fired when the engine's I/O configuration changes out from under us —
    /// default input device switched, sample rate changed. The engine has
    /// already stopped delivering buffers by the time this fires; the owner
    /// should end the session gracefully.
    var onConfigurationChange: (@Sendable () -> Void)?

    init(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.bufferHandler = bufferHandler
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        // With no usable input device (external-mic-only setup, mic unplugged)
        // the node reports a 0 Hz / 0-channel format, and installTap raises an
        // uncatchable ObjC exception. Fail as a Swift error instead so the
        // overlay can show "No microphone available".
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [handler = bufferHandler] buffer, _ in
            guard let copy = AudioCapture.copy(buffer: buffer) else { return }
            handler(copy)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
        else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        }
        return copy
    }
}
