import ClaudeDeckCore
import Foundation

/// `claudedeck close ID|self [--force] [--remove|--keep]`: a session ends itself or a session it
/// started, the way the owner's End Session / Close Terminal does, and its pane closes. With
/// `--remove`, or Settings › "Closed sessions are removed from the list" (on by default) without
/// `--keep`, it then leaves the deck like the owner's End and Remove (`removeSession`: only the
/// deck entry; the Claude transcript, the folder and any work tree stay); otherwise it stays in the
/// sidebar and can be resumed. `claudedeck remove ID` removes one that has already stopped.
/// Behind "Sessions may close sessions they started" (off by default). Contract: docs/agents.md.
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
        guard SessionCLI.mayClose(caller: caller, target: target.id, startedBy: startedByMap()) else {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (not started by this session)", ok: false)
            return SessionCLI.failure(403, "not_yours", exit: .refused)
        }
        let force = form["force"] == "1"
        let remove = SessionCLI.removesAfterClose(form: form, setting: deck.settings.removeClosedSessions)
        let id = target.id
        // Being moved to another Claude account (AppModel+Accounts): its process is replaced
        // right now; ask again once it's back.
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (switching account)", ok: false)
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }

        // Already ended: only the pane is left to close.
        guard terminals.isRunning(id) else {
            finishCLIClose(target, by: caller, forced: false, ended: false, remove: remove)
            return closedAnswer(id, forced: false, removed: remove, json: json)
        }
        // Watched read-only in another app's session helper: it can't be driven or ended from here.
        if terminals.readOnlySessions.contains(id) {
            logAgent(callerName, inbound: true, "claudedeck close · \(target.name): refused (read-only)", ok: false)
            return SessionCLI.failure(409, "read_only", exit: .failed)
        }

        // Itself: the answer has to go out first (the caller is inside this very command).
        if id == caller {
            logAgent(callerName, inbound: true, "claudedeck close self" + (force ? " --force" : "") + ": ends "
                     + (force ? "now" : "once the current turn is over") + (remove ? ", then is removed" : ""))
            closeSelfLater(target, force: force, remove: remove, requestedAt: Date())
            let closed = SessionCLIClosed(closed: false, id: id, forced: force, pending: true, removed: remove)
            let text = (force ? "closing" : "closing: after this turn") + (remove ? " (then removed)" : "")
            return SessionCLI.answer(200, closed, text: text, exit: .ok, json: json)
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
        if let session = deck.session(id) { finishCLIClose(session, by: caller, forced: forced, remove: remove) }
        return closedAnswer(id, forced: forced, removed: remove, json: json)
    }

    private func closedAnswer(_ id: UUID, forced: Bool, removed: Bool, json: Bool) -> AgentHTTPResponse {
        SessionCLI.answer(200, SessionCLIClosed(closed: true, id: id, forced: forced, removed: removed),
                          text: removed ? "closed and removed" : "closed", exit: .ok, json: json)
    }

    /// `claudedeck remove ID`: a session that has stopped (ended, or never started) leaves the
    /// deck like the owner's End and Remove. Same rules as `close`: the setting, and only the
    /// caller's own sessions (those it started, and theirs); a running one is `409
    /// still_running` (close it instead, `close --remove`).
    func cliRemove(_ caller: UUID, ref: String, json: Bool) -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        guard deck.settings.sessionsMayCloseSessions else {
            logAgent(callerName, inbound: true, "claudedeck remove \(ref): refused (the setting is off)", ok: false)
            return SessionCLI.failure(403, "close_off", exit: .refused)
        }
        let target: DeckSession
        switch cliCloseTarget(ref, caller: caller) {
        case .failure(let refusal): return refusal.response
        case .success(let session): target = session
        }
        let id = target.id
        let running = terminals.isRunning(id) || terminals.readOnlySessions.contains(id)
        switch SessionCLI.mayRemove(caller: caller, target: id, startedBy: startedByMap(), running: running) {
        case .notYours:
            logAgent(callerName, inbound: true, "claudedeck remove · \(target.name): refused (not started by this session)", ok: false)
            return SessionCLI.failure(403, "not_yours", exit: .refused)
        case .stillRunning:
            logAgent(callerName, inbound: true, "claudedeck remove · \(target.name): refused (still running; close it)", ok: false)
            return SessionCLI.failure(409, "still_running", exit: .failed)
        case .allowed:
            break
        }
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            logAgent(callerName, inbound: true, "claudedeck remove · \(target.name): refused (switching account)", ok: false)
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }
        logAgent(callerName, inbound: true, "claudedeck remove · \(target.name): removed from the list (transcript kept)")
        notifyStarter(of: target, by: caller, callerName: callerName, removed: true, ended: false)
        removeSession(id, userInitiated: false)
        if deck.cliQueue.contains(where: { $0.status == .queued }) { drainCLIQueueSoon() }
        return SessionCLI.answer(200, SessionCLIRemoved(removed: true, id: id), text: "removed", exit: .ok, json: json)
    }

    private func startedByMap() -> [UUID: UUID] {
        Dictionary(deck.sessions.compactMap { session in session.startedBy.map { (session.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
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
    private func closeSelfLater(_ session: DeckSession, force: Bool, remove: Bool, requestedAt: Date) {
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
            if let current = self.deck.session(id) { self.finishCLIClose(current, by: id, forced: forced, remove: remove) }
        }
    }

    /// After the process ended: its pane closes (or, with `remove`, the session leaves the deck),
    /// the Activity Log gets a line, the session that started it a note (unless that's the caller,
    /// or it had ended already and stays: `ended` and `remove` false), and a queued `new --queue`
    /// may start in the freed slot.
    private func finishCLIClose(_ session: DeckSession, by caller: UUID, forced: Bool, ended: Bool = true, remove: Bool) {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let byItself = caller == session.id
        let how = ended ? (forced ? " (ended with a signal)" : "") : (remove ? " (wasn't running)" : " (wasn't running; pane closed)")
        logAgent(callerName, inbound: true, "claudedeck close · " + (byItself ? "itself" : session.name) + how
                 + (remove ? "; removed from the list (transcript kept)" : ""))
        if ended || remove { notifyStarter(of: session, by: caller, callerName: callerName, removed: remove, ended: ended) }
        if remove {
            removeSession(session.id, userInitiated: false)
        } else if deck.panes.contains(session.id) {
            // Like the pane's close button; the owner's selection only moves if it was this one.
            mutate(userInitiated: false) { $0.closePane(session.id) }
        }
        onCountsChanged?()
        if deck.cliQueue.contains(where: { $0.status == .queued }) { drainCLIQueueSoon() }
    }

    /// A note for the session that started `session` (when that's a Claude session other than the
    /// caller), saying it was closed and/or removed.
    private func notifyStarter(of session: DeckSession, by caller: UUID, callerName: String, removed: Bool, ended: Bool) {
        guard let parent = session.startedBy, parent != caller, deck.session(parent)?.kind == .claude else { return }
        let byItself = caller == session.id
        let text: String
        switch (byItself, ended, removed) {
        case (true, _, true):
            text = String(localized: "\(session.name), a session this one started, closed itself and was removed from the list.")
        case (true, _, false):
            text = String(localized: "\(session.name), a session this one started, closed itself.")
        case (false, true, true):
            text = String(localized: "\(callerName) closed and removed \(session.name), a session this one started.")
        case (false, false, true):
            text = String(localized: "\(callerName) removed \(session.name), a session this one started, from the list.")
        case (false, _, false):
            text = String(localized: "\(callerName) closed \(session.name), a session this one started.")
        }
        receiveNote(requestID: nil, sessionID: parent, agent: removed ? "claudedeck remove" : "claudedeck close", text: text)
    }
}
