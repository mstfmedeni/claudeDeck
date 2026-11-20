import ClaudeDeckCore
import Foundation

/// What ClaudeDeck does about the Mac's load (LoadController, SystemLoad.swift): one notification
/// (Mac and phone) and one note to the agents per overload episode, the start queue resuming once
/// the Mac is back to ok, and the `claudedeck load` / `slot` routes. The throttling checks sit in
/// `new` (AppModel+SessionCLIAutonomy), the queue drain (AppModel+SessionCLILaunch) and
/// `sim acquire` (AppModel+SessionCLISimulators).
extension AppModel {
    var systemLoad: LoadController { LoadController.shared }

    /// The note an agent gets when the Mac becomes overloaded (Turkish in the Turkish UI).
    static var overloadNote: String {
        String(localized: "[ClaudeDeck] The Mac is overloaded: postpone heavy work (builds, simulators) and release simulators you're done with.")
    }

    func loadChanged(_ events: [LoadEvent], sample: LoadSample) {
        for event in events {
            switch event {
            case .level(let from, let to):
                let contributors = LoadContributor.of(sample, thresholds: systemLoad.thresholds).map(\.text).joined(separator: ", ")
                logAgent("ClaudeDeck", inbound: false, "Mac load: \(from.rawValue) → \(to.rawValue) (\(contributors))", ok: to != .overloaded)
            case .episodeStarted:
                overloadEpisodeStarted(sample)
            case .episodeEnded:
                // The queue held back during the episode starts draining again.
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
        // Agents hear about it once per episode, as a note (never typed into Claude).
        guard settings.throttle else { return }
        let agents = deck.sessions.filter { $0.kind == .claude && $0.startedBy != nil && terminals.isRunning($0.id) }
        for session in agents {
            _ = receiveNote(requestID: nil, sessionID: session.id, agent: "ClaudeDeck", text: Self.overloadNote)
        }
        if !agents.isEmpty { logAgent("ClaudeDeck", inbound: false, "Mac overloaded: told \(agents.count) agents to postpone heavy work") }
    }

    /// "11 simulators booted, 30 builds, 37 sessions · load 42 on 20 cores" (localized).
    static func overloadSummary(_ sample: LoadSample, thresholds: LoadThresholds) -> String {
        var parts: [String] = []
        var loadText: String?
        for contributor in LoadContributor.of(sample, thresholds: thresholds) {
            switch contributor {
            case .simulators(let n): parts.append(String(localized: "\(n) simulators booted"))
            case .compilers(let n): parts.append(String(localized: "\(n) builds"))
            case .sessions(let n): parts.append(String(localized: "\(n) sessions"))
            case .memory(let pressure):
                parts.append(pressure == .critical ? String(localized: "memory pressure critical") : String(localized: "memory pressure high"))
            case .load(let value, let cores):
                loadText = String(localized: "load \(Int(value.rounded())) on \(cores) cores")
            }
        }
        return (parts + [loadText].compactMap { $0 }).joined(separator: ", ")
    }

    // MARK: claudedeck load / slot

    func cliLoad(json: Bool) -> AgentHTTPResponse {
        systemLoad.pruneSlots()
        let report = loadReport()
        return SessionCLI.answer(200, report, text: report.text, exit: .ok, json: json)
    }

    func loadReport() -> SessionCLILoad {
        let slots = systemLoad.slots.slots.map {
            SessionCLILoad.Slot(id: $0.id, session: $0.session, sessionName: deck.session($0.session)?.name, label: $0.label, since: $0.acquiredAt)
        }
        return SessionCLILoad(level: systemLoad.level, throttled: systemLoad.monitor.throttled, throttle: deck.settings.load.throttle,
                              sample: systemLoad.latest, thresholds: systemLoad.thresholds, capacity: systemLoad.slotCapacity, slots: slots,
                              waiting: systemLoad.slots.waiters.count)
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
