import Foundation

/// ClaudeDeck pool simulators left booted with nobody holding them (a release that didn't shut
/// them down, a session that ended, a device ClaudeDeck didn't create): shut down once they've
/// been unheld for a while (Settings › Agents, 10 minutes by default; 0 turns it off).
public enum SimulatorIdleShutdown {
    public struct Device: Sendable, Equatable {
        public var udid: String
        public var name: String
        public var held: Bool
        /// A session's process uses it right now (an xcodebuild test without a hold, …).
        public var inUse: Bool

        public init(udid: String, name: String, held: Bool, inUse: Bool) {
            self.udid = udid
            self.name = name
            self.held = held
            self.inUse = inUse
        }
    }

    /// Booted devices in, `unheldSince` updated (first time seen free); returns the ones to shut
    /// down now. Only "ClaudeDeck · …" devices: the owner's own are never touched.
    public static func due(booted: [Device], unheldSince: inout [String: Date], now: Date, minutes: Int) -> [String] {
        let free = booted.filter { $0.name.hasPrefix(SimulatorAllocation.namePrefix) && !$0.held && !$0.inUse }
        let freeIDs = Set(free.map(\.udid))
        unheldSince = unheldSince.filter { freeIDs.contains($0.key) }
        for device in free where unheldSince[device.udid] == nil { unheldSince[device.udid] = now }
        guard minutes > 0 else { return [] }
        return free.filter { now.timeIntervalSince(unheldSince[$0.udid] ?? now) >= Double(minutes) * 60 }.map(\.udid)
    }
}
