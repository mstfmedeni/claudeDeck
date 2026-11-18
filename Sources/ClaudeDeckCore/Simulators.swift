import Darwin
import Foundation

// MARK: - Devices (`xcrun simctl list -j devices`)

/// Simulator platforms the Simulators tab lists (tvOS is left out on purpose).
public enum SimulatorPlatform: String, Sendable, CaseIterable, Comparable {
    case iOS, watchOS, visionOS

    /// The prefix CoreSimulator uses in runtime identifiers (visionOS is still "xrOS" there).
    var runtimePrefix: String {
        switch self {
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        case .visionOS: "xrOS"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A simulator runtime, parsed from its identifier
/// (`com.apple.CoreSimulator.SimRuntime.iOS-27-2`, `…iOS-27-2-iPhone19-4`, `…xrOS-2-0`).
public struct SimulatorRuntime: Hashable, Sendable {
    public let identifier: String
    public let platform: SimulatorPlatform
    /// Numeric version parts, e.g. [27, 2].
    public let version: [Int]
    /// Anything after the version (a device-specific runtime build such as "iPhone19-4").
    public let variant: String?

    public init?(identifier: String) {
        let key = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = key.split(separator: "-").map(String.init)
        guard let first = parts.first,
              let platform = SimulatorPlatform.allCases.first(where: { $0.runtimePrefix == first }) else { return nil }
        let version = parts.dropFirst().prefix { Int($0) != nil }.compactMap { Int($0) }
        guard !version.isEmpty else { return nil }
        let rest = parts.dropFirst(1 + version.count)
        self.identifier = identifier
        self.platform = platform
        self.version = version
        self.variant = rest.isEmpty ? nil : rest.joined(separator: "-")
    }

    public var versionString: String { version.map(String.init).joined(separator: ".") }
    /// "iOS 27.2", "visionOS 2.0", "iOS 27.2 (iPhone19-4)".
    public var displayName: String {
        let base = "\(platform.rawValue) \(versionString)"
        return variant.map { "\(base) (\($0))" } ?? base
    }

    /// Whether `os` (an xcodebuild destination's `OS=` value, e.g. "18.1" or "18") names this version.
    func matches(os: String) -> Bool {
        let wanted = os.split(separator: ".").compactMap { Int($0) }
        guard !wanted.isEmpty else { return true }
        return Array(version.prefix(wanted.count)) == wanted
            || (wanted.count > version.count && Array(wanted.prefix(version.count)) == version && wanted.dropFirst(version.count).allSatisfy { $0 == 0 })
    }
}

public struct Simulator: Identifiable, Hashable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool
    public let deviceTypeIdentifier: String?
    public let runtime: SimulatorRuntime

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
    public var platform: SimulatorPlatform { runtime.platform }

    public init(udid: String, name: String, state: String, isAvailable: Bool = true,
                deviceTypeIdentifier: String? = nil, runtime: SimulatorRuntime) {
        self.udid = udid.uppercased()
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtime = runtime
    }
}

public enum SimulatorList {
    private struct Output: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let deviceTypeIdentifier: String?
    }

    /// The iOS, watchOS and visionOS simulators in `simctl list -j devices` output that can be used
    /// (available, or booted anyway): booted first, then by platform, newest runtime, name.
    public static func parse(_ data: Data) throws -> [Simulator] {
        let output = try JSONDecoder().decode(Output.self, from: data)
        var result: [Simulator] = []
        for (key, devices) in output.devices {
            guard let runtime = SimulatorRuntime(identifier: key) else { continue }
            for device in devices {
                let simulator = Simulator(udid: device.udid, name: device.name, state: device.state,
                                          isAvailable: device.isAvailable ?? true,
                                          deviceTypeIdentifier: device.deviceTypeIdentifier, runtime: runtime)
                if simulator.isAvailable || simulator.isBooted { result.append(simulator) }
            }
        }
        return result.sorted(by: order)
    }

    static func order(_ a: Simulator, _ b: Simulator) -> Bool {
        if a.isBooted != b.isBooted { return a.isBooted }
        if a.platform != b.platform { return a.platform < b.platform }
        if a.runtime.version != b.runtime.version { return b.runtime.version.lexicographicallyPrecedes(a.runtime.version) }
        if a.runtime.identifier != b.runtime.identifier { return a.runtime.identifier < b.runtime.identifier }
        if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return a.udid < b.udid
    }
}

// MARK: - Processes

/// One sysctl snapshot of the process table: pid, parent, short name, start time.
public struct ProcessTable: Sendable {
    public struct Entry: Hashable, Sendable {
        public let pid: pid_t
        public let ppid: pid_t
        /// `p_comm`: at most 16 characters.
        public let name: String
        /// Start time in microseconds; with the pid it identifies a process across snapshots.
        public let started: Int64

