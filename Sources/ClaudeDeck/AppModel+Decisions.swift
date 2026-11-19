import ClaudeDeckCore
import Foundation

/// Decisions sessions leave for the owner (`claudedeck decide`, Decisions.swift): asked without
/// waiting, answered on the Mac (the Decisions tab) or a phone, and the answer goes into the
/// asking session through its prompt queue, so it's typed at its next "your turn" and never into
/// a permission prompt or a question. Kept in Application Support/decisions.json.
extension AppModel {
    // MARK: Routes

    /// `POST /v1/cli/decisions`: returns at once with the id.
    func cliDecide(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard let session = deck.session(caller) else { return SessionCLI.failure(404, "unknown_session", exit: .unknown) }
        let asked: Decisions.Asked
        switch Decisions.validate(question: form["question"] ?? "", options: form["options"] ?? "",
                                  recommend: form["recommend"] ?? "", context: form["context"] ?? "") {
        case .failure(let refusal): return SessionCLI.failure(400, refusal.code, exit: .usage)
        case .success(let value): asked = value
        }
        let projectID: UUID
        switch SessionCLI.project(form["project"] ?? "", callerProject: session.projectID, projects: deck.projects) {
        case .found(let id): projectID = id
        case .unknown: return SessionCLI.failure(404, "unknown_project", exit: .unknown)
        case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
        }
        // Warn only: the owner reads these, in Turkish.
        let notTurkish = !Decisions.looksTurkish(question: asked.question, options: asked.options)
        // `--supersedes ID`: checked before anything changes; nothing is created when it can't go.
        let supersedes = (form["supersedes"] ?? "").trimmingCharacters(in: .whitespaces)
        var replaced: OwnerDecision?
        if !supersedes.isEmpty {
            switch checkCancellable(caller, id: supersedes, command: "decide --supersedes") {
            case .failure(let refusal): return refusal.response
            case .success(let old): replaced = old
            }
        }
        // The same question still waiting from this session: its id, nothing new.
        if let existing = decisions.pendingDuplicate(session: caller, question: asked.question, except: replaced?.id) {
            var notes = ["already_pending:\(existing.id)"]
            if notTurkish { notes.append("not_turkish") }
            if let replaced {
                cancelDecision(replaced.id, reason: "superseded by \(existing.id)", by: session.name)
            }
            logAgent(session.name, inbound: true, "claudedeck decide: already pending as \(existing.id), nothing new"
                + (replaced.map { " (\($0.id) superseded by it)" } ?? ""))
            return decideAnswer(existing, notes: notes, json: json)
        }
        guard decisions.pendingCount - (replaced == nil ? 0 : 1) < Decisions.maxPending else {
            logAgent(session.name, inbound: true, "claudedeck decide: too many waiting", ok: false)
            return SessionCLI.failure(429, "too_many_pending", exit: .refused)
        }
        guard cli.decisions.allow(caller) else {
            logAgent(session.name, inbound: true, "claudedeck decide: too many", ok: false)
            return SessionCLI.failure(429, "too_many", exit: .refused)
        }
        var id = Decisions.newID()
        while decisions.decision(id) != nil { id = Decisions.newID() }
        let decision = OwnerDecision(id: id, question: asked.question, options: asked.options, recommended: asked.recommended,
                                     context: asked.context, projectID: projectID, project: deck.project(projectID)?.name ?? "",
                                     sessionID: caller, session: session.name,
                                     ancestors: Decisions.ancestors(of: caller, startedBy: sessionStarters))
        // One step on the main actor: the old one goes and the new one comes together.
        if let replaced {
            _ = decisions.cancel(replaced.id, reason: "superseded by \(id)")
            logAgent(session.name, inbound: true, "decision \(replaced.id) cancelled · superseded by \(id)")
        }
        decisions.add(decision)
        decisionsChanged(added: decision)
        logAgent(session.name, inbound: true, "claudedeck decide \(id) · \(String(asked.question.prefix(80)))"
            + (notTurkish ? " · not in Turkish (warned)" : ""))
        return decideAnswer(decision, notes: notTurkish ? ["not_turkish"] : [], json: json)
    }

