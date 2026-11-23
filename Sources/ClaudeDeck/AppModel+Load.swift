import ClaudeDeckCore
import Foundation

/// What ClaudeDeck does about the Mac's load (LoadController, SystemLoad.swift): one notification
/// (Mac and phone) and one queued message to the agents per overload episode, the start queue
/// resuming as soon as starts are no longer held, and the `claudedeck load` / `slot` routes. The
/// throttling checks sit in `new` (AppModel+SessionCLIAutonomy), the queue drain
/// (AppModel+SessionCLILaunch) and `sim acquire` (AppModel+SessionCLISimulators).
extension AppModel {
    var systemLoad: LoadController { LoadController.shared }

    func loadChanged(_ events: [LoadEvent], sample: LoadSample) {
        for event in events {
            switch event {
            case .level(let from, let to):
                let fired = systemLoad.monitor.fired.map(\.rawValue).joined(separator: ", ")
                let contributors = LoadContributor.of(sample, thresholds: systemLoad.thresholds).map(\.text).joined(separator: ", ")
                logAgent("ClaudeDeck", inbound: false, "Mac load: \(from.rawValue) → \(to.rawValue) ("
                         + (fired.isEmpty ? "" : "fired: \(fired); ") + "\(contributors))", ok: to != .overloaded)
                // Starts held at the old level and not at the new one: the queue drains again.
                let settings = deck.settings.load
                if !LoadThrottle.drains(level: from, busyAction: settings.busyAction, enabled: settings.throttle),
                   LoadThrottle.drains(level: to, busyAction: settings.busyAction, enabled: settings.throttle),
                   deck.cliQueue.contains(where: { $0.status == .queued }) {
                    drainCLIQueueSoon()
                }
            case .episodeStarted:
                overloadEpisodeStarted(sample)
            case .episodeEnded:
                if deck.cliQueue.contains(where: { $0.status == .queued }) { drainCLIQueueSoon() }
            }
        }
    }

    private func overloadEpisodeStarted(_ sample: LoadSample) {
        let settings = deck.settings.load
        let title = String(localized: "The Mac is overloaded")
        let body = Self.overloadSummary(sample, thresholds: systemLoad.thresholds)
        if settings.notify, deck.settings.notifications {
            systemLoad.onOverloaded?(title, body)
            remote.pushNotice(title: title, body: body, collapseID: "load-overloaded", threadID: "load")
        }
        // Agents hear about it once per episode as a queued message (typed only once each is idle,
        // never interrupting a turn); a note would reach the owner only. Not with the brake off:
        // the owner chose to let agents run through it.
        guard settings.throttle else { return }
        let text = AgentNoticeRouting.overloadMessage
        let recipients = AgentNoticeRouting.overloadRecipients(deck.sessions.map {
            (id: $0.id, isClaude: $0.kind == .claude, startedBy: $0.startedBy, running: terminals.isRunning($0.id))
        })
        var told = 0
        for id in recipients {
            let queued = deck.session(id)?.queue.contains { $0.text == text } ?? false
            guard AgentNoticeRouting.route(.overloaded, recipientIsLiveClaude: true, enabled: true, alreadyQueued: queued) == .queue else { continue }
            enqueue(id, text: text)
            told += 1
        }
        if told > 0 { logAgent("ClaudeDeck", inbound: false, "Mac overloaded: queued a message for \(told) agents to postpone heavy work") }
    }

    /// "11 simulators booted, 3 builds, 37 sessions · load 42 on 20 cores" (localized).
    static func overloadSummary(_ sample: LoadSample, thresholds: LoadThresholds) -> String {
        var parts: [String] = []
        var loadText: String?
        for contributor in LoadContributor.of(sample, thresholds: thresholds) {
            switch contributor {
            case .simulators(let n): parts.append(String(localized: "\(n) simulators booted"))
            case .builds(let n): parts.append(String(localized: "\(n) builds"))
            case .sessions(let n): parts.append(String(localized: "\(n) sessions"))
            case .memory(let pressure):
                parts.append(pressure == .critical ? String(localized: "memory pressure critical") : String(localized: "memory pressure high"))
            case .swap(let bytes):
                parts.append(String(localized: "swap \(String(format: "%.1f", Double(bytes) / 1_073_741_824)) GB"))
            case .processes(let n):
                parts.append(String(localized: "\(n) processes"))
            case .load(let value, let cores):
                loadText = String(localized: "load \(Int(value.rounded())) on \(cores) cores")
            }
        }
        return (parts + [loadText].compactMap { $0 }).joined(separator: ", ")
    }

