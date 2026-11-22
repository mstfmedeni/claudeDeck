import ClaudeDeckCore
import Foundation

/// `claudedeck compact [ID|self]`: `/compact` is typed into a Claude session, the way the owner
/// would. A session compacts itself when its context runs low (after updating docs/HANDOFF.md),
/// and a lead may compact the sessions it started (`mayCompact`: the `close` chain). For itself,
/// and for a session that is working, it waits until the current turn is over (`compactLimit`,
/// then it is given up, logged); a session waiting on a permission or a question is `409 blocked`.
/// Needs only the session CLI (no setting); every compact goes to the Activity Log.
/// Contract: docs/agents.md.
extension AppModel {
    func cliCompact(_ caller: UUID, ref: String, json: Bool) -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let target: DeckSession
        switch cliCloseTarget(ref, caller: caller) {
        case .failure(let refusal): return refusal.response
        case .success(let session): target = session
        }
        let id = target.id
        let label = id == caller ? "self" : "· \(target.name)"
        switch SessionCLI.mayCompact(caller: caller, target: id, targetKind: target.kind,
                                     startedBy: startedByMap(), openedBy: openedByMap()) {
        case .allowed:
            break
        case .notClaude:
            return SessionCLI.failure(400, "not_claude", exit: .usage)
        case .notYours:
            logAgent(callerName, inbound: true, "claudedeck compact \(label): refused (not started by this session)", ok: false)
            return SessionCLI.failure(403, "not_yours", exit: .refused)
        }
        // Watched read-only in another app's session helper: it can't be typed into from here.
        if terminals.readOnlySessions.contains(id) {
            logAgent(callerName, inbound: true, "claudedeck compact \(label): refused (read-only)", ok: false)
            return SessionCLI.failure(409, "read_only", exit: .failed)
        }
        guard terminals.isRunning(id) else {
            logAgent(callerName, inbound: true, "claudedeck compact \(label): refused (not running)", ok: false)
            return SessionCLI.failure(409, "not_running", exit: .failed)
        }
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            logAgent(callerName, inbound: true, "claudedeck compact \(label): refused (switching account)", ok: false)
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }
        // One deferred `/compact` per session is enough.
        if cliCompactsPending.contains(id) {
            return compactingAnswer(id, pending: true, toSelf: id == caller, json: json)
        }

        // Itself: the caller is inside this very command, so its turn can't be over yet.
        if id == caller {
            logAgent(callerName, inbound: true, "claudedeck compact self: compacts once the current turn is over")
            compactLater(id, name: target.name, by: callerName, requestedAt: Date())
            return compactingAnswer(id, pending: true, toSelf: true, json: json)
        }
        switch SessionCLI.compactTiming(cliProgress(id)) {
        case .blocked:
            logAgent(callerName, inbound: true, "claudedeck compact \(label): refused (waits on a permission or a question)", ok: false)
            return SessionCLI.failure(409, "blocked", exit: .blocked)
        case .afterTurn:
            logAgent(callerName, inbound: true, "claudedeck compact \(label): compacts once its current turn is over")
            compactLater(id, name: target.name, by: callerName, requestedAt: Date())
            return compactingAnswer(id, pending: true, toSelf: false, json: json)
        case .now:
            logAgent(callerName, inbound: true, "claudedeck compact \(label): /compact typed")
            // Right away, so a `wait` that follows doesn't see the idle from before the typing.
            cli.sentAt[id] = Date()
            Task { @MainActor [weak self] in await self?.typeCompact(id) }
            return compactingAnswer(id, pending: false, toSelf: false, json: json)
        }
    }

    private func compactingAnswer(_ id: UUID, pending: Bool, toSelf isSelf: Bool, json: Bool) -> AgentHTTPResponse {
        let text = pending ? (isSelf ? "compacting after this turn" : "compacting after its turn") : "compacting"
        return SessionCLI.answer(200, SessionCLICompacting(id: id, pending: pending), text: text, exit: .ok, json: json)
    }

    /// Like `close self`: waits for the turn to end (a hook state newer than the request saying
    /// idle), then types `/compact`. Given up when the session ends or after `compactLimit` (logged).
    private func compactLater(_ id: UUID, name: String, by callerName: String, requestedAt: Date) {
        cliCompactsPending.insert(id)
        Task { @MainActor [weak self] in
            // Time for the HTTP answer to reach the command.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            defer { self.cliCompactsPending.remove(id) }
            let deadline = ContinuousClock.now + .seconds(Int(SessionCLI.compactLimit))
            while ContinuousClock.now < deadline {
                guard self.terminals.isRunning(id), self.deck.session(id) != nil else {
                    self.logAgent(callerName, inbound: true, "claudedeck compact · \(name): given up, the session stopped", ok: false)
                    return
                }
                // Never in the middle of a move to another account: wait until it's back up.
                if !self.switchingAccounts.contains(id), !self.accountSwitchPending(id) {
                    let state = Self.stateName(self.status(of: id).display)
                    let progress = SessionCLI.claudeProgress(state: state, updatedAt: self.hookStatuses[id]?.updatedAt,
                                                             sentAt: requestedAt)
                    if progress == .finished(0) {
                        await self.typeCompact(id)
                        self.logAgent(callerName, inbound: true, "claudedeck compact · \(name): /compact typed after the turn")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.logAgent(callerName, inbound: true, "claudedeck compact · \(name): given up, the turn didn't end in \(Int(SessionCLI.compactLimit / 60)) minutes", ok: false)
        }
    }

    /// Types `/compact` into an idle Claude: Ctrl+C first clears a draft in the prompt (as
    /// `typeExit` does), otherwise "/compact" would be appended to it and sent as a message.
    /// `wait` then counts it as working until Claude is idle again.
    func typeCompact(_ id: UUID) async {
        terminals.type("\u{3}", into: id)
        try? await Task.sleep(for: .milliseconds(200))
        guard terminals.isRunning(id) else { return }
        cli.sentAt[id] = Date()
        terminals.type("/compact\r", into: id)
    }
}
