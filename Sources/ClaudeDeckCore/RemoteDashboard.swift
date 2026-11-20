import Foundation

// What the phone shows of the Mac's Dashboard and Simulators tabs (RemoteSnapshot.dashboard /
// .simulators). Built on the Mac only while a remote is connected, at most every few seconds, and
// kept free of "now": wait times go as the moment the wait began and the projected limit is
// rounded to the minute, so an unchanged dashboard doesn't resend the snapshot.

/// The Dashboard in brief: the "now" tiles, who is waiting (top 5) and the usage windows.
public struct RemoteDashboard: Codable, Sendable, Equatable {
    /// Claude sessions working / blocked on the user / finished and not yet seen (the Mac's tiles).
    public var working: Int
    public var waiting: Int
    public var yourTurn: Int
    /// Lines Claude changed today; nil until the Mac has read the transcripts.
    public var linesAdded: Int?
    public var linesRemoved: Int?
    /// Longest wait first, blocked before "your turn"; at most `maxWaiting`.
    public var waitingList: [Waiting]
    /// How many more are waiting than `waitingList` holds.
    public var moreWaiting: Int
    public var fiveHour: Window?
    public var week: Window?
    /// Each project's share of the usage windows (biggest first, at most `maxProjects`); nil from
    /// Macs that don't send it.
    public var projects: [ProjectShare]?

    public static let maxWaiting = 5
    public static let maxProjects = 8

    public init(working: Int, waiting: Int, yourTurn: Int, linesAdded: Int?, linesRemoved: Int?,
                waitingList: [Waiting], moreWaiting: Int = 0, fiveHour: Window?, week: Window?, projects: [ProjectShare]? = nil) {
        self.projects = projects
        self.working = working
        self.waiting = waiting
        self.yourTurn = yourTurn
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.waitingList = waitingList
        self.moreWaiting = moreWaiting
        self.fiveHour = fiveHour
        self.week = week
    }

    /// A session (or a terminal with Program Status) waiting on the user.
    public struct Waiting: Codable, Sendable, Equatable, Identifiable {
        public var sessionID: UUID
        public var name: String
        public var project: String
        /// "permission", "question" or "idle" (your turn) for Claude; "blocked", "finished" or
        /// "failed" for a terminal. A string: remotes show ones they don't know as waiting.
        public var reason: String
        public var detail: String?
        /// When the wait began (the remote counts the time itself).
        public var since: Date
        public var id: UUID { sessionID }

        public init(sessionID: UUID, name: String, project: String, reason: String, detail: String?, since: Date) {
            self.sessionID = sessionID
            self.name = name
            self.project = project
            self.reason = reason
            self.detail = detail
            self.since = since
        }

        /// Blocked on the user (rather than a result waiting to be seen).
        public var isBlocked: Bool { reason == "permission" || reason == "question" || reason == "blocked" }
    }

    /// A usage window with where it is heading at the current pace (`UsageProjection`).
    public struct Window: Codable, Sendable, Equatable {
        public var usedPercent: Double
        public var resetsAt: Date?
        /// When it reaches 100 % at the current pace (to the minute); nil when it isn't climbing.
        public var limitAt: Date?
        /// Percent per hour.
        public var ratePerHour: Double?

        public init(usedPercent: Double, resetsAt: Date?, limitAt: Date?, ratePerHour: Double?) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.limitAt = limitAt
            self.ratePerHour = ratePerHour
        }

