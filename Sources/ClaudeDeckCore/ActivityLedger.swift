import Foundation

// The dashboard's memory: every change of a Claude session's state (working, waiting on the user,
// idle, off) and every usage reading, appended as it happens and kept for a week. The dashboard
// derives its timeline, response times and burn-rate projection from it; nothing here polls.

/// A Claude session's state as the dashboard draws it.
public enum LedgerActivity: String, Codable, Sendable, CaseIterable {
    case running
    case permission
    case question
    case idle
    /// Not running (closed, ended, the app quit).
    case off

    public var isBlocked: Bool { self == .permission || self == .question }

    public init(_ activity: SessionActivity?) {
        switch activity {
        case .running: self = .running
        case .needsPermission: self = .permission
        case .needsAnswer: self = .question
        case .idle: self = .idle
        case .ended, nil: self = .off
        }
    }
}

/// One state change.
public struct LedgerEvent: Codable, Sendable, Equatable {
    public var session: UUID
    public var project: UUID
    public var activity: LedgerActivity
    /// What it was doing ("Bash: swift test"), short.
    public var detail: String?
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case session = "s", project = "p", activity = "a", detail = "d", at = "t"
    }

    public init(session: UUID, project: UUID, activity: LedgerActivity, detail: String? = nil, at: Date) {
        self.session = session
        self.project = project
        self.activity = activity
        self.detail = detail
        self.at = at
    }
}

/// One usage reading of the plan's windows.
public struct UsageSample: Codable, Sendable, Equatable {
    public var at: Date
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDay: Double?
    public var sevenDayResetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case at = "t", fiveHour = "h", fiveHourResetsAt = "hr", sevenDay = "w", sevenDayResetsAt = "wr"
    }

    public init(at: Date, fiveHour: Double?, fiveHourResetsAt: Date? = nil, sevenDay: Double?, sevenDayResetsAt: Date? = nil) {
        self.at = at
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDay = sevenDay
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    public init(_ usage: ClaudeUsage) {
        self.init(at: usage.fetchedAt, fiveHour: usage.fiveHour?.usedPercent, fiveHourResetsAt: usage.fiveHour?.resetsAt,
                  sevenDay: usage.sevenDay?.usedPercent, sevenDayResetsAt: usage.sevenDay?.resetsAt)
    }
}

/// A stretch of one session in one state (a bar of the activity timeline).
public struct LedgerSegment: Sendable, Equatable, Identifiable {
    public var session: UUID
    public var project: UUID
    public var activity: LedgerActivity
    public var detail: String?
    public var start: Date
    public var end: Date
    public var id: String { "\(session.uuidString)-\(start.timeIntervalSince1970)" }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The user answering a permission prompt or question: how long the session waited.
public struct LedgerResponse: Sendable, Equatable {
    public var session: UUID
    public var activity: LedgerActivity
    public var askedAt: Date
    public var waited: TimeInterval
}

public struct ActivityLedger: Codable, Sendable, Equatable {
    public static let keep: TimeInterval = 7 * 86400
    public static let maxEvents = 40_000
    public static let maxUsageSamples = 3_000
    static let maxDetail = 80

    /// Oldest first.
    public private(set) var events: [LedgerEvent] = []
    /// Oldest first.
    public private(set) var usage: [UsageSample] = []
    /// Last time the ledger was written: a session still "on" in a ledger read at launch was on
    /// until about then.
    public var savedAt: Date?
    /// Each session's latest state (not persisted; rebuilt from `events`).
    private var latest: [UUID: Int] = [:]

