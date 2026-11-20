import Foundation
import Observation

/// Owner approvals that a session (an agent) asks for: the ServerPlan 428 gates (`claudedeck
/// server …` actions the panel wants confirmed) and domain purchases. They're a non-modal queue
/// (the Approvals tab, a sidebar tray, a notification, the phone's snapshot) and wait up to the
/// owner's setting (24 hours by default, or with no limit). The asking `claudedeck` call doesn't
/// hold one request open for that long: it's told "pending approval a_…" (exit 75) and long-polls
/// `approval wait`. The gated action runs in the app, apart from that request: once the owner
/// says yes it's sent again with the panel's confirm even when the asking call is gone, and the
/// result is queued for the asking session as a one-line message. Pending ones are kept in
/// Application Support/approvals.json and stay actionable after a relaunch.
/// `OwnerApproval`, `ApprovalOutcome` and `ResolvedApproval` live in RemoteProtocol.swift (the
/// phone decodes them too).
public enum Approvals {
    /// More waiting at once is refused at once (a runaway loop shouldn't bury the owner).
    public static let maxPending = 20
    /// Resolved ones kept (the Recent section, the phone's history, `approval status`).
    public static let maxRecent = 50
    /// The phone's history covers this many days.
    public static let historyDays = 7
    /// One long-poll round of `claudedeck approval wait` (and of a gated call's first answer).
    public static let pollWindow: TimeInterval = 25

    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return "a_" + String((0..<12).map { _ in digits[Int(generator.next() % 16)] })
    }

    /// An id as the app makes it: `a_` and letters or digits (checked before a phone's answer
    /// or a debug hook file name is used).
    public static func isValidID(_ id: String) -> Bool { OwnerApproval.isValidID(id) }

    /// The one-line message queued for the asking session once its approval ended.
    public static func message(for resolved: ResolvedApproval) -> String {
        let head = "[ClaudeDeck approval \(resolved.approval.id)]"
        let title = resolved.approval.title
        switch resolved.outcome {
        case .approved: return "\(head) Owner approved: \(title) → \(oneLine(resolved.result ?? "done"))"
        case .refused: return "\(head) Owner refused: \(title)"
        case .expired: return "\(head) Expired with no answer from the owner: \(title)"
        case .cancelled: return "\(head) Cancelled: \(title)"
        }
    }

    /// The first line of a result, cut for a message or a list.
    public static func oneLine(_ text: String, limit: Int = 300) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// The phone's history: resolved in the last `historyDays`, newest first.
    public static func history(_ recent: [ResolvedApproval], now: Date) -> [ResolvedApproval] {
        recent.filter { now.timeIntervalSince($0.resolvedAt) < TimeInterval(historyDays) * 24 * 3600 }
    }
}

/// Settings > Agents > Approval wait time: how long an approval waits for the owner.
public enum ApprovalWait: String, Codable, CaseIterable, Sendable {
    case quarterHour = "15m"
    case hour = "1h"
    case fourHours = "4h"
    case day = "24h"
    case never

    public var interval: TimeInterval? {
        switch self {
        case .quarterHour: 15 * 60
        case .hour: 3600
        case .fourHours: 4 * 3600
        case .day: 24 * 3600
        case .never: nil
        }
    }

    /// When an approval made at `date` expires; "never" is a century out (`OwnerApproval.neverExpires`).
    public func expiry(from date: Date) -> Date {
        date.addingTimeInterval(interval ?? 100 * 365 * 24 * 3600)
    }

    /// For the log ("no answer in 24 h").
    public var label: String {
        switch self {
        case .quarterHour: "15 min"
        case .hour: "1 h"
        case .fourHours: "4 h"
        case .day: "24 h"
        case .never: "no limit"
        }
    }
}

/// A `claudedeck server` call that waits on an approval: enough to run it again when the owner
/// approves after the app restarted (the running call is gone then).
public struct ApprovalReplay: Codable, Sendable, Equatable {
    public var caller: UUID
    public var command: String
    public var method: String
    public var form: [String: String]
    public var json: Bool

    public init(caller: UUID, command: String, method: String, form: [String: String], json: Bool) {
        self.caller = caller
        self.command = command
        self.method = method
        self.form = form
        self.json = json
    }
}

