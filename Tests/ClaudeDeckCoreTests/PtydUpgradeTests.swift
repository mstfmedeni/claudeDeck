import Darwin
import Foundation
import Security
import Testing
@testable import ClaudeDeckCore

// MARK: - State handover (unit)

@Suite struct PtydHandoverTests {
    private func spawn(_ id: String) -> PtydSpawn {
        PtydSpawn(id: id, executable: "/bin/zsh", argv: ["-zsh"], env: ["A=1", "B=ü"], cwd: "/tmp/a b",
                  cols: 120, rows: 40, meta: ["askToken": "t", "pencil": "1"])
    }

    @Test func roundTripsEverySessionWithItsScrollback() throws {
        var binary = [UInt8](repeating: 0, count: 300)
        for i in binary.indices { binary[i] = UInt8(truncatingIfNeeded: i * 7) }
        let state = PtydHandover(instance: "INST", fromBuild: "48", listenFD: 3, lockFD: 4, draining: true, sessions: [
            .init(spawn: spawn("a"), pid: 101, master: 7, startedAt: 1_700_000_000.25, cols: 100, rows: 30, alive: true,
                  pendingInput: Array("ls\r".utf8), killIn: 2.5, readStopped: false, scrollback: binary),
            .init(spawn: spawn("b"), pid: 102, master: -1, startedAt: 1_700_000_001, cols: 80, rows: 24, alive: false,
                  exitCode: 3),
            .init(spawn: spawn("c"), pid: 103, master: 9, startedAt: 1_700_000_002, cols: 80, rows: 24, alive: true,
                  readStopped: true, scrollback: Array("tick 1\r\n".utf8)),
        ])
        let decoded = try PtydHandover.decode(try state.encoded())
        #expect(decoded == state)
        #expect(decoded.sessions[0].scrollback == binary)
        #expect(decoded.sessions[1].exitCode == 3)
        #expect(decoded.descriptors == [3, 4, 7, 9])
    }

    @Test func fileIsPrivateUnlinkedAndReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cdh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = PtydHandover(instance: "I", fromBuild: "1", listenFD: 5, lockFD: 6, draining: false, sessions: [
            .init(spawn: spawn("x"), pid: 1, master: 8, startedAt: 1, cols: 1, rows: 1, alive: true,
                  scrollback: [UInt8](repeating: 65, count: 100_000)),
        ])
        let fd = try state.writeUnlinked(in: dir)
        defer { close(fd) }
        // Nothing left in the folder, whatever happens next.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(try PtydHandover.read(fd: fd) == state)
    }

    @Test func refusesGarbageAndFutureFormats() throws {
        #expect(throws: PtydHandover.Failure.self) { try PtydHandover.decode(Array("nope".utf8)) }
        var state = PtydHandover(instance: "I", fromBuild: "1", listenFD: 5, lockFD: 6, draining: false, sessions: [])
        state.format = PtydHandover.currentFormat + 1
        #expect(throws: PtydHandover.Failure.unsupportedFormat(PtydHandover.currentFormat + 1)) {
            try PtydHandover.decode(try state.encoded())
        }
        // Truncated scrollback.
        let ok = PtydHandover(instance: "I", fromBuild: "1", listenFD: 5, lockFD: 6, draining: false, sessions: [
            .init(spawn: spawn("x"), pid: 1, master: 8, startedAt: 1, cols: 1, rows: 1, alive: true, scrollback: [1, 2, 3]),
        ])
        let bytes = try ok.encoded()
        #expect(throws: PtydHandover.Failure.self) { try PtydHandover.decode(Array(bytes.dropLast())) }
        #expect(throws: PtydHandover.Failure.self) { try PtydHandover.decode(bytes + [0]) }
    }

    @Test func scrollbackIsBoundedKeepingTheNewestBytes() {
        let big = [UInt8](0..<200).map { $0 }
        let small = [UInt8](repeating: 9, count: 10)
        let out = PtydHandover.bounded([big, small, big], limit: 110)
        #expect(out[1] == small)                       // fits its share: untouched
        #expect(out[0].count + out[2].count == 100)    // the rest shares what's left
        #expect(out[0] == Array(big.suffix(out[0].count)))
        #expect(PtydHandover.bounded([big], limit: 1000) == [big])
    }
}