    enum CodingKeys: String, CodingKey { case events, usage, savedAt }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? c.decodeIfPresent([LedgerEvent].self, forKey: .events)) ?? []
        usage = (try? c.decodeIfPresent([UsageSample].self, forKey: .usage)) ?? []
        savedAt = try? c.decodeIfPresent(Date.self, forKey: .savedAt)
        events.sort { $0.at < $1.at }
        usage.sort { $0.at < $1.at }
        reindex()
    }

    public static func == (a: ActivityLedger, b: ActivityLedger) -> Bool {
        a.events == b.events && a.usage == b.usage && a.savedAt == b.savedAt
    }

    private mutating func reindex() {
        latest = [:]
        for (index, event) in events.enumerated() { latest[event.session] = index }
    }

    public func current(_ session: UUID) -> LedgerEvent? { latest[session].map { events[$0] } }

    /// Sessions whose latest state isn't `off`.
    public var onSessions: [UUID] { latest.filter { events[$0.value].activity != .off }.map(\.key) }

    /// Records a session's state; false (nothing stored) when it's what was recorded last.
    @discardableResult
    public mutating func record(session: UUID, project: UUID, activity: LedgerActivity, detail: String? = nil, at: Date) -> Bool {
        let last = current(session)
        if last?.activity == activity { return false }
        // A session never seen before that isn't running: nothing to draw.
        if last == nil, activity == .off { return false }
        let detail = detail.map { String($0.prefix(Self.maxDetail)) }
        // Never before the previous change (clock adjustments): the timeline stays ordered.
        let at = max(at, events.last?.at ?? at)
        events.append(LedgerEvent(session: session, project: project, activity: activity, detail: detail, at: at))
        latest[session] = events.count - 1
        return true
    }

    /// Marks every session that was still on as off at `at` (the app quit, or it crashed and this
    /// is the next launch with `savedAt`).
    public mutating func closeAll(at: Date) {
        for (session, index) in latest.sorted(by: { $0.value < $1.value }) where events[index].activity != .off {
            record(session: session, project: events[index].project, activity: .off, at: at)
        }
    }

    /// Adds a usage reading unless it's the same fetch as the last one.
    @discardableResult
    public mutating func record(usage sample: UsageSample) -> Bool {
        if let last = usage.last, last.at >= sample.at { return false }
        usage.append(sample)
        return true
    }

    /// Drops what's older than `keep` (keeping each session's state at the cut-off, so its bar
    /// still starts at the left edge) and caps the counts.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keep)
        var carried: [UUID: LedgerEvent] = [:]
        var kept: [LedgerEvent] = []
        for event in events {
            if event.at < cutoff {
                carried[event.session] = event
            } else {
                kept.append(event)
            }
        }
        let carriedOn = carried.values.filter { $0.activity != .off }.map { event in
            var e = event
            e.at = cutoff
            return e
        }.sorted { $0.session.uuidString < $1.session.uuidString }
        kept = carriedOn + kept
        if kept.count > Self.maxEvents { kept.removeFirst(kept.count - Self.maxEvents) }
        events = kept
        usage.removeAll { $0.at < cutoff }
        if usage.count > Self.maxUsageSamples { usage.removeFirst(usage.count - Self.maxUsageSamples) }
        reindex()
    }

    // MARK: Queries

    /// Each session's states overlapping `window`, clipped to it. A session's last state lasts
    /// until `now`. `off` stretches are left out.
    public func segments(in window: DateInterval, now: Date) -> [LedgerSegment] {
        var open: [UUID: LedgerEvent] = [:]
        var result: [LedgerSegment] = []
        func close(_ event: LedgerEvent, at end: Date) {
            guard event.activity != .off else { return }
            let start = max(event.at, window.start)
            let stop = min(end, window.end)
            guard stop > start else { return }
            result.append(LedgerSegment(session: event.session, project: event.project, activity: event.activity,
                                        detail: event.detail, start: start, end: stop))
        }
        for event in events {
            if event.at > window.end { break }
            if let previous = open[event.session] { close(previous, at: event.at) }
            open[event.session] = event
        }
        for event in open.values { close(event, at: now) }
        return result.sorted { ($0.start, $0.session.uuidString) < ($1.start, $1.session.uuidString) }
    }

    /// Prompts and questions answered since `since`: how long each waited for the user. A wait
    /// that ended with the session closing doesn't count.
    public func responses(since: Date) -> [LedgerResponse] {
        var asked: [UUID: LedgerEvent] = [:]
        var result: [LedgerResponse] = []
        for event in events {
            if let pending = asked.removeValue(forKey: event.session), event.activity != .off, event.at >= since {
                result.append(LedgerResponse(session: event.session, activity: pending.activity, askedAt: pending.at,
                                             waited: event.at.timeIntervalSince(pending.at)))
            }
            if event.activity.isBlocked { asked[event.session] = event }
        }
        return result
    }

    /// Seconds each project's sessions spent working, per hour, since `since` (key: start of the
    /// hour). Overlapping sessions add up.
    public func workingSeconds(byHourSince since: Date, now: Date) -> [UUID: [Date: TimeInterval]] {
        var result: [UUID: [Date: TimeInterval]] = [:]
        for segment in segments(in: DateInterval(start: since, end: max(since, now)), now: now) where segment.activity == .running {
            var cursor = segment.start
            while cursor < segment.end {
                let hour = Self.hourStart(cursor)
                let next = min(segment.end, hour.addingTimeInterval(3600))
                result[segment.project, default: [:]][hour, default: 0] += next.timeIntervalSince(cursor)
                cursor = next
            }
        }
        return result
    }

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - Usage projection

