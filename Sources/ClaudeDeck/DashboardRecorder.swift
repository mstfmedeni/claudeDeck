import ClaudeDeckCore
import Darwin
import Foundation
import Observation

/// The Dashboard tab's history. Always on but event-driven: every status change the app already
/// gets (hooks, transcript signals, exits) and every usage reading lands in the `ActivityLedger`,
/// kept for a week in `dashboard.json` beside deck.json. No timers. The transcript counters
/// (`pulses`) are read only while the dashboard is on screen, and then only what was appended.
@MainActor
@Observable
final class DashboardRecorder {
    static let shared = DashboardRecorder()

    private(set) var ledger = ActivityLedger()
    /// Transcript counters by session (refreshed by the dashboard while it's shown).
    private(set) var pulses: [UUID: PulseDigest] = [:]
    /// All of `pulses` added up.
    private(set) var combined = PulseDigest()
    private(set) var pulsesLoaded = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let scanner = PulseScanner()
    @ObservationIgnored private var started = false
    @ObservationIgnored private let url = DeckDataStore.default().url.deletingLastPathComponent().appending(path: "dashboard.json")

    private init() {}

    /// Loads the history and starts following the sessions (once, after `AppModel.start`).
    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if var loaded = try? decoder.decode(ActivityLedger.self, from: data) {
                // Still "on" from the last run (it crashed or was killed): it ended about when it was last saved.
                if !loaded.onSessions.isEmpty { loaded.closeAll(at: loaded.savedAt ?? loaded.events.last?.at ?? Date()) }
                loaded.prune(now: Date())
                ledger = loaded
            }
        }
        follow()
    }

    /// The app is quitting: every session ends now; written right away.
    func stop() {
        guard started else { return }
        ledger.closeAll(at: Date())
        saveTask?.cancel()
        write(ledger, sync: true)
    }

    // MARK: Following the sessions

    private struct Observed: Equatable {
        var session: UUID
        var project: UUID
        var activity: LedgerActivity
        var detail: String?
        var at: Date?
    }

    /// Re-arms on every change to what it reads (statuses, the deck, usage): one pass over the
    /// sessions per hook event, nothing in between.
    private func follow() {
        guard let model else { return }
        let (observed, usage) = withObservationTracking {
            (Self.observe(model), model.usage.state.usage)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        apply(observed, usage: usage)
    }

    private static func observe(_ model: AppModel) -> [Observed] {
        model.deck.sessions.filter { $0.kind == .claude }.map { session in
            let status = model.status(of: session.id)
            return Observed(session: session.id, project: session.projectID,
                            activity: LedgerActivity(status.display.activityValue), detail: status.detail, at: status.updatedAt)
        }
    }

    private func apply(_ observed: [Observed], usage: ClaudeUsage?) {
        let now = Date()
        var changed = false
        for item in observed {
            // The hook's own time when it's recent (a status file read a moment late), else now.
            let at = item.at.map { $0 > now.addingTimeInterval(-120) && $0 <= now ? $0 : now } ?? now
            if ledger.record(session: item.session, project: item.project, activity: item.activity, detail: item.detail, at: at) { changed = true }
        }
        // Removed sessions.
        let present = Set(observed.map(\.session))
        for session in ledger.onSessions where !present.contains(session) {
            if let last = ledger.current(session), ledger.record(session: session, project: last.project, activity: .off, at: now) { changed = true }
        }
        if let usage, !usage.isEmpty, ledger.record(usage: UsageSample(usage)) { changed = true }
        if changed { scheduleSave() }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.ledger.prune(now: Date())
            self.write(self.ledger, sync: false)
        }
    }

    private func write(_ ledger: ActivityLedger, sync: Bool) {
        var copy = ledger
        copy.savedAt = Date()
        let url = url
        if sync { Self.write(copy, to: url) } else { Task.detached(priority: .utility) { Self.write(copy, to: url) } }
    }

    nonisolated private static func write(_ ledger: ActivityLedger, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Transcript counters

    /// Reads what the sessions' transcripts gained since the last call (the first call: the
    /// tails of those touched this week). Called by the visible dashboard only.
    func refreshPulses() async {
        guard let model else { return }
        let sources = model.deck.sessions.filter { $0.kind == .claude }.compactMap { session in
            model.deck.transcriptPath(for: session.id).map { (session.id, $0) }
        }
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let digests = await scanner.refresh(sources, since: since)
        if digests != pulses {
            pulses = digests
            var sum = PulseDigest()
            for digest in digests.values { sum += digest }
            combined = sum
        }
        pulsesLoaded = true
    }
}

/// Keeps one `TranscriptPulse` per transcript off the main actor.
actor PulseScanner {
    private var pulses: [String: TranscriptPulse] = [:]
    private var since: Date?

    func refresh(_ sources: [(UUID, String)], since: Date) -> [UUID: PulseDigest] {
        // A new day: counters start from the new window (one full read of the tails).
        if let old = self.since, Calendar.current.startOfDay(for: old) != Calendar.current.startOfDay(for: since) { pulses = [:] }
        self.since = since
        var result: [UUID: PulseDigest] = [:]
        for (session, path) in sources {
            let url = URL(fileURLWithPath: path)
            if pulses[path] == nil {
                // Untouched this week: nothing to count.
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= since else { continue }
                pulses[path] = TranscriptPulse(since: since)
            }
            if pulses[path]?.read(url, tailBytes: 6 << 20) == false {
                pulses[path] = TranscriptPulse(since: since)
                _ = pulses[path]?.read(url, tailBytes: 6 << 20)
            }
            if let digest = pulses[path]?.digest { result[session] = digest }
        }
        return result
    }
}

/// This process's CPU (since the previous sample) and memory footprint.
struct ProcessSample: Equatable {
    var cpuPercent: Double
    var memoryBytes: UInt64

    @MainActor private static var last: (cpu: Double, at: Double)?

    @MainActor static func take() -> ProcessSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = ProcessInfo.processInfo.systemUptime
        var percent = 0.0
        if let last, now > last.at { percent = (cpu - last.cpu) / (now - last.at) * 100 }
        last = (cpu, now)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ProcessSample(cpuPercent: max(0, percent), memoryBytes: result == KERN_SUCCESS ? info.phys_footprint : 0)
    }
}
