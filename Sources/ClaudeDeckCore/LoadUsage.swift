import Foundation

// Per-process use for the "Mac Yükü" tab and `claudedeck load --detail`: CPU % from the change
// in each process's CPU time between two looks at the process table, memory (resident size),
// and the sum over each Claude session's process tree (claude, its MCP servers, node, browsers it
// started, shells, builds). The app reads the table with libproc (SystemLoadSampler) only while
// the tab is on screen or a command asks; the arithmetic is here so it can be tested.

/// One process at one moment.
public struct ProcessUsageRecord: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// The longer name (`pbi_name`, else `pbi_comm`).
    public var name: String
    /// Start time (seconds since 1970); with the pid it tells a reused pid apart.
    public var started: TimeInterval
    /// User + system CPU time so far, in nanoseconds (0 when it can't be read: another user's process).
    public var cpuNanos: UInt64
    public var residentBytes: UInt64

    public init(pid: Int32, ppid: Int32, name: String, started: TimeInterval = 0, cpuNanos: UInt64 = 0, residentBytes: UInt64 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.started = started
        self.cpuNanos = cpuNanos
        self.residentBytes = residentBytes
    }
}

/// One look at every process.
public struct ProcessUsageTable: Sendable, Equatable {
    public var at: Date
    public var records: [Int32: ProcessUsageRecord]

    public init(at: Date, records: [ProcessUsageRecord]) {
        self.at = at
        var byPID: [Int32: ProcessUsageRecord] = [:]
        for record in records { byPID[record.pid] = record }
        self.records = byPID
    }
}

/// A process with its CPU % (100: one core) and memory.
public struct ProcessUsageRow: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var residentBytes: UInt64
    public var started: TimeInterval
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, residentBytes: UInt64, started: TimeInterval) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.started = started
    }
}

/// A Claude session (or terminal) with all its child processes.
public struct SessionUsage: Sendable, Equatable, Identifiable {
    public var session: UUID
    public var cpuPercent: Double = 0
    public var residentBytes: UInt64 = 0
    /// Its processes, the heaviest first.
    public var processes: [ProcessUsageRow] = []
    public var id: UUID { session }

    public init(session: UUID) { self.session = session }
}

/// A compiler or linker process, with the session it runs under (if any).
public struct BuildProcessUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var session: UUID?
    public var started: TimeInterval
    public var cpuPercent: Double
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, session: UUID?, started: TimeInterval, cpuPercent: Double) {
        self.pid = pid
        self.name = name
        self.session = session
        self.started = started
        self.cpuPercent = cpuPercent
    }
}

/// The result of aggregating one table.
public struct LoadUsageReport: Sendable, Equatable {
    public var at: Date
    /// Per session, the heaviest (CPU) first.
    public var sessions: [SessionUsage] = []
    /// The heaviest processes outside every session and outside ClaudeDeck itself.
    public var others: [ProcessUsageRow] = []
    public var builds: [BuildProcessUsage] = []
    public var processCount = 0
    /// CPU % over every process (100: one core).
    public var totalCPU: Double = 0

    /// Start times by pid (for uptimes of processes not in the lists above).
    public var startTimes: [Int32: TimeInterval] = [:]

    public init(at: Date) { self.at = at }

    public func started(of pid: Int32) -> Date? {
        startTimes[pid].flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
}

public enum LoadUsage {
    /// CPU % per pid between two tables (100: one core busy for the whole interval). A process
    /// new since `previous`, or a reused pid (other start time), has no figure yet (0); CPU time
    /// that went backwards counts as 0.
    public static func cpuPercent(previous: ProcessUsageTable?, current: ProcessUsageTable) -> [Int32: Double] {
        guard let previous else { return [:] }
        let wall = current.at.timeIntervalSince(previous.at)
        guard wall > 0.05 else { return [:] }
        var result: [Int32: Double] = [:]
        for (pid, now) in current.records {
            guard let before = previous.records[pid], before.started == now.started, now.cpuNanos >= before.cpuNanos else { continue }
            let percent = Double(now.cpuNanos - before.cpuNanos) / 1e9 / wall * 100
            if percent > 0 { result[pid] = percent }
        }
        return result
    }

