import Foundation
import Testing
@testable import ClaudeDeckCore

/// Per-process use for the load tab and `claudedeck load --detail`: CPU % from CPU-time deltas,
/// each session's process tree summed, the heaviest other processes, builds, idle agents.
@Suite struct LoadUsageTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = UUID(), b = UUID()

    private func record(_ pid: Int32, _ ppid: Int32, _ name: String, cpu seconds: Double, mb: UInt64 = 10,
                        started: TimeInterval = 100) -> ProcessUsageRecord {
        ProcessUsageRecord(pid: pid, ppid: ppid, name: name, started: started, cpuNanos: UInt64(seconds * 1e9), residentBytes: mb << 20)
    }

    /// launchd (1) ─ zsh 100 (session A) ─ claude 101 ─ node 102 (MCP) ─ Chrome Helper 103
    ///                                     └ swift-frontend 104
    ///             ─ zsh 200 (session B) ─ claude 201
    ///             ─ ClaudeDeck 50 ─ claudedeck-ptyd 51 ─ zsh 60 (a helper session not running here)
    ///             ─ WindowServer 300, clang 301, mds 302
    private func tables() -> (ProcessUsageTable, ProcessUsageTable) {
        let before = [
            record(100, 1, "zsh", cpu: 1), record(101, 100, "claude", cpu: 10), record(102, 101, "node", cpu: 5),
            record(103, 102, "Chrome Helper", cpu: 2), record(104, 101, "swift-frontend", cpu: 0),
            record(200, 1, "zsh", cpu: 1), record(201, 200, "claude", cpu: 3),
            record(50, 1, "ClaudeDeck", cpu: 50), record(51, 50, "claudedeck-ptyd", cpu: 1), record(60, 51, "zsh", cpu: 0),
            record(300, 1, "WindowServer", cpu: 100), record(301, 1, "clang", cpu: 1), record(302, 1, "mds", cpu: 1),
        ]
        var after = before
        func bump(_ pid: Int32, _ seconds: Double) {
            let i = after.firstIndex { $0.pid == pid }!
            after[i].cpuNanos += UInt64(seconds * 1e9)
        }
        // Over 2 seconds: claude 1 s (50 %), node 2 s (100 %), Chrome 0.5 s (25 %), swift-frontend
        // 3 s (150 %), B's claude 0.2 s (10 %), ClaudeDeck 1 s, WindowServer 0.6 s (30 %), clang 1.6 s (80 %).
        bump(101, 1); bump(102, 2); bump(103, 0.5); bump(104, 3); bump(201, 0.2); bump(50, 1); bump(300, 0.6); bump(301, 1.6)
        return (ProcessUsageTable(at: t0, records: before), ProcessUsageTable(at: t0.addingTimeInterval(2), records: after))
    }

    private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

    @Test func cpuPercentFromDeltas() {
        let (before, after) = tables()
        let cpu = LoadUsage.cpuPercent(previous: before, current: after)
        #expect(close(cpu[101], 50) && close(cpu[102], 100) && close(cpu[104], 150) && close(cpu[301], 80))
        #expect(cpu[100] == nil) // no change: no entry
        // A reused pid (other start time), a new process, CPU time going backwards: no figure.
        var later = Array(after.records.values)
        later.removeAll { [102, 201].contains($0.pid) }
        later.append(record(102, 101, "node", cpu: 99, started: 999))
        later.append(record(400, 1, "new", cpu: 5))
        later.append(record(201, 200, "claude", cpu: 0))
        let third = ProcessUsageTable(at: t0.addingTimeInterval(4), records: later)
        let next = LoadUsage.cpuPercent(previous: after, current: third)
        #expect(next[102] == nil && next[400] == nil && next[201] == nil)
        #expect(LoadUsage.cpuPercent(previous: nil, current: after).isEmpty)
        #expect(LoadUsage.cpuPercent(previous: after, current: after).isEmpty)
    }

    @Test func sessionsAreSummedWithTheirChildren() {
        let (before, after) = tables()
        let cpu = LoadUsage.cpuPercent(previous: before, current: after)
        let report = LoadUsage.report(table: after, cpu: cpu, sessionRoots: [a: 100, b: 200], excludedRoots: [50, 51])
        #expect(report.processCount == 13)
        #expect(report.sessions.map(\.session) == [a, b]) // heaviest first
        let first = report.sessions[0]
        #expect(close(first.cpuPercent, 325) && first.processes.count == 5 && first.residentBytes == 50 << 20)
        #expect(first.processes.first?.name == "swift-frontend") // heaviest process first
        #expect(close(report.sessions[1].cpuPercent, 10) && report.sessions[1].processes.count == 2)
        // Others: not in a session, not ClaudeDeck or its helper (nor what runs under them).
        #expect(report.others.map(\.pid) == [301, 300, 302])
        // Builds, with the session they run under.
        #expect(report.builds.map(\.pid).sorted() == [104, 301])
        #expect(report.builds.first { $0.pid == 104 }?.session == a && report.builds.first { $0.pid == 301 }?.session == nil)
        #expect(LoadUsage.report(table: after, cpu: cpu, sessionRoots: [:], othersLimit: 2).others.count == 2)
    }

    @Test func nestedSessionsCountOnce() {
        // A terminal opened by session A's claude (its own session C) is C's, not A's too.
        let c = UUID()
        let table = ProcessUsageTable(at: t0, records: [
            record(100, 1, "zsh", cpu: 0), record(101, 100, "claude", cpu: 0), record(150, 101, "zsh", cpu: 0), record(151, 150, "npm", cpu: 0),
        ])
        let report = LoadUsage.report(table: table, cpu: [101: 20, 151: 60], sessionRoots: [a: 100, c: 150])
        #expect(report.sessions.first { $0.session == a }?.cpuPercent == 20)
        #expect(report.sessions.first { $0.session == c }?.cpuPercent == 60)
        #expect(report.sessions.map(\.session) == [c, a])
    }

    @Test func topEntriesPerSessionAndProject() {
        let (before, after) = tables()
        let report = LoadUsage.report(table: after, cpu: LoadUsage.cpuPercent(previous: before, current: after), sessionRoots: [a: 100, b: 200])
        let names: [UUID: (name: String, project: String, agent: Bool)] = [a: ("backend", "Wakeroo", true), b: ("main", "Wakeroo", false)]
        let entries = LoadTopEntry.entries(from: report) { names[$0] }
        #expect(entries.sessions.map(\.name) == ["backend", "main"])
        #expect(entries.sessions[0].agent && entries.sessions[0].topProcesses.first == "swift-frontend 150%")
        #expect(entries.projects.count == 1 && entries.projects[0].cpuPercent == 335 && entries.projects[0].processes == 7)
        // Sessions no longer in the deck are left out.
        #expect(LoadTopEntry.entries(from: report) { $0 == a ? ("x", "P", false) : nil }.sessions.count == 1)
    }

    @Test func idleAgentsOnly() {
        let now = t0
        let owner = UUID(), agent = UUID(), busy = UUID(), fresh = UUID()
        let list = [
            LoadUsage.IdleCandidate(session: owner, startedBy: nil, idle: true, lastActivity: now.addingTimeInterval(-7200)),
            LoadUsage.IdleCandidate(session: agent, startedBy: owner, idle: true, lastActivity: now.addingTimeInterval(-16 * 60)),
            LoadUsage.IdleCandidate(session: busy, startedBy: owner, idle: false, lastActivity: now.addingTimeInterval(-3600)),
            LoadUsage.IdleCandidate(session: fresh, startedBy: owner, idle: true, lastActivity: now.addingTimeInterval(-60)),
        ]
        #expect(LoadUsage.idleAgents(list, now: now) == [agent])
    }
}
