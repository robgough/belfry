import Foundation
import Observation

/// Special keys the touch UI can synthesize (dock buttons, cursor trackpad,
/// shortcut sequences). Renderer-agnostic: the iOS workspace routes these
/// through libghostty's key events so mode-dependent encodings (application
/// cursor keys etc.) come out right.
enum TerminalKey: String, Codable, Sendable {
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case escape, tab, enter, backspace
    case pageUp, pageDown, home, end
}

extension TerminalWorkspace {
    /// Default no-op: only touch platforms synthesize keys today (macOS has a
    /// hardware keyboard driving the surface directly).
    func sendKey(_ key: TerminalKey) {}
}

/// One-shot sticky modifier for on-screen keyboards: the dock's Ctrl chip
/// arms it, the next typed character is translated to its control code and
/// the modifier disarms. Pure logic — the table also serves the shortcut
/// executor's `.control` steps.
@MainActor
@Observable
final class StickyModifierState {
    private(set) var controlArmed = false

    func armControl() { controlArmed = true }
    func disarm() { controlArmed = false }
    func toggleControl() { controlArmed.toggle() }

    /// Transform typed text through the armed modifier (consuming it), or
    /// pass it through untouched.
    func apply(to text: String) -> Data {
        guard controlArmed else { return Data(text.utf8) }
        controlArmed = false
        guard text.count == 1, let byte = ControlSequences.controlByte(for: text) else {
            return Data(text.utf8)
        }
        return Data([byte])
    }
}

/// Caret-notation control codes: what Ctrl+<char> means on a terminal.
enum ControlSequences {
    /// The control byte for a single typed character, or nil when the pair
    /// has no meaning (sending the bare text is more useful than swallowing
    /// the keystroke).
    static func controlByte(for character: String) -> UInt8? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        switch scalar {
        case "a"..."z":
            return UInt8(scalar.value - UnicodeScalar("a").value + 1)
        case "A"..."Z":
            return UInt8(scalar.value - UnicodeScalar("A").value + 1)
        case "[":  return 0x1B   // ESC
        case "\\": return 0x1C
        case "]":  return 0x1D
        case "^", "6": return 0x1E
        case "_", "-": return 0x1F
        case " ", "@", "2": return 0x00   // NUL
        case "?": return 0x7F   // DEL
        default:
            return nil
        }
    }

    /// Data for a caret-notation control string like "^C" or a bare letter
    /// ("c" → Ctrl-C). Used by shortcut `.control` steps.
    static func data(forControl spec: String) -> Data? {
        let key = spec.hasPrefix("^") ? String(spec.dropFirst()) : spec
        guard let byte = controlByte(for: key.lowercased()) else { return nil }
        return Data([byte])
    }
}
