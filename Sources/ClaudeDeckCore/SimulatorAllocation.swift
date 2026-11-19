import Foundation

// `claudedeck sim acquire|release|list`: a session reserves simulators of its own, so two agents
// never drive the same device. The rules are here (which device, which runtime, what a hold is);
// the app runs simctl (AppModel+SessionCLISimulators.swift). Contract: docs/agents.md.
//
// ClaudeDeck only reuses simulators it created itself (named "ClaudeDeck · <type> · <n>"): the
// user's own devices, and ones other tools made, are never booted, shut down or erased here.

/// A device type from `simctl list -j devicetypes`.
public struct SimulatorDeviceType: Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let productFamily: String?

    public init(identifier: String, name: String, productFamily: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.productFamily = productFamily
    }
}

/// A runtime from `simctl list -j runtimes`, with the device types it can run.
public struct SimulatorRuntimeInfo: Hashable, Sendable {
    public let runtime: SimulatorRuntime
    public let isAvailable: Bool
    public let supportedDeviceTypes: Set<String>

    public init(runtime: SimulatorRuntime, isAvailable: Bool, supportedDeviceTypes: Set<String>) {
        self.runtime = runtime
        self.isAvailable = isAvailable
        self.supportedDeviceTypes = supportedDeviceTypes
    }
}

/// One simulator a session holds.
public struct SimulatorHold: Codable, Sendable, Equatable {
    public var udid: String
    public var name: String
    /// The session holding it.
    public var session: UUID
    public var at: Date
    /// ClaudeDeck created this device (it may shut it down on release).
    public var created: Bool

    public init(udid: String, name: String, session: UUID, at: Date = Date(), created: Bool) {
        self.udid = udid.uppercased()
        self.name = name
        self.session = session
        self.at = at
        self.created = created
    }
}

/// Holds and the devices ClaudeDeck created, kept in Application Support (simulator-holds.json)
/// so a hold outlives an app restart while its session does.
public struct SimulatorHoldBook: Codable, Sendable, Equatable {
    public private(set) var holds: [SimulatorHold] = []
    /// UDIDs of the devices ClaudeDeck created (its pool).
    public private(set) var created: Set<String> = []

    public init() {}

    public func holder(of udid: String) -> UUID? { holds.first { $0.udid == udid.uppercased() }?.session }
    public func held(by session: UUID) -> [SimulatorHold] { holds.filter { $0.session == session } }
    public var heldUDIDs: Set<String> { Set(holds.map(\.udid)) }

    public mutating func hold(_ hold: SimulatorHold) {
        holds.removeAll { $0.udid == hold.udid }
        holds.append(hold)
        if hold.created { created.insert(hold.udid) }
    }

    public mutating func noteCreated(_ udid: String) { created.insert(udid.uppercased()) }

    /// Releases `udid` (when `session` holds it) or, without one, everything `session` holds.
    @discardableResult
    public mutating func release(session: UUID, udid: String? = nil) -> [SimulatorHold] {
        let wanted = udid?.uppercased()
        let released = holds.filter { $0.session == session && (wanted == nil || $0.udid == wanted) }
        holds.removeAll { hold in released.contains { $0.udid == hold.udid } }
        return released
    }

    /// Drops holds of sessions that no longer exist, and pool devices that were deleted.
    @discardableResult
    public mutating func prune(sessions: Set<UUID>, devices: Set<String>?) -> [SimulatorHold] {
        let gone = holds.filter { hold in !sessions.contains(hold.session) || (devices.map { !$0.contains(hold.udid) } ?? false) }
        holds.removeAll { hold in gone.contains { $0.udid == hold.udid } }
        if let devices { created = created.intersection(devices) }
        return gone
    }
}

public enum SimulatorAllocation {
    /// The device `acquire` gives without `--device`.
    public static let defaultDevice = "iPhone 17 Pro"
    /// `--duo`'s second device: app-factory QA runs every app on an iPhone and on iPhone Duo.
    public static let duoDevice = "iPhone Duo"
    /// At most this many simulators per session.
    public static let maxPerSession = 4
    /// The name prefix of the devices ClaudeDeck creates.
    public static let namePrefix = "ClaudeDeck · "

    /// The device types `acquire` asks for: `--device` (default iPhone 17 Pro), and with `--duo`
    /// an iPhone Duo next to it (two iPhone Duos when `--device` already is one).
    public static func requested(device: String?, duo: Bool) -> [String] {
        let first = device.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDevice
        return duo ? [first, duoDevice] : [first]
    }