    /// Why new agent sessions wait right now (the Agents row and overview say it), or nil when a
    /// start would go ahead: the load (and which trigger), or the running cap.
    var startHoldReason: String? {
        let settings = deck.settings.load
        if LoadThrottle.holdsStarts(level: systemLoad.level, busyAction: settings.busyAction, enabled: settings.throttle) {
            if systemLoad.level == .overloaded {
                let monitor = systemLoad.monitor
                let triggers = monitor.fired.isEmpty ? monitor.lastFired : monitor.fired
                // "too many builds 8/7": the number now against the limit, as the Load tab shows it.
                let names = triggers.map { trigger in
                    let name = Self.triggerName(trigger)
                    guard let state = monitor.triggers.first(where: { $0.trigger == trigger }),
                          [.compilers, .processes].contains(trigger) else { return name }
                    return "\(name) \(Int(state.current))/\(Int(state.threshold))"
                }.joined(separator: ", ")
                return names.isEmpty ? String(localized: "the Mac is overloaded")
                    : String(localized: "the Mac is overloaded (\(names))")
            }
            return String(localized: "the Mac is busy")
        }
        let cap = deck.settings.maxStartedSessions
        if cliRunningStarted >= cap { return String(localized: "\(cliRunningStarted) of \(cap) agent sessions are working") }
        return nil
    }

    private static func triggerName(_ trigger: LoadTrigger) -> String {
        switch trigger {
        case .pressure: String(localized: "memory pressure")
        case .swapGrowth: String(localized: "swap growing")
        case .swapSize: String(localized: "swap size")
        case .compilers: String(localized: "too many builds")
        case .load: String(localized: "CPU load")
        case .processes: String(localized: "too many processes")
        }
    }

    // MARK: claudedeck load / slot

    /// `claudedeck load [--json] [--detail]`: the JSON always has `top` (per session, measured now
    /// unless the load tab measured it in the last few seconds); the text lists it with `--detail`.
    func cliLoad(form: [String: String], json: Bool) async -> AgentHTTPResponse {
        systemLoad.pruneSlots()
        await systemLoad.sampleIfStale()
        let detail = form["detail"] == "1"
        var usage = systemLoad.usage
        if json || detail, usage == nil || Date().timeIntervalSince(usage!.at) > 10 {
            usage = await systemLoad.measureUsage()
        }
        var report = loadReport(usage: usage)
        if json || detail {
            // Memory per booted simulator (measured now unless sampled in the last 10 s) and simslim's state.
            await SimulatorsController.shared.sampleForRemote(model: self, every: .seconds(10))
            report.bootedSimulators = systemLoad.bootedSimulators().map { sim in
                LoadSimulator(udid: sim.udid, name: sim.name, holder: sim.holder == nil ? nil : (sim.holderName ?? "a closed session"),
                              memoryBytes: sim.memoryBytes, slim: sim.slim)
            }
        }
        return SessionCLI.answer(200, report, text: report.text(detail: detail), exit: .ok, json: json)
    }

    func loadReport(usage: LoadUsageReport? = nil) -> SessionCLILoad {
        let slots = systemLoad.slots.slots.map {
            SessionCLILoad.Slot(id: $0.id, session: $0.session, sessionName: deck.session($0.session)?.name, label: $0.label, since: $0.acquiredAt)
        }
        let top = usage.map { systemLoad.topEntries($0) }
        var report = SessionCLILoad(level: systemLoad.level, settings: deck.settings.load, sample: systemLoad.latest,
                              thresholds: systemLoad.thresholds, triggers: systemLoad.monitor.triggers,
                              capacity: systemLoad.slotCapacity, slots: slots, waiting: systemLoad.slots.waiters.count,
                              maxStartedSessions: deck.settings.maxStartedSessions, runningStartedSessions: cliRunningStarted,
                              top: top?.sessions, topProjects: top?.projects)
        report.explainExit(systemLoad.monitor)
        return report
    }

