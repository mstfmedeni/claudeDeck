import Foundation

/// Bytes a terminal key sends (the phone's quick keys, its on-screen keyboard and a hardware
/// keyboard). Ctrl+letter is always the plain control byte (0x03 for C), never a kitty CSI-u
/// sequence, so it works whatever keyboard mode the program asked for.
public enum TerminalKeys {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// X11 keysyms of the special keys (what the screen-sharing keyboard emits).
    public enum Keysym {
        public static let backSpace: UInt32 = 0xff08
        public static let tab: UInt32 = 0xff09
        public static let returnKey: UInt32 = 0xff0d
        public static let escape: UInt32 = 0xff1b
        public static let home: UInt32 = 0xff50
        public static let left: UInt32 = 0xff51
        public static let up: UInt32 = 0xff52
        public static let right: UInt32 = 0xff53
        public static let down: UInt32 = 0xff54
        public static let pageUp: UInt32 = 0xff55
        public static let pageDown: UInt32 = 0xff56
        public static let end: UInt32 = 0xff57
        public static let insert: UInt32 = 0xff63
        public static let forwardDelete: UInt32 = 0xffff
        /// F1 is 0xffbe, F2 0xffbf, …
        public static func function(_ number: Int) -> UInt32 { 0xffbd + UInt32(number) }
    }

    public static let interrupt: [UInt8] = [0x03]
    public static let endOfFile: [UInt8] = [0x04]
    public static let suspend: [UInt8] = [0x1a]
    public static let clearScreen: [UInt8] = [0x0c]
    public static let escape: [UInt8] = [0x1b]
    public static let tab: [UInt8] = [0x09]
    public static let backTab: [UInt8] = Array("\u{1b}[Z".utf8)

    /// The control byte for Ctrl plus a character: a–z (either case) are 1–26; `@ [ \ ] ^ _` and
    /// space follow the ASCII rule (char & 0x1f), `?` is DEL; `2`–`8` are the VT220 aliases. nil
    /// when the character has no control code.
    public static func controlByte(for character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return value - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1b
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1c
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1d
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1e
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "7"): return 0x1f
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7f
        default: return nil
        }
    }

    /// Text typed with modifiers: Ctrl turns a single character into its control byte (Return
    /// becomes Ctrl+J, a new line in Claude Code); Option prefixes Esc (meta). Command sends nothing
    /// (the phone keeps ⌘ shortcuts for itself).
    public static func bytes(text: String, modifiers: Modifiers) -> [UInt8] {
        if modifiers.contains(.command) { return [] }
        var out: [UInt8] = []
        if modifiers.contains(.control) {
            if text == "\n" || text == "\r" { out = [0x0a] }
            else if text.count == 1, let first = text.first, let byte = controlByte(for: first) { out = [byte] }
            else { out = Array(text.utf8) }
        } else {
            out = text == "\n" ? [0x0d] : Array(text.utf8)
        }
        if modifiers.contains(.option) { out.insert(0x1b, at: 0) }
        return out
    }

    /// A special key's sequence (xterm). Arrows follow the program's cursor mode (`ESC O A` in
    /// application mode, `ESC [ A` otherwise); with modifiers they use the `ESC [ 1 ; m A` form.
    /// nil for a keysym that isn't a special key.
    public static func bytes(keysym: UInt32, modifiers: Modifiers = [], applicationCursor: Bool = false) -> [UInt8]? {
        let param = modifierParameter(modifiers)
        func csi(_ final: String) -> [UInt8] {
            if let param { return Array("\u{1b}[1;\(param)\(final)".utf8) }
            return Array((applicationCursor ? "\u{1b}O" : "\u{1b}[").utf8) + Array(final.utf8)
        }
        func tilde(_ code: Int) -> [UInt8] {
            Array((param.map { "\u{1b}[\(code);\($0)~" } ?? "\u{1b}[\(code)~").utf8)
        }
        func ss3(_ final: String) -> [UInt8] {
            Array((param.map { "\u{1b}[1;\($0)\(final)" } ?? "\u{1b}O\(final)").utf8)
        }
        var out: [UInt8]
        switch keysym {
        case Keysym.escape: out = escape
        case Keysym.tab: return modifiers.contains(.shift) ? backTab : tab
        case Keysym.returnKey: return modifiers.contains(.control) || modifiers.contains(.shift) ? [0x0a] : [0x0d]
        case Keysym.backSpace: out = modifiers.contains(.control) ? [0x08] : [0x7f]
        case Keysym.up: return csi("A")
        case Keysym.down: return csi("B")
        case Keysym.right: return csi("C")
        case Keysym.left: return csi("D")
        case Keysym.home: return csi("H")
        case Keysym.end: return csi("F")
        case Keysym.insert: return tilde(2)
        case Keysym.forwardDelete: return tilde(3)
        case Keysym.pageUp: return tilde(5)
        case Keysym.pageDown: return tilde(6)
        case Keysym.function(1)...Keysym.function(4):
            return ss3(["P", "Q", "R", "S"][Int(keysym - Keysym.function(1))])
        case Keysym.function(5)...Keysym.function(12):
            return tilde([15, 17, 18, 19, 20, 21, 23, 24][Int(keysym - Keysym.function(5))])
        default: return nil
        }
        if modifiers.contains(.option) { out.insert(0x1b, at: 0) }
        return out
    }

    /// xterm's modifier parameter (1 + shift 1 + alt 2 + ctrl 4); nil without modifiers.
    static func modifierParameter(_ modifiers: Modifiers) -> Int? {
        var value = 0
        if modifiers.contains(.shift) { value += 1 }
        if modifiers.contains(.option) { value += 2 }
        if modifiers.contains(.control) { value += 4 }
        return value == 0 ? nil : value + 1
    }
}
