import Foundation

// Build slots (`claudedeck slot acquire|release build`, `claudedeck heavy -- COMMAND`): a global
// semaphore so agents don't run thirty compiles at once. Settings › Resources › "Aynı anda en fazla
// derleme" sets how many (3 on a 20-core Mac); during an overload episode only one is handed out.
// Waiters are served first come, first served: `acquire --wait` polls with the same ticket, and a
// ticket not seen for `waiterTimeout` gives up its place. A slot goes back with `release`, when
// its session ends, or after the longest hold (Settings). In memory only: nothing survives a quit.

public struct BuildSlot: Sendable, Equatable {
    /// `b_` and 8 hex characters.
    public var id: String
    /// Only "build" for now.
    public var kind: String
    public var session: UUID
    /// What it's for (`heavy` passes the command), shown in `load` and `status`.
    public var label: String?
    public var acquiredAt: Date

    public init(id: String = BuildSlotBook.newID(), kind: String = BuildSlotBook.build, session: UUID, label: String?, acquiredAt: Date) {
        self.id = id
        self.kind = kind
        self.session = session
        self.label = label
        self.acquiredAt = acquiredAt
    }
}

public struct BuildSlotBook: Sendable, Equatable {
    public static let build = "build"
    public static let kinds: Set<String> = [build]
    /// A waiter that hasn't asked again for this long gives up its place (`--wait` asks every 25 s at most).
    public static let waiterTimeout: TimeInterval = 45

    public struct Waiter: Sendable, Equatable {
        public var ticket: String
        public var session: UUID
        public var since: Date
        public var lastSeen: Date
    }

    public enum Acquire: Equatable, Sendable {
        case acquired(BuildSlot)
        /// Every slot is taken (or others wait first): `position` 1 is next.
        case full(position: Int?)
    }

    public private(set) var slots: [BuildSlot] = []
    public private(set) var waiters: [Waiter] = []

    public init() {}

    public static func newID() -> String { "b_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }

    public static func isValidTicket(_ ticket: String) -> Bool {
        (1...64).contains(ticket.count) && ticket.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public func held(by session: UUID) -> [BuildSlot] { slots.filter { $0.session == session } }

    /// One try. With a `ticket` the caller waits in line: it keeps its place between tries and gets
    /// a slot once it's at the front and one is free. Without one it only gets a slot that no
    /// waiter is in line for.
    public mutating func acquire(session: UUID, ticket: String?, label: String?, capacity: Int, now: Date = Date()) -> Acquire {
        dropStaleWaiters(now: now)
        let free = max(0, capacity - slots.count)
        guard let ticket else {
            guard free > waiters.count else { return .full(position: nil) }
            return .acquired(grant(session: session, label: label, now: now))
        }
        let index: Int
        if let found = waiters.firstIndex(where: { $0.ticket == ticket && $0.session == session }) {
            waiters[found].lastSeen = now
            index = found
        } else {
            waiters.append(Waiter(ticket: ticket, session: session, since: now, lastSeen: now))
            index = waiters.count - 1
        }
        guard index < free else { return .full(position: index + 1) }
        waiters.remove(at: index)
        return .acquired(grant(session: session, label: label, now: now))
    }

    /// The caller stops waiting (`heavy` interrupted while in line).
    public mutating func leave(ticket: String, session: UUID) {
        waiters.removeAll { $0.ticket == ticket && $0.session == session }
    }

    /// Releases slot `id` (when `session` holds it) or, without one, every slot `session` holds.
    @discardableResult
    public mutating func release(session: UUID, id: String? = nil) -> [BuildSlot] {
        let released = slots.filter { $0.session == session && (id == nil || $0.id == id) }
        slots.removeAll { slot in released.contains { $0.id == slot.id } }
        return released
    }

    /// Slots of sessions that no longer run and slots held longer than `maxHold` go; so do the
    /// places in line of sessions that no longer run.
    @discardableResult
    public mutating func prune(running: Set<UUID>, maxHold: TimeInterval, now: Date = Date()) -> [BuildSlot] {
        let gone = slots.filter { !running.contains($0.session) || now.timeIntervalSince($0.acquiredAt) >= maxHold }
        slots.removeAll { slot in gone.contains { $0.id == slot.id } }
        waiters.removeAll { !running.contains($0.session) }
        dropStaleWaiters(now: now)
        return gone
    }

    private mutating func dropStaleWaiters(now: Date) {
        waiters.removeAll { now.timeIntervalSince($0.lastSeen) > Self.waiterTimeout }
    }

    private mutating func grant(session: UUID, label: String?, now: Date) -> BuildSlot {
        var slot = BuildSlot(session: session, label: label.map { String($0.prefix(120)) }, acquiredAt: now)
        while slots.contains(where: { $0.id == slot.id }) { slot.id = Self.newID() }
        slots.append(slot)
        return slot
    }
}

/// `POST /v1/cli/slot/build/acquire`: the slot (`acquired`), or `acquired: false` with the place in line.
public struct SessionCLISlot: Encodable, Sendable, Equatable {
    public var acquired: Bool
    public var id: String?
    public var kind: String
    public var position: Int?
    public var used: Int
    public var capacity: Int

    public init(acquired: Bool, id: String?, kind: String, position: Int?, used: Int, capacity: Int) {
        self.acquired = acquired
        self.id = id
        self.kind = kind
        self.position = position
        self.used = used
        self.capacity = capacity
    }
}
