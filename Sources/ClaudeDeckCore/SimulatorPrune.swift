import Foundation

// `claudedeck sim prune` and the automatic prune (at launch, then daily): ClaudeDeck deletes the
// pool simulators it created that nobody uses any more. The rules are here; the app runs
// `simctl delete` (AppModel+SessionCLISimulators.swift). Contract: docs/agents.md.
//
// Never deleted: a booted device, a held one, or anything outside the pool (the user's own
// simulators, other tools' and sessions' "<Project> · <purpose>" devices).

public enum SimulatorPrune {
    /// Pool devices kept per device type beyond the booted-simulator cap.
    public static let spare = 2
    /// Default for Settings › Agents "Delete unused pool simulators after N days".
    public static let defaultDays = 3
    public static let dayRange = 0...60

    public enum Reason: String, Codable, Sendable {
        /// Unused for longer than the age limit.
        case unused
        /// More pool devices of its type than cap + spare.
        case overCap = "over_cap"
    }

    public struct Candidate: Equatable, Sendable {
        public let device: Simulator
        public let reason: Reason
        /// When it was last used (released or booted), if known.
        public let lastUsed: Date?
    }

    /// ClaudeDeck's pool: devices it created (by UDID, from its records) or that carry its name prefix.
    public static func isPool(_ device: Simulator, book: SimulatorHoldBook) -> Bool {
        book.created.contains(device.udid) || device.name.hasPrefix(SimulatorAllocation.namePrefix)
    }

    /// When `device` was last used: the later of ClaudeDeck's release time and simctl's last boot.
    public static func lastUsed(_ device: Simulator, book: SimulatorHoldBook) -> Date? {
        [book.lastUsed[device.udid], device.lastUsedAt].compactMap { $0 }.max()
    }

    /// The pool devices to delete, oldest first. Only shut-down, unheld pool devices with a known
    /// last use are candidates; booted and held ones still count toward their type's total.
    /// - `olderThan`: delete candidates unused for at least this long (nil: no age rule).
    /// - `maxPerType`: keep at most this many pool devices of one type (nil: no bound); the
    ///   least recently used candidates go first.
    public static func select(devices: [Simulator], book: SimulatorHoldBook, now: Date,
                              olderThan: TimeInterval?, maxPerType: Int?) -> [Candidate] {
        let held = book.heldUDIDs
        let pool = devices.filter { isPool($0, book: book) }
        var chosen: [String: Candidate] = [:]
        var groups: [String: [Simulator]] = [:]
        for device in pool { groups[typeKey(device), default: []].append(device) }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let candidates = group
                .filter { $0.state == "Shutdown" && !held.contains($0.udid) && lastUsed($0, book: book) != nil }
                .sorted { (lastUsed($0, book: book)!, $0.udid) < (lastUsed($1, book: book)!, $1.udid) }
            var remaining = group.count
            if let maxPerType {
                for device in candidates where remaining > max(0, maxPerType) {
                    chosen[device.udid] = Candidate(device: device, reason: .overCap, lastUsed: lastUsed(device, book: book))
                    remaining -= 1
                }
            }
            if let olderThan {
                for device in candidates where chosen[device.udid] == nil {
                    guard let used = lastUsed(device, book: book), now.timeIntervalSince(used) >= olderThan else { continue }
                    chosen[device.udid] = Candidate(device: device, reason: .unused, lastUsed: used)
                }
            }
        }
        return chosen.values.sorted { a, b in
            (a.lastUsed ?? .distantPast, a.device.udid) < (b.lastUsed ?? .distantPast, b.device.udid)
        }
    }

    /// Pool devices with no known last use (never booted, and no release on record): the app
    /// stamps them "first seen now", so they age like the others.
    public static func undated(devices: [Simulator], book: SimulatorHoldBook) -> [String] {
        devices.filter { isPool($0, book: book) && lastUsed($0, book: book) == nil }.map(\.udid)
    }

    /// Groups by device type; a device without one by its name without the trailing " · n".
    static func typeKey(_ device: Simulator) -> String {
        if let type = device.deviceTypeIdentifier { return type }
        if let range = device.name.range(of: " · ", options: .backwards),
           device.name[range.upperBound...].allSatisfy(\.isNumber) {
            return String(device.name[..<range.lowerBound])
        }
        return device.name
    }

    /// `--older-than`: "3d", "12h", "90m" or plain days ("3"). Must be positive.
    public static func parseAge(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = trimmed.last else { return nil }
        let unit: TimeInterval
        var number = Substring(trimmed)
        switch last {
        case "d": unit = 86_400; number = number.dropLast()
        case "h": unit = 3_600; number = number.dropLast()
        case "m": unit = 60; number = number.dropLast()
        default: unit = 86_400
        }
        guard let value = Double(number), value > 0, value.isFinite else { return nil }
        return value * unit
    }

    // MARK: Session-created simulators

    /// The project of a simulator a session created and named "<Project> · <purpose>"
    /// (owner directive), when `projects` has that name; ClaudeDeck's pool names never match.
    public static func sessionProject(_ name: String, projects: [String]) -> String? {
        guard !name.hasPrefix(SimulatorAllocation.namePrefix),
              let range = name.range(of: " · ") else { return nil }
        let head = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return projects.first { $0.caseInsensitiveCompare(head) == .orderedSame }
    }

    // MARK: Answers

    public struct Item: Encodable, Sendable, Equatable {
        public var udid: String
        public var name: String
        public var runtime: String
        public var reason: Reason
        public var lastUsed: Date?
        public var dataBytes: UInt64?
        /// Deleted (false: a dry run, or `simctl delete` failed; see `error`).
        public var deleted: Bool
        public var error: String?

        public init(_ candidate: Candidate, deleted: Bool, error: String? = nil) {
            udid = candidate.device.udid
            name = candidate.device.name
            runtime = candidate.device.runtime.displayName
            reason = candidate.reason
            lastUsed = candidate.lastUsed
            dataBytes = candidate.device.dataSize
            self.deleted = deleted
            self.error = error
        }
    }

    public struct Answer: Encodable, Sendable, Equatable {
        public var dryRun: Bool
        public var olderThanSeconds: Double?
        public var maxPerType: Int
        public var items: [Item]

        public init(dryRun: Bool, olderThanSeconds: Double?, maxPerType: Int, items: [Item]) {
            self.dryRun = dryRun
            self.olderThanSeconds = olderThanSeconds
            self.maxPerType = maxPerType
            self.items = items
        }
    }

    public static func text(_ answer: Answer, now: Date = Date()) -> String {
        guard !answer.items.isEmpty else { return answer.dryRun ? "nothing would be deleted" : "nothing to delete" }
        let rows = answer.items.map { item -> [String] in
            let age = item.lastUsed.map { String(format: "%.1fd", now.timeIntervalSince($0) / 86_400) } ?? "-"
            let action = answer.dryRun ? "would delete" : (item.deleted ? "deleted" : "failed: " + (item.error ?? "?").prefix(60))
            return [action, item.udid, item.reason.rawValue, age, item.runtime, item.name]
        }
        return SessionCLI.table([["ACTION", "UDID", "REASON", "UNUSED", "RUNTIME", "NAME"]] + rows)
    }
}
