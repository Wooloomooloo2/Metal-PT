import Carbon.HIToolbox

/// A global hotkey: Carbon virtual key code plus Carbon modifier mask (`controlKey`, `optionKey`,
/// `shiftKey`, `cmdKey`), as `RegisterEventHotKey` takes them (no Accessibility permission needed).
///
/// Persistence: `Codable` (JSON `Data`/string); `display` ("⌃⇧F6") is also a stable, human-readable
/// string form that `init?(display:)` parses back, suitable for `@AppStorage`.
public struct HotkeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// Only the four modifiers we model; caps lock, fn etc. are dropped.
    private static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    public static let record = HotkeyCombo(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey | shiftKey))
    public static let overlay = HotkeyCombo(keyCode: UInt32(kVK_F7), modifiers: UInt32(controlKey | shiftKey))

    /// Modifier glyphs in display order: ⌃⌥⇧⌘.
    private static let modifierGlyphs: [(Character, Int)] = [
        ("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey),
    ]

    private static let keyNames: [(String, Int)] = {
        var t: [(String, Int)] = [
            ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E),
            ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J),
            ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O),
            ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
            ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y),
            ("Z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab), ("Esc", kVK_Escape),
            ("Delete", kVK_Delete), ("←", kVK_LeftArrow), ("→", kVK_RightArrow), ("↑", kVK_UpArrow),
            ("↓", kVK_DownArrow), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), (",", kVK_ANSI_Comma),
            (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash), (";", kVK_ANSI_Semicolon),
            ("'", kVK_ANSI_Quote), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            ("\\", kVK_ANSI_Backslash), ("`", kVK_ANSI_Grave),
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in f.enumerated() { t.append(("F\(i + 1)", code)) }
        return t
    }()

    /// "⌃⇧F6": modifier glyphs in ⌃⌥⇧⌘ order, then the key name. Unknown keys show as "Key0x__".
    public var display: String {
        var s = ""
        for (glyph, mask) in Self.modifierGlyphs where modifiers & UInt32(mask) != 0 { s.append(glyph) }
        let name = Self.keyNames.first { UInt32($0.1) == keyCode }?.0
            ?? "Key0x" + String(keyCode, radix: 16, uppercase: true)
        return s + name
    }

    /// Parses `display` output back. Nil if the key is unknown or modifiers are out of order/duplicated.
    public init?(display: String) {
        var rest = Substring(display)
        var mods: UInt32 = 0
        var next = 0
        while let ch = rest.first, let i = Self.modifierGlyphs.firstIndex(where: { $0.0 == ch }) {
            guard i >= next else { return nil }
            mods |= UInt32(Self.modifierGlyphs[i].1)
            next = i + 1
            rest = rest.dropFirst()
        }
        let name = String(rest)
        if let entry = Self.keyNames.first(where: { $0.0 == name }) {
            self.init(keyCode: UInt32(entry.1), modifiers: mods)
        } else if name.hasPrefix("Key0x"), let code = UInt32(name.dropFirst(5), radix: 16) {
            self.init(keyCode: code, modifiers: mods)
        } else {
            return nil
        }
    }
}

extension HotkeyCombo {
    /// True for F1–F20 (allowed without modifiers: they type nothing).
    public var isFunctionKey: Bool {
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return f.contains { UInt32($0) == keyCode }
    }

    /// Why this combo must not be registered as a global hotkey, or nil if it may be. A bare key (no modifier)
    /// would swallow ordinary typing system-wide, so only function keys may go without one. The modifiers are
    /// re-masked to the four modelled bits (a decoded combo may carry others).
    public var registrationProblem: String? {
        let mods = modifiers & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        if mods == 0 && !isFunctionKey { return "\(display) needs a modifier (⌃, ⌥, ⇧ or ⌘)" }
        return nil
    }
}

/// Settings' click-to-record hotkey field: what a key press means while a field is recording (pure; the app feeds it
/// `NSEvent.keyCode` and `NSEvent.modifierFlags.rawValue`).
public enum HotkeyCapture {
    public enum Outcome: Equatable, Sendable {
        /// Bare Esc: stop recording, keep the current combo.
        case cancel
        /// Bare Delete / Forward Delete: back to the default combo.
        case reset
        case combo(HotkeyCombo)
    }

    // `NSEvent.ModifierFlags` bits (AppKit is not imported here).
    private static let cocoaShift: UInt = 1 << 17
    private static let cocoaControl: UInt = 1 << 18
    private static let cocoaOption: UInt = 1 << 19
    private static let cocoaCommand: UInt = 1 << 20

    /// The four modelled modifiers, Cocoa → Carbon; caps lock, fn and the rest are dropped.
    public static func carbonModifiers(cocoaFlags: UInt) -> UInt32 {
        var m = 0
        if cocoaFlags & cocoaControl != 0 { m |= controlKey }
        if cocoaFlags & cocoaOption != 0 { m |= optionKey }
        if cocoaFlags & cocoaShift != 0 { m |= shiftKey }
        if cocoaFlags & cocoaCommand != 0 { m |= cmdKey }
        return UInt32(m)
    }

    public static func outcome(keyCode: UInt16, cocoaFlags: UInt) -> Outcome {
        let mods = carbonModifiers(cocoaFlags: cocoaFlags)
        if mods == 0 {
            if Int(keyCode) == kVK_Escape { return .cancel }
            if Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete { return .reset }
        }
        return .combo(HotkeyCombo(keyCode: UInt32(keyCode), modifiers: mods))
    }

    /// Why `combo` cannot be used when the other hotkey (`otherName`) is `other`, or nil if it can. Whether another
    /// app holds it is only known by registering it.
    public static func problem(_ combo: HotkeyCombo, other: HotkeyCombo, otherName: String) -> String? {
        if let p = combo.registrationProblem { return p }
        if combo == other { return "\(combo.display) is already the \(otherName) hotkey" }
        return nil
    }
}
