import Foundation

// How busy the Mac is, and what ClaudeDeck does about it (Settings › Resources). The app samples
// the system every few seconds off the main thread (SystemLoadSampler in the app target); the
// rules are here so they can be tested: thresholds scaled to the core count, the level with
// hysteresis, the overload "episode" that throttling and the one notification hang on, and the
// throttling decisions for `claudedeck new`, the start queue and `claudedeck sim acquire`.
// Build slots (`claudedeck slot` / `heavy`) are in BuildSlots.swift. Contract: docs/agents.md.

/// ok → busy → overloaded. Comparable in that order.
public enum LoadLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case ok, busy, overloaded

    private var rank: Int {
        switch self {
        case .ok: 0
        case .busy: 1
        case .overloaded: 2
        }
    }

    public static func < (a: LoadLevel, b: LoadLevel) -> Bool { a.rank < b.rank }
}

/// The kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`: 1, 2, 4).
public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical

    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .warning
        default: self = .normal
        }
    }
}

/// One look at the system.
public struct LoadSample: Codable, Sendable, Equatable {
    public var at: Date
    /// The 1- and 5-minute load averages.
    public var load1: Double
    public var load5: Double
    public var cores: Int
    public var pressure: MemoryPressure
    /// Memory in use (active, wired, compressed) out of the physical memory, 0–100.
    public var memoryUsedPercent: Double
    public var swapUsedBytes: UInt64
    /// Booted simulators (one `launchd_sim` each).
    public var simulators: Int
    /// Compiler and linker processes (swift-frontend, clang, ld, xcodebuild…).
    public var compilers: Int
    public var processes: Int
    /// Claude sessions running in ClaudeDeck (filled in by the app).
    public var sessions: Int

    public init(at: Date = Date(), load1: Double, load5: Double = 0, cores: Int, pressure: MemoryPressure = .normal,
                memoryUsedPercent: Double = 0, swapUsedBytes: UInt64 = 0, simulators: Int = 0, compilers: Int = 0,
                processes: Int = 0, sessions: Int = 0) {
        self.at = at
        self.load1 = load1
        self.load5 = load5
        self.cores = max(1, cores)
        self.pressure = pressure
        self.memoryUsedPercent = memoryUsedPercent
        self.swapUsedBytes = swapUsedBytes
        self.simulators = simulators
        self.compilers = compilers
        self.processes = processes
        self.sessions = sessions
    }

    /// The load average per core (1.0: every core busy).
    public var loadPerCore: Double { load1 / Double(max(1, cores)) }
}

/// Settings › Resources. Counts left nil follow the core count (`LoadThresholds.resolve`).
public struct LoadSettings: Codable, Sendable, Equatable {
    /// "Mac yüklüyken ajanları yavaşlat": while overloaded, `claudedeck new`, the start queue and
    /// `claudedeck sim acquire` hold back, and only one build slot is handed out. On by default.
    public var throttle = true
    /// A notification (Mac and phone) when the Mac becomes overloaded, once per episode.
    public var notify = true
    /// Overloaded once the 1-minute load stays above this many times the core count for a minute.
    public var overloadFactor: Double = 2
    /// Busy above this many times the core count.
    public var busyFactor: Double = 1
    /// Overloaded with more compiler processes than this at once (nil: 60% of the cores).
    public var maxCompilers: Int?
    /// "En fazla açık simülatör": `claudedeck sim acquire` is refused at this many booted
    /// simulators (nil: a fifth of the cores, 2–10; 4 on a 20-core Mac).
    public var maxSimulators: Int?
    /// "Aynı anda en fazla derleme": build slots (`claudedeck slot` / `heavy`) (nil: a sixth of
    /// the cores, 1–8; 3 on a 20-core Mac).
    public var buildSlots: Int?
    /// A slot is released by itself after this many minutes (a command that hangs, a session
    /// that forgot `slot release`).
    public var maxSlotHoldMinutes = 60
    /// The sidebar shows the load row even when the Mac is fine (otherwise only when busy or overloaded).
    public var alwaysShowInSidebar = false

    public static let overloadRange: ClosedRange<Double> = 1...10
    public static let busyRange: ClosedRange<Double> = 0.25...10
    public static let compilerRange = 2...400
    public static let simulatorRange = 1...40
    public static let slotRange = 1...32
    public static let holdRange = 5...600

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LoadSettings()
        throttle = (try? c.decodeIfPresent(Bool.self, forKey: .throttle)) ?? d.throttle
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? d.notify
        overloadFactor = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .overloadFactor)) ?? d.overloadFactor, Self.overloadRange)
        busyFactor = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .busyFactor)) ?? d.busyFactor, Self.busyRange)
        maxCompilers = (try? c.decodeIfPresent(Int.self, forKey: .maxCompilers))?.map { Self.clamp($0, Self.compilerRange) }
        maxSimulators = (try? c.decodeIfPresent(Int.self, forKey: .maxSimulators))?.map { Self.clamp($0, Self.simulatorRange) }
        buildSlots = (try? c.decodeIfPresent(Int.self, forKey: .buildSlots))?.map { Self.clamp($0, Self.slotRange) }
        maxSlotHoldMinutes = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .maxSlotHoldMinutes)) ?? d.maxSlotHoldMinutes, Self.holdRange)
        alwaysShowInSidebar = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysShowInSidebar)) ?? d.alwaysShowInSidebar
    }

    static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T { min(max(value, range.lowerBound), range.upperBound) }
}

