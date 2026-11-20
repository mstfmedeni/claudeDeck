import Foundation

// How busy the Mac is, and what ClaudeDeck does about it (Settings › Resources). The app samples
// the system every few seconds off the main thread (SystemLoadSampler in the app target); the
// rules are here so they can be tested: the overload triggers (each with its own switch and
// value), the level with hysteresis, the overload "episode" the one notification and the one
// message to the agents hang on, and the throttling decisions for `claudedeck new`, the start
// queue, `claudedeck sim acquire` and the build slots.
//
// The rule is "only prevent freezes": `overloaded` means a real risk of the Mac locking up
// (critical memory pressure, swap growing fast under pressure, too many compilers, an extreme
// load or process count). A merely high load average is `busy`, which is informational and holds
// nothing back unless the owner picks "hold new starts" for it.
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
public enum MemoryPressure: String, Codable, Sendable, CaseIterable, Comparable {
    case normal, warning, critical

    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .warning
        default: self = .normal
        }
    }

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rank < b.rank }
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

/// What can make the Mac `overloaded`. Each has its own switch and value in Settings › Resources.
public enum LoadTrigger: String, Codable, Sendable, CaseIterable {
    /// macOS memory pressure at or above a level (critical by default).
    case pressure
    /// Swap growing by more than N GB within M minutes while memory pressure is warning or worse.
    case swapGrowth = "swap_growth"
    /// Swap in use above N GB (off by default: a big swap on its own is no freeze).
    case swapSize = "swap_size"
    /// More compiler and linker processes than N at once.
    case compilers
    /// The 1-minute load above N × the cores for M minutes.
    case load
    /// More than N processes.
    case processes
}

/// What `busy` does (Settings › Resources › "Meşgulken").
public enum LoadBusyAction: String, Codable, Sendable, CaseIterable {
    /// Nothing: busy is only shown.
    case nothing
    /// New starts (`claudedeck new` and the start queue) wait as they do while overloaded.
    case holdStarts = "hold_starts"
}

/// Settings › Resources. Counts left nil follow the core count (`LoadThresholds.resolve`).
public struct LoadSettings: Codable, Sendable, Equatable {
    /// The defaults' generation. Files without it (2), or older, were written with the first
    /// defaults (overloaded at 2 × cores, busy at 1 × cores); a value still equal to those old
    /// defaults is moved to the new one when read, anything else the owner set is kept.
    public static let currentVersion = 2
    public var version = LoadSettings.currentVersion

    /// "Mac yüklüyken ajanları yavaşlat": while overloaded, `claudedeck new`, the start queue and
    /// `claudedeck sim acquire` hold back, and fewer build slots are handed out. On by default.
    public var throttle = true
    /// A notification (Mac and phone) when the Mac becomes overloaded, once per episode.
    public var notify = true

    // Overload triggers.
    public var pressureEnabled = true
    /// Overloaded at this memory pressure or worse (warning or critical).
    public var pressureLevel: MemoryPressure = .critical
    public var swapGrowthEnabled = true
    /// Overloaded when swap grows by more than this many GB within `swapGrowthMinutes` while memory
    /// pressure is warning or worse.
    public var swapGrowthGB: Double = 2
    public var swapGrowthMinutes = 5
    public var swapSizeEnabled = false
    /// Overloaded with more than this many GB of swap in use.
    public var swapSizeGB: Double = 64
    public var compilersEnabled = true
    /// Overloaded with more compiler processes than this at once (nil: 60% of the cores).
    public var maxCompilers: Int?
    public var loadEnabled = true
    /// Overloaded once the 1-minute load stays above this many times the core count for
    /// `overloadMinutes`. The default is a freeze-level load (200 on a 20-core Mac).
    public var overloadFactor: Double = 10
    public var overloadMinutes: Double = 3
    public var processesEnabled = true
    /// Overloaded with more processes than this.
    public var maxProcesses = 3000

