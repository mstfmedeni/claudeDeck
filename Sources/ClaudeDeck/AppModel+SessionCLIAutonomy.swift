import AppKit
import ClaudeDeckCore
import Foundation

/// `claudedeck projects`, `project add`, `new` and `server …` (SessionCLIAutonomy.swift,
/// ServerPlanCLI.swift). Each needs its own setting under Settings › Agents › Command-line tool
/// (off by default); a terminal another session opened never has the scopes.
extension AppModel {
    // MARK: Projects

    private func cliProjectInfo(_ project: Project, existing: Bool? = nil) -> SessionCLIProject {
        SessionCLIProject(id: project.id, name: project.name, path: project.path,
                          group: project.groupID.flatMap { id in deck.groups.first { $0.id == id }?.name },
                          sessions: deck.sessions(in: project.id).count, existing: existing)
    }

    func cliProjects(json: Bool) -> AgentHTTPResponse {
        let infos = deck.projects.map { cliProjectInfo($0) }
        return SessionCLI.answer(200, infos, text: SessionCLI.projectsText(infos), exit: .ok, json: json)
    }

    /// Folders `--create` may make: the user's home (in the demo, its own folder too).
    private var cliCreateRoots: [String] {
        var roots = [FileManager.default.homeDirectoryForCurrentUser.path]
        if Self.isDemo { roots.append(DeckDataStore.default().url.deletingLastPathComponent().deletingLastPathComponent().path) }
        return roots
    }

