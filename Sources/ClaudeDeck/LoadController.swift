import ClaudeDeckCore
import Foundation
import Observation

/// The Mac's load (Settings › Resources): samples the system every 12 seconds off the main
/// thread, keeps the level and the recent samples for the sidebar row, the dashboard card and the
/// phone, and holds the build slots. What an overload episode does (notification, notes to the
/// agents, throttling) is in AppModel+Load.swift; the rules are in SystemLoad.swift.
@MainActor
@Observable
final class LoadController {
    static let shared = LoadController()

    static let interval: Duration = .seconds(12)

    private(set) var monitor = LoadMonitor()
    /// Build slots (`claudedeck slot` / `heavy`).
    var slots = BuildSlotBook()
    /// A sample injected for testing (demo mode's debug hook): used instead of the real one until cleared.
    @ObservationIgnored private(set) var injected: LoadSample?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// AttentionCenter: an overload episode began (title, body). Once per episode.
    @ObservationIgnored var onOverloaded: ((String, String) -> Void)?

    private init() {}

    var settings: LoadSettings { model?.deck.settings.load ?? LoadSettings() }
    var cores: Int { monitor.latest?.cores ?? ProcessInfo.processInfo.activeProcessorCount }
    var thresholds: LoadThresholds { LoadThresholds.resolve(settings, cores: cores) }
    var level: LoadLevel { monitor.level }
    var latest: LoadSample? { monitor.latest }
    /// In an overload episode with throttling on: new agents, simulators and builds hold back.
    var isThrottling: Bool { settings.throttle && monitor.throttled }
    /// Build slots handed out right now (one during an episode).
    var slotCapacity: Int { LoadThrottle.slotCapacity(thresholds.buildSlots, throttled: monitor.throttled, enabled: settings.throttle) }

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
            injected = LoadSample(load1: Double(cores) * 3, load5: Double(cores) * 2.5, cores: cores, pressure: .warning,
                                  memoryUsedPercent: 92, swapUsedBytes: 6 << 30, simulators: 11, compilers: 30, processes: 3400)
        case "busy":
            injected = LoadSample(load1: Double(cores) * 1.3, load5: Double(cores), cores: cores, memoryUsedPercent: 70,
                                  simulators: 2, compilers: 4, processes: 1200)
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

    /// The phone's dashboard row (while a remote is connected).
    var remoteLoad: RemoteLoad? {
        guard let sample = monitor.latest else { return nil }
        return RemoteLoad(level: monitor.level.rawValue, throttled: isThrottling, loadPerCore: sample.loadPerCore, cores: sample.cores,
                          memoryPercent: Int(sample.memoryUsedPercent.rounded()), memoryPressure: sample.pressure.rawValue,
                          simulators: sample.simulators, builds: sample.compilers, sessions: sample.sessions,
                          slotsUsed: slots.slots.count, slots: slotCapacity)
    }
}
