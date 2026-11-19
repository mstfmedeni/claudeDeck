import ClaudeDeckCore
import Foundation

/// The snapshot's extras for connected phones: the Dashboard in brief, the simulators and fresh
/// ServerPlan lists. Nothing here runs without a connected remote: `setConnected(false)` stops
/// the loops, and `apply` leaves the fields out. With one, the dashboard is rebuilt at most every
/// `dashboardInterval`, today's line counts are read every `pulseInterval` (only what the
/// transcripts gained), simulators are sampled every `simulatorInterval` while the Simulators
/// setting is on, and ServerPlan's lists are fetched every `serverPlanInterval` while it's set up.
@MainActor
final class RemotePhoneFeeds {
    static let shared = RemotePhoneFeeds()

    static let dashboardInterval: TimeInterval = 5
    static let pulseInterval: Duration = .seconds(30)
    static let simulatorInterval: Duration = .seconds(10)
    static let serverPlanInterval: Duration = .seconds(60)

    private var connected = false
    private var loops: [Task<Void, Never>] = []
    private var dashboard: RemoteDashboard?
    private var dashboardAt: Date = .distantPast
    /// When a session started waiting, for one whose status has no time (kept stable across builds).
    private var waitingSince: [UUID: (reason: String, at: Date)] = [:]
    private var simulators: [RemoteSimulator]?

    private init() {}

    /// A remote connected or the last one left. `changed` republishes the snapshot.
    func setConnected(_ on: Bool, model: AppModel?, changed: @escaping () -> Void) {
        guard on != connected else { return }
        connected = on
        loops.forEach { $0.cancel() }
        loops = []
        dashboard = nil
        dashboardAt = .distantPast
        waitingSince = [:]
        simulators = nil
        guard on, let model else { return }
        loops.append(Task { @MainActor in
            while !Task.isCancelled {
                await DashboardRecorder.shared.refreshPulses()
                guard !Task.isCancelled else { return }
                dashboardAt = .distantPast
                changed()
                try? await Task.sleep(for: Self.pulseInterval)
            }
        })
        loops.append(Task { @MainActor [weak model] in
            while !Task.isCancelled, let model {
                if model.deck.settings.simulators {
                    await SimulatorsController.shared.sampleForRemote(model: model, every: Self.simulatorInterval)
                    simulators = Self.simulators(model)
                } else {
                    simulators = nil
                }
                guard !Task.isCancelled else { return }
                changed()
                try? await Task.sleep(for: Self.simulatorInterval)
            }
        })
        loops.append(Task { @MainActor in
            while !Task.isCancelled {
                let controller = ServerPlanController.shared
                if controller.isConfigured {
                    await controller.refresh(listsOnly: true)
                    guard !Task.isCancelled else { return }
                    changed()
                }
                try? await Task.sleep(for: Self.serverPlanInterval)
            }
        })
    }

    /// Puts the extras into a snapshot about to be published (nothing without a remote).
    func apply(to snapshot: inout RemoteSnapshot, model: AppModel) {
        guard connected else { return }
        let now = Date()
        if dashboard == nil || now.timeIntervalSince(dashboardAt) >= Self.dashboardInterval {
            dashboard = makeDashboard(model, now: now)
            dashboardAt = now
        }
        snapshot.dashboard = dashboard
        snapshot.simulators = model.deck.settings.simulators ? simulators : nil
    }

    // MARK: Dashboard

