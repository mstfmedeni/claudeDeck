import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ProgramStatusTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    func report(_ body: String) -> ProgramStatusReport? {
        if case .report(let r)? = ProgramStatusParser.parse(bytes(body)) { return r }
        return nil
    }

    // MARK: Scanner

    func scan(_ chunks: [String], codes: Set<Int> = [7501, 133]) -> [(Int, String)] {
        var scanner = OSCScanner(codes: codes)
        var found: [(Int, String)] = []
        for chunk in chunks {
            let data = bytes(chunk)
            data.withUnsafeBufferPointer { buffer in
                scanner.scan(buffer) { code, payload in found.append((code, String(decoding: payload, as: UTF8.self))) }
            }
        }
        return found
    }

    @Test func scannerFindsBothTerminators() {
        let found = scan(["text \u{1B}]7501;state=working\u{07} more \u{1B}]133;D;1\u{1B}\\ tail"])
        #expect(found.map(\.0) == [7501, 133])
        #expect(found.map(\.1) == ["state=working", "D;1"])
    }

    @Test func scannerJoinsSequencesSplitAcrossChunks() {
        let found = scan(["abc\u{1B}", "]75", "01;state=bl", "ocked\u{1B}", "\\xyz"])
        #expect(found.count == 1)
        #expect(found.first?.1 == "state=blocked")
    }

    @Test func scannerIgnoresOtherCodesAndEscapes() {
        let found = scan(["\u{1B}]0;title\u{07}\u{1B}[31mred\u{1B}]8;;http://x\u{1B}\\\u{1B}]133;C\u{07}"])
        #expect(found.map(\.0) == [133])
        #expect(found.first?.1 == "C")
    }

    @Test func scannerDropsOverlongAndCancelledSequences() {
        let long = String(repeating: "a", count: ProgramStatusParser.maxSequenceLength + 10)
        let found = scan(["\u{1B}]7501;\(long)\u{07}", "\u{1B}]7501;state=done\u{18}", "\u{1B}]7501;state=error\u{07}"])
        #expect(found.map(\.1) == ["state=error"])
    }

    @Test func scannerSkipsPlainOutputQuickly() {
        #expect(scan([String(repeating: "plain output line\n", count: 1000)]).isEmpty)
    }

    // MARK: OSC 7501

    @Test func parsesTheSpecExample() {
        let r = report("state=blocked:kind=permission:app=terraform:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/")
        #expect(r?.state == .blocked)
        #expect(r?.kind == .permission)
        #expect(r?.app == "terraform")
        #expect(r?.message == "Apply 3 to add, 1 to change, 0 to destroy?")
        #expect(r?.id == "")
    }

    @Test func queryIsRecognized() {
        #expect(ProgramStatusParser.parse(bytes("?")) == .query)
        #expect(ProgramStatusParser.parse(bytes(" ? ")) == .query)
        #expect(ProgramStatusParser.queryReply.hasPrefix("\u{1B}]7501;?"))
        #expect(ProgramStatusParser.queryReply.hasSuffix("\u{1B}\\"))
    }

    @Test func unknownOrMissingStateIgnoresTheReport() {
        #expect(ProgramStatusParser.parse(bytes("state=sleeping")) == nil)
        #expect(ProgramStatusParser.parse(bytes("msg=\(b64("hi"))")) == nil)
        #expect(ProgramStatusParser.parse(bytes("")) == nil)
    }

    @Test func whitespaceMalformedPairsAndRepeatsFollowTheSpec() {
        let r = report(" state = working : junk : progress = 42 : state=done : unknown=1 ")
        #expect(r?.state == .done) // last one wins
        #expect(r?.progress == nil) // progress only with working / blocked
        #expect(report("state=working:progress=42")?.progress == 42)
        #expect(report("state=working:progress=101")?.progress == nil)
        #expect(report("state=working:progress=-1")?.progress == nil)
        #expect(report("state=working:progress=4x")?.progress == nil)
    }

    @Test func kindOnlyWithBlocked() {
        #expect(report("state=working:kind=question")?.kind == nil)
        #expect(report("state=blocked:kind=question")?.kind == .question)
        #expect(report("state=blocked:kind=nope")?.kind == nil)
    }

    @Test func textValuesAreBase64WithoutControlCharacters() {
        #expect(report("state=done:msg=\(b64("Built in 3s"))")?.message == "Built in 3s")
        #expect(report("state=done:title=\(b64("cargo"))")?.title == "cargo")
        #expect(report("state=done:msg=not*base64")?.message == nil)
        #expect(report("state=done:msg=\(b64("two\nlines"))")?.message == nil)
        #expect(report("state=done:msg=\(b64(String(repeating: "x", count: 2049)))")?.message == nil)
        #expect(report("state=done:title=\(b64(String(repeating: "x", count: 193)))")?.title == nil)
        #expect(report("state=done:app=\(String(repeating: "a", count: 33))")?.app == nil)
    }

    @Test func idsAreValidated() {
        #expect(report("state=working:id=build/test")?.id == "build/test")
        #expect(ProgramStatusParser.parse(bytes("state=working:id=a//b")) == nil)
        #expect(ProgramStatusParser.parse(bytes("state=working:id=" + Array(repeating: "a", count: 9).joined(separator: "/"))) == nil)
        #expect(ProgramStatusParser.parse(bytes("state=working:id=" + String(repeating: "a", count: 33))) == nil)
    }

    // MARK: OSC 133

    @Test func parsesShellMarks() {
        #expect(ShellMark.parse(bytes("A")) == .promptStart)
        #expect(ShellMark.parse(bytes("A;k=i")) == .promptStart)
        #expect(ShellMark.parse(bytes("B")) == .commandStart)
        #expect(ShellMark.parse(bytes("C")) == .commandExecuted)
        #expect(ShellMark.parse(bytes("D;0")) == .commandFinished(exitCode: 0))
        #expect(ShellMark.parse(bytes("D;127;aid=12")) == .commandFinished(exitCode: 127))
        #expect(ShellMark.parse(bytes("D")) == .commandFinished(exitCode: nil))
        #expect(ShellMark.parse(bytes("P;k=i")) == nil)
        #expect(ShellMark.parse(bytes("")) == nil)
    }

    // MARK: Tracker

    @Test func shellCommandsGoWorkingThenFinishedOrFailed() {
        var t = ProgramStatusTracker()
        #expect(t.status == nil)
        do { let changed = t.apply(.promptStart, now: t0); #expect(!changed) }
        do { let changed = t.apply(.commandExecuted, now: t0); #expect(changed) }
        #expect(t.status?.state == .working)
        do { let changed = t.apply(.commandFinished(exitCode: 2), now: t0 + 5); #expect(changed) }
        #expect(t.status == ProgramStatus(state: .failed, exitCode: 2, since: t0 + 5))
        // The prompt after it keeps the result on show.
        do { let changed = t.apply(.promptStart, now: t0 + 6); #expect(!changed) }
        #expect(t.status?.state == .failed)
        t.apply(.commandExecuted, now: t0 + 10)
        t.apply(.commandFinished(exitCode: 0), now: t0 + 12)
        #expect(t.status == ProgramStatus(state: .finished, exitCode: 0, since: t0 + 12))
    }

    @Test func emptyLinesAndInterruptsShowNothingNew() {
        var t = ProgramStatusTracker()
        // D without C: an empty line.
        do { let changed = t.apply(.commandFinished(exitCode: 0), now: t0); #expect(!changed) }
        #expect(t.status == nil)
        t.apply(.commandExecuted, now: t0)
        t.apply(.commandFinished(exitCode: 130), now: t0 + 1)
        #expect(t.status == nil)
    }

    @Test func promptWithoutFinishEndsTheCommandQuietly() {
        var t = ProgramStatusTracker()
        t.apply(.commandExecuted, now: t0)
        do { let changed = t.apply(.promptStart, now: t0 + 1); #expect(changed) }
        #expect(t.status == nil)
    }

    @Test func blockedBeatsWorkingAndPromptDropsBoth() {
        var t = ProgramStatusTracker()
        t.apply(.commandExecuted, now: t0)
        t.apply(report("state=working:msg=\(b64("Migrating"))")!, now: t0 + 1)
        #expect(t.status?.state == .working)
        #expect(t.status?.message == "Migrating")
        t.apply(report("state=blocked:id=db:kind=question:msg=\(b64("Apply 3 migrations?"))")!, now: t0 + 2)
        #expect(t.status == ProgramStatus(state: .blocked, message: "Apply 3 migrations?", kind: .question, since: t0 + 2))
        // Same blocked record, new message: same moment (no second notification).
        t.apply(report("state=blocked:id=db:kind=question:msg=\(b64("Apply 4 migrations?"))")!, now: t0 + 3)
        #expect(t.status?.since == t0 + 2)
        #expect(t.status?.message == "Apply 4 migrations?")
        t.apply(report("state=clear:id=db")!, now: t0 + 4)
        #expect(t.status?.state == .working)
        t.apply(report("state=blocked:id=db")!, now: t0 + 5)
        t.apply(.commandFinished(exitCode: 1), now: t0 + 6)
        t.apply(.promptStart, now: t0 + 6)
        #expect(t.status == ProgramStatus(state: .failed, exitCode: 1, since: t0 + 6))
    }

    @Test func programResultBeatsTheExitCodeOfItsCommand() {
        var t = ProgramStatusTracker()
        t.apply(.commandExecuted, now: t0)
        t.apply(report("state=working")!, now: t0)
        t.apply(report("state=error:msg=\(b64("2 tests failed"))")!, now: t0 + 3)
        // Reported done/error while the command still runs: the result is ready.
        #expect(t.status?.state == .failed)
        #expect(t.status?.message == "2 tests failed")
        t.apply(.commandFinished(exitCode: 1), now: t0 + 4)
        #expect(t.status == ProgramStatus(state: .failed, exitCode: 1, message: "2 tests failed", since: t0 + 3))
        // The next command's own exit code wins over the old record.
        t.apply(.commandExecuted, now: t0 + 10)
        #expect(t.status?.state == .working)
        t.apply(.commandFinished(exitCode: 0), now: t0 + 11)
        #expect(t.status == ProgramStatus(state: .finished, exitCode: 0, since: t0 + 11))
    }

    @Test func idleMeansAtRestAndDoneSurvivesTheProcess() {
        var t = ProgramStatusTracker()
        t.apply(report("state=working")!, now: t0)
        t.apply(report("state=idle")!, now: t0 + 1)
        #expect(t.status == nil)
        t.apply(report("state=done:app=cargo")!, now: t0 + 2)
        #expect(t.status?.state == .finished)
        #expect(t.status?.app == "cargo")
        t.apply(report("state=working:id=child")!, now: t0 + 3)
        #expect(t.status?.state == .working)
        t.processExited(now: t0 + 4)
        #expect(t.status?.state == .finished)
        #expect(t.status?.since == t0 + 4) // back from working: a new moment
        t.apply(report("state=clear")!, now: t0 + 5)
        #expect(t.status == nil)
    }

    @Test func clearRemovesChildrenToo() {
        var t = ProgramStatusTracker()
        t.apply(report("state=blocked:id=build/test")!, now: t0)
        t.apply(report("state=working:id=build")!, now: t0)
        t.apply(report("state=working:id=builder")!, now: t0)
        t.apply(report("state=clear:id=build")!, now: t0)
        #expect(t.status?.state == .working) // "builder" isn't a child of "build"
        t.apply(report("state=clear:id=builder")!, now: t0)
        #expect(t.status == nil)
    }

    @Test func unchangedInputsDontReportAChange() {
        var t = ProgramStatusTracker()
        do { let changed = t.apply(report("state=working:msg=\(b64("a"))")!, now: t0); #expect(changed) }
        do { let changed = t.apply(report("state=working:msg=\(b64("a"))")!, now: t0 + 1); #expect(!changed) }
        do { let changed = t.apply(report("state=working:msg=\(b64("b"))")!, now: t0 + 2); #expect(changed) }
        #expect(t.status?.since == t0)
    }

    @Test func recordCountIsCapped() {
        var t = ProgramStatusTracker()
        for i in 0..<ProgramStatusTracker.maxRecords { t.apply(report("state=done:id=r\(i)")!, now: t0) }
        do { let changed = t.apply(report("state=blocked:id=extra")!, now: t0); #expect(!changed) }
        #expect(t.status?.state == .finished)
    }

    @Test func monitorParsesRawOutput() {
        var m = ProgramStatusMonitor()
        var r = m.feed(bytes("$ make\r\n\u{1B}]133;C\u{07}building…\r\n\u{1B}]7501;?\u{1B}\\"), now: t0)
        #expect(r.changed && r.replyToQuery)
        #expect(m.status?.state == .working)
        r = m.feed(bytes("\u{1B}]133;D;2\u{07}\u{1B}]133;A\u{07}$ "), now: t0 + 1)
        #expect(r.changed && !r.replyToQuery)
        #expect(m.status == ProgramStatus(state: .failed, exitCode: 2, since: t0 + 1))
        r = m.feed(bytes("ls\r\n"), now: t0 + 2)
        #expect(!r.changed)
    }

    // MARK: Shell integration

    /// Runs an interactive shell with the integration on `input`, in a scratch HOME.
    func runShell(_ shell: ShellIntegration.Shell, path: String, input: String) throws -> String {
        let root = FileManager.default.temporaryDirectory.appending(path: "cd-shell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home"), folder = root.appending(path: "integration")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The user's own startup files still run.
        try "export FROM_USER_ZSHENV=1\n".write(to: home.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
        try "export FROM_USER_ZSHRC=1\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try "export FROM_USER_PROFILE=1\n".write(to: home.appending(path: ".bash_profile"), atomically: true, encoding: .utf8)
        try ShellIntegration.install(in: folder)
        let launch = ShellIntegration.launch(shell, folder: folder, environment: [:])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = launch.args.filter { $0 != "-l" } + ["-i"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"].merging(launch.environment) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func zshIntegrationMarksCommandsAndKeepsUserFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let out = try runShell(.zsh, path: "/bin/zsh", input: "echo \"[$FROM_USER_ZSHENV$FROM_USER_ZSHRC]\"\nfalse\n\ntrue\nexit\n")
        #expect(out.contains("[11]"))
        var m = ProgramStatusMonitor()
        var states: [ProgramStatus.State?] = []
        for line in out.split(separator: "\u{07}") {
            if m.feed(Array((line + "\u{07}").utf8), now: t0).changed { states.append(m.status?.state) }
        }
        #expect(out.contains("\u{1B}]133;D;1\u{07}"))
        #expect(out.contains("\u{1B}]133;D;0\u{07}"))
        // The last `working` is `exit` itself.
        #expect(states == [.working, .finished, .working, .failed, .working, .finished, .working])
    }

    @Test func bashIntegrationMarksCommandsAndKeepsUserFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else { return }
        let out = try runShell(.bash, path: "/bin/bash", input: "echo \"[$FROM_USER_PROFILE]\"\nfalse\n\ntrue\nexit\n")
        #expect(out.contains("[1]"))
        #expect(out.contains("\u{1B}]133;C\u{07}"))
        #expect(out.contains("\u{1B}]133;D;1\u{07}"))
        #expect(out.contains("\u{1B}]133;D;0\u{07}"))
        // The empty line between them is no command.
        #expect(out.components(separatedBy: "\u{1B}]133;D;").count - 1 == 3)
    }

    @Test func zshLaunchKeepsTheUsersZDOTDIR() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let plain = ShellIntegration.launch(.zsh, folder: folder, environment: [:])
        #expect(plain.environment["ZDOTDIR"] == "/tmp/x/zsh")
        #expect(plain.environment[ShellIntegration.userZDOTDIRKey] == nil)
        #expect(plain.login)
        let custom = ShellIntegration.launch(.zsh, folder: folder, environment: ["ZDOTDIR": "/Users/me/.config/zsh"])
        #expect(custom.environment[ShellIntegration.userZDOTDIRKey] == "/Users/me/.config/zsh")
        let bash = ShellIntegration.launch(.bash, folder: folder, environment: [:])
        #expect(!bash.login)
        #expect(bash.args == ["--init-file", "/tmp/x/bash/claudedeck.bash"])
        #expect(ShellIntegration.shell(forPath: "/bin/zsh") == .zsh)
        #expect(ShellIntegration.shell(forPath: "/bin/sh") == nil)
    }
}