    /// Busy (informational) above this many times the core count for a minute.
    public var busyFactor: Double = 2
    /// What busy does: nothing (default) or hold new starts.
    public var busyAction: LoadBusyAction = .nothing

    // Limits.
    /// "En fazla açık simülatör": `claudedeck sim acquire` is refused at this many booted
    /// simulators (nil: a fifth of the cores, 2–10; 4 on a 20-core Mac).
    public var maxSimulators: Int?
    /// "Aynı anda en fazla derleme": build slots (`claudedeck slot` / `heavy`) (nil: a sixth of
    /// the cores, 1–8; 3 on a 20-core Mac).
    public var buildSlots: Int?
    /// Build slots handed out while overloaded (and throttling is on).
    public var overloadedBuildSlots = 1
    /// A slot is released by itself after this many minutes (a command that hangs, a session
    /// that forgot `slot release`).
    public var maxSlotHoldMinutes = 60
    /// The sidebar shows the load row even when the Mac is fine (otherwise only when busy or overloaded).
    public var alwaysShowInSidebar = false

    public static let overloadRange: ClosedRange<Double> = 1...30
    public static let busyRange: ClosedRange<Double> = 0.25...30
    public static let overloadMinutesRange: ClosedRange<Double> = 0.5...30
    public static let compilerRange = 2...400
    public static let processRange = 200...50_000
    public static let swapGBRange: ClosedRange<Double> = 0.5...512
    public static let swapMinutesRange = 1...60
    public static let simulatorRange = 1...40
    public static let slotRange = 1...32
    public static let holdRange = 5...600

    /// The first defaults (version 1), for the migration.
    static let v1OverloadFactor: Double = 2
    static let v1BusyFactor: Double = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LoadSettings()
        let savedVersion = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        throttle = (try? c.decodeIfPresent(Bool.self, forKey: .throttle)) ?? d.throttle
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? d.notify
        pressureEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .pressureEnabled)) ?? d.pressureEnabled
        let level = (try? c.decodeIfPresent(MemoryPressure.self, forKey: .pressureLevel)) ?? d.pressureLevel
        pressureLevel = level == .normal ? .warning : level
        swapGrowthEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .swapGrowthEnabled)) ?? d.swapGrowthEnabled
        swapGrowthGB = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .swapGrowthGB)) ?? d.swapGrowthGB, Self.swapGBRange)
        swapGrowthMinutes = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .swapGrowthMinutes)) ?? d.swapGrowthMinutes, Self.swapMinutesRange)
        swapSizeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .swapSizeEnabled)) ?? d.swapSizeEnabled
        swapSizeGB = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .swapSizeGB)) ?? d.swapSizeGB, Self.swapGBRange)
        compilersEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .compilersEnabled)) ?? d.compilersEnabled
        maxCompilers = (try? c.decodeIfPresent(Int.self, forKey: .maxCompilers))?.map { Self.clamp($0, Self.compilerRange) }
        loadEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .loadEnabled)) ?? d.loadEnabled
        var overload = (try? c.decodeIfPresent(Double.self, forKey: .overloadFactor)) ?? d.overloadFactor
        var busy = (try? c.decodeIfPresent(Double.self, forKey: .busyFactor)) ?? d.busyFactor
        if savedVersion < 2 {
            // Unchanged first defaults move to the new ones; values the owner set stay.
            if overload == Self.v1OverloadFactor { overload = d.overloadFactor }
            if busy == Self.v1BusyFactor { busy = d.busyFactor }
        }
        overloadFactor = Self.clamp(overload, Self.overloadRange)
        busyFactor = Self.clamp(busy, Self.busyRange)
        overloadMinutes = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .overloadMinutes)) ?? d.overloadMinutes, Self.overloadMinutesRange)
        processesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .processesEnabled)) ?? d.processesEnabled
        maxProcesses = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .maxProcesses)) ?? d.maxProcesses, Self.processRange)
        busyAction = (try? c.decodeIfPresent(LoadBusyAction.self, forKey: .busyAction)) ?? d.busyAction
        maxSimulators = (try? c.decodeIfPresent(Int.self, forKey: .maxSimulators))?.map { Self.clamp($0, Self.simulatorRange) }
        buildSlots = (try? c.decodeIfPresent(Int.self, forKey: .buildSlots))?.map { Self.clamp($0, Self.slotRange) }
        overloadedBuildSlots = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .overloadedBuildSlots)) ?? d.overloadedBuildSlots, Self.slotRange)
        maxSlotHoldMinutes = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .maxSlotHoldMinutes)) ?? d.maxSlotHoldMinutes, Self.holdRange)
        alwaysShowInSidebar = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysShowInSidebar)) ?? d.alwaysShowInSidebar
        version = Self.currentVersion
    }

    /// "Varsayılanlara dön": every trigger, value and limit back to its default; the switches
    /// for throttling, the notification and the sidebar row stay as they are.
    public func restoringDefaults() -> LoadSettings {
        var fresh = LoadSettings()
        fresh.throttle = throttle
        fresh.notify = notify
        fresh.alwaysShowInSidebar = alwaysShowInSidebar
        return fresh
    }

    public func isEnabled(_ trigger: LoadTrigger) -> Bool {
        switch trigger {
        case .pressure: pressureEnabled
        case .swapGrowth: swapGrowthEnabled
        case .swapSize: swapSizeEnabled
        case .compilers: compilersEnabled
        case .load: loadEnabled
        case .processes: processesEnabled
        }
    }

    public mutating func setEnabled(_ trigger: LoadTrigger, _ on: Bool) {
        switch trigger {
        case .pressure: pressureEnabled = on
        case .swapGrowth: swapGrowthEnabled = on
        case .swapSize: swapSizeEnabled = on
        case .compilers: compilersEnabled = on
        case .load: loadEnabled = on
        case .processes: processesEnabled = on
        }
    }

    static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T { min(max(value, range.lowerBound), range.upperBound) }
}