    /// Which root each process belongs to: the nearest ancestor (or itself) in `roots`. Processes
    /// with none are absent.
    public static func owners<Key: Hashable>(in table: ProcessUsageTable, roots: [Int32: Key]) -> [Int32: Key] {
        var owner: [Int32: Key] = [:]
        var resolved: Set<Int32> = []
        for pid in table.records.keys {
            var chain: [Int32] = []
            var current = pid
            var found: Key?
            var steps = 0
            while steps < 64 {
                if let key = roots[current] { found = key; break }
                if resolved.contains(current) { found = owner[current]; break }
                chain.append(current)
                guard let record = table.records[current], record.ppid > 1, record.ppid != current else { break }
                current = record.ppid
                steps += 1
            }
            for p in chain {
                resolved.insert(p)
                if let found { owner[p] = found }
            }
        }
        for (pid, key) in roots where table.records[pid] != nil { owner[pid] = key }
        return owner
    }

    /// Sums each session's process tree. `sessionRoots`: each running session's top process
    /// (claude or its shell). `excludedRoots`: ClaudeDeck itself and its session helper, whose
    /// other children are left out of `others`.
    public static func report(table: ProcessUsageTable, cpu: [Int32: Double], sessionRoots: [UUID: Int32],
                              excludedRoots: Set<Int32> = [], othersLimit: Int = 10) -> LoadUsageReport {
        enum Owner: Hashable {
            case session(UUID)
            case claudeDeck
        }
        var roots: [Int32: Owner] = [:]
        for pid in excludedRoots { roots[pid] = .claudeDeck }
        for (session, pid) in sessionRoots where pid > 0 { roots[pid] = .session(session) }
        let owner = owners(in: table, roots: roots)

        var report = LoadUsageReport(at: table.at)
        report.processCount = table.records.count
        for record in table.records.values where LoadProcesses.simulatorNames.contains(record.name) {
            report.startTimes[record.pid] = record.started
        }
        var sessions: [UUID: SessionUsage] = [:]
        for session in sessionRoots.keys { sessions[session] = SessionUsage(session: session) }
        var others: [ProcessUsageRow] = []
        for record in table.records.values {
            let percent = cpu[record.pid] ?? 0
            report.totalCPU += percent
            let row = ProcessUsageRow(pid: record.pid, name: record.name, cpuPercent: percent, residentBytes: record.residentBytes,
                                      started: record.started)
            let who = owner[record.pid]
            if LoadProcesses.compilerNames.contains(record.name) || LoadProcesses.compilerNames.contains(String(record.name.prefix(16))) {
                var session: UUID?
                if case .session(let id) = who { session = id }
                report.builds.append(BuildProcessUsage(pid: record.pid, name: record.name, session: session, started: record.started,
                                                       cpuPercent: percent))
            }
            switch who {
            case .session(let id):
                sessions[id, default: SessionUsage(session: id)].cpuPercent += percent
                sessions[id, default: SessionUsage(session: id)].residentBytes += record.residentBytes
                sessions[id, default: SessionUsage(session: id)].processes.append(row)
            case .claudeDeck:
                break
            case nil:
                others.append(row)
            }
        }
        report.sessions = sessions.values.map { usage in
            var sorted = usage
            sorted.processes.sort(by: heavier)
            return sorted
        }
        .sorted { a, b in
            a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent
                : a.residentBytes != b.residentBytes ? a.residentBytes > b.residentBytes : a.session.uuidString < b.session.uuidString
        }
        report.others = Array(others.sorted(by: heavier).prefix(othersLimit))
        report.builds.sort { $0.started < $1.started }
        return report
    }

    static func heavier(_ a: ProcessUsageRow, _ b: ProcessUsageRow) -> Bool {
        a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent
            : a.residentBytes != b.residentBytes ? a.residentBytes > b.residentBytes : a.pid < b.pid
    }