/// Where a usage window is heading at the current pace.
public struct UsageProjection: Sendable, Equatable {
    /// Percent of the window used per hour.
    public var ratePerHour: Double
    /// When it reaches 100 % at that pace (nil when it isn't climbing).
    public var limitAt: Date?
    public var resetsAt: Date?
    /// Whether the pace comes from recent readings (else: the window's average so far).
    public var fromRecentSamples: Bool

    /// The limit comes before the reset.
    public var hitsLimitBeforeReset: Bool {
        guard let limitAt else { return false }
        guard let resetsAt else { return true }
        return limitAt < resetsAt
    }

    /// Projects a window of `length` (5 h, 7 days) from the current reading and the samples:
    /// the slope of the readings over the last `recent` (when there are enough of them, all in
    /// this window), else the average pace since the window began (`resetsAt - length`).
    public static func project(
        current: UsageWindow, length: TimeInterval, samples: [(at: Date, percent: Double)], now: Date,
        recent: TimeInterval = 90 * 60, minimumSpan: TimeInterval = 15 * 60
    ) -> UsageProjection? {
        let used = current.usedPercent
        if used >= 100 { return UsageProjection(ratePerHour: 0, limitAt: now, resetsAt: current.resetsAt, fromRecentSamples: false) }
        // Readings from this window only: the percentage drops at a reset.
        var window: [(at: Date, percent: Double)] = []
        for sample in samples.sorted(by: { $0.at < $1.at }) where sample.at <= now && sample.at >= now.addingTimeInterval(-recent) {
            if let last = window.last, sample.percent + 0.5 < last.percent { window.removeAll() }
            window.append(sample)
        }
        if let start = current.resetsAt?.addingTimeInterval(-length) { window.removeAll { $0.at < start } }
        var rate: Double?
        var fromSamples = false
        if window.count >= 3, let first = window.first, let last = window.last, last.at.timeIntervalSince(first.at) >= minimumSpan {
            rate = slopePerHour(window)
            fromSamples = true
        } else if let reset = current.resetsAt {
            let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-length))
            if elapsed > 60 { rate = used / (elapsed / 3600) }
        }
        guard let rate else { return nil }
        let limitAt = rate > 0.01 ? now.addingTimeInterval((100 - used) / rate * 3600) : nil
        return UsageProjection(ratePerHour: rate, limitAt: limitAt, resetsAt: current.resetsAt, fromRecentSamples: fromSamples)
    }

    /// Least-squares slope, percent per hour.
    static func slopePerHour(_ points: [(at: Date, percent: Double)]) -> Double {
        let t0 = points[0].at
        let xs = points.map { $0.at.timeIntervalSince(t0) / 3600 }
        let ys = points.map(\.percent)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - mx) * (y - my)
            den += (x - mx) * (x - mx)
        }
        return den > 0 ? num / den : 0
    }
}