/// The settings applied to this Mac's core count.
public struct LoadThresholds: Sendable, Equatable {
    public var cores: Int
    public var enabled: Set<LoadTrigger>
    public var pressureLevel: MemoryPressure
    public var swapGrowthBytes: UInt64
    public var swapGrowthWindow: TimeInterval
    public var swapSizeBytes: UInt64
    public var overloadCompilers: Int
    /// Load averages (absolute, not per core).
    public var overloadLoad: Double
    /// How long the load must stay above `overloadLoad` to count as overloaded.
    public var overloadSustain: TimeInterval
    public var maxProcesses: Int
    public var busyLoad: Double
    /// How long the load must stay above `busyLoad` to count as busy.
    public var busySustain: TimeInterval
    public var busyCompilers: Int
    public var busyAction: LoadBusyAction
    public var maxSimulators: Int
    public var buildSlots: Int
    public var overloadedBuildSlots: Int
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
        let compilers = settings.maxCompilers ?? defaultCompilers(cores: cores)
        let slots = settings.buildSlots ?? defaultBuildSlots(cores: cores)
        return LoadThresholds(cores: cores, enabled: Set(LoadTrigger.allCases.filter { settings.isEnabled($0) }),
                              pressureLevel: settings.pressureLevel,
                              swapGrowthBytes: UInt64(settings.swapGrowthGB * 1_073_741_824),
                              swapGrowthWindow: TimeInterval(settings.swapGrowthMinutes * 60),
                              swapSizeBytes: UInt64(settings.swapSizeGB * 1_073_741_824),
                              overloadCompilers: compilers,
                              overloadLoad: settings.overloadFactor * Double(cores),
                              overloadSustain: settings.overloadMinutes * 60,
                              maxProcesses: settings.maxProcesses,
                              busyLoad: min(settings.busyFactor, settings.overloadFactor) * Double(cores),
                              busySustain: 60,
                              busyCompilers: max(1, compilers / 2),
                              busyAction: settings.busyAction,
                              maxSimulators: settings.maxSimulators ?? defaultSimulators(cores: cores),
                              buildSlots: slots,
                              overloadedBuildSlots: min(settings.overloadedBuildSlots, slots),
                              maxSlotHold: TimeInterval(settings.maxSlotHoldMinutes * 60))
    }
}