    private func decideAnswer(_ decision: OwnerDecision, notes: [String], json: Bool) -> AgentHTTPResponse {
        var response = SessionCLI.answer(200, decision, text: decision.id, exit: .ok, json: json)
        if !notes.isEmpty { response.headers[Decisions.noteHeader] = notes.joined(separator: ",") }
        return response
    }

    /// Each session's starter (`startedBy`), for the ownership rule.
    private var sessionStarters: [UUID: UUID] {
        Dictionary(deck.sessions.compactMap { session in session.startedBy.map { (session.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Whether `caller` may cancel `id` now: the pending decision, or the refusal (404, 409, 403).
    private func checkCancellable(_ caller: UUID, id: String, command: String) -> Result<OwnerDecision, AgentHTTPRequestRefusal> {
        let name = deck.session(caller)?.name ?? "claudedeck"
        guard Decisions.isValidID(id) else {
            logAgent(name, inbound: true, "claudedeck \(command) \(id): unknown decision", ok: false)
            return .failure(.init(SessionCLI.failure(404, "unknown_decision", exit: .unknown)))
        }
        switch decisions.cancellable(id) {
        case .unknown:
            logAgent(name, inbound: true, "claudedeck \(command) \(id): unknown decision", ok: false)
            return .failure(.init(SessionCLI.failure(404, "unknown_decision", exit: .unknown)))
        case .alreadyAnswered(let decision):
            logAgent(name, inbound: true, "claudedeck \(command) \(decision.id): refused (already answered)", ok: false)
            return .failure(.init(SessionCLI.failure(409, "already_answered", exit: .refused)))
        case .alreadyCancelled(let decision):
            logAgent(name, inbound: true, "claudedeck \(command) \(decision.id): refused (already cancelled)", ok: false)
            return .failure(.init(SessionCLI.failure(409, "already_cancelled", exit: .refused)))
        case .cancelled(let decision):
            guard Decisions.mayCancel(caller: caller, decision: decision, startedBy: sessionStarters) else {
                logAgent(name, inbound: true, "claudedeck \(command) \(decision.id): refused (asked by another session)", ok: false)
                return .failure(.init(SessionCLI.failure(403, "not_yours", exit: .refused)))
            }
            return .success(decision)
        }
    }

    /// `POST /v1/cli/decisions/{id}/cancel`: the asking session (or one that started it) withdraws
    /// a pending decision.
    func cliCancelDecision(_ caller: UUID, id: String, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let name = deck.session(caller)?.name ?? "claudedeck"
        switch checkCancellable(caller, id: id, command: "decision cancel") {
        case .failure(let refusal): return refusal.response
        case .success(let decision):
            let reason = Decisions.cleanReason(form["reason"] ?? "") ?? "cancelled by \(name)"
            guard let cancelled = cancelDecision(decision.id, reason: reason, by: name) else {
                return SessionCLI.failure(409, "already_cancelled", exit: .refused)
            }
            return SessionCLI.answer(200, cancelled, text: "cancelled \(cancelled.id)", exit: .ok, json: json)
        }
    }

    /// Cancels a pending decision (logged; the lists, the badge and the phones follow). Nil when it
    /// wasn't pending.
    @discardableResult
    private func cancelDecision(_ id: String, reason: String, by who: String) -> OwnerDecision? {
        guard case .cancelled(let decision) = decisions.cancel(id, reason: reason) else { return nil }
        decisionsChanged(added: nil)
        logAgent(who, inbound: true, "decision \(decision.id) cancelled · \(reason)")
        return decision
    }

    /// `GET /v1/cli/decisions[?pending=1]`, newest first.
    func cliDecisions(form: [String: String], json: Bool) -> AgentHTTPResponse {
        let list = decisions.newestFirst.filter { form["pending"] != "1" || $0.isPending }
        return SessionCLI.answer(200, list, text: Decisions.listText(list), exit: .ok, json: json)
    }

    /// `GET /v1/cli/decisions/{id}`.
    func cliDecision(_ id: String, json: Bool) -> AgentHTTPResponse {
        guard Decisions.isValidID(id), let decision = decisions.decision(id) else {
            return SessionCLI.failure(404, "unknown_decision", exit: .unknown)
        }
        return SessionCLI.answer(200, decision, text: Decisions.text(decision), exit: .ok, json: json)
    }

    // MARK: Answering

    /// The owner's answer (an option or their own words), from the Mac (`mac`) or a phone
    /// (`phone`). The first answer wins. It goes into the asking session's queue when that's a
    /// Claude session still in the deck; either way it's kept for `decision get`.
    func answerDecision(_ id: String, answer raw: String, from: String) {
        guard let answer = Decisions.cleanAnswer(raw) else { return }
        switch decisions.answer(id, with: answer, from: from) {
        case .unknown:
            return
        case .alreadyAnswered(let decision):
            logAgent("ClaudeDeck", inbound: false, "decision \(decision.id) was already \(decision.isCancelled ? "cancelled" : "answered"); "
                + "the answer from \(from) was ignored", ok: false)
            return
        case .answered(let decision):
            // A plain terminal asked (a user's own shell): typing the answer there would run it.
            var delivery = "no_session"
            if let sessionID = decision.sessionID, let session = deck.session(sessionID) {
                if session.kind == .claude {
                    enqueue(sessionID, text: Decisions.message(for: decision))
                    delivery = "queued"
                } else {
                    delivery = "terminal"
                }
            }
            decisions.setDelivery(decision.id, delivery)
            decisionsChanged(added: nil)
            let target = decision.session.isEmpty ? decision.project : decision.session
            logAgent(target, inbound: false, "decision \(decision.id) answered on the \(from == "phone" ? "phone" : "Mac") · "
                + (delivery == "queued" ? "queued for the session" : "kept for claudedeck decision get (\(delivery))"))
        }
    }

    /// The owner removes a pending decision without answering, on the Mac (`mac`) or a phone
    /// (`phone`): cancelled with "owner dismissed", and the asking Claude session gets a one-line
    /// note through its queue, as answers go.
    func dismissDecision(_ id: String, from: String) {
        let device = from == "phone" ? "phone" : "Mac"
        switch decisions.cancel(id, reason: Decisions.ownerDismissed) {
        case .unknown:
            return
        case .alreadyAnswered(let decision):
            logAgent("ClaudeDeck", inbound: false, "decision \(decision.id) was already answered; the dismissal from the \(device) was ignored", ok: false)
            return
        case .alreadyCancelled:
            return
        case .cancelled(let decision):
            var delivery = "no_session"
            if let sessionID = decision.sessionID, let session = deck.session(sessionID) {
                if session.kind == .claude {
                    enqueue(sessionID, text: Decisions.dismissedMessage(for: decision))
                    delivery = "queued"
                } else {
                    delivery = "terminal"
                }
            }
            decisions.setDelivery(decision.id, delivery)
            decisionsChanged(added: nil)
            let target = decision.session.isEmpty ? decision.project : decision.session
            logAgent(target, inbound: false, "decision \(decision.id) dismissed by the owner on the \(device) · "
                + (delivery == "queued" ? "the session was told" : "kept for claudedeck decision get (\(delivery))"))
        }
    }

    // MARK: Kept on disk (Application Support/decisions.json)

    private var decisionsURL: URL {
        DeckDataStore.default().url.deletingLastPathComponent().appending(path: "decisions.json")
    }

    func loadDecisions() {
        guard let data = try? Data(contentsOf: decisionsURL) else { return }
        do {
            decisions = try JSONDecoder().decode(DecisionBook.self, from: data)
        } catch {
            logAgent("ClaudeDeck", inbound: false, "couldn't read decisions.json: \(error.localizedDescription)", ok: false)
        }
    }

    /// Saved at once (a decision is rare and small): one asked just before quitting stays.
    private func decisionsChanged(added: OwnerDecision?) {
        onDecisionsChanged?(added)
        do {
            try JSONEncoder().encode(decisions).write(to: decisionsURL, options: .atomic)
        } catch {
            logAgent("ClaudeDeck", inbound: false, "couldn't save decisions: \(error.localizedDescription)", ok: false)
        }
    }

    /// The Decisions tab.
    func showDecisions() {
        tabs.open(.decisions)
        showMainWindow()
    }
}
