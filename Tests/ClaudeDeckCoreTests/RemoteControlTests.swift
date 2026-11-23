import Foundation
import Testing
@testable import ClaudeDeckCore

/// Claude Code's Remote Control (RemoteControl.swift): reading the session registry, spotting the
/// disconnect dialog, and when an off request may type.
@Suite struct RemoteControlTests {
    private func entry(_ json: String) -> RemoteControl.RegistryEntry? {
        RemoteControl.parseEntry(Data(json.utf8))
    }

    @Test func registryEntryOnAndOffForms() {
        let on = entry(#"{"pid":1941,"sessionId":"094c","updatedAt":1795394908324,"bridgeSessionId":"session_01R8"}"#)
        #expect(on?.isOn == true)
        #expect(on?.bridgeSessionID == "session_01R8")
        #expect(on?.pid == 1941)
        #expect(on?.updatedAt == 1795394908324)
        // Claude Code writes null on disconnect; older files have no key; "" never counts.
        #expect(entry(#"{"pid":1,"sessionId":"a","bridgeSessionId":null}"#)?.isOn == false)
        #expect(entry(#"{"pid":1,"sessionId":"a"}"#)?.isOn == false)
        #expect(entry(#"{"pid":1,"sessionId":"a","bridgeSessionId":""}"#)?.isOn == false)
        // Not a registry entry.
        #expect(entry(#"{"sessionId":"a"}"#) == nil)
        #expect(entry(#"{"pid":1}"#) == nil)
        #expect(entry("not json") == nil)
        // Falls back to startedAt.
        #expect(entry(#"{"pid":2,"sessionId":"b","startedAt":5}"#)?.updatedAt == 5)
    }

    @Test func liveProcessWinsThenNewest() {
        let stale = RemoteControl.RegistryEntry(pid: 10, sessionID: "s", bridgeSessionID: "session_old", updatedAt: 900)
        let live = RemoteControl.RegistryEntry(pid: 11, sessionID: "s", bridgeSessionID: nil, updatedAt: 100)
        let alive: (Int32) -> Bool = { $0 != 10 }
        #expect(RemoteControl.bySession([stale, live], isAlive: alive)["s"] == live)
        #expect(RemoteControl.bySession([live, stale], isAlive: alive)["s"] == live)
        // Both live: the newest.
        let newer = RemoteControl.RegistryEntry(pid: 12, sessionID: "s", bridgeSessionID: "session_new", updatedAt: 2000)
        #expect(RemoteControl.bySession([live, newer], isAlive: { _ in true })["s"] == newer)
        // Only dead ones: nothing (a leftover file says nothing about a running session).
        #expect(RemoteControl.bySession([stale], isAlive: { _ in false }).isEmpty)
    }

    @Test func sessionsOnMatchByClaudeSessionID() {
        let a = UUID(), b = UUID(), c = UUID()
        let registry = [
            "sa": RemoteControl.RegistryEntry(pid: 1, sessionID: "sa", bridgeSessionID: "session_1"),
            "sb": RemoteControl.RegistryEntry(pid: 2, sessionID: "sb", bridgeSessionID: nil),
        ]
        #expect(RemoteControl.sessionsOn(claudeIDs: [a: "sa", b: "sb", c: "sc"], registry: registry) == [a])
    }

    @Test func readsRegistryFoldersSkippingJunk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rc-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appending(path: "claude"), account = root.appending(path: "work")
        let folders = RemoteControl.registryFolders(defaultConfigDir: main, accountConfigDirs: [account.path, main.path])
        #expect(folders.map(\.lastPathComponent) == ["sessions", "sessions"])
        #expect(folders.count == 2)
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data(#"{"pid":100,"sessionId":"x","bridgeSessionId":"session_x"}"#.utf8).write(to: folders[0].appending(path: "100.json"))
        try Data(#"{"pid":200,"sessionId":"y"}"#.utf8).write(to: folders[1].appending(path: "200.json"))
        try Data("garbage".utf8).write(to: folders[0].appending(path: "bad.json"))
        try Data(#"{"pid":300,"sessionId":"z","bridgeSessionId":"session_z"}"#.utf8).write(to: folders[0].appending(path: "300.txt"))
        let registry = RemoteControl.readRegistry(folders, isAlive: { _ in true })
        #expect(Set(registry.keys) == ["x", "y"])
        #expect(registry["x"]?.isOn == true)
        #expect(registry["y"]?.isOn == false)
    }

    // MARK: The dialog

    /// The bottom of the screen with the dialog open: a real Claude Code 2.1.283 session's output
    /// rendered by SwiftTerm at 120 columns (trailing spaces trimmed).
    private let dialog = [
        "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ Advisor Tool (experimental) is on and may use more tokens · /advisor ▔",
        "   Remote Control",
        "",
        "   This session is available in the Claude mobile app and at https://claude.ai/code/session_01R81gZDGpgHvgXWdge4crND.",
        "",
        "     Disconnect this session",
        "     Show QR code   Scan with your phone to open this session",
        "   ❯ Continue",
        "",
        "   Enter to select · Esc to continue",
    ]

    @Test func spotsTheDisconnectDialog() {
        #expect(RemoteControl.showsDisconnectDialog(dialog))
        // QR code shown: the row's label changes.
        var shown = dialog
        shown[6] = "     Hide QR code"
        #expect(RemoteControl.showsDisconnectDialog(shown))
        // Focus moved to the first row.
        var moved = dialog
        moved[5] = "   ❯ Disconnect this session"
        moved[7] = "     Continue"
        #expect(RemoteControl.showsDisconnectDialog(moved))
    }

    @Test func conversationTextIsNotTheDialog() {
        // Claude talking about the dialog: the words are there, the rows aren't.
        let chat = [
            "⏺ Pick “Disconnect this session” in the Remote Control dialog, then Continue.",
            "  Disconnect this session is the first row; Show QR code is the second.",
            "",
            "────────────────────────────────",
            "❯ ",
            "────────────────────────────────",
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        #expect(!RemoteControl.showsDisconnectDialog(chat))
        // Only the title and the first row (drawn halfway, or a different dialog).
        #expect(!RemoteControl.showsDisconnectDialog(Array(dialog.prefix(6))))
        // Rows out of order.
        var shuffled = dialog
        shuffled.swapAt(5, 7)
        #expect(!RemoteControl.showsDisconnectDialog(shuffled))
        // No footer: not the select dialog.
        #expect(!RemoteControl.showsDisconnectDialog(Array(dialog.dropLast())))
        // Scrolled far above the bottom of the screen.
        #expect(!RemoteControl.showsDisconnectDialog(dialog + Array(repeating: "", count: 30)))
    }

    @Test func disconnectKeysFollowTheCursorMode() {
        #expect(RemoteControl.disconnectKeys(applicationCursor: false) == ["\u{1B}[A", "\u{1B}[A", "\r"])
        #expect(RemoteControl.disconnectKeys(applicationCursor: true) == ["\u{1B}OA", "\u{1B}OA", "\r"])
    }

    // MARK: When to type

    @Test func offStepTypesOnlyIntoAnIdleSessionWithItOn() {
        func step(claude: Bool = true, running: Bool = true, readOnly: Bool = false, on: Bool = true,
                  switching: Bool = false, pending: Bool = false, progress: SessionCLI.Progress = .finished(0)) -> RemoteControl.OffStep {
            RemoteControl.offStep(isClaude: claude, running: running, readOnly: readOnly, on: on, switching: switching,
                                  typingPending: pending, progress: progress)
        }
        #expect(step() == .now)
        #expect(step(claude: false) == .skip(.notClaude))
        #expect(step(running: false) == .skip(.notRunning))
        #expect(step(readOnly: true) == .skip(.readOnly))
        #expect(step(on: false) == .skip(.alreadyOff))
        #expect(step(switching: true) == .wait)
        #expect(step(pending: true) == .wait)
        #expect(step(progress: .running) == .wait)
        #expect(step(progress: .blocked("needsPermission")) == .wait)
        #expect(step(progress: .limited(nil)) == .wait)
    }

    // MARK: The phone

    @Test func wireFieldIsOptionalAndBehindAFeature() throws {
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.remoteControl))
        var session = RemoteSession(id: UUID(), name: "app", project: "app", state: .idle)
        let quiet = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!quiet.contains("remoteControl"))
        session.remoteControl = true
        let back = try JSONDecoder().decode(RemoteSession.self, from: try JSONEncoder().encode(session))
        #expect(back.remoteControl == true)
        // An older host's session (no field) still decodes.
        let old = try JSONDecoder().decode(RemoteSession.self, from: Data(quiet.utf8))
        #expect(old.remoteControl == nil)
        let action = RemoteMessage.sessionAction(sessionID: session.id, action: .remoteControlOff)
        let decoded = try RemoteMessage.decode(try action.frame())
        #expect(decoded == action)
    }

    @Test func autoOffOnlyRightAfterAResume() {
        let now = Date()
        #expect(RemoteControl.autoOffDue(launchedAt: now.addingTimeInterval(-20), on: true, now: now))
        #expect(!RemoteControl.autoOffDue(launchedAt: now.addingTimeInterval(-20), on: false, now: now))
        #expect(!RemoteControl.autoOffDue(launchedAt: nil, on: true, now: now))
        // Turned on by hand later: left alone.
        #expect(!RemoteControl.autoOffDue(launchedAt: now.addingTimeInterval(-RemoteControl.resumeWatch - 1), on: true, now: now))
    }
}