/// One overload trigger right now: its switch, threshold, the live value and whether it fires.
/// Settings, the load tab and `claudedeck load --json` all show these.
public struct LoadTriggerState: Codable, Sendable, Equatable, Identifiable {
    public var trigger: LoadTrigger
    public var enabled: Bool
    /// In `unit`: "pressure" (0 normal, 1 warning, 2 critical), "gb", "processes", "per_core".
    public var threshold: Double
    public var current: Double
    public var unit: String
    /// Above the threshold now (for `load`: for long enough), and enabled.
    public var firing: Bool
    /// The swap growth window, or how long the load must last, in minutes (nil for the others).
    public var minutes: Double?
    /// For `load`: how long it has been above the threshold, in seconds.
    public var aboveFor: Double?

    public var id: LoadTrigger { trigger }

    public init(trigger: LoadTrigger, enabled: Bool, threshold: Double, current: Double, unit: String, firing: Bool,
                minutes: Double? = nil, aboveFor: Double? = nil) {
        self.trigger = trigger
        self.enabled = enabled
        self.threshold = threshold
        self.current = current
        self.unit = unit
        self.firing = firing
        self.minutes = minutes
        self.aboveFor = aboveFor
    }

    /// English, for `claudedeck load`: "compilers > 12 (now 14)".
    public var text: String {
        switch trigger {
        case .pressure:
            return "memory pressure >= \(Self.pressureName(threshold)) (now \(Self.pressureName(current)))"
        case .swapGrowth:
            return String(format: "swap +%.1f GB in %.0f min under pressure (now +%.1f)", threshold, minutes ?? 0, current)
        case .swapSize:
            return String(format: "swap > %.1f GB (now %.1f)", threshold, current)
        case .compilers:
            return "compilers > \(Int(threshold)) (now \(Int(current)))"
        case .load:
            return String(format: "load > %.1f x cores for %.1f min (now %.2f)", threshold, minutes ?? 0, current)
        case .processes:
            return "processes > \(Int(threshold)) (now \(Int(current)))"
        }
    }

