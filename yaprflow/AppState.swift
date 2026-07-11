import Combine
import SwiftUI

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case correcting(String)
    case summarizing  // New: on-demand summary in progress
    case copied
    /// Delivered via clipboard-free direct insertion (Preserve Clipboard on).
    case inserted
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private static let streamingModeKey = "yaprflow.streamingMode"
    private static let grammarModeKey = "yaprflow.grammarMode"
    private static let autoPasteModeKey = "yaprflow.autoPasteMode"
    private static let screenContextModeKey = "yaprflow.screenContextMode"
    private static let preserveClipboardModeKey = "yaprflow.preserveClipboardMode"
    private static let duckWhileRecordingKey = "yaprflow.duckWhileRecording"
    private static let soundEffectsEnabledKey = "yaprflow.soundEffectsEnabled"
    private static let startSoundNameKey = "yaprflow.startSoundName"
    private static let stopSoundNameKey = "yaprflow.stopSoundName"
    private static let lastTranscriptKey = "yaprflow.lastTranscript"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey

    /// When `true` (default), show live partials during dictation at the cost
    /// of slightly lower accuracy. When `false`, record silently and transcribe
    /// the full clip in one pass when the hotkey is released — more accurate
    /// for longer sentences, but no text appears until you stop.
    @Published var streamingMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingMode, forKey: Self.streamingModeKey)
        }
    }

    /// When `true`, run the finalized transcript through an on-device MLX LLM
    /// for grammar / punctuation correction. The original text is still copied
    /// to the clipboard immediately so the workflow doesn't block.
    @Published var grammarMode: Bool {
        didSet {
            UserDefaults.standard.set(grammarMode, forKey: Self.grammarModeKey)
        }
    }

    /// When `true`, the final transcript is auto-pasted into the focused text
    /// field via a synthesized ⌘V (in addition to landing on the clipboard).
    /// Gated at the paste site on Accessibility permission, secure-input
    /// state, and a focus-PID match captured at recording start. Defaults to
    /// off so existing users aren't surprised by injected keystrokes.
    @Published var autoPasteMode: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteMode, forKey: Self.autoPasteModeKey)
        }
    }

    /// When `true`, capture a small window of text around the cursor at
    /// recording start and feed it to the on-device grammar polish so the
    /// LLM can prefer spellings already on the screen ("fleet view" →
    /// "FleetView"). Uses the same Accessibility permission as auto-paste.
    /// Defaults to off — reading text out of other apps is a meaningfully
    /// different privacy posture than the existing features and shouldn't
    /// turn itself on. Browsers, mail, messages, and password managers are
    /// hard-denied at capture time regardless of this toggle.
    @Published var screenContextMode: Bool {
        didSet {
            UserDefaults.standard.set(screenContextMode, forKey: Self.screenContextModeKey)
        }
    }

    /// When `true` (and Auto-Paste is on), deliver transcripts by direct
    /// insertion — AX selected-text write, falling back to synthetic Unicode
    /// typing — instead of clipboard + ⌘V, leaving whatever the user had
    /// copied untouched. Falls back to the clipboard when neither insertion
    /// mechanism works so the transcript is never lost.
    @Published var preserveClipboardMode: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboardMode, forKey: Self.preserveClipboardModeKey)
        }
    }

    /// When `true`, mute system audio output for the duration of a recording
    /// session (Wispr-style ducking) and restore it afterwards. Toggling it
    /// mid-recording applies immediately (wired in the menu item).
    @Published var duckWhileRecording: Bool {
        didSet {
            UserDefaults.standard.set(duckWhileRecording, forKey: Self.duckWhileRecordingKey)
        }
    }

    /// When `true`, play a short system sound on recording start and stop.
    /// Defaults to on — chimes are a small but useful signal that the mic is
    /// actually live, especially on flaky hotkeys. The specific sounds are
    /// picked via `startSoundName` / `stopSoundName`.
    @Published var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Self.soundEffectsEnabledKey)
        }
    }

    /// Name of the macOS system sound played at recording start. Resolved by
    /// `NSSound(named:)`, so values must match a basename in
    /// `/System/Library/Sounds/` (without the .aiff extension).
    @Published var startSoundName: String {
        didSet {
            UserDefaults.standard.set(startSoundName, forKey: Self.startSoundNameKey)
        }
    }

    /// Name of the macOS system sound played at recording stop. See
    /// `startSoundName` for resolution semantics.
    @Published var stopSoundName: String {
        didSet {
            UserDefaults.standard.set(stopSoundName, forKey: Self.stopSoundNameKey)
        }
    }

    /// Live input audio level, normalized to 0…1. Driven from
    /// `TranscriptionController.feed()` at each PCM buffer (~50 Hz at the
    /// engine's default tap size). Consumed by the overlay's bouncing-bar
    /// visualizer; safe to leave at 0 outside of an active session.
    @Published var inputLevel: Float = 0

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// can be re-copied from the menu bar after the clipboard has been replaced.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    /// The raw transcript before grammar correction. Empty when grammar mode
    /// is off or hasn't run yet.
    @Published var lastOriginalTranscript: String = ""

    private init() {
        if let stored = UserDefaults.standard.object(forKey: Self.streamingModeKey) as? Bool {
            self.streamingMode = stored
        } else {
            self.streamingMode = true
        }
        if let stored = UserDefaults.standard.object(forKey: Self.grammarModeKey) as? Bool {
            self.grammarMode = stored
        } else {
            self.grammarMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.autoPasteModeKey) as? Bool {
            self.autoPasteMode = stored
        } else {
            self.autoPasteMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.screenContextModeKey) as? Bool {
            self.screenContextMode = stored
        } else {
            self.screenContextMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.preserveClipboardModeKey) as? Bool {
            self.preserveClipboardMode = stored
        } else {
            self.preserveClipboardMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.duckWhileRecordingKey) as? Bool {
            self.duckWhileRecording = stored
        } else {
            self.duckWhileRecording = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.soundEffectsEnabledKey) as? Bool {
            self.soundEffectsEnabled = stored
        } else {
            self.soundEffectsEnabled = true
        }
        self.startSoundName = UserDefaults.standard.string(forKey: Self.startSoundNameKey)
            ?? SoundEffect.defaultStartName
        self.stopSoundName = UserDefaults.standard.string(forKey: Self.stopSoundNameKey)
            ?? SoundEffect.defaultStopName
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