// MARK: - Upgrade decision (unit)

@Suite struct PtydUpgradeCheckTests {
    @Test func onlyANewerBuildGoes() {
        #expect(PtydUpgradeCheck.isNewer("50", than: "49"))
        #expect(!PtydUpgradeCheck.isNewer("49", than: "49"))
        #expect(!PtydUpgradeCheck.isNewer("48", than: "49"))
        #expect(!PtydUpgradeCheck.isNewer(nil, than: "49"))
        #expect(!PtydUpgradeCheck.isNewer("dev", than: "49"))
        #expect(!PtydUpgradeCheck.isNewer("50", than: "dev"))
        #expect(PtydUpgradeCheck.verdict(candidateBuild: "50", currentBuild: "49", signatureProblem: nil, allowSameBuild: false)
                == .go(build: "50"))
        #expect(PtydUpgradeCheck.verdict(candidateBuild: "49", currentBuild: "49", signatureProblem: nil, allowSameBuild: false)
                == .notNewer(candidate: "49", current: "49"))
        // A bad signature is refused whatever the build (and in test mode too).
        #expect(PtydUpgradeCheck.verdict(candidateBuild: "50", currentBuild: "49", signatureProblem: "bad", allowSameBuild: true)
                == .invalid("bad"))
        #expect(PtydUpgradeCheck.verdict(candidateBuild: nil, currentBuild: "test", signatureProblem: nil, allowSameBuild: true)
                == .go(build: nil))
    }

    @Test func readsTheBuildOfTheBundleTheBinarySitsIn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cdb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appending(path: "X.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "51"], format: .xml, options: 0)
        try plist.write(to: root.appending(path: "X.app/Contents/Info.plist"))
        #expect(PtydUpgradeCheck.bundleBuild(ofExecutable: macOS.appending(path: "claudedeck-ptyd").path) == "51")
        #expect(PtydUpgradeCheck.bundleBuild(ofExecutable: root.appending(path: "claudedeck-ptyd").path) == nil)
    }

    /// The test runner satisfies its own designated requirement; other code doesn't.
    @Test func signatureCheckAcceptsItselfAndRefusesOtherCode() throws {
        let me = try #require(Bundle.main.executablePath)
        let own = PtydUpgradeCheck.ownDesignatedRequirement()
        let requirement = try #require(own.requirement, "\(own.problem ?? "")")
        #expect(PtydUpgradeCheck.signatureProblem(path: me, requirement: requirement) == nil)
        #expect(PtydUpgradeCheck.signatureProblem(path: "/bin/ls", requirement: requirement) != nil)
        #expect(PtydUpgradeCheck.signatureProblem(path: "/nonexistent/claudedeck-ptyd", requirement: requirement) != nil)
        // Nothing captured at launch: nothing is accepted.
        #expect(PtydUpgradeCheck.signatureProblem(path: me, requirement: nil) != nil)
        // A requirement naming another developer refuses this code.
        #expect(PtydUpgradeCheck.signatureProblem(path: me, requirement: #"identifier "x" and anchor apple generic and certificate leaf[subject.OU] = "AAAAAAAAAA""#) != nil)
    }

    @Test func watchWaitsForTheFileToSettleAndForgetsRefusals() {
        let base = PtydFileIdentity(device: 1, inode: 10, size: 100, modified: 1)
        let new = PtydFileIdentity(device: 1, inode: 11, size: 120, modified: 2)
        var watch = PtydBinaryWatch(baseline: base, settle: 3)
        func see(_ identity: PtydFileIdentity?, _ now: Double) -> Bool { watch.observe(identity, now: now) }
        #expect(!see(base, 0))
        #expect(!see(nil, 1))           // mid-swap: no file
        #expect(!see(new, 2))           // first sight
        #expect(!see(new, 4))
        #expect(see(new, 5.5))          // stayed the same for 3 s
        watch.reject(new)
        #expect(!see(new, 20))          // refused: not again
        let newer = PtydFileIdentity(device: 1, inode: 12, size: 130, modified: 3)
        #expect(!see(newer, 21))
        #expect(see(newer, 24))
    }
}