/// The settings applied to this Mac's core count.
public struct LoadThresholds: Sendable, Equatable {
    public var cores: Int
    /// Load averages (absolute, not per core).
    public var busyLoad: Double
    public var overloadLoad: Double
    /// How long the load must stay above `overloadLoad` to count as overloaded.
    public var overloadSustain: TimeInterval
    public var busyCompilers: Int
    public var overloadCompilers: Int
    public var maxSimulators: Int
    public var buildSlots: Int
    public var maxSlotHold: TimeInterval

    /// Leaving a level needs the numbers this far under its threshold…
    public static let exitMargin = 0.8
    /// …for this long (overloaded → lower, busy → ok).
    public static let overloadCalm: TimeInterval = 60
    public static let busyCalm: TimeInterval = 30

    public static func defaultCompilers(cores: Int) -> Int { max(4, Int((Double(cores) * 0.6).rounded())) }
    public static func defaultSimulators(cores: Int) -> Int { min(10, max(2, cores / 5)) }
    public static func defaultBuildSlots(cores: Int) -> Int { min(8, max(1, cores / 6)) }

    public static func resolve(_ settings: LoadSettings, cores: Int) -> LoadThresholds {
        let cores = max(1, cores)
        let overloadFactor = settings.overloadFactor
        let busyFactor = min(settings.busyFactor, overloadFactor)
        let compilers = settings.maxCompilers ?? defaultCompilers(cores: cores)
        return LoadThresholds(cores: cores, busyLoad: busyFactor * Double(cores), overloadLoad: overloadFactor * Double(cores),
                              overloadSustain: 60, busyCompilers: max(1, compilers / 2), overloadCompilers: compilers,
                              maxSimulators: settings.maxSimulators ?? defaultSimulators(cores: cores),
                              buildSlots: settings.buildSlots ?? defaultBuildSlots(cores: cores),
                              maxSlotHold: TimeInterval(settings.maxSlotHoldMinutes * 60))
    }
}

/// What changed with a sample.
public enum LoadEvent: Equatable, Sendable {
    case level(from: LoadLevel, to: LoadLevel)
    /// The Mac became overloaded: throttling starts, the one notification for this episode goes out.
    case episodeStarted(Int)
    /// Back to ok: throttling ends, the start queue drains again.
    case episodeEnded(Int)
}

/// The level, with hysteresis, and the overload episode.
///
/// - overloaded: memory pressure critical, more compilers than `overloadCompilers`, or the load
///   above `overloadLoad` for `overloadSustain` (a minute). It ends once none of that holds and
///   the load has stayed under `exitMargin` of `overloadLoad` for `overloadCalm`.
/// - busy: the load above `busyLoad`, memory pressure warning, more compilers than
///   `busyCompilers`, or `maxSimulators` booted. It ends once all of that has been clear (load
///   under `exitMargin` of `busyLoad`) for `busyCalm`.
/// - An episode starts when the level becomes overloaded and ends only when it is back to ok, so a
///   Mac swinging between busy and overloaded is one episode (one notification, one note).
public struct LoadMonitor: Sendable, Equatable {
    public private(set) var level: LoadLevel = .ok
    /// In an overload episode (from overloaded until back to ok): throttling applies.
    public private(set) var throttled = false
    public private(set) var episode = 0
    public private(set) var samples: [LoadSample] = []
    /// Kept for the chart: 30 minutes at one sample every 12 seconds.
    public static let keep = 150

    private var highLoadSince: Date?
    private var calmSince: Date?

    public init() {}

    public var latest: LoadSample? { samples.last }

    @discardableResult
    public mutating func add(_ sample: LoadSample, thresholds t: LoadThresholds) -> [LoadEvent] {
        samples.append(sample)
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }

