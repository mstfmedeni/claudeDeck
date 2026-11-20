import ClaudeDeckCore
import Foundation
import Observation

/// The Mac's load (Settings › Resources): samples the system every 12 seconds off the main
/// thread, keeps the level and the recent samples for the sidebar row, the dashboard card and the
/// phone, and holds the build slots. What an overload episode does (notification, messages to the
/// agents) is in AppModel+Load.swift; the rules are in SystemLoad.swift.
///
/// Per-process use (CPU and memory per session, builds, the heaviest other processes) is read
/// only while the "Mac Yükü" tab is on screen (every few seconds), while a phone is connected
/// (with its other feeds), or when `claudedeck load --detail` asks; the 12-second sample stays a
/// few sysctls and one pass over the process names.
@MainActor
@Observable
final class LoadController {
    static let shared = LoadController()

    static let interval: Duration = .seconds(12)
    static let detailInterval: Duration = .seconds(3)

    private(set) var monitor = LoadMonitor()
    /// Build slots (`claudedeck slot` / `heavy`).
    var slots = BuildSlotBook()
    /// The latest per-process report (nil until measured).
    private(set) var usage: LoadUsageReport?
    /// A sample injected for testing (demo mode's debug hook): used instead of the real one until cleared.
    @ObservationIgnored private(set) var injected: LoadSample?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previousTable: ProcessUsageTable?
    @ObservationIgnored private var detailViewers = 0
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// AttentionCenter: an overload episode began (title, body). Once per episode.
    @ObservationIgnored var onOverloaded: ((String, String) -> Void)?

    private init() {}

    var settings: LoadSettings { model?.deck.settings.load ?? LoadSettings() }
    var cores: Int { monitor.latest?.cores ?? ProcessInfo.processInfo.activeProcessorCount }
    var thresholds: LoadThresholds { LoadThresholds.resolve(settings, cores: cores) }
    var level: LoadLevel { monitor.level }
    var latest: LoadSample? { monitor.latest }
    /// New starts wait right now (overloaded, or busy with "hold new starts"), with throttling on.
    var holdsStarts: Bool { LoadThrottle.holdsStarts(level: level, busyAction: settings.busyAction, enabled: settings.throttle) }
    /// Overloaded with throttling on: new agents, simulators and extra builds hold back.
    var isThrottling: Bool { settings.throttle && monitor.overloaded }
    /// Build slots handed out right now (fewer while overloaded).
    var slotCapacity: Int { LoadThrottle.slotCapacity(thresholds, level: level, enabled: settings.throttle) }