    private struct SlotRefusal: Encodable {
        var error: String
        var position: Int?
        var used: Int
        var capacity: Int
    }

    /// Long poll like `wait`: answers with a slot as soon as one is free for the caller, or after
    /// `timeout` seconds (at most `maxWaitWindow`) with `429 no_slot` (exit 124); the command asks
    /// again with the same ticket, keeping its place in line.
    func cliSlotAcquire(_ caller: UUID, kind: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard BuildSlotBook.kinds.contains(kind) else { return SessionCLI.failure(404, "unknown_slot", exit: .unknown) }
        let rawTicket = (form["ticket"] ?? "").trimmingCharacters(in: .whitespaces)
        guard rawTicket.isEmpty || BuildSlotBook.isValidTicket(rawTicket) else { return SessionCLI.failure(400, "bad_ticket", exit: .usage) }
        let ticket = rawTicket.isEmpty ? nil : rawTicket
        let label = (form["label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let window = min(SessionCLI.maxWaitWindow, max(0, form["timeout"].flatMap(Int.init) ?? 0))
        let deadline = ContinuousClock.now + .seconds(window)
        let name = deck.session(caller)?.name ?? "claudedeck"
        systemLoad.pruneSlots()
        await systemLoad.sampleIfStale()
        while true {
            guard deck.session(caller) != nil else { return SessionCLI.failure(404, "unknown_session", exit: .unknown) }
            let capacity = systemLoad.slotCapacity
            switch systemLoad.slots.acquire(session: caller, ticket: ticket, label: label.isEmpty ? nil : label, capacity: capacity) {
            case .acquired(let slot):
                logAgent(name, inbound: true, "claudedeck slot acquire · \(slot.id)" + (slot.label.map { " · \($0.prefix(60))" } ?? ""))
                let info = SessionCLISlot(acquired: true, id: slot.id, kind: kind, position: nil, used: systemLoad.slots.slots.count, capacity: capacity)
                return SessionCLI.answer(200, info, text: slot.id, exit: .ok, json: json)
            case .full(let position):
                if ContinuousClock.now >= deadline {
                    var response = AgentHTTPResponse.json(429, SlotRefusal(error: "no_slot", position: position,
                                                                           used: systemLoad.slots.slots.count, capacity: capacity))
                    response.headers[SessionCLI.exitHeader] = String(SessionCLI.Exit.timeout.rawValue)
                    return response
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// `slot release build [ID]`; with a ticket (an interrupted `heavy` still in line) it leaves the line.
    func cliSlotRelease(_ caller: UUID, kind: String, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard BuildSlotBook.kinds.contains(kind) else { return SessionCLI.failure(404, "unknown_slot", exit: .unknown) }
        let name = deck.session(caller)?.name ?? "claudedeck"
        let ticket = (form["ticket"] ?? "").trimmingCharacters(in: .whitespaces)
        if !ticket.isEmpty {
            systemLoad.slots.leave(ticket: ticket, session: caller)
            return SessionCLI.answer(200, ["released": [String]()], text: "left the line", exit: .ok, json: json)
        }
        let id = (form["id"] ?? "").trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, !systemLoad.slots.held(by: caller).contains(where: { $0.id == id }) {
            return SessionCLI.failure(404, "unknown_slot_id", exit: .unknown)
        }
        let released = systemLoad.slots.release(session: caller, id: id.isEmpty ? nil : id).map(\.id)
        if !released.isEmpty { logAgent(name, inbound: true, "claudedeck slot release · " + released.joined(separator: ", ")) }
        let text = released.isEmpty ? "nothing to release" : "released " + released.joined(separator: ", ")
        return SessionCLI.answer(200, ["released": released], text: text, exit: .ok, json: json)
    }

    /// A session ended or was closed: its build slots go back at once.
    func releaseSlots(of session: UUID) {
        let released = systemLoad.slots.release(session: session)
        guard !released.isEmpty else { return }
        logAgent(deck.session(session)?.name ?? "a closed session", inbound: true,
                 "claudedeck slot: released \(released.map(\.id).joined(separator: ", ")) (the session ended)")
    }
}