    static func pressureValue(_ p: MemoryPressure) -> Double {
        switch p {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    static func pressureName(_ value: Double) -> String {
        value >= 2 ? "critical" : value >= 1 ? "warning" : "normal"
    }
}

/// What changed with a sample.
public enum LoadEvent: Equatable, Sendable {
    case level(from: LoadLevel, to: LoadLevel)
    /// The Mac became overloaded: the one notification and agent message of this episode go out.
    case episodeStarted(Int)
    /// Back to ok.
    case episodeEnded(Int)
}

/// The level, with hysteresis, and the overload episode.
///
/// - overloaded: any enabled trigger fires (`LoadTriggerState`). It ends once none fires and the
///   numbers have stayed under `exitMargin` of their thresholds for `overloadCalm`.
/// - busy (informational): the load above `busyLoad` for `busySustain`, memory pressure warning or
///   worse, or more compilers than `busyCompilers`. It ends once all of that has been clear (load
///   under `exitMargin` of `busyLoad`) for `busyCalm`. Booted simulators never make the Mac busy:
///   their cap only refuses `sim acquire`.
/// - Throttling follows the level (`LoadThrottle`): it ends as soon as the level leaves
///   overloaded. An episode starts when the level becomes overloaded and ends only when it is back
///   to ok, so a Mac swinging between busy and overloaded gets one notification and one message.
public struct LoadMonitor: Sendable, Equatable {
    public private(set) var level: LoadLevel = .ok
    /// In an overload episode (from overloaded until back to ok).
    public private(set) var inEpisode = false
    public private(set) var episode = 0
    public private(set) var samples: [LoadSample] = []
    /// The triggers as of the latest sample.
    public private(set) var triggers: [LoadTriggerState] = []
    /// Kept for the charts: 60 minutes at one sample every 12 seconds.
    public static let keep = 300

    private var highLoadSince: Date?
    private var busyLoadSince: Date?
    private var calmSince: Date?

    public init() {}

    public var latest: LoadSample? { samples.last }
    /// Overloaded right now: throttling applies (when on).
    public var overloaded: Bool { level == .overloaded }
    /// The triggers firing now.
    public var fired: [LoadTrigger] { triggers.filter(\.firing).map(\.trigger) }

    /// The triggers for `sample` given the samples before it and since when the load is high.
    public static func evaluate(_ sample: LoadSample, history: [LoadSample], highLoadSince: Date?,
                                thresholds t: LoadThresholds) -> [LoadTriggerState] {
        let gb = 1_073_741_824.0
        var list: [LoadTriggerState] = []
        let pressure = LoadTriggerState.pressureValue(sample.pressure)
        list.append(.init(trigger: .pressure, enabled: t.enabled.contains(.pressure),
                          threshold: LoadTriggerState.pressureValue(t.pressureLevel), current: pressure, unit: "pressure",
                          firing: t.enabled.contains(.pressure) && sample.pressure >= t.pressureLevel))
        let window = history.filter { sample.at.timeIntervalSince($0.at) <= t.swapGrowthWindow && $0.at <= sample.at }
        let lowest = (window.map(\.swapUsedBytes) + [sample.swapUsedBytes]).min() ?? sample.swapUsedBytes
        let growth = sample.swapUsedBytes > lowest ? sample.swapUsedBytes - lowest : 0
        list.append(.init(trigger: .swapGrowth, enabled: t.enabled.contains(.swapGrowth), threshold: Double(t.swapGrowthBytes) / gb,
                          current: Double(growth) / gb, unit: "gb",
                          firing: t.enabled.contains(.swapGrowth) && growth > t.swapGrowthBytes && sample.pressure >= .warning,
                          minutes: t.swapGrowthWindow / 60))
        list.append(.init(trigger: .swapSize, enabled: t.enabled.contains(.swapSize), threshold: Double(t.swapSizeBytes) / gb,
                          current: Double(sample.swapUsedBytes) / gb, unit: "gb",
                          firing: t.enabled.contains(.swapSize) && sample.swapUsedBytes > t.swapSizeBytes))
        list.append(.init(trigger: .compilers, enabled: t.enabled.contains(.compilers), threshold: Double(t.overloadCompilers),
                          current: Double(sample.compilers), unit: "processes",
                          firing: t.enabled.contains(.compilers) && sample.compilers > t.overloadCompilers))
        let above = highLoadSince.map { sample.at.timeIntervalSince($0) }
        list.append(.init(trigger: .load, enabled: t.enabled.contains(.load), threshold: t.overloadLoad / Double(t.cores),
                          current: sample.loadPerCore, unit: "per_core",
                          firing: t.enabled.contains(.load) && (above.map { $0 >= t.overloadSustain } ?? false),
                          minutes: t.overloadSustain / 60, aboveFor: above))
        list.append(.init(trigger: .processes, enabled: t.enabled.contains(.processes), threshold: Double(t.maxProcesses),
                          current: Double(sample.processes), unit: "processes",
                          firing: t.enabled.contains(.processes) && sample.processes > t.maxProcesses))
        return list
    }

    /// Every enabled trigger well under its threshold (the exit margin), so overloaded may end.
    static func clearWithMargin(_ sample: LoadSample, triggers: [LoadTriggerState], thresholds t: LoadThresholds) -> Bool {
        guard !triggers.contains(where: \.firing) else { return false }
        let m = LoadThresholds.exitMargin
        if t.enabled.contains(.load), sample.load1 >= t.overloadLoad * m { return false }
        if t.enabled.contains(.processes), Double(sample.processes) >= Double(t.maxProcesses) * (1 - (1 - m) / 2) { return false }
        return true
    }

    @discardableResult
    public mutating func add(_ sample: LoadSample, thresholds t: LoadThresholds) -> [LoadEvent] {
        let history = samples
        samples.append(sample)
        if samples.count > Self.keep { samples.removeFirst(samples.count - Self.keep) }

        if sample.load1 > t.overloadLoad {
            if highLoadSince == nil { highLoadSince = sample.at }
        } else {
            highLoadSince = nil
        }
        if sample.load1 > t.busyLoad {
            if busyLoadSince == nil { busyLoadSince = sample.at }
        } else {
            busyLoadSince = nil
        }
        triggers = Self.evaluate(sample, history: history, highLoadSince: highLoadSince, thresholds: t)
        let overloadedNow = triggers.contains(where: \.firing)
        let busyLoad = busyLoadSince.map { sample.at.timeIntervalSince($0) >= t.busySustain } ?? false
        let busyNow = busyLoad || sample.pressure >= .warning || sample.compilers > t.busyCompilers
        let overloadClear = Self.clearWithMargin(sample, triggers: triggers, thresholds: t)
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
        if next == .overloaded, !inEpisode {
            inEpisode = true
            episode += 1
            events.append(.episodeStarted(episode))
        } else if next == .ok, inEpisode {
            inEpisode = false
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
    case swap(UInt64)
    case processes(Int)
    case load(Double, cores: Int)

    /// The worst first: what stands out against its threshold, then the sessions, then the load.
    public static func of(_ sample: LoadSample, thresholds t: LoadThresholds) -> [LoadContributor] {
        var list: [LoadContributor] = []
        if sample.simulators > 0, sample.simulators >= max(2, t.maxSimulators / 2) { list.append(.simulators(sample.simulators)) }
        if sample.compilers > t.busyCompilers { list.append(.compilers(sample.compilers)) }
        if sample.sessions > 0 { list.append(.sessions(sample.sessions)) }
        if sample.pressure != .normal { list.append(.memory(sample.pressure)) }
        if sample.pressure != .normal, sample.swapUsedBytes >= 1 << 30 { list.append(.swap(sample.swapUsedBytes)) }
        if sample.processes > t.maxProcesses * 3 / 4 { list.append(.processes(sample.processes)) }
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
        case .swap(let bytes): String(format: "swap %.1f GB", Double(bytes) / 1_073_741_824)
        case .processes(let n): "\(n) processes"
        case .load(let load, let cores): String(format: "load %.0f on %d cores", load, cores)
        }
    }
}

/// Throttling (Settings › Resources › "Mac yüklüyken ajanları yavaşlat"). Everything follows the
/// level as it is now: holding back ends as soon as the Mac leaves overloaded.
public enum LoadThrottle {
    public enum Start: Equatable, Sendable {
        case allow
        /// `429 overloaded`.
        case refuse
        /// `new --queue`: queued, started once the Mac is no longer overloaded.
        case queue
    }

    /// New starts (`claudedeck new`, the start queue) wait: while overloaded, and while busy only
    /// when the owner chose "hold new starts" for busy.
    public static func holdsStarts(level: LoadLevel, busyAction: LoadBusyAction, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch level {
        case .overloaded: return true
        case .busy: return busyAction == .holdStarts
        case .ok: return false
        }
    }

    /// `claudedeck new`.
    public static func start(level: LoadLevel, busyAction: LoadBusyAction, enabled: Bool, queue: Bool) -> Start {
        guard holdsStarts(level: level, busyAction: busyAction, enabled: enabled) else { return .allow }
        return queue ? .queue : .refuse
    }

    /// The start queue drains whenever starts aren't held.
    public static func drains(level: LoadLevel, busyAction: LoadBusyAction, enabled: Bool) -> Bool {
        !holdsStarts(level: level, busyAction: busyAction, enabled: enabled)
    }

    public enum Simulator: Equatable, Sendable {
        case allow
        /// `429 overloaded`.
        case overloaded
        /// `429 too_many_booted`: `maxSimulators` would be exceeded.
        case tooManyBooted
    }

    /// `claudedeck sim acquire` for `wanted` devices with `booted` simulators running: refused
    /// while overloaded (with throttling on), and whenever the cap would be exceeded.
    public static func simulator(level: LoadLevel, enabled: Bool, booted: Int, wanted: Int, max: Int) -> Simulator {
        if enabled, level == .overloaded { return .overloaded }
        return booted + wanted > max ? .tooManyBooted : .allow
    }

    /// Build slots handed out right now: the overloaded count while overloaded with throttling
    /// on, the full count otherwise (busy included).
    public static func slotCapacity(_ t: LoadThresholds, level: LoadLevel, enabled: Bool) -> Int {
        enabled && level == .overloaded ? max(1, min(t.overloadedBuildSlots, t.buildSlots)) : max(1, t.buildSlots)
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

    /// The limits in force (Settings › Resources).
    public struct Limits: Encodable, Sendable, Equatable {
        public var buildSlots: Int
        public var buildSlotsOverloaded: Int
        public var maxSimulators: Int
        public var maxStartedSessions: Int
        public var runningStartedSessions: Int
        public init(buildSlots: Int, buildSlotsOverloaded: Int, maxSimulators: Int, maxStartedSessions: Int, runningStartedSessions: Int) {
            self.buildSlots = buildSlots
            self.buildSlotsOverloaded = buildSlotsOverloaded
            self.maxSimulators = maxSimulators
            self.maxStartedSessions = maxStartedSessions
            self.runningStartedSessions = runningStartedSessions
        }
    }

    public var level: String
    /// Something is held back right now (new starts; while overloaded also simulators and builds).
    public var throttled: Bool
    public var throttle: Bool
    /// New starts (`new`, the start queue) wait right now.
    public var holdsStarts: Bool
    /// What busy does: `nothing` or `hold_starts`.
    public var busyAction: String
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
    /// Every overload trigger with its switch, threshold, live value and whether it fires.
    public var triggers: [LoadTriggerState]
    /// The triggers firing now (`compilers`, `load`, …).
    public var fired: [String]
    public var limits: Limits
    /// Per-session use (CPU and memory of each Claude session with its child processes), the
    /// heaviest first; nil when not measured.
    public var top: [LoadTopEntry]?
    /// The same summed per project.
    public var topProjects: [LoadTopEntry]?

    public init(level: LoadLevel, settings: LoadSettings, sample: LoadSample?, thresholds: LoadThresholds, triggers: [LoadTriggerState],
                capacity: Int, slots: [Slot], waiting: Int, maxStartedSessions: Int = SessionCLI.maxRunningStarted,
                runningStartedSessions: Int = 0, top: [LoadTopEntry]? = nil, topProjects: [LoadTopEntry]? = nil) {
        self.level = level.rawValue
        throttle = settings.throttle
        holdsStarts = LoadThrottle.holdsStarts(level: level, busyAction: settings.busyAction, enabled: settings.throttle)
        throttled = holdsStarts
        busyAction = settings.busyAction.rawValue
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
        self.triggers = triggers.map { state in
            var rounded = state
            rounded.current = (state.current * 100).rounded() / 100
            rounded.threshold = (state.threshold * 100).rounded() / 100
            rounded.aboveFor = state.aboveFor.map { $0.rounded() }
            return rounded
        }
        fired = triggers.filter(\.firing).map(\.trigger.rawValue)
        limits = Limits(buildSlots: thresholds.buildSlots, buildSlotsOverloaded: thresholds.overloadedBuildSlots,
                        maxSimulators: thresholds.maxSimulators, maxStartedSessions: maxStartedSessions,
                        runningStartedSessions: runningStartedSessions)
        self.top = top
        self.topProjects = topProjects
    }

    public var text: String { text(detail: false) }

    public func text(detail: Bool, now: Date = Date()) -> String {
        var lines: [String] = []
        let note: String
        switch level {
        case LoadLevel.overloaded.rawValue:
            note = throttle ? " (new sessions and simulators are held back; \(buildSlots) build slot\(buildSlots == 1 ? "" : "s"))" : ""
        case LoadLevel.busy.rawValue:
            note = holdsStarts ? " (new sessions wait; simulators and builds go on)" : " (informational: nothing is held back)"
        default:
            note = ""
        }
        lines.append("level: \(level)\(note)")
        guard sampledAt != nil else {
            lines.append("no sample yet")
            return lines.joined(separator: "\n")
        }
        lines.append(String(format: "load: %.1f on %d cores (%.2f per core), 5 min %.1f", load1, cores, loadPerCore, load5))
        lines.append(String(format: "memory: %.0f%% used, pressure %@, swap %d MB", memoryUsedPercent, memoryPressure, swapUsedMB))
        lines.append("simulators: \(simulators) booted (sim acquire allows \(maxSimulators))")
        lines.append("compilers: \(compilers)")
        lines.append("sessions: \(sessions) Claude sessions (\(limits.runningStartedSessions)/\(limits.maxStartedSessions) agent-started), \(processes) processes")
        lines.append("build slots: \(slots.count)/\(buildSlots) used" + (slotsWaiting > 0 ? ", \(slotsWaiting) waiting" : "")
                     + (buildSlots != limits.buildSlots ? " (\(limits.buildSlots) when not overloaded)" : ""))
        for slot in slots {
            let minutes = Int(now.timeIntervalSince(slot.since) / 60)
            lines.append("  \(slot.id)  \(slot.sessionName ?? String(slot.session.uuidString.prefix(8)))  \(minutes)m" + (slot.label.map { "  \($0)" } ?? ""))
        }
        lines.append("overloaded when:")
        for state in triggers {
            let mark = !state.enabled ? "off " : state.firing ? "FIRE" : "ok  "
            lines.append("  \(mark) \(state.text)")
        }
        if detail {
            if let top, !top.isEmpty {
                lines.append("top sessions (CPU, memory, processes):")
                for entry in top.prefix(15) { lines.append("  " + entry.line) }
            } else {
                lines.append("top sessions: not measured")
            }
            if let topProjects, !topProjects.isEmpty {
                lines.append("top projects:")
                for entry in topProjects.prefix(10) { lines.append("  " + entry.line) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// The phone's Mac Load charts (RemoteLoad.history). Here rather than in RemoteDashboard.swift:
// the iOS app compiles that file but not this one.
extension RemoteLoad {
    /// The samples as one point per finished minute (the minute of the latest sample is still
    /// filling and left out), the last `maxHistory`.
    public static func history(from samples: [LoadSample]) -> [Sample] {
        guard let last = samples.last else { return [] }
        let current = (last.at.timeIntervalSinceReferenceDate / 60).rounded(.down)
        var buckets: [(minute: Double, items: [LoadSample])] = []
        for sample in samples {
            let minute = (sample.at.timeIntervalSinceReferenceDate / 60).rounded(.down)
            guard minute < current else { continue }
            if let index = buckets.indices.last, buckets[index].minute == minute {
                buckets[index].items.append(sample)
            } else {
                buckets.append((minute, [sample]))
            }
        }
        return buckets.suffix(maxHistory).map { bucket in
            let n = Double(bucket.items.count)
            return Sample(at: Date(timeIntervalSinceReferenceDate: bucket.minute * 60),
                          loadPerCore: bucket.items.map(\.loadPerCore).reduce(0, +) / n,
                          memoryPercent: Int((bucket.items.map(\.memoryUsedPercent).reduce(0, +) / n).rounded()),
                          simulators: bucket.items.map(\.simulators).max() ?? 0,
                          builds: bucket.items.map(\.compilers).max() ?? 0)
        }
    }
}