    func start(model: AppModel) {
        self.model = model
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { SystemLoadSampler.sample() }.value
                guard let self else { return }
                self.apply(self.injected.map { Self.restamped($0, at: sample.at) } ?? sample)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private static func restamped(_ sample: LoadSample, at date: Date) -> LoadSample {
        var copy = sample
        copy.at = date
        return copy
    }

    /// A new sample: the running Claude sessions are counted, the level moves, slots of sessions
    /// that ended (or held too long) go back, and an episode's start or end is acted on.
    func apply(_ sample: LoadSample) {
        guard let model else { return }
        var sample = sample
        sample.sessions = model.deck.sessions.filter { $0.kind == .claude && model.terminals.isRunning($0.id) }.count
        let events = monitor.add(sample, thresholds: LoadThresholds.resolve(settings, cores: sample.cores))
        pruneSlots()
        if !events.isEmpty { model.loadChanged(events, sample: sample) }
    }

    /// Slots of sessions that no longer run, and slots held past the longest hold, go back.
    func pruneSlots(now: Date = Date()) {
        guard let model else { return }
        let running = Set(model.deck.sessions.lazy.filter { model.terminals.isRunning($0.id) }.map(\.id))
        let gone = slots.prune(running: running, maxHold: thresholds.maxSlotHold, now: now)
        for slot in gone {
            let name = model.deck.session(slot.session)?.name ?? "a closed session"
            let why = running.contains(slot.session) ? "held longer than \(settings.maxSlotHoldMinutes) min" : "its session ended"
            model.logAgent(name, inbound: true, "claudedeck slot: released \(slot.id) (\(why))")
        }
    }

    // MARK: Per-process use

    /// The load tab appeared: per-process sampling runs every few seconds until it disappears.
    func detailVisible(_ on: Bool) {
        detailViewers = max(0, detailViewers + (on ? 1 : -1))
        if detailViewers > 0, detailTask == nil {
            detailTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await AppVisibility.shared.waitUntilVisible()
                    guard !Task.isCancelled, let self else { return }
                    await self.measureUsage()
                    try? await Task.sleep(for: Self.detailInterval)
                }
            }
        } else if detailViewers == 0 {
            detailTask?.cancel()
            detailTask = nil
        }
    }

    /// One look at every process; CPU % against the previous look (taken again a second later
    /// when the previous one is missing or old, so a one-off `load --detail` has figures too).
    @discardableResult
    func measureUsage() async -> LoadUsageReport? {
        guard let model else { return nil }
        var previous = previousTable
        if previous == nil || Date().timeIntervalSince(previous!.at) > 60 {
            previous = await Task.detached(priority: .utility) { SystemLoadSampler.usageTable() }.value
            try? await Task.sleep(for: .seconds(1))
        }
        let table = await Task.detached(priority: .utility) { SystemLoadSampler.usageTable() }.value
        previousTable = table
        var roots: [UUID: Int32] = [:]
        for session in model.deck.sessions where model.terminals.isRunning(session.id) {
            let pid = model.terminals.pid(for: session.id)
            if pid > 0 { roots[session.id] = pid }
        }
        let own = getpid()
        let excluded = Set([own] + table.records.values.filter { $0.name == "claudedeck-ptyd" }.map(\.pid))
        let cpu = LoadUsage.cpuPercent(previous: previous, current: table)
        let report = LoadUsage.report(table: table, cpu: cpu, sessionRoots: roots, excludedRoots: excluded)
        usage = report
        return report
    }

    /// `top` / `top_projects` for `claudedeck load --json` and the phone.
    func topEntries(_ report: LoadUsageReport) -> (sessions: [LoadTopEntry], projects: [LoadTopEntry]) {
        guard let model else { return ([], []) }
        return LoadTopEntry.entries(from: report) { id in
            guard let session = model.deck.session(id) else { return nil }
            return (session.name, model.deck.project(session.projectID)?.name ?? "", session.startedBy != nil)
        }
    }

    // MARK: Testing

    /// Demo mode's debug hook (`load.inject` in CLAUDEDECK_SNAPSHOT_DIR): "overloaded", "busy",
    /// "ok", a JSON LoadSample, or "real" to go back to the system's numbers. Applied at once.
    func inject(_ text: String) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch word {
        case "real", "":
            injected = nil
            return
        case "overloaded":
            injected = LoadSample(load1: Double(cores) * 3, load5: Double(cores) * 2.5, cores: cores, pressure: .critical,
                                  memoryUsedPercent: 92, swapUsedBytes: 6 << 30, simulators: 11, compilers: 30, processes: 3400)
        case "busy":
            injected = LoadSample(load1: Double(cores) * 2.5, load5: Double(cores) * 2, cores: cores, pressure: .warning,
                                  memoryUsedPercent: 70, simulators: 4, compilers: 4, processes: 2000)
        case "ok":
            injected = LoadSample(load1: Double(cores) * 0.1, load5: Double(cores) * 0.1, cores: cores, memoryUsedPercent: 40, processes: 800)
        default:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let sample = try? decoder.decode(LoadSample.self, from: Data(word.utf8)) else { return }
            injected = sample
        }
        if let injected { apply(Self.restamped(injected, at: Date())) }
    }

    // MARK: Phone

    /// The phone's dashboard row (while a remote is connected), with the heaviest sessions and the
    /// booted simulators when measured.
    var remoteLoad: RemoteLoad? {
        guard let sample = monitor.latest else { return nil }
        var load = RemoteLoad(level: monitor.level.rawValue, throttled: holdsStarts, loadPerCore: sample.loadPerCore, cores: sample.cores,
                              memoryPercent: Int(sample.memoryUsedPercent.rounded()), memoryPressure: sample.pressure.rawValue,
                              simulators: sample.simulators, builds: sample.compilers, sessions: sample.sessions,
                              slotsUsed: slots.slots.count, slots: slotCapacity)
        load.fired = monitor.fired.map(\.rawValue)
        if let usage, Date().timeIntervalSince(usage.at) < 90 {
            // Rounded to 5 % and 50 MB so small changes don't resend the snapshot.
            load.top = topEntries(usage).sessions.prefix(6).map {
                RemoteLoad.Top(session: $0.session ?? UUID(), name: $0.name, project: $0.project ?? "",
                               cpuPercent: Int(($0.cpuPercent / 5).rounded()) * 5, memoryMB: ($0.memoryMB / 50) * 50, agent: $0.agent)
            }
        }
        load.bootedSimulators = bootedSimulators().map {
            RemoteLoad.BootedSimulator(udid: $0.udid, name: $0.name, holder: $0.holderName,
                                       memoryMB: $0.memoryBytes.map { Int($0 / 52_428_800) * 50 })
        }
        return load
    }

    /// A booted simulator as the load tab and the phone show it.
    struct BootedSimulator: Identifiable, Equatable {
        var udid: String
        var name: String
        var runtime: String?
        /// The session holding it (`claudedeck sim acquire`); nil: the user's own.
        var holder: UUID?
        var holderName: String?
        var memoryBytes: UInt64?
        /// When its `launchd_sim` started (from the per-process table).
        var bootedAt: Date?
        var id: String { udid }
    }

    /// Booted simulators from the Simulators list (when read) and ClaudeDeck's holds.
    func bootedSimulators() -> [BootedSimulator] {
        guard let model else { return [] }
        let sims = SimulatorsController.shared
        var list: [BootedSimulator] = []
        var seen: Set<String> = []
        for device in sims.booted {
            let holder = model.simHolds.holder(of: device.udid)
            list.append(BootedSimulator(udid: device.udid, name: device.name, runtime: device.runtime.displayName, holder: holder,
                                        holderName: holder.flatMap { model.deck.session($0)?.name },
                                        memoryBytes: sims.memory[device.udid]?.bytes,
                                        bootedAt: sims.launchdPIDs[device.udid].flatMap { usage?.started(of: $0) }))
            seen.insert(device.udid)
        }
        for hold in model.simHolds.holds where !seen.contains(hold.udid) && sims.loaded == false {
            list.append(BootedSimulator(udid: hold.udid, name: hold.name, holder: hold.session,
                                        holderName: model.deck.session(hold.session)?.name))
        }
        return list
    }
}