// MARK: - Code identity after an update (harness, opt-in)

/// What privacy (TCC) checks about a process, approximately: its running code, validated
/// against the file at its path on disk (and, with a requirement, against that too). After an
/// update replaced the file, the old image fails this; that is the owner's "Operation not
/// permitted" in every session of a helper that outlived an update.
private func runningCodeStatus(pid: pid_t, requirement: String? = nil) -> OSStatus {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard found == errSecSuccess, let code else { return found }
    var parsed: SecRequirement?
    if let requirement { SecRequirementCreateWithString(requirement as CFString, [], &parsed) }
    return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), parsed)
}

private func run(_ tool: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Opt-in (`CLAUDEDECK_PTYD_SIGN_IDENTITY=<codesigning identity hash>`): the real helper, signed
/// with a real identity like a release, is replaced on disk by a newer signature of itself
/// while it serves a session. Its running code then no longer validates against its file (what
/// breaks TCC); after the in-place upgrade it validates again, same pid, same child.
@Suite(.serialized, .enabled(if: helperBinary != nil && ProcessInfo.processInfo.environment["CLAUDEDECK_PTYD_SIGN_IDENTITY"] != nil,
                             "set CLAUDEDECK_PTYD_SIGN_IDENTITY to run"))
struct PtydCodeIdentityHarness {
    @Test func upgradeMakesTheRunningCodeMatchItsFileAgain() throws {
        let identity = try #require(ProcessInfo.processInfo.environment["CLAUDEDECK_PTYD_SIGN_IDENTITY"])
        let original = try #require(helperBinary)
        let work = URL(fileURLWithPath: "/tmp/cdptyd-tcc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Two signatures of the same code by the same developer: different cdhash, same
        // designated requirement (identifier + team), like two releases.
        let old = work.appending(path: "old"), new = work.appending(path: "new")
        try FileManager.default.copyItem(at: original, to: old)
        try FileManager.default.copyItem(at: original, to: new)
        let id = "co.codemagnet.ClaudeDeck.ptyd-harness"
        #expect(run("/usr/bin/codesign", ["--force", "--timestamp=none", "--sign", identity, "--identifier", id, old.path]) == 0)
        #expect(run("/usr/bin/codesign", ["--force", "--timestamp=none", "--options", "runtime", "--sign", identity,
                                          "--identifier", id, new.path]) == 0)
        let installed = work.appending(path: "claudedeck-ptyd")
        try FileManager.default.copyItem(at: old, to: installed)

        let helper = try HelperProcess(binary: installed, extra: ["--upgrade-allow-same-build", "--watch-interval", "0"],
                                       logging: true)
        #expect(helper.waitUntilListening())
        let pid = helper.process.processIdentifier
        let client = try helper.connect(Collector())
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }
        #expect(runningCodeStatus(pid: pid) == errSecSuccess)

        // The update lands (rename over the old file, like Sparkle's bundle swap).
        #expect(rename(new.path, installed.path) == 0)
        let stale = runningCodeStatus(pid: pid)
        #expect(stale != errSecSuccess, "the old image should no longer match its file")

        #expect(try upgrade(client).message.op == .ok)
        #expect(waitFor(10) { helper.log.contains("resumed from build") })
        #expect(helper.process.processIdentifier == pid)
        #expect(runningCodeStatus(pid: pid) == errSecSuccess, "\(helper.log)")
        let again = try reconnect(helper, Collector())
        #expect(try sync { again.list($0) }.first { $0.id == spawn.id }?.pid == info.pid)
        #expect(kill(info.pid, 0) == 0)
        print("code identity harness: stale image status \(stale), after re-exec \(runningCodeStatus(pid: pid))")
        helper.kill()
    }
}

// MARK: - Re-exec with live sessions (integration)

