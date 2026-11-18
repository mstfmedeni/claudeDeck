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

    public static let maxWaiting = 5

    public init(working: Int, waiting: Int, yourTurn: Int, linesAdded: Int?, linesRemoved: Int?,
                waitingList: [Waiting], moreWaiting: Int = 0, fiveHour: Window?, week: Window?) {
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

        /// From the current reading and the recorded samples. The pace and the limit are rounded
        /// (0.1 %/h, the minute) so the same pace gives the same value on the next build.
        public static func make(_ current: UsageWindow, length: TimeInterval, samples: [(at: Date, percent: Double)], now: Date,
                                recent: TimeInterval = 90 * 60, minimumSpan: TimeInterval = 15 * 60) -> Window {
            let projection = UsageProjection.project(current: current, length: length, samples: samples, now: now,
                                                     recent: recent, minimumSpan: minimumSpan)
            let limit = projection?.limitAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
            let rate = projection.map { ($0.ratePerHour * 10).rounded() / 10 }
            return Window(usedPercent: (current.usedPercent * 10).rounded() / 10, resetsAt: current.resetsAt, limitAt: limit, ratePerHour: rate)
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
    public var id: String { udid }

    public init(udid: String, name: String, runtime: String, state: String, memoryBytes: UInt64? = nil, sessionIDs: [UUID] = []) {
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
