import ClaudeDeckCore
import Foundation

/// `claudedeck resume ID [--prompt TEXT] [--queue]`: a stopped Claude session the caller started
/// (directly or through sessions it started, the `close` chain) runs again with its conversation
/// (`claude --resume`), keeping its ClaudeDeck id, so `send`, `wait` and `decide` answers keep
/// reaching it. One a session removed from the list comes back from its tombstone
/// (SessionCLIResume.swift) while `claude --resume` can still find its transcript. Behind
/// "Sessions may add projects and start Claude sessions", under the running cap, the rate limit
/// and the Mac's load like `new`.
///
/// Automatic resume (Settings › Agents, on by default): a `send` from a session that may resume
/// it, or the owner's answer to its `decide` question, resumes a stopped Claude session a session
/// closed (never one the owner stopped) and gives it that text as its first message; with no room
/// it waits in the start queue and the text waits in the session's own queue.
/// Contract: docs/agents.md.
extension AppModel {
    // MARK: The command

    func cliResume(_ caller: UUID, ref: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        guard deck.settings.sessionsMayStartSessions else {
            logAgent(callerName, inbound: true, "claudedeck resume \(ref): refused (the setting is off)", ok: false)
            return SessionCLI.failure(403, "setting_off", exit: .refused)
        }
        let prompt = (form["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count <= SessionCLI.maxText else { return SessionCLI.failure(400, "too_long", exit: .usage) }
        let id: UUID
        switch cliResumeTarget(ref, caller: caller) {
        case .failure(let refusal): return refusal.response
        case .success(let found): id = found
        }
        let removed = deck.session(id) == nil
        let name = deck.session(id)?.name ?? deck.tombstone(id)?.name ?? ""
        let check = SessionCLI.mayResume(caller: caller, target: id, targetKind: deck.session(id)?.kind ?? .claude,
                                         running: isRunningForResume(id), resumable: isResumable(id),
                                         startedBy: resumeStartedByMap(), openedBy: openedByMap(), settingOn: true)
        if let refusal = check.response {
            logAgent(callerName, inbound: true, "claudedeck resume · \(name): refused (\(SessionCLI.errorCode(of: refusal) ?? "refused"))", ok: false)
            return refusal
        }
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }
        if restartingSessions.contains(id) { return SessionCLI.failure(409, "busy", exit: .failed) }

        let queue = form["queue"] == "1"
        // Already waiting to resume (an earlier `--queue`, or a message for it): that entry; the
        // prompt waits in the session's own queue behind its first message.
        if let waiting = deck.cliQueue.first(where: { $0.status == .queued && $0.resumeSessionID == id }), queue {
            if !prompt.isEmpty { queueBehind(prompt, for: id, from: caller) }
            let position = SessionCLI.queuePosition(waiting.id, in: deck.cliQueue) ?? 1
            let queued = SessionCLIQueued(queueId: waiting.id, position: position, reason: waiting.reason ?? "queued")
            return SessionCLI.answer(200, queued, text: waiting.id, exit: .ok, json: json)
        }
        await systemLoad.sampleIfStale()
        switch admitResume(by: caller, queue: queue) {
        case .refuse(let code):
            logAgent(callerName, inbound: true, "claudedeck resume · \(name): refused (\(code))", ok: false)
            return SessionCLI.failure(429, code, exit: .refused)
        case .queue(let reason):
            var request = resumeRequest(id, caller: caller, callerName: callerName, prompt: prompt)
            request.auto = nil
            return cliEnqueue(request, reason: reason, json: json)
        case .now:
            break
        }
        switch startResume(id, prompt: prompt, from: caller) {
        case .failure(let refusal):
            logAgent(callerName, inbound: true, "claudedeck resume · \(name): not resumed (\(SessionCLI.errorCode(of: refusal.response) ?? "failed"))", ok: false)
            return refusal.response
        case .success(let resumed):
            logAgent(callerName, inbound: true, "claudedeck resume · \(resumed.name)" + (removed ? " (restored to the list)" : "")
                     + (prompt.isEmpty ? "" : " (with a prompt)"))
            return SessionCLI.answer(200, resumed, text: SessionCLI.resumedText(restored: resumed.restored), exit: .ok, json: json)
        }
    }

    /// A session in the deck (or a started queue id, like `close`), else a removed one by its id
    /// or a unique prefix of it.
    func cliResumeTarget(_ ref: String, caller: UUID) -> Result<UUID, AgentHTTPRequestRefusal> {
        switch cliCloseTarget(ref, caller: caller) {
        case .success(let session): return .success(session.id)
        case .failure(let refusal):
            guard !SessionCLI.isQueueID(ref), SessionCLI.errorCode(of: refusal.response) == "unknown_session" else { return .failure(refusal) }
        }
        switch SessionCLI.target(ref, caller: caller, sessions: deck.removedSessions.map(\.id)) {
        case .found(let id) where deck.tombstone(id) != nil: return .success(id)
        case .ambiguous: return .failure(.init(SessionCLI.failure(400, "ambiguous", exit: .usage)))
        default: return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown)))
        }
    }

    /// `startedByMap` with the removed sessions' starters, for the ownership chain.
    func resumeStartedByMap() -> [UUID: UUID] {
        var map = startedByMap()
        for tombstone in deck.removedSessions {
            if let parent = tombstone.startedBy, map[tombstone.id] == nil { map[tombstone.id] = parent }
        }
        return map
    }

    private func isRunningForResume(_ id: UUID) -> Bool {
        deck.session(id) != nil && (terminals.isRunning(id) || terminals.readOnlySessions.contains(id))
    }

    /// `claude --resume` would find its conversation (a removed one: and its project is still here).
    func isResumable(_ id: UUID) -> Bool {
        deck.session(id) != nil ? deck.resumableID(for: id) != nil : deck.tombstoneResumable(id)
    }

    /// The Mac's load, then the running cap and the rate limit of `key` (the caller; for the
    /// owner's answer, the session itself).
    private func admitResume(by key: UUID, queue: Bool) -> SessionCLI.Admission {
        let load = LoadThrottle.start(level: systemLoad.level, busyAction: deck.settings.load.busyAction,
                                      enabled: deck.settings.load.throttle, queue: queue)
        var refusal: String?
        if load == .allow, let refused = SessionCLI.admitStart(caller: key, runningStarted: cliRunningStarted,
                                                               cap: deck.settings.maxStartedSessions, book: &cli) {
            refusal = SessionCLI.errorCode(of: refused) ?? "too_many_starts"
        }
        return SessionCLI.admission(load: load, heldBy: systemLoad.level == .busy ? "busy" : "overloaded",
                                    startRefusal: refusal, queue: queue)
    }

    private func resumeRequest(_ id: UUID, caller: UUID, callerName: String, prompt: String) -> CLIQueuedStart {
        let projectID = deck.session(id)?.projectID ?? deck.tombstone(id)?.projectID ?? UUID()
        let name = deck.session(id)?.name ?? deck.tombstone(id)?.name ?? ""
        var request = CLIQueuedStart(id: SessionCLI.newQueueID(), caller: caller, callerName: callerName, projectID: projectID,
                                     name: name, prompt: prompt, worktree: "", skill: nil, options: ClaudeLaunchOptions())
        request.resumeSessionID = id
        return request
    }

    /// Resumes `id` now: a removed one is put back in the list first. `prompt` goes first in its
    /// queue, typed at its first "your turn" (the messages already queued follow, one per turn).
    func startResume(_ id: UUID, prompt: String, from caller: UUID?) -> Result<SessionCLIResumed, AgentHTTPRequestRefusal> {
        var restored = false
        if deck.session(id) == nil {
            guard deck.tombstoneResumable(id) else { return .failure(.init(SessionCLI.failure(409, "not_resumable", exit: .failed))) }
            mutate(userInitiated: false) { $0.restoreTombstone(id) }
            guard deck.session(id) != nil else { return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown))) }
            restored = true
        }
        guard let session = deck.session(id), session.kind == .claude else {
            return .failure(.init(SessionCLI.failure(400, "not_claude", exit: .usage)))
        }
        guard !terminals.isRunning(id) else { return .failure(.init(SessionCLI.failure(409, "running", exit: .failed))) }
        guard deck.resumableID(for: id) != nil else { return .failure(.init(SessionCLI.failure(409, "not_resumable", exit: .failed))) }
        if !prompt.isEmpty { queueFirst(prompt, for: id, from: caller) }
        // It picks up with its first message, never the "continue" one a session cut off
        // mid-turn would get.
        mutate(userInitiated: false) { $0.updateSession(id) { $0.busyAtQuit = false } }
        launch(id, resume: true)
        // `wait` and `send` now concern the new process.
        cli.commandExits[id] = nil
        cli.sentAt[id] = nil
        onCountsChanged?()
        return .success(SessionCLIResumed(id: id, name: session.name, restored: restored))
    }

    /// First in the session's queue: the message a resume was for.
    private func queueFirst(_ text: String, for id: UUID, from caller: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if caller != nil { rememberAgentPrompt(trimmed, in: id) }
        mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.insert(QueuedPrompt(text: trimmed), at: 0) } }
    }

    /// Behind what's queued: a message for a session that is already waiting to resume.
    private func queueBehind(_ text: String, for id: UUID, from caller: UUID?) {
        if caller != nil { rememberAgentPrompt(text, in: id) }
        enqueue(id, text: text)
    }

    // MARK: Automatic resume

    enum AutoResumeOutcome: Equatable {
        /// Resuming now; the text is its first message.
        case resumed
        /// Waiting in the start queue (this id); the text waits in the session's queue.
        case queued(String)
        /// Not resumed (`SessionCLI.AutoResumeCheck`'s reason, or why the start failed).
        case notResumed(String)
    }

    /// Whether a message or an answer for `id` would resume it (setting, kind, stopped by a
    /// session, conversation still there).
    func autoResumeCheck(_ id: UUID) -> SessionCLI.AutoResumeCheck {
        let enabled = deck.settings.autoResumeOnDelivery
        if let session = deck.session(id) {
            return SessionCLI.autoResume(enabled: enabled, kind: session.kind, running: isRunningForResume(id),
                                         stoppedBy: session.stoppedBy, resumable: deck.resumableID(for: id) != nil)
        }
        guard let tombstone = deck.tombstone(id) else { return .notResumable }
        return SessionCLI.autoResume(enabled: enabled, kind: .claude, running: false, stoppedBy: tombstone.stoppedBy,
                                     resumable: deck.tombstoneResumable(id))
    }

    /// Resumes a stopped session for `text` (a `send` from `caller`, or the owner's answer when
    /// `caller` is nil) when `autoResumeCheck` allows it: now when there's room, else through
    /// the start queue. The text then waits in the session's queue (first), so nothing is lost
    /// whatever the start queue does.
    func autoResume(_ id: UUID, text: String, caller: UUID?, callerName: String, what: String) -> AutoResumeOutcome {
        let check = autoResumeCheck(id)
        guard check == .resume else { return .notResumed(check.rawValue) }
        if switchingAccounts.contains(id) || accountSwitchPending(id) || restartingSessions.contains(id) { return .notResumed("busy") }
        // A removed one comes back to the list (stopped) so its queue can hold the text.
        if deck.session(id) == nil {
            mutate(userInitiated: false) { $0.restoreTombstone(id) }
            guard deck.session(id) != nil else { return .notResumed("not_resumable") }
        }
        let name = deck.session(id)?.name ?? ""
        if let waiting = deck.cliQueue.first(where: { $0.status == .queued && $0.resumeSessionID == id }) {
            queueBehind(text, for: id, from: caller)
            logAgent(callerName, inbound: true, "\(what) · \(name): waits with its queued resume \(waiting.id)")
            return .queued(waiting.id)
        }
        switch admitResume(by: caller ?? id, queue: true) {
        case .refuse(let code):
            return .notResumed(code)
        case .queue(let reason):
            var request = resumeRequest(id, caller: caller ?? id, callerName: callerName, prompt: "")
            request.auto = true
            if SessionCLI.admitQueued(caller: request.caller, queue: deck.cliQueue) != nil {
                // The start queue is full: the text still waits in its queue for the next start.
                queueBehind(text, for: id, from: caller)
                logAgent(callerName, inbound: true, "\(what) · \(name): queued for the session (the start queue is full)", ok: false)
                return .notResumed("too_many_queued")
            }
            queueFirst(text, for: id, from: caller)
            mutate(userInitiated: false) { deck in
                deck.cliQueue = SessionCLI.pruneQueue(deck.cliQueue)
                deck.cliQueue.append(request)
            }
            logAgent(callerName, inbound: true, "\(what) · \(name): resume queued \(request.id) (\(reason))")
            drainCLIQueueSoon()
            return .queued(request.id)
        case .now:
            switch startResume(id, prompt: text, from: caller) {
            case .failure(let refusal):
                let code = SessionCLI.errorCode(of: refusal.response) ?? "not_resumed"
                logAgent(callerName, inbound: true, "\(what) · \(name): not resumed (\(code))", ok: false)
                return .notResumed(code)
            case .success:
                logAgent(callerName, inbound: true, "\(what) · \(name): resumed (stopped by a session) with it as its first message")
                return .resumed
            }
        }
    }

    /// `send` to a removed session: resumed for the text when it may be (else the usual 404).
    func cliSendToRemoved(_ caller: UUID, ref: String, form: [String: String], json: Bool) -> AgentHTTPResponse? {
        let text = form["text"] ?? ""
        guard form["enter"] != "0", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= SessionCLI.maxText,
              !SessionCLI.isQueueID(ref), case .found(let id) = SessionCLI.target(ref, caller: caller, sessions: deck.removedSessions.map(\.id)),
              deck.tombstone(id) != nil else { return nil }
        return cliSendResume(caller, to: id, text: text, json: json)
    }

    /// `send` to a stopped Claude session: resumed with the text as its first message when the
    /// caller may resume it and the automatic resume allows it; nil leaves the usual answer.
    func cliSendResume(_ caller: UUID, to id: UUID, text: String, json: Bool) -> AgentHTTPResponse? {
        let sender = deck.session(caller)
        guard SessionCLI.sendMayResume(caller: caller, callerOpenedBy: sender?.openedBy, target: id, startedBy: resumeStartedByMap(),
                                       openedBy: openedByMap(), startSetting: deck.settings.sessionsMayStartSessions) else { return nil }
        let senderName = sender?.name ?? "claudedeck"
        switch autoResume(id, text: text, caller: caller, callerName: senderName, what: "claudedeck send") {
        case .resumed:
            let name = deck.session(id)?.name ?? ""
            return SessionCLI.answer(200, SessionCLISent(delivered: "resumed"),
                                     text: "resumed: \(name) was stopped and resumes with this as its first message", exit: .ok, json: json)
        case .queued(let queueID):
            return SessionCLI.answer(200, SessionCLISent(delivered: "resume_queued", queueId: queueID),
                                     text: "resume_queued: it resumes once there's room (\(queueID)); the text waits in its queue", exit: .ok, json: json)
        case .notResumed("too_many_queued"):
            return SessionCLI.answer(200, SessionCLISent(delivered: "queued"),
                                     text: "queued: it's stopped and the start queue is full; the text waits for its next start", exit: .ok, json: json)
        case .notResumed:
            return nil
        }
    }

    /// The owner's answer (or a change, or a dismissal) for a decision whose session is stopped
    /// or removed: resumed with it as its first message when it may be. nil: deliver as before.
    func deliverDecisionByResume(_ id: UUID, text: String, decision: String) -> String? {
        guard deck.session(id).map({ $0.kind == .claude }) ?? (deck.tombstone(id) != nil) else { return nil }
        switch autoResume(id, text: text, caller: nil, callerName: deck.session(id)?.name ?? deck.tombstone(id)?.name ?? "ClaudeDeck",
                          what: "decision \(decision)") {
        case .resumed: return "resumed"
        case .queued: return "resume_queued"
        case .notResumed("too_many_queued"): return "queued"
        case .notResumed: return nil
        }
    }

    // MARK: The start queue

    /// A queued resume whose turn came (`drainCLIQueue`): true when it's done with (started or
    /// failed), false when the running cap is full and the queue should stop for now.
    func drainResume(_ entry: CLIQueuedStart, target id: UUID) -> Bool {
        let auto = entry.auto == true
        if auto ? !deck.settings.autoResumeOnDelivery : (!deck.settings.sessionsMayStartSessions || !deck.settings.sessionCLIEnabled) {
            finishResumeQueued(entry, .failed, reason: "setting_off")
            return true
        }
        if !auto, deck.session(entry.caller) == nil { finishResumeQueued(entry, .failed, reason: "caller_gone"); return true }
        guard deck.session(id) != nil || deck.tombstone(id) != nil else {
            finishResumeQueued(entry, .failed, reason: "unknown_session")
            return true
        }
        // Started meanwhile (the owner, or another resume): its prompt goes to its queue.
        if isRunningForResume(id) {
            if !entry.prompt.isEmpty { queueBehind(entry.prompt, for: id, from: auto ? nil : entry.caller) }
            finishResumeQueued(entry, .started, reason: nil)
            return true
        }
        if auto {
            let check = autoResumeCheck(id)
            guard check == .resume else { finishResumeQueued(entry, .failed, reason: check.rawValue); return true }
        }
        if switchingAccounts.contains(id) || accountSwitchPending(id) || restartingSessions.contains(id) { return true }
        if let refusal = SessionCLI.admitStart(caller: entry.caller, runningStarted: cliRunningStarted,
                                               cap: deck.settings.maxStartedSessions, book: &cli) {
            return SessionCLI.errorCode(of: refusal) != "too_many_running"
        }
        switch startResume(id, prompt: entry.prompt, from: auto ? nil : entry.caller) {
        case .success(let resumed):
            finishResumeQueued(entry, .started, reason: nil)
            logAgent(entry.callerName, inbound: true, "claudedeck queue · \(entry.id) resumed \(resumed.name)"
                     + (resumed.restored ? " (restored to the list)" : ""))
        case .failure(let refusal):
            finishResumeQueued(entry, .failed, reason: SessionCLI.errorCode(of: refusal.response) ?? "not_resumed")
        }
        return true
    }

    private func finishResumeQueued(_ entry: CLIQueuedStart, _ status: CLIQueuedStart.Status, reason: String?) {
        mutate(userInitiated: false) { deck in
            guard let index = deck.cliQueue.firstIndex(where: { $0.id == entry.id }) else { return }
            deck.cliQueue[index].status = status
            deck.cliQueue[index].reason = reason
            deck.cliQueue[index].finishedAt = Date()
            if status == .started { deck.cliQueue[index].sessionID = entry.resumeSessionID }
        }
        if status != .started {
            logAgent(entry.callerName, inbound: true, "claudedeck queue · \(entry.id) \(status.rawValue) (\(reason ?? ""))", ok: status != .failed)
        }
    }

    /// On launch and now and then: removed sessions older than 30 days are forgotten.
    func pruneTombstones() {
        let pruned = SessionCLI.pruneTombstones(deck.removedSessions)
        if pruned != deck.removedSessions { mutate(userInitiated: false) { $0.removedSessions = pruned } }
    }
}