/// The answer the asking call would have got, kept for `claudedeck approval wait`.
public struct ApprovalCallResult: Codable, Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var headers: [String: String]

    public init(_ response: AgentHTTPResponse) {
        status = response.status
        body = response.body
        contentType = response.contentType
        headers = response.headers
    }

    public var response: AgentHTTPResponse {
        AgentHTTPResponse(status: status, body: body, contentType: contentType, headers: headers)
    }
}

/// What `claudedeck approval status` (and a gated call's "pending" answer) says about one.
public struct ApprovalStatus: Codable, Sendable, Equatable {
    public var id: String
    /// "pending", "approved", "refused", "expired", "cancelled".
    public var status: String
    public var title: String
    public var command: String
    public var target: String
    public var session: String
    public var createdAt: Date
    /// Nil when it never expires.
    public var expiresAt: Date?
    public var resolvedAt: Date?
    public var result: String?

    enum CodingKeys: String, CodingKey {
        case id, status, title, command, target, session, result
        case createdAt = "created_at", expiresAt = "expires_at", resolvedAt = "resolved_at"
    }

    public init(pending approval: OwnerApproval) {
        id = approval.id
        status = "pending"
        title = approval.title
        command = approval.command
        target = approval.target
        session = approval.session
        createdAt = approval.createdAt
        expiresAt = approval.neverExpires ? nil : approval.expiresAt
    }

    public init(resolved: ResolvedApproval) {
        self.init(pending: resolved.approval)
        status = resolved.outcome.rawValue
        resolvedAt = resolved.resolvedAt
        result = resolved.result
    }

    /// One line for the text format.
    public func text(now: Date = Date()) -> String {
        switch status {
        case "pending":
            let left = expiresAt.map { "expires in " + Self.durationText($0.timeIntervalSince(now)) } ?? "no expiry"
            return "pending approval \(id) (\(left)): \(title)"
        default:
            return "\(id) \(status): \(title)" + (result.map { " → " + Approvals.oneLine($0) } ?? "")
        }
    }

    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded(.up)) / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// The pending and recently resolved approvals (pure value; `ApprovalQueue` drives it).
public struct ApprovalBook: Codable, Sendable, Equatable {
    /// Waiting ones, the one that expires first on top (ties: the older first).
    public private(set) var pending: [OwnerApproval] = []
    /// Resolved ones, newest first.
    public private(set) var recent: [ResolvedApproval] = []
    /// The `claudedeck server` call behind each pending (or just resolved) approval, by id.
    public private(set) var replays: [String: ApprovalReplay] = [:]
    /// The answers the asking calls get, by id (kept while the approval is in `recent`).
    public private(set) var results: [String: ApprovalCallResult] = [:]

    public init() {}

    public func approval(_ id: String) -> OwnerApproval? { pending.first { $0.id == id } }

    /// Adds a request; false when the id is taken or too many are waiting.
    @discardableResult
    public mutating func add(_ approval: OwnerApproval) -> Bool {
        guard self.approval(approval.id) == nil, pending.count < Approvals.maxPending else { return false }
        pending.append(approval)
        pending.sort { ($0.expiresAt, $0.createdAt, $0.id) < ($1.expiresAt, $1.createdAt, $1.id) }
        return true
    }

    /// Takes a pending approval out with its outcome; nil when it isn't pending (already
    /// resolved, or unknown), so a second answer never counts.
    public mutating func resolve(_ id: String, _ outcome: ApprovalOutcome, from: String, at date: Date) -> ResolvedApproval? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let resolved = ResolvedApproval(approval: pending.remove(at: index), outcome: outcome, from: from, resolvedAt: date)
        recent.insert(resolved, at: 0)
        if recent.count > Approvals.maxRecent { recent.removeLast(recent.count - Approvals.maxRecent) }
        let kept = Set(pending.map(\.id) + recent.map(\.id))
        replays = replays.filter { kept.contains($0.key) }
        results = results.filter { kept.contains($0.key) }
        return resolved
    }

    public func resolved(_ id: String) -> ResolvedApproval? { recent.first { $0.id == id } }

    /// Remembers the call behind a pending approval (for a replay after a relaunch).
    public mutating func attach(_ replay: ApprovalReplay, to id: String) {
        guard approval(id) != nil else { return }
        replays[id] = replay
    }

    /// The asking call's answer once the gated action ran (or was refused); `line` goes on the
    /// resolved approval (the Recent section, the message, the phone's history).
    public mutating func setResult(_ id: String, _ result: ApprovalCallResult, line: String?) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        results[id] = result
        if let line { recent[index].result = line }
        replays[id] = nil
    }

    /// The status `claudedeck approval status` shows; nil for an unknown id.
    public func status(_ id: String) -> ApprovalStatus? {
        if let approval = approval(id) { return ApprovalStatus(pending: approval) }
        return resolved(id).map(ApprovalStatus.init(resolved:))
    }

    /// Pending ones whose time is up at `now`.
    public func due(at now: Date) -> [String] {
        pending.filter { $0.expiresAt <= now }.map(\.id)
    }
}