        if sample.load1 > t.overloadLoad {
            if highLoadSince == nil { highLoadSince = sample.at }
        } else {
            highLoadSince = nil
        }
        let sustained = highLoadSince.map { sample.at.timeIntervalSince($0) >= t.overloadSustain } ?? false
        let overloadedNow = sample.pressure == .critical || sample.compilers > t.overloadCompilers || sustained
        let busyNow = sample.load1 > t.busyLoad || sample.pressure != .normal || sample.compilers > t.busyCompilers
            || sample.simulators >= t.maxSimulators
        let overloadClear = !overloadedNow && sample.load1 < t.overloadLoad * LoadThresholds.exitMargin
            && sample.pressure != .critical && sample.compilers <= t.overloadCompilers
        let busyClear = !busyNow && sample.load1 < t.busyLoad * LoadThresholds.exitMargin

        let previous = level
        var next = level
        switch level {
        case .ok:
            next = overloadedNow ? .overloaded : busyNow ? .busy : .ok
            calmSince = nil
        case .busy:
            if overloadedNow {
                next = .overloaded
                calmSince = nil
            } else if busyClear {
                if calmSince == nil { calmSince = sample.at }
                if sample.at.timeIntervalSince(calmSince!) >= LoadThresholds.busyCalm { next = .ok }
            } else {
                calmSince = nil
            }
        case .overloaded:
            if overloadClear {
                if calmSince == nil { calmSince = sample.at }
                if sample.at.timeIntervalSince(calmSince!) >= LoadThresholds.overloadCalm {
                    // Straight to ok only when busy is clear as well.
                    next = busyClear ? .ok : .busy
                }
            } else {
                calmSince = nil
            }
        }
        if next != previous { calmSince = nil }
        level = next

        var events: [LoadEvent] = []
        if next != previous { events.append(.level(from: previous, to: next)) }
        if next == .overloaded, !throttled {
            throttled = true
            episode += 1
            events.append(.episodeStarted(episode))
        } else if next == .ok, throttled {
            throttled = false
            events.append(.episodeEnded(episode))
        }
        return events
    }
}

/// What makes the Mac busy, for the notification ("11 simülatör açık, 30 derleme, 37 oturum").
public enum LoadContributor: Equatable, Sendable {
    case simulators(Int)
    case compilers(Int)
    case sessions(Int)
    case memory(MemoryPressure)
    case load(Double, cores: Int)

    /// The worst first: what stands out against its threshold, then the sessions, then the load.
    public static func of(_ sample: LoadSample, thresholds t: LoadThresholds) -> [LoadContributor] {
        var list: [LoadContributor] = []
        if sample.simulators > 0, sample.simulators >= max(2, t.maxSimulators / 2) { list.append(.simulators(sample.simulators)) }
        if sample.compilers > t.busyCompilers { list.append(.compilers(sample.compilers)) }
        if sample.sessions > 0 { list.append(.sessions(sample.sessions)) }
        if sample.pressure != .normal { list.append(.memory(sample.pressure)) }
        list.append(.load(sample.load1, cores: sample.cores))
        return list
    }

    /// English, for `claudedeck load` and the log.
    public var text: String {
        switch self {
        case .simulators(let n): "\(n) simulators booted"
        case .compilers(let n): "\(n) compiler processes"
        case .sessions(let n): "\(n) Claude sessions"
        case .memory(let pressure): "memory pressure \(pressure.rawValue)"
        case .load(let load, let cores): String(format: "load %.0f on %d cores", load, cores)
        }
    }
}

/// Throttling (Settings › Resources › "Mac yüklüyken ajanları yavaşlat").
public enum LoadThrottle {
    public enum Start: Equatable, Sendable {
        case allow
        /// `429 overloaded`.
        case refuse
        /// `new --queue`: queued, started once the Mac is back to ok.
        case queue
    }

    /// `claudedeck new`: held back during an overload episode while the setting is on.
    public static func start(throttled: Bool, enabled: Bool, queue: Bool) -> Start {
        guard enabled, throttled else { return .allow }
        return queue ? .queue : .refuse
    }

    /// The start queue drains only outside an episode (it resumes once the Mac is back to ok).
    public static func drains(throttled: Bool, enabled: Bool) -> Bool { !(enabled && throttled) }

    public enum Simulator: Equatable, Sendable {
        case allow
        /// `429 overloaded`.
        case overloaded
        /// `429 too_many_booted`: `maxSimulators` would be exceeded.
        case tooManyBooted
    }

    /// `claudedeck sim acquire` for `wanted` devices with `booted` simulators running. The cap on
    /// booted simulators applies whenever the setting is on, the episode check too.
    public static func simulator(throttled: Bool, enabled: Bool, booted: Int, wanted: Int, max: Int) -> Simulator {
        guard enabled else { return .allow }
        if throttled { return .overloaded }
        return booted + wanted > max ? .tooManyBooted : .allow
    }

    /// Build slots handed out right now: one during an episode while the setting is on.
    public static func slotCapacity(_ slots: Int, throttled: Bool, enabled: Bool) -> Int {
        enabled && throttled ? 1 : max(1, slots)
    }
}