        /// The limit comes before the reset.
        public var hitsLimitBeforeReset: Bool {
            guard let limitAt else { return false }
            guard let resetsAt else { return true }
            return limitAt < resetsAt
        }
    }

    /// One project's part of the plan's usage (ProjectUsage.swift on the Mac), rounded so small
    /// changes don't resend the snapshot.
    public struct ProjectShare: Codable, Sendable, Equatable, Identifiable {
        public var projectID: UUID
        public var name: String
        /// Percent points of the window this project used (its share × the window's percent);
        /// nil when the plan's usage isn't known.
        public var fiveHourPercent: Double?
        public var weekPercent: Double?
        /// Its share of the tracked cost in the window, 0–1.
        public var fiveHourShare: Double
        public var weekShare: Double
        /// Tokens in the window (cache reads included).
        public var fiveHourTokens: Int
        public var weekTokens: Int
        /// Estimated cost this week at API prices, in dollars.
        public var weekCost: Double
        public var id: UUID { projectID }

        public init(projectID: UUID, name: String, fiveHourPercent: Double?, weekPercent: Double?, fiveHourShare: Double,
                    weekShare: Double, fiveHourTokens: Int, weekTokens: Int, weekCost: Double) {
            self.projectID = projectID
            self.name = name
            self.fiveHourPercent = fiveHourPercent.map { ($0 * 10).rounded() / 10 }
            self.weekPercent = weekPercent.map { ($0 * 10).rounded() / 10 }
            self.fiveHourShare = (fiveHourShare * 1000).rounded() / 1000
            self.weekShare = (weekShare * 1000).rounded() / 1000
            self.fiveHourTokens = Self.round(fiveHourTokens)
            self.weekTokens = Self.round(weekTokens)
            self.weekCost = (weekCost * 100).rounded() / 100
        }

        /// To 3 significant digits.
        static func round(_ n: Int) -> Int {
            guard n >= 1000 else { return n }
            var scale = 1
            while n / scale >= 1000 { scale *= 10 }
            return (n + scale / 2) / scale * scale
        }
    }

    /// Sorts the waiting sessions like the Mac's "Waiting on you" card (blocked first, then the
    /// longest wait) and keeps the first `maxWaiting`.
    public static func top(_ waiting: [Waiting]) -> (list: [Waiting], more: Int) {
        let sorted = waiting.sorted { ($0.isBlocked ? 0 : 1, $0.since, $0.name) < ($1.isBlocked ? 0 : 1, $1.since, $1.name) }
        return (Array(sorted.prefix(maxWaiting)), max(0, sorted.count - maxWaiting))
    }
}

/// A simulator on the Mac (read-only on the phone).
public struct RemoteSimulator: Codable, Sendable, Equatable, Identifiable {
    public var udid: String
    public var name: String
    /// "iOS 26.0".
    public var runtime: String
    /// simctl's state: "Booted", "Shutdown", "Booting"…
    public var state: String
    /// Memory of a running simulator (its processes' footprint).
    public var memoryBytes: UInt64?
    /// The sessions seen using it (latest first).
    public var sessionIDs: [UUID]
    /// The session that reserved it (`claudedeck sim acquire`); nil from older Macs.
    public var heldBy: UUID?
    public var id: String { udid }

    public init(udid: String, name: String, runtime: String, state: String, memoryBytes: UInt64? = nil, sessionIDs: [UUID] = [],
                heldBy: UUID? = nil) {
        self.heldBy = heldBy
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.memoryBytes = memoryBytes
        self.sessionIDs = sessionIDs
    }

    public var isBooted: Bool { state == "Booted" }

    /// Running ones first (then by name), at most `max`: the phone gets the ones that matter.
    public static func forRemote(_ list: [RemoteSimulator], max: Int = 30) -> [RemoteSimulator] {
        Array(list.sorted { ($0.state == "Shutdown" ? 1 : 0, $0.name, $0.udid) < ($1.state == "Shutdown" ? 1 : 0, $1.name, $1.udid) }.prefix(max))
    }
}

/// The Mac's load in brief (RemoteSnapshot.load, hosts with `Feature.load`), for the phone's
/// dashboard. Rounded so a Mac whose load barely moves doesn't resend the snapshot every sample.
public struct RemoteLoad: Codable, Sendable, Equatable {
    /// "ok", "busy" or "overloaded" (a string: an unknown one shows as busy).
    public var level: String
    /// Something is held back right now (new agents; while overloaded simulators and builds too).
    public var throttled: Bool
    /// The 1-minute load per core, to one decimal (1.0: every core busy).
    public var loadPerCore: Double
    public var cores: Int
    /// Memory in use, in whole percent; "normal", "warning" or "critical".
    public var memoryPercent: Int
    public var memoryPressure: String
    public var simulators: Int
    /// Compiler and linker processes.
    public var builds: Int
    /// Claude sessions running on the Mac.
    public var sessions: Int
    public var slotsUsed: Int
    public var slots: Int
    /// The heaviest sessions (hosts with `Feature.loadDetail`, while measured; nil otherwise).
    public var top: [Top]?
    /// Booted simulators with who holds them (hosts with `Feature.loadDetail`).
    public var bootedSimulators: [BootedSimulator]?
    /// The overload triggers firing now (`compilers`, `load`, …; hosts with `Feature.loadDetail`).
    public var fired: [String]?
    /// The last hour, one point per minute, oldest first, at most `maxHistory` (hosts with
    /// `Feature.loadHistory`). Only finished minutes, so it changes once a minute.
    public var history: [Sample]?
    /// The heaviest projects (hosts with `Feature.loadHistory`, while measured).
    public var topProjects: [ProjectUse]?
    /// Who holds the build slots now (hosts with `Feature.loadHistory`).
    public var slotHolders: [SlotHolder]?
    /// Compiler and linker processes running now, the busiest first (hosts with `Feature.loadHistory`, while measured).
    public var runningBuilds: [Build]?

