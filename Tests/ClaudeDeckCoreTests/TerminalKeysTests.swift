import Foundation
import Testing
@testable import ClaudeDeckCore

/// The bytes the phone's quick keys, on-screen keyboard and hardware keyboard send to the terminal.
@Suite struct TerminalKeysTests {
    @Test func ctrlLettersAreControlBytes() {
        #expect(TerminalKeys.controlByte(for: "c") == 0x03)
        #expect(TerminalKeys.controlByte(for: "C") == 0x03)
        #expect(TerminalKeys.controlByte(for: "a") == 0x01)
        #expect(TerminalKeys.controlByte(for: "d") == 0x04)
        #expect(TerminalKeys.controlByte(for: "z") == 0x1a)
        #expect(TerminalKeys.controlByte(for: "l") == 0x0c)
        #expect(TerminalKeys.controlByte(for: "[") == 0x1b)
        #expect(TerminalKeys.controlByte(for: " ") == 0x00)
        #expect(TerminalKeys.controlByte(for: "?") == 0x7f)
        #expect(TerminalKeys.controlByte(for: "é") == nil)
        #expect(TerminalKeys.controlByte(for: "1") == nil)
    }

    @Test func typedTextWithModifiers() {
        #expect(TerminalKeys.bytes(text: "c", modifiers: .control) == [0x03])
        #expect(TerminalKeys.bytes(text: "\n", modifiers: .control) == [0x0a])
        #expect(TerminalKeys.bytes(text: "\n", modifiers: []) == [0x0d])
        #expect(TerminalKeys.bytes(text: "x", modifiers: .option) == [0x1b, UInt8(ascii: "x")])
        #expect(TerminalKeys.bytes(text: "c", modifiers: [.control, .option]) == [0x1b, 0x03])
        #expect(TerminalKeys.bytes(text: "c", modifiers: .command).isEmpty)
        #expect(TerminalKeys.bytes(text: "ğ", modifiers: []) == Array("ğ".utf8))
    }

    @Test func specialKeys() {
        typealias K = TerminalKeys.Keysym
        #expect(TerminalKeys.bytes(keysym: K.escape) == [0x1b])
        #expect(TerminalKeys.bytes(keysym: K.tab) == [0x09])
        #expect(TerminalKeys.bytes(keysym: K.tab, modifiers: .shift) == Array("\u{1b}[Z".utf8))
        #expect(TerminalKeys.bytes(keysym: K.returnKey) == [0x0d])
        #expect(TerminalKeys.bytes(keysym: K.returnKey, modifiers: .shift) == [0x0a])
        #expect(TerminalKeys.bytes(keysym: K.backSpace) == [0x7f])
        #expect(TerminalKeys.bytes(keysym: K.up) == Array("\u{1b}[A".utf8))
        #expect(TerminalKeys.bytes(keysym: K.up, applicationCursor: true) == Array("\u{1b}OA".utf8))
        #expect(TerminalKeys.bytes(keysym: K.left, modifiers: .control) == Array("\u{1b}[1;5D".utf8))
        #expect(TerminalKeys.bytes(keysym: K.pageUp) == Array("\u{1b}[5~".utf8))
        #expect(TerminalKeys.bytes(keysym: K.forwardDelete) == Array("\u{1b}[3~".utf8))
        #expect(TerminalKeys.bytes(keysym: K.function(1)) == Array("\u{1b}OP".utf8))
        #expect(TerminalKeys.bytes(keysym: K.function(5)) == Array("\u{1b}[15~".utf8))
        #expect(TerminalKeys.bytes(keysym: K.function(12)) == Array("\u{1b}[24~".utf8))
        #expect(TerminalKeys.bytes(keysym: 0x61) == nil)
    }
}