/// Counting processes by name (`proc_name`, at most 16 characters).
public enum LoadProcesses {
    /// One per booted simulator.
    public static let simulatorNames: Set<String> = ["launchd_sim"]
    /// Compilers, linkers and the build drivers that run them.
    public static let compilerNames: Set<String> = ["swift-frontend", "swiftc", "clang", "clang++", "cc1", "cc1plus", "ld", "ld64",
                                                    "ld-prime", "xcodebuild", "swift-build", "ibtool", "actool", "kotlin-daemon"]

    public static func count(_ names: [String]) -> (simulators: Int, compilers: Int) {
        var simulators = 0, compilers = 0
        for name in names {
            if simulatorNames.contains(name) { simulators += 1 } else if compilerNames.contains(name) { compilers += 1 }
        }
        return (simulators, compilers)
    }
}

/// `GET /v1/cli/load` (`claudedeck load`).
public struct SessionCLILoad: Encodable, Sendable, Equatable {
    public struct Slot: Encodable, Sendable, Equatable {
        public var id: String
        public var session: UUID
        public var sessionName: String?
        public var label: String?
        public var since: Date
        public init(id: String, session: UUID, sessionName: String?, label: String?, since: Date) {
            self.id = id
            self.session = session
            self.sessionName = sessionName
            self.label = label
            self.since = since
        }
    }

    public var level: String
    /// In an overload episode: `new` and `sim acquire` are held back (when `throttle` is on).
    public var throttled: Bool
    public var throttle: Bool
    public var load1: Double
    public var load5: Double
    public var cores: Int
    public var loadPerCore: Double
    public var memoryPressure: String
    public var memoryUsedPercent: Double
    public var swapUsedMB: Int
    public var simulators: Int
    public var maxSimulators: Int
    public var compilers: Int
    public var maxCompilers: Int
    public var processes: Int
    public var sessions: Int
    public var buildSlots: Int
    public var slotsAvailable: Int
    public var slotsWaiting: Int
    public var slots: [Slot]
    public var sampledAt: Date?
    public var contributors: [String]

    public init(level: LoadLevel, throttled: Bool, throttle: Bool, sample: LoadSample?, thresholds: LoadThresholds,
                capacity: Int, slots: [Slot], waiting: Int) {
        self.level = level.rawValue
        self.throttled = throttled
        self.throttle = throttle
        load1 = ((sample?.load1 ?? 0) * 100).rounded() / 100
        load5 = ((sample?.load5 ?? 0) * 100).rounded() / 100
        cores = sample?.cores ?? thresholds.cores
        loadPerCore = ((sample?.loadPerCore ?? 0) * 100).rounded() / 100
        memoryPressure = (sample?.pressure ?? .normal).rawValue
        memoryUsedPercent = ((sample?.memoryUsedPercent ?? 0) * 10).rounded() / 10
        swapUsedMB = Int((sample?.swapUsedBytes ?? 0) / 1_048_576)
        simulators = sample?.simulators ?? 0
        maxSimulators = thresholds.maxSimulators
        compilers = sample?.compilers ?? 0
        maxCompilers = thresholds.overloadCompilers
        processes = sample?.processes ?? 0
        sessions = sample?.sessions ?? 0
        buildSlots = capacity
        slotsAvailable = max(0, capacity - slots.count)
        slotsWaiting = waiting
        self.slots = slots
        sampledAt = sample?.at
        contributors = sample.map { LoadContributor.of($0, thresholds: thresholds).map(\.text) } ?? []
    }

    public var text: String {
        var lines: [String] = []
        let note = throttled && throttle ? " (new sessions, simulators and builds are held back)" : ""
        lines.append("level: \(level)\(note)")
        guard sampledAt != nil else {
            lines.append("no sample yet")
            return lines.joined(separator: "\n")
        }
        lines.append(String(format: "load: %.1f on %d cores (%.2f per core), 5 min %.1f", load1, cores, loadPerCore, load5))
        lines.append(String(format: "memory: %.0f%% used, pressure %@, swap %d MB", memoryUsedPercent, memoryPressure, swapUsedMB))
        lines.append("simulators: \(simulators) booted (sim acquire allows \(maxSimulators))")
        lines.append("compilers: \(compilers) (overloaded above \(maxCompilers))")
        lines.append("sessions: \(sessions) Claude sessions, \(processes) processes")
        lines.append("build slots: \(slots.count)/\(buildSlots) used" + (slotsWaiting > 0 ? ", \(slotsWaiting) waiting" : ""))
        for slot in slots {
            let minutes = Int(Date().timeIntervalSince(slot.since) / 60)
            lines.append("  \(slot.id)  \(slot.sessionName ?? String(slot.session.uuidString.prefix(8)))  \(minutes)m" + (slot.label.map { "  \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}
