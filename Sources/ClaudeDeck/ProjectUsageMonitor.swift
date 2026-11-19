import ClaudeDeckCore
import Foundation
import Observation

/// Usage per project (ProjectUsage.swift): the transcripts of the deck's projects, read off the
/// main actor and only when someone looks (the Dashboard tab, a connected phone, `claudedeck
/// usage`), at most once a minute.
@MainActor
@Observable
final class ProjectUsageMonitor {
    static let shared = ProjectUsageMonitor()

    private(set) var shares: [ProjectUsageShare] = []
    private(set) var loaded = false
    @ObservationIgnored private var slots: [UUID: [Date: UsageTotals]] = [:]
    @ObservationIgnored private var refreshedAt: Date = .distantPast
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private let scanner = Scanner()

    static let interval: TimeInterval = 60

    private init() {}

    /// Reads what the transcripts gained, unless that happened less than `maxAge` ago.
    func refresh(model: AppModel, maxAge: TimeInterval = interval) async {
        if let inFlight { return await inFlight.value }
        guard Date().timeIntervalSince(refreshedAt) >= maxAge else { return recompute(model: model) }
        let projects = model.deck.projects.map { (id: $0.id, path: $0.path) }
        let extra = model.deck.sessions.filter { $0.kind == .claude }.compactMap { session in
            model.deck.transcriptPath(for: session.id).map { ProjectUsageScanner.Source(path: $0, project: session.projectID) }
        }
        let root = TranscriptIndex.defaultRoot(home: AppModel.claudeHome)
        let task = Task {
            let read = await scanner.refresh(root: root, projects: projects, extra: extra, now: Date())
            slots = read
            refreshedAt = Date()
            loaded = true
            recompute(model: model)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// The shares against the plan's current reading.
    func recompute(model: AppModel) {
        let names = Dictionary(model.deck.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let next = ProjectUsageReport.make(slots, names: names, usage: model.usage.state.usage, now: Date())
        if next != shares { shares = next }
    }

    /// Off the main actor.
    private actor Scanner {
        private var scanner = ProjectUsageScanner()

        func refresh(root: URL, projects: [(id: UUID, path: String)], extra: [ProjectUsageScanner.Source], now: Date) -> [UUID: [Date: UsageTotals]] {
            let since = now.addingTimeInterval(-ProjectUsageReport.week)
            let sources = ProjectUsageScanner.sources(root: root, projects: projects, extra: extra, since: since)
            return scanner.refresh(sources, since: since)
        }
    }
}