    public static let maxHistory = 60
    public static let maxBuilds = 8

    /// One minute of the Mac's load (averages; simulators and builds at their highest).
    public struct Sample: Codable, Sendable, Equatable, Identifiable {
        public var at: Date
        /// The 1-minute load per core, to two decimals.
        public var loadPerCore: Double
        public var memoryPercent: Int
        public var simulators: Int
        public var builds: Int
        public var id: Date { at }
        public init(at: Date, loadPerCore: Double, memoryPercent: Int, simulators: Int, builds: Int) {
            self.at = at
            self.loadPerCore = (loadPerCore * 100).rounded() / 100
            self.memoryPercent = memoryPercent
            self.simulators = simulators
            self.builds = builds
        }
    }

    /// A project with its sessions' use together.
    public struct ProjectUse: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var cpuPercent: Int
        public var memoryMB: Int
        public var id: String { name }
        public init(name: String, cpuPercent: Int, memoryMB: Int) {
            self.name = name
            self.cpuPercent = cpuPercent
            self.memoryMB = memoryMB
        }
    }

    /// A build slot (`claudedeck slot` / `heavy`) and the session holding it.
    public struct SlotHolder: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var session: UUID
        /// The session's name ("" when it's gone).
        public var name: String
        /// What it's for (`heavy` passes the command).
        public var label: String?
        public var since: Date
        public init(id: String, session: UUID, name: String, label: String?, since: Date) {
            self.id = id
            self.session = session
            self.name = name
            self.label = label
            self.since = since
        }
    }

    /// A compiler or linker process.
    public struct Build: Codable, Sendable, Equatable, Identifiable {
        public var pid: Int32
        /// The process name (swift-frontend, clang, ld…).
        public var name: String
        /// The session it runs under; nil: outside ClaudeDeck.
        public var session: String?
        public var cpuPercent: Int
        public var id: Int32 { pid }
        public init(pid: Int32, name: String, session: String?, cpuPercent: Int) {
            self.pid = pid
            self.name = name
            self.session = session
            self.cpuPercent = cpuPercent
        }
    }

    /// One session with its child processes.
    public struct Top: Codable, Sendable, Equatable, Identifiable {
        public var session: UUID
        public var name: String
        public var project: String
        /// CPU in whole percent (100: one core), memory in MB.
        public var cpuPercent: Int
        public var memoryMB: Int
        /// Started by another session (`claudedeck new`).
        public var agent: Bool
        public var id: UUID { session }
        public init(session: UUID, name: String, project: String, cpuPercent: Int, memoryMB: Int, agent: Bool) {
            self.session = session
            self.name = name
            self.project = project
            self.cpuPercent = cpuPercent
            self.memoryMB = memoryMB
            self.agent = agent
        }
    }

    public struct BootedSimulator: Codable, Sendable, Equatable, Identifiable {
        public var udid: String
        public var name: String
        /// The session holding it (`claudedeck sim acquire`); nil: the user's own.
        public var holder: String?
        public var memoryMB: Int?
        public var id: String { udid }
        public init(udid: String, name: String, holder: String?, memoryMB: Int?) {
            self.udid = udid
            self.name = name
            self.holder = holder
            self.memoryMB = memoryMB
        }
    }

    public init(level: String, throttled: Bool, loadPerCore: Double, cores: Int, memoryPercent: Int, memoryPressure: String,
                simulators: Int, builds: Int, sessions: Int, slotsUsed: Int, slots: Int) {
        self.level = level
        self.throttled = throttled
        self.loadPerCore = (loadPerCore * 10).rounded() / 10
        self.cores = cores
        self.memoryPercent = memoryPercent
        self.memoryPressure = memoryPressure
        self.simulators = simulators
        self.builds = builds
        self.sessions = sessions
        self.slotsUsed = slotsUsed
        self.slots = slots
    }
}
