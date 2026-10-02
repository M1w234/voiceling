// Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.

import Carbon.HIToolbox
import Foundation

enum HotkeyMode: String, Codable {
    case tapToToggle
    case holdToTalk
}

struct HotkeyConfig: Codable, Equatable {
    /// Sentinel value used in `keyCode` to indicate a modifier-only binding
    /// (e.g. ⌘⇧ alone, no key). Modifier-only bindings can't go through
    /// Carbon's `RegisterEventHotKey` — they're handled by `ModifierOnlyHotkey`.
    static let modifierOnlyKeyCode: UInt32 = 0

    /// Sentinel bit for the Fn / 🌐 (Globe) key inside `modifiers`. Fn isn't a
    /// Carbon modifier (no cmdKey-style constant) and can't be a Carbon key
    /// code either, so we represent it with a high bit that never collides
    /// with the low-bit Carbon modifier masks. `ModifierOnlyHotkey` maps it
    /// to/from `CGEventFlags.maskSecondaryFn`. Fn is the natural dictation key
    /// on modern Mac laptops, so it's allowed as a stand-alone trigger.
    static let fnBit: UInt32 = 0x8000_0000

    var keyCode: UInt32
    var modifiers: UInt32
    var mode: HotkeyMode

    /// For modifier-only bindings: the device-dependent CGEventFlags bits
    /// (NX_DEVICE*KEYMASK — left/right specific) the chord must match, so
    /// Voiceling can distinguish left ⌘⇧ from right ⌘⇧ the way Wispr does.
    /// 0 = side-agnostic (fires on either side, and `ModifierOnlyHotkey`
    /// learns + persists the side on first use). Ignored for key bindings.
    var sideMask: UInt

    init(keyCode: UInt32, modifiers: UInt32, mode: HotkeyMode = .tapToToggle, sideMask: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mode = mode
        self.sideMask = sideMask
    }

    var isModifierOnly: Bool {
        keyCode == Self.modifierOnlyKeyCode
    }

    /// A modifier-only binding needs a chord of at least two modifiers.
    /// Zero would fire on every flagsChanged transition; a single modifier
    /// (bare ⌘ or ⇧) collides with normal typing — holding ⌘ for 200 ms
    /// while thinking about a shortcut would start dictation. Each Carbon
    /// modifier flag is one bit, so the bit count is the modifier count.
    var isValid: Bool {
        if isModifierOnly {
            // Fn alone is a legitimate single-key trigger (it's a dedicated
            // key, not a chord you accidentally hold while typing). Every
            // other modifier-only binding still needs a chord of ≥2.
            return modifiers == Self.fnBit || modifiers.nonzeroBitCount >= 2
        }
        return true
    }

    // Default for fresh installs: ⌥⇧ (Option+Shift) held together. Modifier-
    // only so there's no key that collides with app shortcuts (the old ⌘T
    // default clashed with "new tab" everywhere), and no Fn/emoji conflict.
    // Supports hold-to-talk and double-tap-to-lock out of the box. Needs
    // Accessibility (which the app already needs for auto-paste); the first-
    // launch flow surfaces that.
    static let defaultHotkey = HotkeyConfig(
        keyCode: modifierOnlyKeyCode,
        modifiers: UInt32(optionKey | shiftKey),
        mode: .tapToToggle
    )

    private static let defaultsKey = "voiceling.hotkey.v1"

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, mode, sideMask
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        self.modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        self.mode = try c.decodeIfPresent(HotkeyMode.self, forKey: .mode) ?? .tapToToggle
        self.sideMask = try c.decodeIfPresent(UInt.self, forKey: .sideMask) ?? 0
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func load() -> HotkeyConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }

    var shortcutDisplayString: String {
        var s = ""
        if modifiers & Self.fnBit != 0         { s += "🌐" }
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0  { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0   { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0     { s += "⌘" }
        if !isModifierOnly { s += Self.name(for: keyCode) }
        return s
    }

    var displayString: String {
        var s = shortcutDisplayString
        // Modifier-only bindings always support both hold and double-tap-to-lock
        // simultaneously, so the per-mode "(hold)" suffix doesn't apply.
        if !isModifierOnly && mode == .holdToTalk { s += "  (hold)" }
        return s
    }

    private static func name(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        default: return "Key\(code)"
        }
    }
}

/// Optional second dictation shortcut intended for mouse/remapping software.
/// It deliberately accepts only a key-based shortcut: modifier-only triggers
/// use side-aware physical-key state that synthetic Logitech events may not
/// preserve reliably.
struct ExternalHotkeyConfig: Codable, Equatable {
    var enabled: Bool
    var keyCode: UInt32
    var modifiers: UInt32
    var mode: HotkeyMode

    static let defaultConfig = ExternalHotkeyConfig(
        enabled: false,
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        mode: .tapToToggle
    )

    private static let defaultsKey = "voiceling.externalHotkey.v1"

    var hotkey: HotkeyConfig {
        HotkeyConfig(keyCode: keyCode, modifiers: modifiers, mode: mode)
    }

    var shortcutDisplayString: String {
        hotkey.shortcutDisplayString
    }

    func conflicts(with primary: HotkeyConfig) -> Bool {
        !primary.isModifierOnly
            && primary.keyCode == keyCode
            && primary.modifiers == modifiers
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func load() -> ExternalHotkeyConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ExternalHotkeyConfig.self, from: data)
    }
}