/// Every number in "tick N" lines, in order of appearance.
private func ticks(_ text: String) -> [Int] {
    text.components(separatedBy: "tick ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
}

private let listFDs = #"ls /dev/fd | tr '\n' ' '; echo; sleep 1"#

/// The signature check reads the whole binary: on a busy Mac it can take seconds.
private func upgrade(_ client: PtydClient) throws -> PtydFrame {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<PtydFrame, PtydClientError>?
    client.upgrade { result = $0; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 30) == .success, let result else { throw PtydClientError.timeout }
    return try result.get()
}

/// Waits until a connection is answered by a re-exec'd image (the old one may still answer
/// for a moment after saying yes).
private func reconnect(_ helper: HelperProcess, _ collector: Collector) throws -> PtydClient {
    var client: PtydClient?
    _ = waitFor(10) {
        client = try? helper.connect(collector)
        return client != nil
    }
    return try #require(client)
}

@Suite(.serialized, .enabled(if: helperBinary != nil, "claudedeck-ptyd not built"))
struct PtydUpgradeIntegrationTests {
    /// The helper execs itself (same pid): children keep their pids and ptys, scrollback and
    /// ended sessions come through, output produced during the exec isn't lost, the new image
    /// reaps the children, and nothing leaks into new sessions.
    @Test func reexecKeepsEverySession() throws {
        let helper = try HelperProcess(extra: ["--upgrade-allow-same-build", "--watch-interval", "0"], logging: true)
        #expect(helper.waitUntilListening())
        let helperPID = helper.process.processIdentifier
        let first = Collector()
        let client = try helper.connect(first)
        #expect(client.supportsUpgrade)
        let instance = client.welcome.instance

        let ticker = shellSpawn(tickLoop)
        let echo = shellSpawn(#"while read line; do echo "got:$line"; stty size; done"#)
        let ended = shellSpawn("exit 7")
        let tickInfo = try sync { client.spawn(ticker, $0) }
        let echoInfo = try sync { client.spawn(echo, $0) }
        _ = try sync { client.spawn(ended, $0) }
        #expect(waitFor { first.text(ticker.id).contains("tick 5") && first.exit(ended.id) != nil })
        // What a new session inherits from the helper (only its own stdio and ls's directory).
        let fdsBefore = shellSpawn(listFDs)
        _ = try sync { client.spawn(fdsBefore, $0) }
        #expect(waitFor { first.text(fdsBefore.id).contains("\r\n") })

        // Twice in a row: the second image execs the third the same way.
        var upgrader = client
        for round in 1...2 {
            if round > 1 { upgrader = try reconnect(helper, Collector()) }
            let reply = try upgrade(upgrader)
            #expect(reply.message.op == .ok)
            // The old image's connections close at the exec.
            if round == 1 { #expect(waitFor { first.isDisconnected }) }
            usleep(300_000)
            #expect(helper.process.isRunning)
            #expect(helper.process.processIdentifier == helperPID)
            #expect(waitFor { helper.log.components(separatedBy: "resumed from build").count - 1 == round })
        }

        let second = Collector()
        let again = try reconnect(helper, second)
        #expect(again.welcome.instance == instance)        // same helper as far as the app is concerned
        #expect(again.welcome.pid == helperPID)
        #expect(helper.paths.lockHolderPID() == helperPID)
        #expect(helper.paths.helperHoldsLock())

        let listed = Dictionary(uniqueKeysWithValues: try sync { again.list($0) }.map { ($0.id, $0) })
        #expect(listed[ticker.id]?.pid == tickInfo.pid)
        #expect(listed[ticker.id]?.startedAt == tickInfo.startedAt)
        #expect(listed[ticker.id]?.alive == true)
        #expect(listed[ticker.id]?.meta == ["k": "v"])
        #expect(listed[echo.id]?.pid == echoInfo.pid)
        #expect(listed[ended.id]?.alive == false)
        #expect(listed[ended.id]?.exitCode == 7)
        #expect(kill(tickInfo.pid, 0) == 0)

        // Scrollback from before the exec, then live output, with no tick missing in between.
        let (attached, replay) = try sync { again.attach(ticker.id, $0) }
        #expect(attached.pid == tickInfo.pid)
        let replayed = ticks(String(decoding: replay, as: UTF8.self))
        #expect(replayed.first == 0)
        let last = replayed.last ?? 0
        #expect(waitFor { ticks(second.text(ticker.id)).contains(last + 5) })
        let all = replayed + ticks(second.text(ticker.id))
        #expect(all == Array(0..<all.count), "ticks lost or repeated across the exec")

        // The pty still works both ways.
        _ = try sync { again.attach(echo.id, $0) }
        again.resize(echo.id, cols: 111, rows: 33)
        again.write(echo.id, Array("after\n".utf8))
        #expect(waitFor { second.text(echo.id).contains("got:after") && second.text(echo.id).contains("33 111") })

        // A new session inherits nothing of the helper's (sockets, lock, other ptys, the handover).
        let fds = shellSpawn(listFDs)
        _ = try sync { again.spawn(fds, $0) }
        #expect(waitFor { second.text(fds.id).contains("\r\n") })
        #expect(second.text(fds.id) == first.text(fdsBefore.id))

        // The new image reaps the children it inherited.
        again.signal(ticker.id, SIGKILL)
        #expect(waitFor { second.exit(ticker.id) != nil })
        #expect(second.exit(ticker.id)?.exitSignal == SIGKILL)
        #expect(waitFor { kill(tickInfo.pid, 0) != 0 && errno == ESRCH }, "not reaped (zombie)")
        helper.kill()
    }

    /// Not newer, or not this developer's code: refused, and nothing happens to anything.
    @Test func refusedUpgradeChangesNothing() throws {
        let helper = try HelperProcess(extra: ["--watch-interval", "0"])
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }
        // Same build ("test"), no test override.
        #expect(throws: PtydClientError.refused(PtydErrorCode.notNewer, nil)) { _ = try upgrade(client) }
        usleep(500_000)
        #expect(!collector.isDisconnected)
        let before = ticks(collector.text(spawn.id)).last ?? 0
        #expect(waitFor { (ticks(collector.text(spawn.id)).last ?? 0) > before + 3 })
        #expect(try sync { client.list($0) }.first?.pid == info.pid)
        helper.kill()
    }

    /// The app never sends `upgrade` to a helper that doesn't know it.
    @Test func olderHelperIsNotAskedToUpgrade() throws {
        let helper = try HelperProcess(extra: ["--protocol-version", "2"])
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        #expect(!client.supportsUpgrade)
        #expect(throws: PtydClientError.refused(PtydErrorCode.badRequest, nil)) { _ = try upgrade(client) }
        helper.kill()
    }

    /// Trigger (b): the helper notices its file was replaced. A binary signed by someone else is
    /// refused (it keeps running, its client connected); the right one is exec'd into.
    @Test func replacedBinaryIsCheckedAndExecd() throws {
        let original = try #require(helperBinary)
        let work = URL(fileURLWithPath: "/tmp/cdptyd-bin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let installed = work.appending(path: "claudedeck-ptyd")
        try FileManager.default.copyItem(at: original, to: installed)

        let helper = try HelperProcess(binary: installed, extra: ["--upgrade-allow-same-build", "--watch-interval", "0.3"],
                                       logging: true)
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }

        // Replace it (rename over, like an update) with the same code re-signed as another
        // identity: its designated requirement doesn't match.
        let foreign = work.appending(path: "foreign")
        try FileManager.default.copyItem(at: original, to: foreign)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "com.example.not-claudedeck", foreign.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        #expect(rename(foreign.path, installed.path) == 0)
        #expect(waitFor(10) { helper.log.contains("upgrade refused") })
        #expect(!collector.isDisconnected)
        #expect(!helper.log.contains("resumed from build"))

        // Now the real one (same code, new file): exec'd.
        let good = work.appending(path: "good")
        try FileManager.default.copyItem(at: original, to: good)
        #expect(rename(good.path, installed.path) == 0)
        #expect(waitFor(10) { helper.log.contains("resumed from build") })
        #expect(waitFor { collector.isDisconnected })
        let again = try reconnect(helper, Collector())
        #expect(again.welcome.instance == client.welcome.instance)
        #expect(try sync { again.list($0) }.first { $0.id == spawn.id }?.pid == info.pid)
        #expect(kill(info.pid, 0) == 0)
        helper.kill()
    }
}
