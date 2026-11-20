import ClaudeDeckCore
import Foundation

/// `claudedeck` in the terminals ClaudeDeck starts (SessionCLI): the script, each session's
/// environment and token, and the `/v1/cli` routes. Off in Settings › Agents: no environment, the
/// script isn't written, and the routes answer 404.
extension AppModel {
    /// Next to `claudedeck-ask`.
    var cliScriptURL: URL { askScriptURL.deletingLastPathComponent().appending(path: "claudedeck") }

    /// Where the commands `claudedeck open` starts leave their exit codes.
    var cliRunDirectory: URL { DeckDataStore.default().url.deletingLastPathComponent().appending(path: "cli-runs") }

    /// Written on launch and when the setting is turned on, so it matches this version.
    func installCLIScript() {
        guard deck.settings.sessionCLIEnabled else { return }
        let url = cliScriptURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(SessionCLI.script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            logAgent("ClaudeDeck", inbound: false, "couldn't write claudedeck: \(error.localizedDescription)", ok: false)
        }
    }

    /// What a terminal gets while the command-line tool is on: its session id, its own token
    /// (scoped: a terminal another session opened may only look), where to post, and the command
    /// (also on PATH; Claude Code's Bash tool may reset PATH, the absolute path stays).
    func cliEnvironment(for id: UUID) -> [String: String] {
        guard deck.settings.sessionCLIEnabled, let session = deck.session(id) else { return [:] }
        let token = cli.token(for: id, scopes: SessionCLI.scopes(openedBy: session.openedBy))
        let bin = cliScriptURL.deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            SessionCLI.Env.session: id.uuidString,
            SessionCLI.Env.token: token,
            SessionCLI.Env.url: "http://127.0.0.1:\(deck.settings.agentAPIPort)\(SessionCLI.prefix)",
            SessionCLI.Env.command: cliScriptURL.path,
            "PATH": bin + ":" + path,
        ]
    }

    // MARK: Routes

    /// `/v1/cli/…`, authorized by a session's own token (never the API's), within its scopes.
    func handleSessionCLI(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        let caller: UUID, route: SessionCLI.Route
        switch SessionCLI.resolve(request, book: cli) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): (caller, route) = resolved
        }
        guard deck.session(caller) != nil else { return SessionCLI.failure(404, "unknown_session", exit: .unknown) }
        guard request.body.count <= 256 * 1024 else { return SessionCLI.failure(413, "too_large", exit: .usage) }
        let form = request.method == "GET" ? request.query : SessionCLI.form(request.body)
        let json = form["format"] == "json"
        switch route {
        case .list:
            return cliList(caller, json: json)
        case .open:
            return cliOpen(caller, form: form, json: json)
        case .send(let ref):
            return target(ref, caller: caller).flatMapResponse { cliSend(caller, to: $0, form: form, json: json) }
        case .capture(let ref):
            return target(ref, caller: caller).flatMapResponse { cliCapture($0, form: form, json: json) }
        case .wait(let ref) where SessionCLI.isQueueID(ref):
            return await cliWaitQueued(caller, id: ref, form: form, json: json)
        case .wait(let ref):
            switch target(ref, caller: caller) {
            case .failure(let refusal): return refusal.response
            case .success(let session): return await cliWait(caller, for: session, form: form, json: json)
            }
        case .notify:
            return cliNotify(caller, form: form, json: json)
        case .ask:
            return cliAsk(caller, form: form, json: json)
        case .projects:
            return cliProjects(json: json)
        case .addProject:
            return cliAddProject(caller, form: form, json: json)
        case .newSession(let ref):
            return await cliNewSession(caller, project: ref, form: form, json: json)
        case .server(let command):
            return await cliServer(caller, command: command, method: request.method, form: form, json: json)
        case .presets:
            return cliPresets(json: json)
        case .showPreset(let ref):
            return cliShowPreset(caller, project: ref, json: json)
        case .setPreset(let ref):
            return cliSetPreset(caller, project: ref, form: form, json: json)
        case .queue:
            return cliQueueList(caller, json: json)
        case .queueItem(let id):
            return cliQueueShow(caller, id: id, json: json)
        case .cancelQueued(let id):
            return cliQueueCancel(caller, id: id, json: json)
        case .waitMany:
            return await cliWaitMany(caller, form: form, json: json)
        case .decide:
            return cliDecide(caller, form: form, json: json)
        case .decisions:
            return cliDecisions(form: form, json: json)
        case .decision(let id):
            return cliDecision(id, json: json)
        case .cancelDecision(let id):
            return cliCancelDecision(caller, id: id, form: form, json: json)
        case .accounts:
            return cliAccounts(caller, json: json)
        case .currentAccount:
            return cliCurrentAccount(caller, json: json)
        case .switchAccount:
            return await cliSwitchAccount(caller, form: form, json: json)
        case .simList, .simAcquire, .simRelease:
            return await cliSimulators(caller, route: route, form: form, json: json)
        case .usage:
            return await cliUsage(form: form, json: json)
        case .status(let ref):
            return target(ref, caller: caller).flatMapResponse { cliStatus($0, json: json) }
        case .close(let ref):
            return await cliClose(caller, ref: ref, form: form, json: json)
        case .remove(let ref):
            return cliRemove(caller, ref: ref, json: json)
        case .load:
            return cliLoad(json: json)
        case .slotAcquire(let kind):
            return await cliSlotAcquire(caller, kind: kind, form: form, json: json)
        case .slotRelease(let kind):
            return cliSlotRelease(caller, kind: kind, form: form, json: json)
        }
    }

    private func target(_ ref: String, caller: UUID) -> Result<DeckSession, AgentHTTPRequestRefusal> {
        // A queue id (`new --queue`) names its session once it started.
        if SessionCLI.isQueueID(ref) {
            switch cliQueuedSession(ref) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let id):
                if let session = deck.session(id) { return .success(session) }
                return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown)))
            }
        }
        switch SessionCLI.target(ref, caller: caller, sessions: deck.sessions.map(\.id)) {
        case .found(let id):
            if let session = deck.session(id) { return .success(session) }
            return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown)))
        case .unknown: return .failure(.init(SessionCLI.failure(404, "unknown_session", exit: .unknown)))
        case .ambiguous: return .failure(.init(SessionCLI.failure(400, "ambiguous", exit: .usage)))
        }
    }

    private func cliList(_ caller: UUID, json: Bool) -> AgentHTTPResponse {
        let panes = deck.visiblePanes
        let infos = deck.sessions.map { session in
            let status = status(of: session.id)
            return SessionCLIInfo(id: session.id, name: session.name, kind: session.kind == .shell ? "terminal" : "claude",
                                  state: cliState(session), detail: status.detail, projectId: session.projectID,
                                  project: deck.project(session.projectID)?.name ?? "", pane: panes.firstIndex(of: session.id).map { $0 + 1 },
                                  isSelf: session.id == caller, openedBySelf: session.openedBy == caller, openedBy: session.openedBy,
                                  account: session.kind == .claude ? accountID(of: session) : nil,
                                  limitResetsAt: usageLimitHits[session.id] == nil ? nil : usageLimitReset(for: session.id))
        }
        return SessionCLI.answer(200, infos, text: SessionCLI.listText(infos), exit: .ok, json: json)
    }

    /// A Claude session's state name; a terminal's: `running`, `idle` (at its prompt), `failed`,
    /// `blocked` (its program waits for the user; Program Status) or `stopped`.
    /// A Claude session at its usage limit: `switching_account` while it moves (or is about to)
    /// to another account, `limit_reached` while it waits for the reset.
    func cliState(_ session: DeckSession) -> String {
        guard session.kind == .shell else {
            if terminals.isRunning(session.id) || switchingAccounts.contains(session.id) {
                if accountSwitchPending(session.id) { return "switching_account" }
                if usageLimitHits[session.id] != nil { return "limit_reached" }
            }
            return Self.stateName(status(of: session.id).display)
        }
        switch cliProgress(session.id) {
        case .running: return "running"
        case .finished: return "idle"
        case .failed: return "failed"
        case .blocked(let state): return state
        case .stopped: return "stopped"
        case .limited: return "limit_reached"
        }
    }

    /// `claudedeck status ID`: state, who started it, the stall watch, the simulators it holds.
    private func cliStatus(_ session: DeckSession, json: Bool) -> AgentHTTPResponse {
        let info = SessionCLIStatus(id: session.id, name: session.name, kind: session.kind == .shell ? "terminal" : "claude",
                                    state: cliState(session), detail: status(of: session.id).detail,
                                    project: deck.project(session.projectID)?.name ?? "", startedBy: session.startedBy,
                                    stall: stallStatus(session.id), simulators: simHolds.held(by: session.id).map(\.udid),
                                    slots: systemLoad.slots.held(by: session.id).map(\.id))
        return SessionCLI.answer(200, info, text: info.text, exit: .ok, json: json)
    }

    /// `claudedeck usage [--project P]`: each project's share of the 5-hour and weekly windows.
    private func cliUsage(form: [String: String], json: Bool) async -> AgentHTTPResponse {
        await usage.refresh()
        let monitor = ProjectUsageMonitor.shared
        await monitor.refresh(model: self, maxAge: 30)
        var shares = monitor.shares
        let ref = (form["project"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ref.isEmpty {
            switch SessionCLI.project(ref, callerProject: nil, projects: deck.projects) {
            case .found(let id): shares = shares.filter { $0.projectID == id }
            case .unknown: return SessionCLI.failure(404, "unknown_project", exit: .unknown)
            case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
            }
        }
        let plan = usage.state.usage
        return SessionCLI.answer(200, SessionCLIUsage(usage: plan, projects: shares),
                                 text: ProjectUsageReport.text(shares, usage: plan), exit: .ok, json: json)
    }

    private func cliOpen(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard let opener = deck.session(caller), let project = deck.project(opener.projectID) else {
            return SessionCLI.failure(404, "unknown_session", exit: .unknown)
        }
        let splitName = (form["split"] ?? "").isEmpty ? "right" : form["split"]!
        guard let split = SessionCLI.Split(rawValue: splitName) else { return SessionCLI.failure(400, "bad_split", exit: .usage) }
        let command = (form["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.count <= SessionCLI.maxText else { return SessionCLI.failure(400, "too_long", exit: .usage) }
        var folder = opener.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? project.path
        if let cwd = form["cwd"], !cwd.isEmpty {
            var isFolder: ObjCBool = false
            guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
                return SessionCLI.failure(400, "bad_cwd", exit: .usage)
            }
            folder = cwd
        }
        let given = (form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !given.isEmpty ? String(given.prefix(80))
            : command.isEmpty ? deck.nextShellName(for: project) : "\(project.name) · \(command.prefix(40))"
        var created: DeckSession?
        mutate(userInitiated: false) { deck in
            created = deck.addSession(to: project.id, kind: .shell, name: name)
            guard let id = created?.id else { return }
            deck.updateSession(id) {
                $0.openedBy = caller
                $0.workingDirectory = folder
                // Shown in the sidebar and run again when the user restarts it; never on launch.
                $0.startupCommand = command.isEmpty ? nil : command
                $0.autoStart = false
            }
        }
        guard let id = created?.id else { return SessionCLI.failure(409, "not_started", exit: .failed) }

        var exitFile: URL?
        if !command.isEmpty {
            let file = cliRunDirectory.appending(path: "\(id.uuidString).exit")
            try? FileManager.default.createDirectory(at: cliRunDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            exitFile = file
            cli.exitFiles[id] = file
        }
        terminals.startShell(id: id, cwd: folder, programStatus: deck.showsProgramStatus(id), environment: cliEnvironment(for: id), command: exitFile == nil ? nil : command, exitFile: exitFile)

        // Beside the caller when it's on screen; the user's focus stays where it was.
        var shown = false
        let focused = deck.selectedSessionID
        mutate(userInitiated: false) { deck in
            deck.updateSession(id) { $0.isOpen = true }
            guard split != .none, deck.visiblePanes.contains(caller) else { return }
            shown = deck.openPane(id, besideOf: caller, before: split.before)
            if shown { deck.selectedSessionID = focused }
        }
        onCountsChanged?()
        logAgent(opener.name, inbound: true, "claudedeck open · \(name)")
        let opened = SessionCLIOpened(id: id, name: name, cwd: folder, command: command.isEmpty ? nil : command, shown: shown)
        return SessionCLI.answer(200, opened, text: id.uuidString, exit: .ok, json: json)
    }

    private func cliSend(_ caller: UUID, to target: DeckSession, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let text = form["text"] ?? ""
        // Text typed into Claude but never submitted just sits in its input box, so a Claude
        // session gets Return unless the caller says --no-enter; a plain terminal only with --enter.
        let enter = form["enter"] == "1" || (target.kind == .claude && form["enter"] != "0")
        guard text.count <= SessionCLI.maxText else { return SessionCLI.failure(400, "too_long", exit: .usage) }
        guard !text.isEmpty || enter else { return SessionCLI.failure(400, "bad_request", exit: .usage) }
        let sender = deck.session(caller)?.name ?? "claudedeck"
        let panes = deck.visiblePanes
        let delivery = SessionCLI.delivery(caller: caller, target: target.id, targetKind: target.kind, targetOpenedBy: target.openedBy,
                                           besideCaller: panes.contains(caller) && panes.contains(target.id),
                                           mayTypeIntoClaude: deck.settings.sessionsMayTypeIntoClaude, targetStartedBy: target.startedBy)
        switch delivery {
        case .refuse(let reason):
            return reason == "cannot_send_to_self"
                ? SessionCLI.failure(400, reason, exit: .usage) : SessionCLI.failure(403, reason, exit: .refused)
        case .note:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return SessionCLI.failure(400, "bad_request", exit: .usage) }
            guard cli.notices.allow(caller) else { return SessionCLI.failure(429, "too_many", exit: .refused) }
            let note = receiveNote(requestID: nil, sessionID: target.id, agent: sender, text: text)
            logAgent(sender, inbound: true, "claudedeck send → note (sessions may not type into Claude) · \(target.name)")
            return SessionCLI.answer(200, SessionCLISent(delivered: "note", noteId: note),
                                     text: "note: \(target.name) gets it as a note for the user (sessions may not type into Claude)", exit: .ok, json: json)
        case .type:
            guard terminals.isRunning(target.id) else { return SessionCLI.failure(409, "not_running", exit: .failed) }
            let delivered: String
            if target.kind == .claude {
                guard !status(of: target.id).display.isBlocked else { return SessionCLI.failure(409, "blocked", exit: .blocked) }
                if enter {
                    rememberAgentPrompt(text, in: target.id)
                    if typePrompt(text, into: target.id) != nil { return SessionCLI.failure(409, "blocked", exit: .blocked) }
                } else {
                    terminals.type(text, into: target.id)
                }
                logAgent(sender, inbound: true, "claudedeck send → Claude · \(target.name)")
                delivered = "claude"
            } else {
                terminals.timeOutput(of: target.id)
                terminals.type(text + (enter ? "\r" : ""), into: target.id)
                // What `wait` reports is now about the typed command, not the first one.
                if enter { cli.commandExits[target.id] = nil }
                delivered = "terminal"
            }
            if enter { cli.sentAt[target.id] = Date() }
            return SessionCLI.answer(200, SessionCLISent(delivered: delivered), text: "\(delivered): typed into \(target.name)", exit: .ok, json: json)
        }
    }

    private func cliCapture(_ target: DeckSession, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard let view = terminals.view(for: target.id) else { return SessionCLI.failure(409, "not_running", exit: .failed) }
        let last = form["lines"].flatMap(Int.init).map { min(max($0, 0), 10_000) }
        let screen = TerminalCapture.screen(of: view, scrollback: last ?? 1_000)
        let text = SessionCLI.text(of: screen.lines, last: last, trim: form["trim"] == "1")
        return SessionCLI.answer(200, SessionCLIScreen(id: target.id, text: text), text: text, exit: .ok, json: json)
    }

    /// Long poll: answers once the target stops running, or after at most `maxWaitWindow`
    /// seconds (the command asks again until its own timeout). Checks four times a second, and
    /// only while someone waits.
    func cliWait(_ caller: UUID, for target: DeckSession, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard target.id != caller else { return SessionCLI.failure(400, "cannot_wait_for_self", exit: .usage) }
        let window = min(SessionCLI.maxWaitWindow, max(0, form["timeout"].flatMap(Int.init) ?? SessionCLI.maxWaitWindow))
        let deadline = ContinuousClock.now + .seconds(window)
        while true {
            guard let session = deck.session(target.id) else { return SessionCLI.failure(404, "unknown_session", exit: .unknown) }
            let progress = cliProgress(target.id)
            if progress != .running || ContinuousClock.now >= deadline {
                let detail = status(of: target.id).detail
                let waited = SessionCLIWaited(progress, state: cliState(session), detail: detail)
                return SessionCLI.answer(200, waited, text: SessionCLI.waitText(progress, detail: detail), exit: progress.exit, json: json)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Where a session or terminal is, for `wait` and `list`.
    func cliProgress(_ id: UUID) -> SessionCLI.Progress {
        guard let session = deck.session(id) else { return .stopped }
        guard session.kind == .shell else {
            // The usage limit: moving to another account counts as running; waiting for the reset doesn't.
            if accountSwitchPending(id) { return .running }
            if usageLimitHits[id] != nil, terminals.isRunning(id) { return .limited(usageLimitReset(for: id)) }
            return SessionCLI.claudeProgress(state: Self.stateName(status(of: id).display), updatedAt: hookStatuses[id]?.updatedAt, sentAt: cli.sentAt[id])
        }
        if let file = cli.exitFiles[id], let text = try? String(contentsOf: file, encoding: .utf8),
           let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            cli.commandExits[id] = code
            cli.exitFiles[id] = nil
            try? FileManager.default.removeItem(at: file)
        }
        let running = terminals.isRunning(id)
        let guessed = SessionCLI.shellProgress(running: running, commandPending: cli.exitFiles[id] != nil,
                                               commandExit: cli.commandExits[id], processExit: cli.processExits[id],
                                               foregroundBusy: terminals.foregroundBusy(id), sentAt: cli.sentAt[id],
                                               lineEditing: terminals.lineEditing(id), lastOutput: terminals.lastOutput(of: id))
        // Program Status, when the terminal shows it: what the program says (blocked, its result).
        guard running, deck.showsProgramStatus(id), let program = terminals.programStatuses[id] else { return guessed }
        return SessionCLI.programProgress(program.state, exitCode: program.exitCode, fallback: guessed)
    }

    private func cliNotify(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let text = (form["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SessionCLI.failure(400, "bad_request", exit: .usage) }
        guard cli.notices.allow(caller) else { return SessionCLI.failure(429, "too_many", exit: .refused) }
        let name = deck.session(caller)?.name ?? ""
        logAgent(name, inbound: true, "claudedeck notify")
        guard deck.settings.notifications else {
            return SessionCLI.answer(200, ["delivered": "off"], text: "notifications are off in ClaudeDeck's settings", exit: .refused, json: json)
        }
        onSessionNotice?(caller, String(text.prefix(SessionCLI.maxNotice)))
        return SessionCLI.answer(200, ["delivered": "notification"], text: "notified", exit: .ok, json: json)
    }

    /// A question for the user (a note beside the caller, and a notification), or with an agent's
    /// name, for that agent under `claudedeck-ask`'s rules (the answer is a note too).
    private func cliAsk(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let question = (form["question"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= SessionCLI.maxText else { return SessionCLI.failure(400, "bad_request", exit: .usage) }
        let name = deck.session(caller)?.name ?? ""
        let agent = (form["agent"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty else {
            guard cli.notices.allow(caller) else { return SessionCLI.failure(429, "too_many", exit: .refused) }
            let note = receiveNote(requestID: nil, sessionID: caller, agent: "claudedeck ask", text: question)
            if deck.settings.notifications { onSessionNotice?(caller, String(question.prefix(SessionCLI.maxNotice))) }
            logAgent(name, inbound: true, "claudedeck ask → note")
            return SessionCLI.answer(200, SessionCLISent(delivered: "note", noteId: note),
                                     text: "note: the question is beside this session for the user; the answer comes as a message", exit: .ok, json: json)
        }
        switch AgentAsk.targets(agent, profiles: agents, registrations: deck.settings.agentRegistrations) {
        case .failure(let refusal):
            logAgent("Claude", inbound: false, "asked \(agent) · \(name): refused", ok: false)
            var response = refusal.response
            response.headers[SessionCLI.exitHeader] = String(SessionCLI.exit(status: response.status, header: nil).rawValue)
            return response
        case .success(let targets):
            guard askLimiter.allow(caller) else { return SessionCLI.failure(429, "too_many_asks", exit: .refused) }
            askAgents(targets.map(\.id), about: caller, request: String(question.prefix(AgentAsk.maxRequest)), event: .claudeAsk)
            let names = targets.map(\.name).joined(separator: ", ")
            return SessionCLI.answer(200, ["asked": names], text: "asked \(names): the answer comes to the user as a note", exit: .ok, json: json)
        }
    }
}

private extension Result where Success == DeckSession, Failure == AgentHTTPRequestRefusal {
    func flatMapResponse(_ body: (DeckSession) -> AgentHTTPResponse) -> AgentHTTPResponse {
        switch self {
        case .failure(let refusal): refusal.response
        case .success(let session): body(session)
        }
    }
}
