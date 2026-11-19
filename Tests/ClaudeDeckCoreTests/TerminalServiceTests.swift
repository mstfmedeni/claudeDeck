import Darwin
import Foundation
import Testing
@testable import ClaudeDeckCore

/// Service terminals (TerminalService.swift): a long-running command that listens on a port
/// shows as a service, not as working.
@Suite struct TerminalServiceTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    func running(at time: Date) -> ProgramStatusTracker {
        var tracker = ProgramStatusTracker()
        tracker.apply(.promptStart, now: time)
        tracker.apply(.commandExecuted, now: time)
        return tracker
    }

    @Test func listeningCommandBecomesAServiceKeepingItsStart() {
        var tracker = running(at: t0)
        #expect(tracker.status?.state == .working)
        let changed1 = tracker.noteListening([5173, 3000, 3000], now: t0 + 25)
        #expect(changed1)
        #expect(tracker.status?.state == .service)
        #expect(tracker.status?.ports == [3000, 5173])
        #expect(tracker.status?.since == t0) // still the command that started at t0
        #expect(tracker.statusFromCommand)
    }

    @Test func serviceIsStickyWhileTheCommandRuns() {
        var tracker = running(at: t0)
        tracker.noteListening([5050], now: t0 + 25)
        // A dev server restarting listens on nothing for a moment: no flicker back to working.
        let changed2 = tracker.noteListening([], now: t0 + 35)
        #expect(!changed2)
        #expect(tracker.status?.state == .service)
        // New ports replace the old.
        let changed3 = tracker.noteListening([5051], now: t0 + 45)
        #expect(changed3)
        #expect(tracker.status?.ports == [5051])
        #expect(tracker.status?.since == t0)
    }

    @Test func serverExitStillEndsAsFinishedOrFailed() {
        var tracker = running(at: t0)
        tracker.noteListening([5050], now: t0 + 25)
        tracker.apply(.commandFinished(exitCode: 1), now: t0 + 60)
        #expect(tracker.status?.state == .failed)
        #expect(tracker.status?.exitCode == 1)
        #expect(tracker.status?.ports == nil)
        #expect(tracker.status?.since == t0 + 60)

        // The next command starts as working again, not as the old service.
        tracker.apply(.promptStart, now: t0 + 61)
        tracker.apply(.commandExecuted, now: t0 + 62)
        #expect(tracker.status?.state == .working)
        tracker.apply(.commandFinished(exitCode: 0), now: t0 + 70)
        #expect(tracker.status?.state == .finished)
    }

    @Test func processExitDropsTheService() {
        var tracker = running(at: t0)
        tracker.noteListening([8080], now: t0 + 25)
        tracker.processExited(now: t0 + 30)
        #expect(tracker.status == nil)
    }

    @Test func probeOutsideACommandChangesNothing() {
        var tracker = ProgramStatusTracker()
        tracker.apply(.promptStart, now: t0)
        let changed4 = tracker.noteListening([5050], now: t0 + 30)
        #expect(!changed4)
        #expect(tracker.status == nil)
    }

    @Test func programReportsWinOverTheProbe() {
        var tracker = running(at: t0)
        tracker.apply(ProgramStatusReport(state: .working, message: "building"), now: t0 + 1)
        tracker.noteListening([5050], now: t0 + 25)
        #expect(tracker.status?.state == .working)
        #expect(!tracker.statusFromCommand)

        var monitor = ProgramStatusMonitor()
        _ = monitor.feed(Array("\u{1B}]133;C\u{07}\u{1B}]7501;state=working\u{07}".utf8), now: t0)
        #expect(monitor.status?.state == .working)
        #expect(monitor.commandSince == nil) // not probed: the program says what it does
    }

    @Test func monitorReportsWhenTheCommandStarted() {
        var monitor = ProgramStatusMonitor()
        #expect(monitor.commandSince == nil)
        _ = monitor.feed(Array("\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}".utf8), now: t0)
        #expect(monitor.commandSince == t0)
        monitor.noteListening([5050], now: t0 + 25)
        #expect(monitor.status?.state == .service)
        #expect(monitor.commandSince == t0) // a service is still probed (its ports may change)
        _ = monitor.feed(Array("\u{1B}]133;D;0\u{07}".utf8), now: t0 + 40)
        #expect(monitor.commandSince == nil)
    }

    @Test func probesOnlyLongRunningCommandsUnlessMarked() {
        #expect(!TerminalService.shouldProbe(commandSince: nil, override: nil, now: t0))
        #expect(!TerminalService.shouldProbe(commandSince: t0, override: nil, now: t0 + 19))
        #expect(TerminalService.shouldProbe(commandSince: t0, override: nil, now: t0 + 20))
        #expect(TerminalService.shouldProbe(commandSince: t0, override: true, now: t0 + 1))
        #expect(!TerminalService.shouldProbe(commandSince: t0, override: false, now: t0 + 600))
        #expect(!TerminalService.shouldProbe(commandSince: nil, override: true, now: t0))
    }

    @Test func manualMarkOnlyTouchesRunningStates() {
        let working = ProgramStatus(state: .working, since: t0)
        let service = ProgramStatus(state: .service, since: t0, ports: [5050])
        #expect(TerminalService.applying(override: true, to: working).state == .service)
        #expect(TerminalService.applying(override: nil, to: working).state == .working)
        #expect(TerminalService.applying(override: false, to: service).state == .working)
        #expect(TerminalService.applying(override: false, to: service).ports == nil)
        #expect(TerminalService.applying(override: true, to: service) == service)
        for state in [ProgramStatus.State.blocked, .finished, .failed] {
            let status = ProgramStatus(state: state, exitCode: 2, since: t0)
            #expect(TerminalService.applying(override: true, to: status) == status)
            #expect(TerminalService.applying(override: false, to: status) == status)
        }
    }

    @Test func portsLabel() {
        #expect(TerminalService.portsLabel(nil) == nil)
        #expect(TerminalService.portsLabel([]) == nil)
        #expect(TerminalService.portsLabel([5050]) == ":5050")
        #expect(TerminalService.portsLabel([3000, 5173]) == ":3000, :5173")
        #expect(TerminalService.portsLabel([3000, 5173, 8080, 9229]) == ":3000, :5173 +2")
    }

    @Test func serviceCountsAsRunningForTheCLI() {
        #expect(SessionCLI.programProgress(.service, exitCode: nil, fallback: .finished(nil)) == .running)
    }

    @Test func overrideIsOptionalOnDisk() throws {
        var session = DeckSession(projectID: UUID(), name: "dev", kind: .shell)
        let old = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(DeckSession.self, from: old).serviceOverride == nil)
        session.serviceOverride = true
        let new = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(DeckSession.self, from: new).serviceOverride == true)
    }

    @Test func remoteServiceDecodesOnOldAndNewShapes() throws {
        let status = RemoteProgramStatus(state: "service", ports: [5050])
        let data = try JSONEncoder().encode(status)
        let back = try JSONDecoder().decode(RemoteProgramStatus.self, from: data)
        #expect(back.isService && !back.isWorking && !back.isOutcome && !back.isBlocked)
        #expect(back.ports == [5050])
        // An older host's payload has no ports.
        let old = try JSONDecoder().decode(RemoteProgramStatus.self, from: Data(#"{"state":"working"}"#.utf8))
        #expect(old.ports == nil && old.isWorking)
    }

    // MARK: libproc probe

    @Test func findsAPortThisProcessListensOn() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(ListeningPorts.listening(getpid()).contains(port))
        #expect(ListeningPorts.scan(roots: [getpid()], includeRoot: true)[getpid()]?.contains(port) == true)
    }

    @Test func walksChildProcesses() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        #expect(ListeningPorts.descendants(of: getpid()).contains(child.processIdentifier))
    }
}