    /// Agent-started sessions idle for longer than `minutes`: candidates for "Boşta olanları kapat".
    /// Only sessions another session started (`startedBy`), never the owner's own.
    public struct IdleCandidate: Sendable, Equatable {
        public var session: UUID
        public var startedBy: UUID?
        public var idle: Bool
        public var lastActivity: Date?
        public init(session: UUID, startedBy: UUID?, idle: Bool, lastActivity: Date?) {
            self.session = session
            self.startedBy = startedBy
            self.idle = idle
            self.lastActivity = lastActivity
        }
    }

    public static let idleMinutes = 15

    public static func idleAgents(_ candidates: [IdleCandidate], now: Date, minutes: Int = idleMinutes) -> [UUID] {
        candidates.filter { candidate in
            guard candidate.startedBy != nil, candidate.idle, let last = candidate.lastActivity else { return false }
            return now.timeIntervalSince(last) >= TimeInterval(minutes * 60)
        }
        .map(\.session)
    }
}

/// One row of `claudedeck load --json`'s `top` (a session) or `top_projects` (a project).
public struct LoadTopEntry: Encodable, Sendable, Equatable {
    /// "session" or "project".
    public var kind: String
    public var session: UUID?
    public var name: String
    public var project: String?
    public var cpuPercent: Double
    public var memoryMB: Int
    public var processes: Int
    /// Started by another session (`claudedeck new`).
    public var agent: Bool
    /// The heaviest processes ("node 34%"), at most five.
    public var topProcesses: [String]

    public init(kind: String, session: UUID?, name: String, project: String?, cpuPercent: Double, memoryBytes: UInt64, processes: Int,
                agent: Bool, topProcesses: [String]) {
        self.kind = kind
        self.session = session
        self.name = name
        self.project = project
        self.cpuPercent = (cpuPercent * 10).rounded() / 10
        memoryMB = Int(memoryBytes / 1_048_576)
        self.processes = processes
        self.agent = agent
        self.topProcesses = topProcesses
    }

    /// "  85.0%   2140 MB   14 procs  Wakeroo / backend  (node 40%, claude 30%)".
    public var line: String {
        let title = kind == "session" ? [project, name].compactMap { $0 }.joined(separator: " / ") : name
        var text = String(format: "%6.1f%%  %6d MB  %4d procs  ", cpuPercent, memoryMB, processes) + title
        if agent { text += "  [agent]" }
        if !topProcesses.isEmpty { text += "  (" + topProcesses.joined(separator: ", ") + ")" }
        return text
    }

    /// Session rows and project sums from a report. `describe`: a session's name, project name
    /// and whether another session started it (nil: no longer in the deck, left out).
    public static func entries(from report: LoadUsageReport,
                               describe: (UUID) -> (name: String, project: String, agent: Bool)?) -> (sessions: [LoadTopEntry], projects: [LoadTopEntry]) {
        var sessions: [LoadTopEntry] = []
        var projects: [String: (cpu: Double, bytes: UInt64, processes: Int)] = [:]
        var order: [String] = []
        for usage in report.sessions {
            guard let info = describe(usage.session) else { continue }
            let top = usage.processes.prefix(5).filter { $0.cpuPercent >= 1 }.map { "\($0.name) \(Int($0.cpuPercent.rounded()))%" }
            sessions.append(LoadTopEntry(kind: "session", session: usage.session, name: info.name, project: info.project,
                                         cpuPercent: usage.cpuPercent, memoryBytes: usage.residentBytes,
                                         processes: usage.processes.count, agent: info.agent, topProcesses: top))
            if projects[info.project] == nil { order.append(info.project) }
            projects[info.project, default: (0, 0, 0)].cpu += usage.cpuPercent
            projects[info.project, default: (0, 0, 0)].bytes += usage.residentBytes
            projects[info.project, default: (0, 0, 0)].processes += usage.processes.count
        }
        let projectRows = order.compactMap { name -> LoadTopEntry? in
            guard let sum = projects[name] else { return nil }
            return LoadTopEntry(kind: "project", session: nil, name: name, project: nil, cpuPercent: sum.cpu, memoryBytes: sum.bytes,
                                processes: sum.processes, agent: false, topProcesses: [])
        }
        .sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.memoryMB > $1.memoryMB }
        return (sessions, projectRows)
    }
}
