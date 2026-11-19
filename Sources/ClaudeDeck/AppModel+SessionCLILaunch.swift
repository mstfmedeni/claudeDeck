import ClaudeDeckCore
import Foundation

/// `claudedeck new` options (permission mode, allowed tools, model, effort, skill), per-project
/// presets, `new --queue` and `wait --all|--any` (SessionCLILaunch.swift). All of it behind
/// "Sessions may add projects and start Claude sessions"; `wait` behind the wait scope only.
extension AppModel {
    // MARK: Options

    /// The arguments a session `claudedeck new` started passes to `claude` on every start.
    /// `bypassPermissions` only while the owner still allows it.
    func cliLaunchArguments(for session: DeckSession) -> [String] {
        guard session.kind == .claude, let options = session.launchOptions, !options.isEmpty else { return [] }
        let effective = options.effective(bypassAllowed: deck.settings.sessionsMayBypassPermissions)
        if effective != options {
            logAgent(session.name, inbound: false, "bypassPermissions is off in Settings: \(session.name) starts without it (default mode, no blanket Bash rule)", ok: false)
        }
        return effective.arguments(cliCommand: deck.settings.sessionCLIEnabled ? cliScriptURL.path : nil)
    }

    func cliPreset(for project: UUID) -> CLIPreset? {
        deck.cliPresets.first { $0.projectID == project }
    }

    /// `bypassPermissions`, and rules that allow every shell command, need their own setting.
    func cliLaunchRefusal(_ options: ClaudeLaunchOptions) -> SessionCLI.LaunchRefusal? {
        options.skipsPermissions && !deck.settings.sessionsMayBypassPermissions ? .bypassOff : nil
    }

