import Foundation
import Observation

/// Owner approvals that a session (an agent) asks for and waits on: the ServerPlan 428 gates
/// (`claudedeck server …` actions the panel wants confirmed) and domain purchases. They used to be
/// modal sheets on whatever window was key; they are now a non-modal queue (the Approvals tab,
/// a sidebar tray, a notification, the phone's snapshot) and the asking call keeps waiting until
/// the owner answers, the request expires (refused) or the caller goes away.
/// `OwnerApproval` itself lives in RemoteProtocol.swift (the phone decodes it too).
public enum Approvals {
    /// How long an approval waits. `claudedeck server` waits for it with curl timeouts built
    /// around these 2 minutes (SessionCLIScript.swift), so change both together.
    public static let timeout: TimeInterval = 120
    /// More waiting at once is refused at once (a runaway loop shouldn't bury the owner).
    public static let maxPending = 20
    /// Resolved ones kept for the Recent section.
    public static let maxRecent = 30

    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return "a_" + String((0..<12).map { _ in digits[Int(generator.next() % 16)] })
    }

    /// An id as the app makes it: `a_` and letters or digits (checked before a phone's answer
    /// or a debug hook file name is used).
    public static func isValidID(_ id: String) -> Bool { OwnerApproval.isValidID(id) }
}

/// The pending and recently resolved approvals (pure value; `ApprovalQueue` drives it).
public struct ApprovalBook: Sendable, Equatable {
    /// Waiting ones, the one that expires first on top (ties: the older first).
    public private(set) var pending: [OwnerApproval] = []
    /// Resolved ones, newest first.
    public private(set) var recent: [ResolvedApproval] = []

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
        return resolved
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
    /// once (without being queued); so is a request whose time is already up.
    public func request(_ approval: OwnerApproval) async -> ApprovalOutcome {
        guard book.approval(approval.id) == nil, book.pending.count < Approvals.maxPending, approval.expiresAt > now() else { return .refused }
        let id = approval.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
                waiters[id] = continuation
                book.add(approval)
                scheduleExpiry(approval)
                notify(.added(approval))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, .cancelled, from: "caller") }
        }
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
