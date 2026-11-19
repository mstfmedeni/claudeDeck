import ClaudeDeckCore
import Foundation

/// Stall watch (StallWatch.swift) for Claude sessions another session started with `claudedeck
/// new`: no progress for N minutes while working, or the same error again and again, gets the
/// action picked in Settings › Agents (off by default). Every action is in the activity log.
extension AppModel {
    /// The default nudge ("Devam et" in Turkish).
    static var defaultStallNudge: String { String(localized: "Continue") }

    var stallNudgeText: String {
        let custom = deck.settings.stallWatch.nudgeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Self.defaultStallNudge : custom
    }

    /// Watched: Claude sessions another session started.
    private func stallWatched(_ id: UUID) -> Bool {
        guard let session = deck.session(id) else { return false }
        return session.kind == .claude && session.startedBy != nil
    }

    func startStallWatch() {
        guard stallTask == nil else { return }
        stallTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(StallWatch.checkInterval))
                self?.checkStalls()
            }
        }
    }

    /// A hook event or transcript append: the session moved.
    func stallProgress(_ id: UUID, at date: Date = Date()) {
        guard deck.settings.stallWatch.enabled, stallWatched(id) else { return }
        stallTrackers[id, default: StallTracker(lastProgress: date)].progress(at: min(date, Date()))
    }

    func stallTranscriptGrew(_ id: UUID, chunk: String) {
        guard deck.settings.stallWatch.enabled, stallWatched(id) else { return }
        stallProgress(id)
        guard deck.settings.stallWatch.errorRepeats > 1 else { return }
        let results = StallWatch.results(in: chunk)
        guard !results.isEmpty else { return }
        stallTrackers[id]?.results(results.map(\.signature), texts: results.map(\.text))
        // An error loop needn't wait for the next tick.
        checkStall(id)
    }

    private func checkStalls() {
        guard deck.settings.stallWatch.enabled else {
            if !stallTrackers.isEmpty { stallTrackers = [:] }
            return
        }
        for session in deck.sessions where stallWatched(session.id) && terminals.isRunning(session.id) { checkStall(session.id) }
    }

    private func checkStall(_ id: UUID, now: Date = Date()) {
        let settings = deck.settings.stallWatch
        guard settings.enabled, stallWatched(id), terminals.isRunning(id), !restartingSessions.contains(id),
              let session = deck.session(id) else { return }
        // First look: the watch starts now (or at the last hook event, if newer).
        if stallTrackers[id] == nil { stallTrackers[id] = StallTracker(lastProgress: max(hookStatuses[id]?.updatedAt ?? now, now)) }
        guard let tracker = stallTrackers[id] else { return }
        let working = status(of: id).display.isRunning
        guard let reason = StallWatch.check(tracker, working: working, startedBySession: true, settings: settings, now: now) else { return }
        var (action, capped) = StallWatch.action(for: settings, tracker: tracker, now: now)
        // A nudge can't go in while a permission or question is on screen.
        if action == .nudge, status(of: id).display.isBlocked { action = .notify }
        StallWatch.acted(&stallTrackers[id]!, action: action, reason: reason, now: now)
        let count = stallTrackers[id]?.interventions.count ?? 0
        let nudge = stallNudgeText

        let what: String
        switch action {
        case .notify:
            what = capped ? "notified (nudge limit of \(StallWatch.maxInterventionsPerHour) an hour reached)" : "notified"
        case .nudge:
            rememberAgentPrompt(nudge, in: id)
            if let refusal = typePrompt(nudge, into: id) {
                what = "nudge not sent (\(refusal)); notified"
            } else {
                what = "nudged with “\(nudge)” (\(count)/\(StallWatch.maxInterventionsPerHour) this hour)"
            }
        case .restart:
            what = "restarting it, then “\(nudge)” (\(count)/\(StallWatch.maxInterventionsPerHour) this hour)"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.restartSession(id, busy: .force, interactive: false) {
                    self.typeWhenClaudeIsUp(nudge, into: id)
                } else {
                    self.logAgent("ClaudeDeck", inbound: false, "stall watch · \(session.name): restart wasn't possible", ok: false)
                }
            }
        }
        logAgent("ClaudeDeck", inbound: false, "stall watch · \(session.name): \(reason.summary) → \(what)")
        let notice = String(localized: "Looks stuck: \(reason.localizedSummary(minutes: settings.minutes)). \(action.localizedOutcome)")
        if deck.settings.notifications { onSessionNotice?(id, notice) }
        if settings.tellParent, let parent = session.startedBy, deck.session(parent) != nil {
            _ = receiveNote(requestID: nil, sessionID: parent, agent: String(localized: "ClaudeDeck stall watch"),
                            text: String(localized: "\(session.name) (which this session started) looks stuck: \(reason.localizedSummary(minutes: settings.minutes)). \(action.localizedOutcome)"))
        }
    }

    /// `claudedeck status`: what the watch knows about a session.
    func stallStatus(_ id: UUID, now: Date = Date()) -> SessionCLIStatus.Stall? {
        guard stallWatched(id) else { return nil }
        let settings = deck.settings.stallWatch
        guard settings.enabled else {
            return .init(watching: false, stalled: nil, lastProgressAt: nil, minutesWithoutProgress: nil, repeatedErrors: 0,
                         lastAction: nil, lastActionAt: nil, interventionsLastHour: 0)
        }
        let tracker = stallTrackers[id]
        let working = status(of: id).display.isRunning
        let stalled = tracker.flatMap { StallWatch.check($0, working: working, startedBySession: true, settings: settings, now: now)?.code }
        return .init(watching: true, stalled: stalled, lastProgressAt: tracker?.lastProgress,
                     minutesWithoutProgress: working ? tracker.map { Int(now.timeIntervalSince($0.lastProgress) / 60) } : nil,
                     repeatedErrors: tracker?.errorCount ?? 0, lastAction: tracker?.lastAction, lastActionAt: tracker?.lastActionAt,
                     interventionsLastHour: tracker?.interventions.filter { now.timeIntervalSince($0) < 3600 }.count ?? 0)
    }
}

extension StallReason {
    func localizedSummary(minutes: Int) -> String {
        switch self {
        case .noProgress: String(localized: "no progress for \(minutes) minutes while working")
        case .errorLoop(let count, _): String(localized: "the same error \(count) times in a row")
        }
    }
}

extension StallAction {
    var localizedOutcome: String {
        switch self {
        case .notify: String(localized: "Have a look.")
        case .nudge: String(localized: "ClaudeDeck nudged it.")
        case .restart: String(localized: "ClaudeDeck restarts it.")
        }
    }

    var title: String {
        switch self {
        case .notify: String(localized: "Notify only")
        case .nudge: String(localized: "Nudge it (type the message)")
        case .restart: String(localized: "Restart it (resume), then nudge")
        }
    }
}
