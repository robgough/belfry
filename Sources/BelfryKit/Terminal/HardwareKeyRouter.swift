import Foundation

/// Routing for hardware-keyboard presses (iPad Magic Keyboard et al).
///
/// The naive approach — forward every UIPress into ghostty's key API and
/// claim it handled — turned out to eat Return and Ctrl chords on real
/// hardware. This router makes the decision explicit and testable: plain
/// typing passes through to UIKit's text-input system (which delivers
/// `insertText` reliably), while keys the text system won't deliver —
/// control chords, Alt-as-Meta, Return, Esc, arrows, paging — are handled
/// deterministically with the same primitives the on-screen dock uses.
enum HardwareKeyRouter {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let alternate = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    enum Action: Equatable {
        /// Not ours (modifier-only press, system shortcut): call super so
        /// UIKit / the system can have it.
        case passToSystem
        /// A printing key: let the text-input system deliver it as
        /// `insertText` (call super; do NOT synthesize).
        case passToTextInput
        /// Send these bytes to the host, claim the press.
        case sendBytes(Data)
        /// Synthesize this key through the renderer's key path, claim it.
        case sendKey(TerminalKey)
        /// Paste the general pasteboard, claim it.
        case paste
    }

    // iOS HID usages (UIKeyboardHIDUsage raw values) for keys we route.
    private static let specialKeys: [UInt32: TerminalKey] = [
        40: .enter,      // keyboardReturnOrEnter
        88: .enter,      // keypadEnter
        41: .escape,     // keyboardEscape
        43: .tab,        // keyboardTab
        42: .backspace,  // keyboardDeleteOrBackspace
        76: .backspace,  // keyboardDeleteForward (nearest useful mapping)
        82: .arrowUp, 81: .arrowDown, 80: .arrowLeft, 79: .arrowRight,
        75: .pageUp, 78: .pageDown, 74: .home, 77: .end,
    ]

    /// Decide what to do with one hardware key press.
    /// - Parameters:
    ///   - keyCode: HID usage (UIKey.keyCode.rawValue)
    ///   - charactersIgnoringModifiers: UIKey.charactersIgnoringModifiers
    ///   - modifiers: active modifier flags
    static func route(keyCode: UInt32, charactersIgnoringModifiers: String,
                      modifiers: Modifiers) -> Action {
        // Modifier keys themselves (LeftControl 0xE0 … RightGUI 0xE7).
        if (0xE0...0xE7).contains(keyCode) { return .passToSystem }

        // Command shortcuts belong to the system (⌘Tab, ⌘H, …) with two
        // exceptions: paste, and ⌘. as Escape — the iPadOS convention, and
        // the only Esc many iPad Magic Keyboards have (no function row).
        if modifiers.contains(.command) {
            if modifiers == .command {
                if keyCode == 25 { return .paste }               // V
                if keyCode == 55 { return .sendKey(.escape) }    // .
            }
            return .passToSystem
        }

        // Special keys: deterministic synthesis, modifiers or not. (Shift/Ctrl
        // variants of arrows etc. are a later refinement — plain arrows first.)
        if let key = specialKeys[keyCode] {
            return .sendKey(key)
        }

        // Ctrl chords: the text system won't deliver these; encode directly.
        if modifiers.contains(.control) {
            if let byte = ControlSequences.controlByte(for: charactersIgnoringModifiers) {
                return .sendBytes(Data([byte]))
            }
            return .passToSystem
        }

        // Alt-as-Meta: ESC prefix, terminal convention.
        if modifiers.contains(.alternate), !charactersIgnoringModifiers.isEmpty {
            return .sendBytes(Data([0x1B] + Array(charactersIgnoringModifiers.utf8)))
        }

        // Plain / shifted typing: UIKit's text system handles it best.
        return .passToTextInput
    }
}