/// The live queue: requests wait on a continuation that is resumed exactly once, by the owner's
/// answer, the expiry timer, or the caller's cancellation, whichever comes first.
@MainActor
@Observable
public final class ApprovalQueue {
    public enum Change: Sendable {
        case added(OwnerApproval)
        case resolved(ResolvedApproval)
        /// A replay or a result was attached (only the file changes).
        case updated(String)
    }

    public private(set) var book = ApprovalBook()
    public var pending: [OwnerApproval] { book.pending }
    public var pendingCount: Int { book.pending.count }

    @ObservationIgnored private var waiters: [String: CheckedContinuation<ApprovalOutcome, Never>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [(Change) -> Void] = []
    /// The clock (tests move it).
    @ObservationIgnored public var now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Called on every add and every resolution (the notification, the phone's snapshot, the log).
    public func observe(_ handler: @escaping (Change) -> Void) {
        observers.append(handler)
    }

    /// Queues the request and waits for its outcome. A full queue or a taken id is refused at
    /// once (without being queued); so is a request whose time is already up. `replay` is the
    /// call behind it, kept with it on disk. The wait isn't tied to the asking HTTP request: an
    /// approval ends only with the owner's answer, its expiry, or `cancel`.
    public func request(_ approval: OwnerApproval, replay: ApprovalReplay? = nil) async -> ApprovalOutcome {
        guard book.approval(approval.id) == nil, book.pending.count < Approvals.maxPending, approval.expiresAt > now() else { return .refused }
        let id = approval.id
        return await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
            waiters[id] = continuation
            book.add(approval)
            if let replay { book.attach(replay, to: id) }
            scheduleExpiry(approval)
            notify(.added(approval))
        }
    }

    /// Whether a running call waits on this approval (false after a relaunch: then the app
    /// replays the call itself once it's approved).
    public func hasWaiter(_ id: String) -> Bool { waiters[id] != nil }

    /// The asking session withdraws it.
    @discardableResult
    public func cancel(_ id: String, from: String = "agent") -> ResolvedApproval? {
        resolve(id, .cancelled, from: from)
    }

    /// The gated call's answer (see `ApprovalBook.setResult`).
    public func setResult(_ id: String, _ result: ApprovalCallResult, line: String?) {
        book.setResult(id, result, line: line)
        notify(.updated(id))
    }

    /// The book read back from disk at launch: pending ones wait again (no running call behind
    /// them), the ones whose time ran out while the app was closed expire now.
    public func restore(_ saved: ApprovalBook) {
        book = saved
        for approval in book.pending { scheduleExpiry(approval) }
        expireDue()
    }

    /// The owner's (or the timer's) answer. Returns the resolution, or nil when the approval
    /// isn't pending any more: only the first answer counts.
    @discardableResult
    public func resolve(_ id: String, _ outcome: ApprovalOutcome, from: String) -> ResolvedApproval? {
        guard let resolved = book.resolve(id, outcome, from: from, at: now()) else { return nil }
        timers.removeValue(forKey: id)?.cancel()
        let waiter = waiters.removeValue(forKey: id)
        notify(.resolved(resolved))
        waiter?.resume(returning: outcome)
        return resolved
    }

    /// Expires every pending approval whose time is up (the timers do this on their own; this
    /// catches up after the Mac slept, and lets tests move the clock).
    public func expireDue() {
        for id in book.due(at: now()) { resolve(id, .expired, from: "timeout") }
    }

    private func scheduleExpiry(_ approval: OwnerApproval) {
        guard !approval.neverExpires else { return }
        let delay = max(0, approval.expiresAt.timeIntervalSince(now()))
        let id = approval.id
        timers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resolve(id, .expired, from: "timeout")
        }
    }

    private func notify(_ change: Change) {
        for observer in observers { observer(change) }
    }
}
