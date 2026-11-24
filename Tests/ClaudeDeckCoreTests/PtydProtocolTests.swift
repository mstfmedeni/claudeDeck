import Darwin
import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct PtydProtocolTests {
    private func sampleSpawn() -> PtydSpawn {
        PtydSpawn(id: UUID().uuidString, executable: "/bin/zsh", argv: ["-zsh", "-l", "-c", #"exec "$0" "$@""#, "/usr/local/bin/claude", "--name", "a b"],
                  env: ["CLAUDEDECK_TERMINAL_ID=X", "TERM=xterm-256color", "WEIRD=a=b=c"], cwd: "/tmp/some dir",
                  cols: 120, rows: 40, meta: ["askToken": "t"])
    }

    @Test func frameRoundTrip() throws {
        var message = PtydMessage(op: .spawn, seq: 7, session: "s1")
        message.spawn = sampleSpawn()
        let frame = PtydFrame(message, payload: Array("héllo\u{1b}[0m".utf8))
        var reader = PtydFrameReader()
        reader.append(try frame.encoded())
        let decoded = try #require(try reader.next())
        #expect(decoded == frame)
        #expect(try reader.next() == nil)
        #expect(reader.pendingBytes == 0)
    }

    @Test func framesSplitAnywhere() throws {
        var output = PtydMessage(op: .output, session: "s")
        output.seq = nil
        let frames = [
            PtydFrame(PtydMessage(op: .list, seq: 1)),
            PtydFrame(output, payload: (0..<5000).map { UInt8(truncatingIfNeeded: $0) }),
            PtydFrame(PtydMessage(op: .detach, seq: 2, session: "s")),
        ]
        let bytes = try frames.flatMap { try $0.encoded() }
        // One byte at a time, and in odd-sized chunks.
        for chunk in [1, 3, 7, 1000, bytes.count] {
            var reader = PtydFrameReader()
            var got: [PtydFrame] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + chunk, bytes.count)
                reader.append(bytes[index..<end])
                index = end
                while let frame = try reader.next() { got.append(frame) }
            }
            #expect(got == frames, "chunk \(chunk)")
        }
    }

    @Test func oversizedAndMalformedFramesAreRejected() throws {
        var reader = PtydFrameReader()
        var header: [UInt8] = []
        PtydFrame.appendU32(UInt32(PtydProtocol.maxHeaderBytes + 1), to: &header)
        PtydFrame.appendU32(0, to: &header)
        reader.append(header)
        #expect(throws: PtydFrameError.tooLarge) { try reader.next() }

        var bad = PtydFrameReader()
        let junk = Array("{nope".utf8)
        var bytes: [UInt8] = []
        PtydFrame.appendU32(UInt32(junk.count), to: &bytes)
        PtydFrame.appendU32(0, to: &bytes)
        bad.append(bytes + junk)
        #expect(throws: PtydFrameError.badHeader) { try bad.next() }

        let huge = PtydFrame(PtydMessage(op: .write), payload: [UInt8](repeating: 0, count: PtydProtocol.maxPayloadBytes + 1))
        #expect(throws: PtydFrameError.tooLarge) { try huge.encoded() }
    }

    @Test func spawnKeepsArgvAndEnvironmentExactly() throws {
        let spawn = sampleSpawn()
        let data = try JSONEncoder().encode(spawn)
        let back = try JSONDecoder().decode(PtydSpawn.self, from: data)
        #expect(back == spawn)
        #expect(back.argv[0] == "-zsh")
        #expect(back.env.contains("WEIRD=a=b=c"))
    }

    /// The frozen subset is how any app reads any helper: these names never change.
    @Test func frozenOperationNames() {
        let frozen: [PtydOp: String] = [
            .hello: "hello", .welcome: "welcome", .list: "list", .sessions: "sessions", .attach: "attach",
            .attached: "attached", .detach: "detach", .output: "output", .exited: "exited", .error: "error",
        ]
        for (op, name) in frozen { #expect(op.rawValue == name) }
        // Unknown fields from a newer peer are ignored, missing ones are nil.
        let json = #"{"op":"welcome","seq":0,"protocolVersion":9,"instance":"i","somethingNew":{"x":1}}"#
        let message = try? JSONDecoder().decode(PtydMessage.self, from: Data(json.utf8))
        #expect(message?.protocolVersion == 9)
        #expect(message?.build == nil)
    }

    @Test func versionNegotiation() {
        // Same version: full.
        #expect(PtydVersion.negotiate(client: (1, 1), helper: (1, 1)) == .full(dialect: 1))
        // App newer, still supports the older helper: full, in the helper's dialect.
        #expect(PtydVersion.negotiate(client: (3, 2), helper: (2, 1)) == .full(dialect: 2))
        // Helper newer and still accepts this app: full, in the app's dialect.
        #expect(PtydVersion.negotiate(client: (2, 1), helper: (4, 2)) == .full(dialect: 2))
        // App dropped support for that old helper: read-only.
        #expect(PtydVersion.negotiate(client: (5, 4), helper: (3, 1)) == .readOnly)
        // Helper no longer accepts this old app: read-only.
        #expect(PtydVersion.negotiate(client: (2, 1), helper: (5, 3)) == .readOnly)
    }

    /// Protocol 2 (the access probe) still drives version 1 helpers fully, and a version 1 app
    /// still drives this helper.
    @Test func accessProbeVersionStaysCompatible() {
        #expect(PtydProtocol.version >= PtydProtocol.accessProbeVersion)
        #expect(PtydProtocol.oldestCompatibleHelper == 1 && PtydProtocol.oldestCompatibleClient == 1)
        #expect(PtydVersion.negotiate(client: (PtydProtocol.version, PtydProtocol.oldestCompatibleHelper),
                                      helper: (1, 1)) == .full(dialect: 1))
        #expect(PtydVersion.negotiate(client: (1, 1),
                                      helper: (PtydProtocol.version, PtydProtocol.oldestCompatibleClient)) == .full(dialect: 1))
        #expect(PtydOp.probeAccess.rawValue == "probeAccess" && PtydOp.access.rawValue == "access")
    }

    @Test func accessReportOnTheWire() throws {
        var message = PtydMessage(op: .access, seq: 3)
        message.access = PtydAccessReport(fullDiskAccess: .denied, desktop: .granted)
        let frame = try #require(try { var r = PtydFrameReader(); r.append(try PtydFrame(message).encoded()); return try r.next() }())
        #expect(frame.message.access == PtydAccessReport(fullDiskAccess: .denied, desktop: .granted))
        // A version 1 message has none.
        let old = try JSONDecoder().decode(PtydMessage.self, from: Data(#"{"op":"ok","seq":1}"#.utf8))
        #expect(old.access == nil)
        // A state from a later build reads as unknown, the rest still decodes.
        let later = try JSONDecoder().decode(PtydMessage.self, from: Data(#"{"op":"access","access":{"fullDiskAccess":"partial","desktop":"granted"}}"#.utf8))
        #expect(later.access == PtydAccessReport(fullDiskAccess: .unknown, desktop: .granted))
    }
}

@Suite struct PtydAccessTests {
    @Test func errnoClassification() {
        #expect(PtydAccessProbe.classify(errno: 0) == .granted)
        #expect(PtydAccessProbe.classify(errno: EPERM) == .denied)
        #expect(PtydAccessProbe.classify(errno: ENOENT) == .unknown)
        #expect(PtydAccessProbe.classify(errno: EACCES) == .unknown)
        #expect(PtydAccessProbe.classify(errno: EIO) == .unknown)
    }

    @Test func fullDiskAccessTriesTCCThenSafari() {
        let home = "/Users/x"
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let safari = home + "/Library/Safari/Bookmarks.plist"
        func probe(_ answers: [String: Int32]) -> (PtydAccessState, [String]) {
            var tried: [String] = []
            let state = PtydAccessProbe.fullDiskAccess(home: home) { path in tried.append(path); return answers[path] ?? ENOENT }
            return (state, tried)
        }
        // TCC.db decides when it answers.
        #expect(probe([tcc: 0]) == (.granted, [tcc]))
        #expect(probe([tcc: EPERM]) == (.denied, [tcc]))
        // Missing TCC.db: Safari's bookmarks decide.
        #expect(probe([safari: EPERM]) == (.denied, [tcc, safari]))
        #expect(probe([safari: 0]) == (.granted, [tcc, safari]))
        // Neither exists: unknown.
        #expect(probe([:]) == (.unknown, [tcc, safari]))
    }

    @Test func desktopProbe() {
        var listed: String?
        #expect(PtydAccessProbe.desktop(home: "/Users/x") { listed = $0; return EPERM } == .denied)
        #expect(listed == "/Users/x/Desktop")
        #expect(PtydAccessProbe.desktop(home: "/Users/x") { _ in 0 } == .granted)
        #expect(PtydAccessProbe.desktop(home: "/Users/x") { _ in ENOENT } == .unknown)
    }

    @Test func levels() {
        typealias R = PtydAccessReport
        #expect(R(fullDiskAccess: .granted, desktop: .granted).level == .full)
        #expect(R(fullDiskAccess: .granted, desktop: .unknown).level == .full)
        #expect(R(fullDiskAccess: .denied, desktop: .granted).level == .desktopOnly)
        #expect(R(fullDiskAccess: .denied, desktop: .denied).level == .none)
        #expect(R(fullDiskAccess: .denied, desktop: .unknown).level == .none)
        #expect(R(fullDiskAccess: .unknown, desktop: .granted).level == .unknown)
        #expect(R.unknown.level == .unknown)
    }

    @Test func helperLacksOnlyOnDefiniteDenials() {
        typealias R = PtydAccessReport
        let appFull = R(fullDiskAccess: .granted, desktop: .granted)
        #expect(R(fullDiskAccess: .denied, desktop: .denied).lacks(comparedTo: appFull))
        #expect(R(fullDiskAccess: .denied, desktop: .granted).lacks(comparedTo: appFull))
        #expect(!R(fullDiskAccess: .granted, desktop: .granted).lacks(comparedTo: appFull))
        // An old helper (unknown) never warns.
        #expect(!R.unknown.lacks(comparedTo: appFull))
        // The app has only the Desktop grant, the helper not even that.
        let appDesktop = R(fullDiskAccess: .denied, desktop: .granted)
        #expect(R(fullDiskAccess: .denied, desktop: .denied).lacks(comparedTo: appDesktop))
        #expect(!R(fullDiskAccess: .denied, desktop: .granted).lacks(comparedTo: appDesktop))
        // The app has nothing either: nothing to tell.
        #expect(!R(fullDiskAccess: .denied, desktop: .denied).lacks(comparedTo: R(fullDiskAccess: .denied, desktop: .denied)))
    }

    @Test func realProbeNeverCrashesAndReadsNothing() {
        // Whatever this machine grants the test runner, the probe answers.
        let report = PtydAccessProbe.run()
        #expect([.granted, .denied, .unknown].contains(report.fullDiskAccess))
        let empty = PtydAccessProbe.run(home: "/nonexistent-\(UUID().uuidString)")
        #expect(empty == .unknown)
    }
}

@Suite struct PtydDeckDataTests {
    @Test func settingIsOffByDefaultAndOldFilesDecode() throws {
        #expect(DeckSettings().keepSessionsRunning == false)
        let old = Data(#"{"settings":{"resumeOnLaunch":true},"sessions":[{"id":"C0000000-0000-0000-0000-000000000001","projectID":"B0000000-0000-0000-0000-000000000001","name":"a","isOpen":true}]}"#.utf8)
        let deck = try JSONDecoder().decode(DeckData.self, from: old)
        #expect(deck.settings.keepSessionsRunning == false)
        #expect(deck.settings.retireSessionHelper == false)
        #expect(deck.sessions.first?.helperHost == nil)
    }

    @Test func helperHostRoundTrips() throws {
        var deck = DeckData()
        var session = DeckSession(projectID: UUID(), name: "s")
        session.helperHost = PtydHost(instance: "i", pid: 42, startedAt: 1234.5)
        deck.sessions = [session]
        deck.settings.keepSessionsRunning = true
        let back = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(back.sessions.first?.helperHost == session.helperHost)
        #expect(back.settings.keepSessionsRunning)
    }
}

@Suite struct PtydRingBufferTests {
    @Test func keepsEverythingUnderCapacity() {
        var ring = PtydRingBuffer(capacity: 10)
        ring.append(Array("abc".utf8))
        ring.append(Array("def".utf8))
        #expect(ring.snapshot() == Array("abcdef".utf8))
        #expect(ring.count == 6)
        #expect(ring.totalWritten == 6)
    }

    @Test func keepsTheNewestBytesWhenFull() {
        var ring = PtydRingBuffer(capacity: 5)
        ring.append(Array("abcd".utf8))
        ring.append(Array("efg".utf8))
        #expect(ring.snapshot() == Array("cdefg".utf8))
        ring.append(Array("h".utf8))
        #expect(ring.snapshot() == Array("defgh".utf8))
        ring.append(Array("0123456789".utf8))
        #expect(ring.snapshot() == Array("56789".utf8))
        #expect(ring.totalWritten == 18)
        #expect(ring.count == 5)
    }

    @Test func matchesTheSuffixOfEverythingWritten() {
        var generator = SystemRandomNumberGenerator()
        for capacity in [1, 7, 64, 1000] {
            var ring = PtydRingBuffer(capacity: capacity)
            var all: [UInt8] = []
            for _ in 0..<200 {
                let length = Int.random(in: 0...(capacity * 2), using: &generator)
                let chunk = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                ring.append(chunk)
                all += chunk
                #expect(ring.snapshot() == Array(all.suffix(capacity)))
            }
        }
    }

    @Test func fourMegabytesOfOutput() {
        var ring = PtydRingBuffer(capacity: PtydProtocol.defaultRingBytes)
        let line = Array("line of terminal output 0123456789\r\n".utf8)
        var total = 0
        while total < PtydProtocol.defaultRingBytes * 2 + 123 {
            ring.append(line)
            total += line.count
        }
        let snapshot = ring.snapshot()
        #expect(snapshot.count == PtydProtocol.defaultRingBytes)
        #expect(Array(snapshot.suffix(line.count)) == line)
    }
}

@Suite struct PtydLaunchPlanTests {
    let id = UUID()
    let host = PtydHost(instance: "helper-A", pid: 4242, startedAt: 1000)
    var aliveInfo: PtydSessionInfo { PtydSessionInfo(id: id.uuidString, pid: 4242, startedAt: 1000, cols: 80, rows: 24, alive: true) }
    var exitedInfo: PtydSessionInfo {
        PtydSessionInfo(id: id.uuidString, pid: 4242, startedAt: 1000, cols: 80, rows: 24, alive: false, exitCode: 0)
    }

    private func live(_ instance: String, _ infos: [PtydSessionInfo], readOnly: Bool = false) -> PtydHelperState {
        .live(instance: instance, compatibility: readOnly ? .readOnly : .full(dialect: 1),
              sessions: Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) }))
    }

    private func gate(host: PtydHost?, helper: PtydHelperState, alive: Bool = false) -> PtydGate {
        PtydLaunchPlan.gate(sessionID: id, host: host, helper: helper) { _ in alive }
    }

    /// The rule that matters most: alive in the helper → attach, never resume.
    @Test func neverResumesASessionStillAliveInTheHelper() {
        #expect(gate(host: host, helper: live("helper-A", [aliveInfo])) == .attach(aliveInfo))
        // Even when the deck doesn't know it was in the helper (crashed before saving).
        #expect(gate(host: nil, helper: live("helper-A", [aliveInfo])) == .attach(aliveInfo))
        // Even when the saved instance is another one.
        #expect(gate(host: host, helper: live("helper-B", [aliveInfo])) == .attach(aliveInfo))
        for helper in [live("helper-A", [aliveInfo]), live("helper-B", [aliveInfo]), live("helper-A", [aliveInfo], readOnly: true)] {
            for saved in [host, nil] {
                #expect(gate(host: saved, helper: helper) != .proceed)
            }
        }
    }

    @Test func incompatibleHelperIsReadOnlyNeverResumed() {
        #expect(gate(host: host, helper: live("helper-A", [aliveInfo], readOnly: true)) == .attachReadOnly(aliveInfo))
    }

    @Test func notInTheHelperFollowsTodaysPath() {
        #expect(gate(host: nil, helper: .gone) == .proceed)
        #expect(gate(host: nil, helper: .unknown) == .proceed)
        #expect(gate(host: nil, helper: .unresponsive) == .proceed)
        #expect(gate(host: nil, helper: live("helper-A", [])) == .proceed)
    }

    @Test func unknownOrUnresponsiveHelperHoldsItsSessions() {
        #expect(gate(host: host, helper: .unknown) == .hold(.helperUnknown))
        #expect(gate(host: host, helper: .unresponsive) == .hold(.helperUnresponsive))
    }

    @Test func endedWhileTheAppWasAway() {
        #expect(gate(host: host, helper: live("helper-A", [exitedInfo])) == .ended(exitedInfo))
        // Forgotten (or never seen) by the same helper: over as well, not resumed.
        #expect(gate(host: host, helper: live("helper-A", [])) == .ended(nil))
    }

    /// Helper crash: its children got SIGHUP. Resume only once the old process is really gone.
    @Test func crashFallback() {
        #expect(gate(host: host, helper: .gone, alive: false) == .proceed)
        #expect(gate(host: host, helper: live("helper-B", []), alive: false) == .proceed)
        #expect(gate(host: host, helper: .gone, alive: true) == .hold(.processStillRunning))
        #expect(gate(host: host, helper: live("helper-B", []), alive: true) == .hold(.processStillRunning))
    }

    /// Restart of a terminal in the helper: the old process was stopped and its pid is gone, but
    /// until the helper's exit notice arrives its list still says alive. Launching then would
    /// attach to the dying process (the attach fails, the terminal ends, nothing starts).
    @Test func restartLaunchesOnlyOnceTheHelperReportedTheExit() {
        // Exit notice not here yet: wait.
        #expect(!PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: false, helper: live("helper-A", [aliveInfo])))
        // The terminal itself still counts it as running: wait.
        #expect(!PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: true, helper: .gone))
        // Notice in (or never in the helper): go — and the gate then lets the launch start it.
        #expect(PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: false, helper: live("helper-A", [exitedInfo])))
        #expect(gate(host: host, helper: live("helper-A", [exitedInfo])) == .ended(exitedInfo))
        #expect(PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: false, helper: live("helper-A", [])))
        #expect(PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: false, helper: .gone))
        // Another session alive in the helper doesn't matter.
        let other = PtydSessionInfo(id: UUID().uuidString, pid: 1, startedAt: 1, cols: 80, rows: 24, alive: true)
        #expect(PtydLaunchPlan.restartMayLaunch(sessionID: id, terminalRunning: false, helper: live("helper-A", [other])))
    }

    /// The old process's exit notice arriving after the new one started must not end (or fail) it.
    @Test func staleExitNoticeDoesntEndTheNewRun() {
        // Stopped by the restart itself: never an exit of the terminal, whenever it arrives.
        #expect(!PtydLaunchPlan.exitNoticeApplies(noticePID: 4242, currentPID: nil, retiredPIDs: [4242]))
        #expect(!PtydLaunchPlan.exitNoticeApplies(noticePID: 4242, currentPID: 5151, retiredPIDs: [4242]))
        // Another process than the one it runs now.
        #expect(!PtydLaunchPlan.exitNoticeApplies(noticePID: 4242, currentPID: 5151, retiredPIDs: []))
        // The process it runs ends: that's its exit.
        #expect(PtydLaunchPlan.exitNoticeApplies(noticePID: 5151, currentPID: 5151, retiredPIDs: [4242]))
        // Pid not known yet (attach without info): taken as before.
        #expect(PtydLaunchPlan.exitNoticeApplies(noticePID: 5151, currentPID: nil, retiredPIDs: []))
    }

    @Test func processIdentityChecksStartTime() throws {
        let me = getpid()
        let started = try #require(PtydLaunchPlan.processStartTime(me))
        #expect(PtydLaunchPlan.processAlive(PtydHost(instance: "x", pid: me, startedAt: started)))
        // Same pid, other start time: a reused pid, not our process.
        #expect(!PtydLaunchPlan.processAlive(PtydHost(instance: "x", pid: me, startedAt: started - 3600)))
        #expect(!PtydLaunchPlan.processAlive(PtydHost(instance: "x", pid: 0, startedAt: 0)))
        #expect(!PtydLaunchPlan.processAlive(PtydHost(instance: "x", pid: 99_999_9, startedAt: 0)))
    }
}