        public init(pid: pid_t, ppid: pid_t, name: String, started: Int64 = 0) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.started = started
        }
    }

    public let entries: [Entry]
    private let children: [pid_t: [pid_t]]
    private let byPID: [pid_t: Entry]

    public init(_ entries: [Entry]) {
        self.entries = entries
        var children: [pid_t: [pid_t]] = [:]
        var byPID: [pid_t: Entry] = [:]
        for entry in entries {
            byPID[entry.pid] = entry
            // launchd (pid 1) and the kernel (0) would make everything a descendant of themselves.
            if entry.pid != entry.ppid { children[entry.ppid, default: []].append(entry.pid) }
        }
        self.children = children
        self.byPID = byPID
    }

    public func entry(_ pid: pid_t) -> Entry? { byPID[pid] }

    /// Every process below `root` (children, grandchildren, …), not `root` itself.
    public func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var stack = children[root] ?? []
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            stack += children[pid] ?? []
        }
        return result
    }

    /// The live process table (one `sysctl(KERN_PROC_ALL)`).
    public static func current() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return ProcessTable([]) }
        size += size / 8 // room for processes started between the two calls
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return ProcessTable([]) }
        let entries = procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let start = proc.kp_proc.p_starttime
            return Entry(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, name: name,
                         started: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
        }
        return ProcessTable(entries)
    }
}

/// A process's argument vector and environment.
public struct ProcessArguments: Equatable, Sendable {
    public var argv: [String]
    public var env: [String]

    public init(argv: [String], env: [String] = []) {
        self.argv = argv
        self.env = env
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (int32), the executable path, NUL padding, argc
    /// NUL-terminated arguments, then the environment up to an empty string.
    public static func parse(procargs2 bytes: [UInt8]) -> ProcessArguments? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        var index = 4
        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }
        _ = nextString() // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let arg = nextString() else { break }
            argv.append(arg)
        }
        var env: [String] = []
        while let entry = nextString(), !entry.isEmpty { env.append(entry) }
        return ProcessArguments(argv: argv, env: env)
    }

    /// The live arguments of `pid` (same user only), or nil.
    public static func of(_ pid: pid_t) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(procargs2: Array(buffer.prefix(size)))
    }
}

// MARK: - Memory

/// What a booted simulator's processes use: the sum of `phys_footprint` (what Activity Monitor
/// calls Memory; includes compressed pages) over its `launchd_sim` and everything below it — the
/// same measure as simslim's `measure`.
public struct SimulatorMemory: Equatable, Sendable {
    public var bytes: UInt64 = 0
    /// Processes counted.
    public var processes = 0
    /// Processes whose footprint couldn't be read (exited meanwhile, or not ours).
    public var unreadable = 0

    public init(bytes: UInt64 = 0, processes: Int = 0, unreadable: Int = 0) {
        self.bytes = bytes
        self.processes = processes
        self.unreadable = unreadable
    }

    /// Sums `footprint` over `root` and its descendants in `table`.
    public static func measure(root: pid_t, in table: ProcessTable, footprint: (pid_t) -> UInt64?) -> SimulatorMemory {
        var memory = SimulatorMemory()
        for pid in [root] + table.descendants(of: root) {
            if let bytes = footprint(pid) {
                memory.bytes += bytes
                memory.processes += 1
            } else {
                memory.unreadable += 1
            }
        }
        return memory
    }

    /// `phys_footprint` of one process through `proc_pid_rusage` (no task port needed).
    public static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }
}

/// Booted simulators found in the process table: each runs a `launchd_sim` whose argument is
/// `…/CoreSimulator/Devices/<UDID>/data/var/run/launchd_bootstrap.plist`.
public enum SimulatorProcesses {
    public static let launchdName = "launchd_sim"

    /// The device UDID in a `launchd_sim`'s arguments.
    public static func udid(ofLaunchdSim arguments: [String]) -> String? {
        for argument in arguments {
            let parts = argument.split(separator: "/")
            if let index = parts.firstIndex(of: "Devices"), index + 1 < parts.count,
               let uuid = UUID(uuidString: String(parts[index + 1])) {
                return uuid.uuidString
            }
        }
        return nil
    }

    /// UDID → pid of its `launchd_sim`.
    public static func launchdSims(in table: ProcessTable, arguments: (pid_t) -> ProcessArguments?) -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        for entry in table.entries where entry.name == launchdName {
            if let args = arguments(entry.pid), let udid = udid(ofLaunchdSim: args.argv) { result[udid] = entry.pid }
        }
        return result
    }
}

// MARK: - Which session uses which simulator