    /// The device type named `name` (any case), or with that identifier.
    public static func deviceType(_ name: String, in types: [SimulatorDeviceType]) -> SimulatorDeviceType? {
        types.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.identifier == name }
    }

    /// The newest available runtime that runs `type` (on the device type's own platform);
    /// ties go to the plain runtime over a device-specific build.
    public static func runtime(for type: SimulatorDeviceType, in runtimes: [SimulatorRuntimeInfo]) -> SimulatorRuntimeInfo? {
        runtimes.filter { $0.isAvailable && $0.supportedDeviceTypes.contains(type.identifier) }.max { a, b in
            if a.runtime.version != b.runtime.version { return a.runtime.version.lexicographicallyPrecedes(b.runtime.version) }
            return (a.runtime.variant == nil ? 1 : 0, a.runtime.identifier) < (b.runtime.variant == nil ? 1 : 0, b.runtime.identifier)
        }
    }

    /// A free device ClaudeDeck created of that type: shut down, available, held by nobody (newest runtime first).
    public static func reusable(_ type: SimulatorDeviceType, devices: [Simulator], book: SimulatorHoldBook, excluding: Set<String> = []) -> Simulator? {
        let held = book.heldUDIDs.union(excluding)
        return devices
            .filter { $0.deviceTypeIdentifier == type.identifier && $0.isAvailable && $0.state == "Shutdown" && !held.contains($0.udid)
                && (book.created.contains($0.udid) || $0.name.hasPrefix(namePrefix)) }
            .sorted(by: SimulatorList.order)
            .first
    }

    /// "ClaudeDeck · iPhone 17 Pro · 3": the first number no device has yet.
    public static func newName(for type: SimulatorDeviceType, existing: [String]) -> String {
        let taken = Set(existing)
        var n = 1
        while taken.contains("\(namePrefix)\(type.name) · \(n)") { n += 1 }
        return "\(namePrefix)\(type.name) · \(n)"
    }

    // MARK: simctl JSON

    public static func parseDeviceTypes(_ data: Data) throws -> [SimulatorDeviceType] {
        struct Output: Decodable {
            struct Item: Decodable { let identifier: String; let name: String; let productFamily: String? }
            let devicetypes: [Item]
        }
        return try JSONDecoder().decode(Output.self, from: data).devicetypes.map {
            SimulatorDeviceType(identifier: $0.identifier, name: $0.name, productFamily: $0.productFamily)
        }
    }

    public static func parseRuntimes(_ data: Data) throws -> [SimulatorRuntimeInfo] {
        struct Output: Decodable {
            struct Item: Decodable {
                struct Kind: Decodable { let identifier: String }
                let identifier: String
                let isAvailable: Bool?
                let supportedDeviceTypes: [Kind]?
            }
            let runtimes: [Item]
        }
        return try JSONDecoder().decode(Output.self, from: data).runtimes.compactMap { item in
            SimulatorRuntime(identifier: item.identifier).map {
                SimulatorRuntimeInfo(runtime: $0, isAvailable: item.isAvailable ?? true,
                                     supportedDeviceTypes: Set((item.supportedDeviceTypes ?? []).map(\.identifier)))
            }
        }
    }

    // MARK: Answers

    public static func listText(_ items: [SessionCLISimulator]) -> String {
        guard !items.isEmpty else { return "no simulators are held" }
        let rows = items.map { [$0.udid, $0.state, $0.holderName ?? "-", $0.created ? "yes" : "no", $0.name] }
        return SessionCLI.table([["UDID", "STATE", "HOLDER", "CREATED", "NAME"]] + rows)
    }
}

/// `claudedeck sim …`: one device.
public struct SessionCLISimulator: Encodable, Sendable, Equatable {
    public var udid: String
    public var name: String
    public var runtime: String?
    public var state: String
    public var holder: UUID?
    public var holderName: String?
    /// The caller holds it.
    public var mine: Bool
    public var created: Bool
    /// `acquire`: a device it created just now (not reused).
    public var new: Bool?

    public init(udid: String, name: String, runtime: String?, state: String, holder: UUID?, holderName: String?,
                mine: Bool, created: Bool, new: Bool? = nil) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.holder = holder
        self.holderName = holderName
        self.mine = mine
        self.created = created
        self.new = new
    }
}
