import ClaudeDeckCore
import Foundation

/// `claudedeck close ID|self [--force]`: a session ends itself or a session it started, the way
/// the owner's End Session / Close Terminal does (the process ends, the session stays in the
/// sidebar with its transcript and can be resumed), and its pane closes. Behind "Sessions may
/// close sessions they started" (off by default). Contract: docs/agents.md.
extension AppModel {
    func cliClose(_ caller: UUID, ref: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        guard deck.settings.sessionsMayCloseSessions else {
            logAgent(callerName, inbound: true, "claudedeck close \(ref): refused (the setting is off)", ok: false)
            return SessionCLI.failure(403, "close_off", exit: .refused)
        }
        let target: DeckSession
        switch cliCloseTarget(ref, caller: caller) {
        case .failure(let refusal): return refusal.response
        case .success(let session): target = session
        }
        let starters = Dictionary(deck.sessions.compactMap { session in session.startedBy.map { (session.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        guard SessionCLI.mayClose(caller: caller, target: target.id, startedBy: starters) else {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (not started by this session)", ok: false)
            return SessionCLI.failure(403, "not_yours", exit: .refused)
        }
        let force = form["force"] == "1"
        let id = target.id
        // Being moved to another Claude account (AppModel+Accounts): its process is replaced
        // right now; ask again once it's back.
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (switching account)", ok: false)
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }

        // Already ended: only the pane is left to close.
        guard terminals.isRunning(id) else {
            finishCLIClose(target, by: caller, forced: false, ended: false)
            return SessionCLI.answer(200, SessionCLIClosed(closed: true, id: id, forced: false), text: "closed", exit: .ok, json: json)
        }
        // Watched read-only in another app's session helper: it can't be driven or ended from here.
        if terminals.readOnlySessions.contains(id) {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (read-only)", ok: false)
            return SessionCLI.failure(409, "read_only", exit: .failed)
        }

        // Itself: the answer has to go out first (the caller is inside this very command).
        if id == caller {
            logAgent(callerName, inbound: true, "claudedeck close self" + (force ? " --force" : "") + ": ends "
                     + (force ? "now" : "once the current turn is over"))
            closeSelfLater(target, force: force, requestedAt: Date())
            let closed = SessionCLIClosed(closed: false, id: id, forced: force, pending: true)
            return SessionCLI.answer(200, closed, text: force ? "closing" : "closing: after this turn", exit: .ok, json: json)
        }

        var forced = false
        if target.kind == .shell {
            // A terminal closes like Close Terminal: its process is ended.
            forced = true
            terminals.terminate(id)
        } else {
            switch cliProgress(id) {
            // At its usage limit it sits at the prompt: ends like an idle one.
            case .finished, .stopped, .limited:
                if !(await typeExit(id, grace: .seconds(Int(SessionCLI.closeGrace)))) {
                    guard force else {
                        logAgent(callerName, inbound: true, "claudedeck close · \(target.name): still running \(Int(SessionCLI.closeGrace)) s after /exit", ok: false)
                        return SessionCLI.failure(409, "still_running", exit: .timeout)
                    }
                    forced = true
                    terminals.terminate(id)
                }
            case .blocked:
                guard force else {
                    logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (waits on a permission or a question)", ok: false)
                    return SessionCLI.failure(409, "blocked", exit: .blocked)
                }
                forced = true
                terminals.terminate(id)
            case .running, .failed:
                guard force else {
                    logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (Claude is working)", ok: false)
                    return SessionCLI.failure(409, "busy", exit: .failed)
                }
                forced = true
                terminals.terminate(id)
            }
        }
        guard !terminals.isRunning(id) else {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): couldn't end it", ok: false)
            return SessionCLI.failure(409, "not_closed", exit: .failed)
        }
        if let session = deck.session(id) { finishCLIClose(session, by: caller, forced: forced) }
        return SessionCLI.answer(200, SessionCLIClosed(closed: true, id: id, forced: forced), text: "closed", exit: .ok, json: json)
    }

    /// Like `target` in AppModel+SessionCLI.swift, with queue ids (a started `new --queue`).
    private func cliCloseTarget(_ ref: String, caller: UUID) -> Result<DeckSession, AgentHTTPRequestRefusal> {
        var id: UUID?
        if SessionCLI.isQueueID(ref) {
            switch cliQueuedSession(ref) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): id = found
            }
        } else {
            switch SessionCLI.target(ref, caller: caller, sessions: deck.sessions.map(\.id)) {
            case .found(let found): id = found
            case .unknown: break
            case .ambiguous: return .failure(.init(SessionCLI.failure(400, "ambiguous", exit: .usage)))
            }
        }
        guard let id, let session = deck.session(id) else { return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown))) }
        return .success(session)
    }

    /// `close self`: after the answer went out. Without `--force` it waits for the turn to end
    /// (a hook state newer than the request saying idle), then types `/exit` like a restart does.
    private func closeSelfLater(_ session: DeckSession, force: Bool, requestedAt: Date) {
        let id = session.id, name = session.name
        Task { @MainActor [weak self] in
            // Time for the HTTP answer to reach the command.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            // Never in the middle of a move to another account: wait until it's back up.
            while self.switchingAccounts.contains(id) { try? await Task.sleep(for: .milliseconds(500)) }
            var forced = false
            if force || session.kind == .shell {
                forced = true
                self.terminals.terminate(id)
            } else {
                let deadline = ContinuousClock.now + .seconds(Int(SessionCLI.selfCloseLimit))
                while self.terminals.isRunning(id), ContinuousClock.now < deadline {
                    let state = Self.stateName(self.status(of: id).display)
                    let progress = SessionCLI.claudeProgress(state: state, updatedAt: self.hookStatuses[id]?.updatedAt,
                                                             sentAt: requestedAt)
                    if progress == .finished(0) { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if self.terminals.isRunning(id) {
                    guard ContinuousClock.now < deadline else {
                        self.logAgent(name, inbound: true, "claudedeck close self: given up, the turn didn't end in \(Int(SessionCLI.selfCloseLimit / 60)) minutes", ok: false)
                        return
                    }
                    await self.typeExit(id, grace: .seconds(Int(SessionCLI.closeGrace)))
                }
            }
            guard !self.terminals.isRunning(id) else {
                self.logAgent(name, inbound: true, "claudedeck close self: still running after /exit", ok: false)
                return
            }
            if let current = self.deck.session(id) { self.finishCLIClose(current, by: id, forced: forced) }
        }
    }

    /// After the process ended: its pane closes, the Activity Log gets a line, the session that
    /// started it a note (unless that's the caller, or it had ended already: `ended` false), and a
    /// queued `new --queue` may start in the freed slot.
    private func finishCLIClose(_ session: DeckSession, by caller: UUID, forced: Bool, ended: Bool = true) {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        // Like the pane's close button; the owner's selection only moves if it was this one.
        if deck.panes.contains(session.id) { mutate(userInitiated: false) { $0.closePane(session.id) } }
        let byItself = caller == session.id
        logAgent(callerName, inbound: true, "claudedeck close · " + (byItself ? "itself" : session.name)
                 + (ended ? (forced ? " (ended with a signal)" : "") : " (wasn't running; pane closed)"))
        if ended, let parent = session.startedBy, parent != caller, deck.session(parent)?.kind == .claude {
            let text = byItself
                ? String(localized: "\(session.name), a session this one started, closed itself.")
                : String(localized: "\(callerName) closed \(session.name), a session this one started.")
            receiveNote(requestID: nil, sessionID: parent, agent: "claudedeck close", text: text)
        }
        onCountsChanged?()
        if deck.cliQueue.contains(where: { $0.status == .queued }) { drainCLIQueueSoon() }
    }
}