    func cliAddProject(_ caller: UUID, form: [String: String], json: Bool) -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let raw = form["path"] ?? ""
        // Already a project: nothing to check or count.
        if case .found(let id) = SessionCLI.project(raw, callerProject: nil, projects: deck.projects), raw.hasPrefix("/"), let project = deck.project(id) {
            return SessionCLI.answer(200, cliProjectInfo(project, existing: true), text: project.id.uuidString, exit: .ok, json: json)
        }
        let create = form["create"] == "1"
        guard cli.projectAdds.allow(caller) else {
            logAgent(callerName, inbound: true, "claudedeck project add: too many", ok: false)
            return SessionCLI.failure(429, "too_many_projects", exit: .refused)
        }
        let path: String
        switch SessionCLI.projectFolder(raw, create: create, createRoots: cliCreateRoots) {
        case .failure(let refusal):
            logAgent(callerName, inbound: true, "claudedeck project add \(raw): \(refusal.rawValue)", ok: false)
            return refusal.response
        case .success(let folder): path = folder
        }
        if let existing = deck.projects.first(where: { SessionCLI.resolved($0.path) == path }) {
            return SessionCLI.answer(200, cliProjectInfo(existing, existing: true), text: existing.id.uuidString, exit: .ok, json: json)
        }
        let name = (form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = (form["group"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var added: Project?
        mutate(userInitiated: false) { deck in
            let project = deck.addProject(path: path)
            guard let index = deck.projects.firstIndex(where: { $0.id == project.id }) else { return }
            if !name.isEmpty { deck.projects[index].name = String(name.prefix(80)) }
            if !groupName.isEmpty {
                let group = deck.groups.first { $0.name.caseInsensitiveCompare(groupName) == .orderedSame } ?? deck.addGroup(name: String(groupName.prefix(80)))
                deck.projects[index].groupID = group.id
            }
            added = deck.projects[index]
        }
        guard let project = added else { return SessionCLI.failure(409, "not_added", exit: .failed) }
        logAgent(callerName, inbound: true, "claudedeck project add · \(project.name) · \(project.path)" + (create ? " (created)" : ""))
        queueStartNotice(caller, String(localized: "Added the project \(project.name)"))
        return SessionCLI.answer(200, cliProjectInfo(project, existing: false), text: project.id.uuidString, exit: .ok, json: json)
    }

    // MARK: New Claude sessions

    func cliNewSession(_ caller: UUID, project ref: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard deck.settings.sessionsMayStartSessions else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let projectID: UUID
        switch SessionCLI.project(ref, callerProject: deck.session(caller)?.projectID, projects: deck.projects) {
        case .found(let id): projectID = id
        case .unknown: return SessionCLI.failure(404, "unknown_project", exit: .unknown)
        case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
        }
        guard let project = deck.project(projectID) else { return SessionCLI.failure(404, "unknown_project", exit: .unknown) }
        let prompt = (form["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count <= SessionCLI.maxText else { return SessionCLI.failure(400, "too_long", exit: .usage) }
        let worktree = (form["worktree"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !worktree.isEmpty {
            guard DeckData.isValidWorktreeName(worktree) else { return SessionCLI.failure(400, "bad_worktree", exit: .usage) }
            guard isGitRepository(project) else { return SessionCLI.failure(400, "not_a_repository", exit: .usage) }
        }
        let running = deck.sessions.filter { $0.startedBy != nil && terminals.isRunning($0.id) }.count
        if let refusal = SessionCLI.admitStart(caller: caller, runningStarted: running, book: &cli) {
            logAgent(callerName, inbound: true, "claudedeck new · \(project.name): refused (rate limit or cap)", ok: false)
            return refusal
        }
        // Claude Code's folder-trust question would stop the session before it starts.
        let trust = await trustFolderForStartedSession(project.path)
        let given = (form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The owner's selection stays where it was, as with `claudedeck open`.
        let focused = selectedSessionID
        let started: UUID?
        if worktree.isEmpty {
            let title = given.isEmpty ? prompt.split(separator: "\n").first.map(String.init) : given
            started = newSession(in: projectID, title: title.flatMap { $0.isEmpty ? nil : $0 })
        } else {
            started = newWorktreeSession(in: projectID, worktreeName: worktree)
        }
        selectedSessionID = focused
        guard let id = started else { return SessionCLI.failure(409, "not_started", exit: .failed) }
        mutate(userInitiated: false) { deck in
            deck.updateSession(id) {
                $0.startedBy = caller
                if !worktree.isEmpty, !given.isEmpty { $0.name = String(given.prefix(80)) }
            }
        }
        typeWhenClaudeIsUp(prompt, into: id)
        let name = deck.session(id)?.name ?? project.name
        logAgent(callerName, inbound: true, "claudedeck new · \(name) in \(project.name)" + (prompt.isEmpty ? "" : " (with a prompt)"))
        switch trust {
        case .trusted(let folder):
            logAgent(callerName, inbound: true, "claudedeck new · \(name): trusted the folder \(folder) for Claude Code")
            queueStartNotice(caller, String(localized: "Started \(name) in \(project.name) and trusted its folder"))
        case .failed(let reason):
            logAgent(callerName, inbound: true, "claudedeck new · \(name): couldn't trust the folder (\(reason)); Claude Code will ask", ok: false)
            queueStartNotice(caller, String(localized: "Started \(name) in \(project.name); Claude Code asks whether to trust its folder"))
        case .skipped(let reason):
            // A folder the rules leave alone may well be trusted already: the plain notice.
            logAgent(callerName, inbound: true, "claudedeck new · \(name): folder trust left to Claude Code (\(reason))")
            queueStartNotice(caller, String(localized: "Started \(name) in \(project.name)"))
        case .alreadyTrusted:
            queueStartNotice(caller, String(localized: "Started \(name) in \(project.name)"))
        }
        onCountsChanged?()
        let info = SessionCLIStarted(id: id, name: name, projectId: projectID, project: project.name, worktree: worktree.isEmpty ? nil : worktree)
        return SessionCLI.answer(200, info, text: id.uuidString, exit: .ok, json: json)
    }

    enum StartedSessionTrust: Equatable {
        case alreadyTrusted
        case trusted(String)
        /// The rules leave this folder alone (`ClaudeTrust.Refusal`).
        case skipped(String)
        /// It should have been trusted, but writing the config didn't work.
        case failed(String)
    }

    /// Marks the folder trusted in Claude Code's config before a session another session started
    /// launches there (ClaudeTrust.swift), when the setting is on and the folder passes the
    /// `project add` path rules. Sessions the owner starts never come here.
    func trustFolderForStartedSession(_ path: String) async -> StartedSessionTrust {
        let folder: String
        switch ClaudeTrust.decide(startedByCLI: true, settingOn: deck.settings.sessionsMayStartSessions, path: path, roots: cliCreateRoots) {
        case .failure(let refusal): return .skipped(refusal.rawValue)
        case .success(let resolved): folder = resolved
        }
        guard let file = ClaudeTrust.configFile(environment: ProcessInfo.processInfo.environment,
                                                home: FileManager.default.homeDirectoryForCurrentUser.path, demo: Self.isDemo) else {
            return .failed("no_config_file")
        }
        let outcome = await Task.detached { ClaudeTrust.trust(folder, in: file) }.value
        switch outcome {
        case .trusted: return .trusted(folder)
        case .alreadyTrusted: return .alreadyTrusted
        case .failed(let reason): return .failed(reason)
        }
    }

    /// One notification per burst: what a caller did in the next 3 seconds goes out together.
    private func queueStartNotice(_ caller: UUID, _ line: String) {
        let first = cli.startNotices[caller] == nil
        cli.startNotices[caller, default: []].append(line)
        guard first else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let lines = self.cli.startNotices.removeValue(forKey: caller), !lines.isEmpty else { return }
            self.onSessionNotice?(caller, SessionCLI.startNotice(lines))
        }
    }

    // MARK: ServerPlan

    func cliServer(_ caller: UUID, command: String, method: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard deck.settings.sessionsMayUseServerPlan else { return SessionCLI.failure(403, "setting_off", exit: .refused) }
        let controller = ServerPlanController.shared
        guard let client = controller.client else { return SessionCLI.failure(403, "serverplan_off", exit: .refused) }
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        var me = controller.me
        if me == nil || ServerPlanCLI.commands[command]?.v11 == true { me = (try? await client.me()) ?? me }
        let runner = ServerPlanCLI.Runner(client: client, me: me, approve: { [weak self] command, target, summary in
            await self?.ownerApproves(caller, command: command, target: target, summary: summary) ?? false
        }, log: { [weak self] line in
            Task { @MainActor in self?.logAgent(callerName, inbound: true, "claudedeck server \(line)") }
        })
        let outcome = await runner.run(command, method: method, form: form)
        // Reads are many (`--wait` polls): only what changes something, or fails, is logged.
        if ServerPlanCLI.commands[command]?.method != "GET" || outcome.exit != .ok && outcome.exit != .timeout {
            logAgent(callerName, inbound: true, "claudedeck server \(command)" + (outcome.status >= 300 ? ": \(outcome.text)" : ""), ok: outcome.status < 300)
        }
        return outcome.response(json: json)
    }

    /// The owner's dialog for a gated ServerPlan action: a sheet on the window (and a
    /// notification); no answer in 2 minutes is a no.
    func ownerApproves(_ caller: UUID, command: String, target: String, summary: String?) async -> Bool {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return false
        }
        onSessionNotice?(caller, String(localized: "Asks to run “\(command)” on \(target) in ServerPlan. Answer in ClaudeDeck."))
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "\(callerName) wants to run “\(command)” on \(target)")
        alert.informativeText = (summary.map { $0 + "\n\n" } ?? "")
            + String(localized: "A session asks through claudedeck server. Without an answer in 2 minutes it's refused.")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Refuse"))
        alert.buttons.first?.hasDestructiveAction = true
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled, alert.window.isVisible { window.endSheet(alert.window, returnCode: .abort) }
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        timeout.cancel()
        return answer == .alertFirstButtonReturn
    }
}