    /// The Dashboard's "now" tiles, "Waiting on you" and usage burn, as the Mac's tab computes them.
    private func makeDashboard(_ model: AppModel, now: Date) -> RemoteDashboard {
        let recorder = DashboardRecorder.shared
        let claude = model.deck.sessions.filter { $0.kind == .claude }
        let states = claude.map { model.status(of: $0.id).display }
        var lines: PulseBucket?
        if recorder.pulsesLoaded {
            lines = recorder.combined.total(in: DateInterval(start: Calendar.current.startOfDay(for: now), duration: 86400))
        }
        var waiting: [RemoteDashboard.Waiting] = []
        var still: [UUID: (reason: String, at: Date)] = [:]
        for session in model.deck.sessions {
            let status = model.status(of: session.id)
            guard status.display.isBlocked || model.isUnseenIdle(session.id) else { continue }
            let reason: String
            var since = status.updatedAt
            if let program = status.display.program {
                reason = program.state.rawValue
            } else {
                let activity = LedgerActivity(status.display.activityValue)
                reason = activity.rawValue
                if let recorded = recorder.ledger.current(session.id), recorded.activity == activity { since = recorded.at }
            }
            let known = waitingSince[session.id].flatMap { $0.reason == reason ? $0.at : nil }
            let at = since ?? known ?? now
            still[session.id] = (reason, at)
            waiting.append(RemoteDashboard.Waiting(sessionID: session.id, name: session.name,
                                                   project: model.deck.project(session.projectID)?.name ?? "", reason: reason,
                                                   detail: status.detail.map { String($0.prefix(160)) }, since: at))
        }
        waitingSince = still
        let top = RemoteDashboard.top(waiting)
        var five: RemoteDashboard.Window?
        var week: RemoteDashboard.Window?
        if let usage = model.usage.state.usage, !usage.isEmpty {
            let samples = recorder.ledger.usage
            five = usage.fiveHour.map { window in
                RemoteDashboard.Window.make(window, length: 5 * 3600, samples: samples.compactMap { s in s.fiveHour.map { (s.at, $0) } }, now: now)
            }
            week = usage.sevenDay.map { window in
                RemoteDashboard.Window.make(window, length: 7 * 86400, samples: samples.compactMap { s in s.sevenDay.map { (s.at, $0) } }, now: now,
                                            recent: 24 * 3600, minimumSpan: 6 * 3600)
            }
        }
        return RemoteDashboard(
            working: states.filter(\.isRunning).count,
            waiting: states.filter(\.isBlocked).count,
            yourTurn: claude.filter { model.isUnseenIdle($0.id) }.count,
            linesAdded: lines?.added, linesRemoved: lines?.removed,
            waitingList: top.list, moreWaiting: top.more, fiveHour: five, week: week,
            projects: Self.projectShares(model)
        )
    }

    /// Each project's part of the usage windows (read in the background, at most once a minute).
    private static func projectShares(_ model: AppModel) -> [RemoteDashboard.ProjectShare]? {
        let monitor = ProjectUsageMonitor.shared
        Task { @MainActor in await monitor.refresh(model: model) }
        guard monitor.loaded else { return nil }
        return monitor.shares.prefix(RemoteDashboard.maxProjects).map { share in
            RemoteDashboard.ProjectShare(projectID: share.projectID, name: share.name, fiveHourPercent: share.fiveHourPercent,
                                         weekPercent: share.weekPercent, fiveHourShare: share.fiveHourShare, weekShare: share.weekShare,
                                         fiveHourTokens: share.fiveHour.tokens, weekTokens: share.week.tokens, weekCost: share.week.cost)
        }
    }

    // MARK: Simulators

    /// Running simulators and the ones a session used, with memory and sessions.
    private static func simulators(_ model: AppModel) -> [RemoteSimulator] {
        let controller = SimulatorsController.shared
        let list = controller.devices.compactMap { device -> RemoteSimulator? in
            let live = controller.uses[device.udid].map { uses in
                uses.reduce(into: [UUID]()) { if !$0.contains($1.session) { $0.append($1.session) } }
            } ?? []
            let sessions = (live.isEmpty ? controller.lastUse[device.udid]?.sessions ?? [] : live).filter { model.deck.session($0) != nil }
            let holder = model.simHolds.holder(of: device.udid)
            guard device.state != "Shutdown" || !sessions.isEmpty || holder != nil else { return nil }
            return RemoteSimulator(udid: device.udid, name: device.name, runtime: device.runtime.displayName, state: device.state,
                                   memoryBytes: device.isBooted ? controller.memory[device.udid].map { roundedMemory($0.bytes) } : nil,
                                   sessionIDs: sessions, heldBy: holder)
        }
        return RemoteSimulator.forRemote(list)
    }

    /// To 10 MB: a few pages more or less don't resend the snapshot.
    private static func roundedMemory(_ bytes: UInt64) -> UInt64 { (bytes + 5_000_000) / 10_000_000 * 10_000_000 }
}