    /// `--skill`: a skill (or command) Claude Code would find for a session in this project.
    func cliSkillRefusal(_ skill: String, project: Project) -> SessionCLI.LaunchRefusal? {
        guard SkillCatalog.isValidInvocation(skill) else { return .badSkill }
        var configDirs = [Self.claudeHome.appending(path: ".claude")]
        if !Self.isDemo, let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDirs.insert(URL(fileURLWithPath: dir), at: 0)
        }
        let found = SkillCatalog.find(skill, configDirs: configDirs, projectPaths: [project.path],
                                      pluginsManifest: SkillCatalog.pluginsManifest(home: Self.claudeHome))
        return found == nil ? .unknownSkill : nil
    }

    // MARK: Presets

    private func presetInfo(_ project: Project) -> SessionCLIPresetInfo {
        SessionCLIPresetInfo(projectId: project.id, project: project.name, preset: cliPreset(for: project.id))
    }

    private func presetText(_ info: SessionCLIPresetInfo) -> String {
        guard info.setBy != nil else { return "\(info.project): no preset" }
        let options = ClaudeLaunchOptions(permissionMode: info.permissionMode, allowedTools: info.allow, model: info.model, effort: info.effort)
        return "\(info.project): \(options.summary)"
    }

    private func presetProject(_ caller: UUID, _ ref: String) -> Result<Project, AgentHTTPRequestRefusal> {
        switch SessionCLI.project(ref, callerProject: deck.session(caller)?.projectID, projects: deck.projects) {
        case .found(let id):
            if let project = deck.project(id) { return .success(project) }
            return .failure(.init(SessionCLI.failure(404, "unknown_project", exit: .unknown)))
        case .unknown: return .failure(.init(SessionCLI.failure(404, "unknown_project", exit: .unknown)))
        case .ambiguous: return .failure(.init(SessionCLI.failure(400, "ambiguous", exit: .usage)))
        }
    }

    func cliPresets(json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let infos = deck.cliPresets.compactMap { preset in deck.project(preset.projectID).map(presetInfo) }
        let text = infos.isEmpty ? "no presets" : infos.map(presetText).joined(separator: "\n")
        return SessionCLI.answer(200, infos, text: text, exit: .ok, json: json)
    }

    func cliShowPreset(_ caller: UUID, project ref: String, json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        switch presetProject(caller, ref) {
        case .failure(let refusal): return refusal.response
        case .success(let project):
            let info = presetInfo(project)
            return SessionCLI.answer(200, info, text: presetText(info), exit: .ok, json: json)
        }
    }

    /// Replaces the project's preset with what's given (`clear=1`, or nothing given: removes it).
    func cliSetPreset(_ caller: UUID, project ref: String, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let project: Project
        switch presetProject(caller, ref) {
        case .failure(let refusal): return refusal.response
        case .success(let found): project = found
        }
        let options: ClaudeLaunchOptions
        switch SessionCLI.launchOptions(form) {
        case .failure(let refusal): return refusal.response
        case .success(let given): options = form["clear"] == "1" ? ClaudeLaunchOptions() : given
        }
        if let refusal = cliLaunchRefusal(options) {
            logAgent(callerName, inbound: true, "claudedeck preset set · \(project.name): refused (\(refusal.rawValue))", ok: false)
            return refusal.response
        }
        mutate(userInitiated: false) { deck in
            deck.cliPresets.removeAll { $0.projectID == project.id }
            if !options.isEmpty { deck.cliPresets.append(CLIPreset(projectID: project.id, options: options, setBy: callerName)) }
        }
        logAgent(callerName, inbound: true, "claudedeck preset " + (options.isEmpty ? "clear · \(project.name)" : "set · \(project.name) · \(options.summary)"))
        let info = presetInfo(project)
        return SessionCLI.answer(200, info, text: presetText(info), exit: .ok, json: json)
    }

    // MARK: Queue

    func cliEnqueue(_ request: CLIQueuedStart, reason: String, json: Bool) -> AgentHTTPResponse {
        let project = deck.project(request.projectID)?.name ?? ""
        if let refusal = SessionCLI.admitQueued(caller: request.caller, queue: deck.cliQueue) {
            logAgent(request.callerName, inbound: true, "claudedeck new --queue · \(project): refused (queue full)", ok: false)
            return refusal
        }
        mutate(userInitiated: false) { deck in
            deck.cliQueue = SessionCLI.pruneQueue(deck.cliQueue)
            deck.cliQueue.append(request)
        }
        let position = SessionCLI.queuePosition(request.id, in: deck.cliQueue) ?? 1
        logAgent(request.callerName, inbound: true, "claudedeck new --queue · \(project): queued \(request.id) (#\(position), \(reason))")
        drainCLIQueueSoon()
        let queued = SessionCLIQueued(queueId: request.id, position: position, reason: reason)
        return SessionCLI.answer(200, queued, text: request.id, exit: .ok, json: json)
    }

    /// On launch: what was queued before the quit drains once there's room.
    func resumeCLIQueue() {
        let pruned = SessionCLI.pruneQueue(deck.cliQueue)
        if pruned != deck.cliQueue { mutate(userInitiated: false) { $0.cliQueue = pruned } }
        if deck.cliQueue.contains(where: { $0.status == .queued }) { drainCLIQueueSoon() }
    }

    /// Every 2 seconds while something waits; stops when nothing does.
    func drainCLIQueueSoon() {
        guard cliQueueDrainer == nil else { return }
        cliQueueDrainer = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.drainCLIQueue()
                guard self.deck.cliQueue.contains(where: { $0.status == .queued }) else { break }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.cliQueueDrainer = nil
        }
    }

    /// Oldest first: each starts once the running cap has room and its caller's rate limit allows.
    /// A caller over its rate limit doesn't hold up the others.
    func drainCLIQueue() async {
        for entry in deck.cliQueue where entry.status == .queued {
            guard deck.cliQueue.first(where: { $0.id == entry.id })?.status == .queued else { continue }
            if !deck.settings.sessionsMayStartSessions || !deck.settings.sessionCLIEnabled {
                finishQueued(entry.id, .failed, reason: "setting_off")
                continue
            }
            guard deck.session(entry.caller) != nil else { finishQueued(entry.id, .failed, reason: "caller_gone"); continue }
            guard deck.project(entry.projectID) != nil else { finishQueued(entry.id, .failed, reason: "unknown_project"); continue }
            if let refusal = SessionCLI.admitStart(caller: entry.caller, runningStarted: cliRunningStarted, cap: deck.settings.maxStartedSessions, book: &cli) {
                if SessionCLI.errorCode(of: refusal) == "too_many_running" { return }
                continue
            }
            switch await cliStart(entry) {
            case .success(let started):
                mutate(userInitiated: false) { deck in
                    guard let index = deck.cliQueue.firstIndex(where: { $0.id == entry.id }) else { return }
                    deck.cliQueue[index].status = .started
                    deck.cliQueue[index].sessionID = started.id
                    deck.cliQueue[index].finishedAt = Date()
                }
                logAgent(entry.callerName, inbound: true, "claudedeck queue · \(entry.id) started \(started.name)")
            case .failure(let refusal):
                finishQueued(entry.id, .failed, reason: SessionCLI.errorCode(of: refusal.response) ?? "not_started")
            }
        }
    }

    private func finishQueued(_ id: String, _ status: CLIQueuedStart.Status, reason: String) {
        guard let entry = deck.cliQueue.first(where: { $0.id == id }) else { return }
        mutate(userInitiated: false) { deck in
            guard let index = deck.cliQueue.firstIndex(where: { $0.id == id }) else { return }
            deck.cliQueue[index].status = status
            deck.cliQueue[index].reason = reason
            deck.cliQueue[index].finishedAt = Date()
        }
        logAgent(entry.callerName, inbound: true, "claudedeck queue · \(id) \(status.rawValue) (\(reason))", ok: status != .failed)
    }

    private func queueInfo(_ entry: CLIQueuedStart, caller: UUID) -> SessionCLIQueueInfo {
        SessionCLIQueueInfo(entry, project: deck.project(entry.projectID)?.name ?? "", mine: entry.caller == caller,
                            position: SessionCLI.queuePosition(entry.id, in: deck.cliQueue))
    }

    func cliQueueList(_ caller: UUID, json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let infos = SessionCLI.pruneQueue(deck.cliQueue).map { queueInfo($0, caller: caller) }
        return SessionCLI.answer(200, infos, text: SessionCLI.queueText(infos), exit: .ok, json: json)
    }

    func cliQueueShow(_ caller: UUID, id: String, json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        guard let entry = deck.cliQueue.first(where: { $0.id == id }) else { return SessionCLI.failure(404, "unknown_queue_id", exit: .unknown) }
        let info = queueInfo(entry, caller: caller)
        let text: String
        switch entry.status {
        case .queued: text = "queued #\(info.position ?? 0)"
        case .started: text = entry.sessionID?.uuidString ?? "started"
        case .cancelled, .failed: text = entry.status.rawValue + (entry.reason.map { " (\($0))" } ?? "")
        }
        // Started: the session id is the answer (as `new` prints it); otherwise exit 1 for a dead end.
        let exit: SessionCLI.Exit = entry.status == .cancelled || entry.status == .failed ? .failed : .ok
        return SessionCLI.answer(200, info, text: text, exit: exit, json: json)
    }

    /// Only the session that queued it, and only while it waits.
    func cliQueueCancel(_ caller: UUID, id: String, json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        guard let entry = deck.cliQueue.first(where: { $0.id == id }) else { return SessionCLI.failure(404, "unknown_queue_id", exit: .unknown) }
        guard entry.caller == caller else { return SessionCLI.failure(403, "not_yours", exit: .refused) }
        guard entry.status == .queued else { return SessionCLI.failure(409, "not_queued", exit: .failed) }
        finishQueued(id, .cancelled, reason: "cancelled")
        let info = queueInfo(deck.cliQueue.first { $0.id == id } ?? entry, caller: caller)
        return SessionCLI.answer(200, info, text: "cancelled \(id)", exit: .ok, json: json)
    }

    // MARK: Waiting

    /// `wait q_…`: until it starts, then like `wait` on its session (the same long-poll window).
    func cliWaitQueued(_ caller: UUID, id: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        let window = min(SessionCLI.maxWaitWindow, max(0, form["timeout"].flatMap(Int.init) ?? SessionCLI.maxWaitWindow))
        let deadline = ContinuousClock.now + .seconds(window)
        while true {
            guard let entry = deck.cliQueue.first(where: { $0.id == id }) else { return SessionCLI.failure(404, "unknown_queue_id", exit: .unknown) }
            switch entry.status {
            case .cancelled: return SessionCLI.failure(409, "queue_cancelled", exit: .failed)
            case .failed: return SessionCLI.failure(409, "queue_failed", exit: .failed)
            case .started:
                guard let sessionID = entry.sessionID, let session = deck.session(sessionID) else {
                    return SessionCLI.failure(404, "unknown_session", exit: .unknown)
                }
                let left = max(0, Int((deadline - ContinuousClock.now).components.seconds))
                var rest = form
                rest["timeout"] = String(left)
                return await cliWait(caller, for: session, form: rest, json: json)
            case .queued:
                if ContinuousClock.now >= deadline {
                    let waited = SessionCLIWaited(.running, state: "queued", detail: nil)
                    return SessionCLI.answer(200, waited, text: "timeout: still queued", exit: .timeout, json: json)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// `wait --all|--any ID…`: long poll like `wait`, over several sessions (or queue ids).
    func cliWaitMany(_ caller: UUID, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard let mode = SessionCLI.WaitMode(rawValue: form["mode"] ?? "") else { return SessionCLI.failure(400, "bad_mode", exit: .usage) }
        let refs = (form["ids"] ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard !refs.isEmpty, refs.count <= 50 else { return SessionCLI.failure(400, "bad_request", exit: .usage) }
        // Every id is checked first: an unknown one ends the wait before it starts.
        enum Target { case session(UUID), queued(String) }
        var targets: [Target] = []
        for ref in refs {
            if SessionCLI.isQueueID(ref) {
                guard deck.cliQueue.contains(where: { $0.id == ref }) else { return SessionCLI.failure(404, "unknown_queue_id", exit: .unknown) }
                targets.append(.queued(ref))
                continue
            }
            switch SessionCLI.target(ref, caller: caller, sessions: deck.sessions.map(\.id)) {
            case .found(let id):
                guard id != caller else { return SessionCLI.failure(400, "cannot_wait_for_self", exit: .usage) }
                targets.append(.session(id))
            case .unknown: return SessionCLI.failure(404, "unknown_session", exit: .unknown)
            case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
            }
        }
        let window = min(SessionCLI.maxWaitWindow, max(0, form["timeout"].flatMap(Int.init) ?? SessionCLI.maxWaitWindow))
        let deadline = ContinuousClock.now + .seconds(window)
        while true {
            var entries: [SessionCLIWaitEntry] = []
            var texts: [String] = []
            for (ref, target) in zip(refs, targets) {
                var sessionID: UUID?
                var queueID: String?
                switch target {
                case .session(let id): sessionID = id
                case .queued(let id):
                    queueID = id
                    let entry = deck.cliQueue.first { $0.id == id }
                    switch entry?.status {
                    case .started?: sessionID = entry?.sessionID
                    case .queued?:
                        entries.append(SessionCLIWaitEntry(ref: ref, id: nil, queueId: id, result: "timeout", exitCode: nil, state: "queued",
                                                           detail: nil, running: true, exit: .timeout))
                        texts.append("still queued")
                        continue
                    default:
                        let result = entry?.status == .cancelled ? "cancelled" : "queue_failed"
                        entries.append(SessionCLIWaitEntry(ref: ref, id: nil, queueId: id, result: result, exitCode: nil, state: "stopped",
                                                           detail: entry?.reason, running: false, exit: .failed))
                        texts.append(result + (entry?.reason.map { " (\($0))" } ?? ""))
                        continue
                    }
                }
                guard let id = sessionID, let session = deck.session(id) else {
                    entries.append(SessionCLIWaitEntry(ref: ref, id: sessionID, queueId: queueID, result: "stopped", exitCode: nil,
                                                       state: "stopped", detail: nil, running: false, exit: .ok))
                    texts.append(SessionCLI.waitText(.stopped, detail: nil))
                    continue
                }
                let progress = cliProgress(id)
                let detail = status(of: id).detail
                entries.append(SessionCLIWaitEntry(ref: ref, id: id, queueId: queueID, result: progress.result, exitCode: progress.exitCode,
                                                   state: cliState(session), detail: detail, running: progress == .running, exit: progress.exit))
                texts.append(SessionCLI.waitText(progress, detail: detail))
            }
            let combined = SessionCLI.combine(entries.map { ($0.running, $0.exit) }, mode: mode)
            if combined.done || ContinuousClock.now >= deadline {
                let exit = combined.done ? combined.exit : .timeout
                let waited = SessionCLIWaitedMany(mode: mode.rawValue, result: SessionCLI.resultName(exit),
                                                  first: combined.first.map { refs[$0] }, sessions: entries)
                return SessionCLI.answer(200, waited, text: SessionCLI.waitManyText(entries, texts: texts), exit: exit, json: json)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// `send`, `capture`, `wait` on a queue id: its session once it started.
    func cliQueuedSession(_ ref: String) -> Result<UUID, AgentHTTPRequestRefusal> {
        guard let entry = deck.cliQueue.first(where: { $0.id == ref }) else {
            return .failure(.init(SessionCLI.failure(404, "unknown_queue_id", exit: .unknown)))
        }
        guard entry.status == .started, let id = entry.sessionID else {
            return .failure(.init(SessionCLI.failure(409, entry.status == .queued ? "queued" : "not_started", exit: .failed)))
        }
        return .success(id)
    }
}