/// Infers the simulators a process works with from its arguments and environment. Only known
/// device UDIDs count (ClaudeDeck's own session ids are UUIDs too); an xcodebuild destination by
/// name, or simctl's `booted`, counts only when it points at exactly one device.
public enum SimulatorUsageInference {
    public static func udids(in arguments: ProcessArguments, devices: [Simulator]) -> Set<String> {
        let known = Set(devices.map(\.udid))
        var found: Set<String> = []
        for string in arguments.argv + arguments.env {
            for uuid in uuids(in: string) where known.contains(uuid) { found.insert(uuid) }
        }
        found.formUnion(destinationMatches(arguments.argv, devices: devices))
        if found.isEmpty, isSimctl(arguments.argv), arguments.argv.contains("booted") {
            let booted = devices.filter(\.isBooted)
            if booted.count == 1 { found.insert(booted[0].udid) }
        }
        return found
    }

    /// Upper-cased UUIDs anywhere in `string`.
    static func uuids(in string: String) -> [String] {
        let bytes = Array(string.utf8)
        guard bytes.count >= 36 else { return [] }
        var result: [String] = []
        var i = 0
        while i + 36 <= bytes.count {
            if isUUID(bytes, at: i) {
                result.append(String(decoding: bytes[i..<i + 36], as: UTF8.self).uppercased())
                i += 36
            } else {
                i += 1
            }
        }
        return result
    }

    private static func isUUID(_ bytes: [UInt8], at start: Int) -> Bool {
        for offset in 0..<36 {
            let byte = bytes[start + offset]
            if [8, 13, 18, 23].contains(offset) {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                let hex = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
                guard hex else { return false }
            }
        }
        // Not part of a longer hex run.
        if start > 0, isHexOrDash(bytes[start - 1]) { return false }
        if start + 36 < bytes.count, isHexOrDash(bytes[start + 36]) { return false }
        return true
    }

    private static func isHexOrDash(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102) || byte == UInt8(ascii: "-")
    }

    private static func isSimctl(_ argv: [String]) -> Bool {
        argv.prefix(3).contains { ($0 as NSString).lastPathComponent == "simctl" }
    }

    /// xcodebuild's `-destination 'platform=iOS Simulator,name=iPhone 16,OS=18.1'` without an id.
    static func destinationMatches(_ argv: [String], devices: [Simulator]) -> Set<String> {
        var specs: [String] = []
        for (index, arg) in argv.enumerated() {
            if arg == "-destination" || arg == "--destination", index + 1 < argv.count {
                specs.append(argv[index + 1])
            } else if arg.hasPrefix("-destination=") || arg.hasPrefix("--destination=") {
                specs.append(String(arg.drop { $0 != "=" }.dropFirst()))
            }
        }
        var found: Set<String> = []
        for spec in specs {
            var fields: [String: String] = [:]
            for pair in spec.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { fields[kv[0].lowercased()] = kv[1] }
            }
            guard fields["id"] == nil, let name = fields["name"] else { continue }
            let platform = fields["platform"].flatMap { value in
                SimulatorPlatform.allCases.first { value.localizedCaseInsensitiveContains($0.rawValue) }
            }
            let os = fields["os"].flatMap { $0.lowercased() == "latest" ? nil : $0 }
            let candidates = devices.filter { device in
                device.name == name && (platform == nil || device.platform == platform)
                    && (os == nil || device.runtime.matches(os: os!))
            }
            let booted = candidates.filter(\.isBooted)
            if booted.count == 1 {
                found.insert(booted[0].udid)
            } else if booted.isEmpty, candidates.count == 1 {
                found.insert(candidates[0].udid)
            }
        }
        return found
    }
}

/// Links simulators to the sessions whose process trees use them.
public enum SimulatorUsage {
    /// One process of a session that references a simulator.
    public struct Use: Hashable, Sendable {
        public let session: UUID
        public let pid: pid_t
        /// The process's short name (xcodebuild, simctl, axe, node, …).
        public let process: String

        public init(session: UUID, pid: pid_t, process: String) {
            self.session = session
            self.pid = pid
            self.process = process
        }
    }

    /// UDID → the uses found under `roots` (session id → its terminal's top process).
    public static func link(roots: [UUID: pid_t], table: ProcessTable, devices: [Simulator],
                            arguments: (pid_t) -> ProcessArguments?) -> [String: [Use]] {
        var result: [String: [Use]] = [:]
        for (session, root) in roots.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where root > 0 {
            for pid in table.descendants(of: root) {
                guard let args = arguments(pid) else { continue }
                let name = table.entry(pid)?.name ?? ""
                for udid in SimulatorUsageInference.udids(in: args, devices: devices) {
                    result[udid, default: []].append(Use(session: session, pid: pid, process: name))
                }
            }
        }
        return result
    }
}
