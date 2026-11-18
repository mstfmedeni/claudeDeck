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
