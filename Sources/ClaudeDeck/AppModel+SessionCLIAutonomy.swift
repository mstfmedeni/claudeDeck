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
        // Permission mode, allowed tools, model, effort: the flags, else the project's preset.
        let given: ClaudeLaunchOptions
        switch SessionCLI.launchOptions(form) {
        case .failure(let refusal): return refusal.response
        case .success(let options): given = options
        }
        if let refusal = cliLaunchRefusal(given.over(cliPreset(for: projectID)?.options)) {
            logAgent(callerName, inbound: true, "claudedeck new · \(project.name): refused (\(refusal.rawValue))", ok: false)
            return refusal.response
        }
        var skill = (form["skill"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if skill.hasPrefix("/") { skill.removeFirst() }
        if !skill.isEmpty, let refusal = cliSkillRefusal(skill, project: project) { return refusal.response }
        let account: String?
        switch cliAccountChoice(form) {
        case .failure(let refusal): return refusal.response
        case .success(let choice): account = choice
        }
        var request = CLIQueuedStart(id: SessionCLI.newQueueID(), caller: caller, callerName: callerName, projectID: projectID,
                                     name: (form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
                                     worktree: worktree, skill: skill.isEmpty ? nil : skill, options: given)
        request.account = account
        // An overloaded Mac (Settings › Resources): refused, or queued until it is back to ok.
        // Before the rate limit, so a refusal doesn't use up one of the caller's starts.
        switch LoadThrottle.start(throttled: systemLoad.monitor.throttled, enabled: deck.settings.load.throttle, queue: form["queue"] == "1") {
        case .allow: break
        case .refuse:
            logAgent(callerName, inbound: true, "claudedeck new · \(project.name): refused (the Mac is overloaded)", ok: false)
            return SessionCLI.failure(429, "overloaded", exit: .refused)
        case .queue:
            return cliEnqueue(request, reason: "overloaded", json: json)
        }
        let running = cliRunningStarted
        if let refusal = SessionCLI.admitStart(caller: caller, runningStarted: running, cap: deck.settings.maxStartedSessions, book: &cli) {
            guard form["queue"] == "1", refusal.status == 429 else {
                logAgent(callerName, inbound: true, "claudedeck new · \(project.name): refused (rate limit or cap)", ok: false)
                return refusal
            }
            return cliEnqueue(request, reason: running >= deck.settings.maxStartedSessions ? "too_many_running" : "too_many_starts", json: json)
        }
        switch await cliStart(request) {
        case .failure(let refusal): return refusal.response
        case .success(let info): return SessionCLI.answer(200, info, text: info.id.uuidString, exit: .ok, json: json)
        }
    }

    /// Claude sessions `claudedeck new` started that are running (the cap counts these).
    var cliRunningStarted: Int { deck.sessions.filter { $0.startedBy != nil && terminals.isRunning($0.id) }.count }

    /// Starts what `new` asked for (now, or when the queue gets room). The options are the
    /// command's over the project's preset at this moment.
    func cliStart(_ request: CLIQueuedStart) async -> Result<SessionCLIStarted, AgentHTTPRequestRefusal> {
        let caller = request.caller, callerName = request.callerName
        guard let project = deck.project(request.projectID) else { return .failure(.init(SessionCLI.failure(404, "unknown_project", exit: .unknown))) }
        let options = request.options.over(cliPreset(for: project.id)?.options)
        if let refusal = cliLaunchRefusal(options) { return .failure(.init(refusal.response)) }
        let prompt = SessionCLI.skillPrompt(request.skill, prompt: request.prompt)
        let worktree = request.worktree, given = request.name
        // Claude Code's folder-trust question would stop the session before it starts.
        let trust = await trustFolderForStartedSession(project.path)
        // The owner's selection stays where it was, as with `claudedeck open`.
        let focused = selectedSessionID
        let launchOptions = options.isEmpty ? nil : options
        // `--account auto`: the first account with room right now (a queued start decides when it starts);
        // not given: the project's pin or the account new sessions use, decided by `launch`.
        let account = request.account.map { $0 == ClaudeAccounts.autoID ? accountForNewSession(ClaudeAccounts.autoID) : $0 }
            .flatMap { hasOtherAccounts || $0 != ClaudeAccounts.defaultID ? $0 : nil }
        let started: UUID?
        if worktree.isEmpty {
            let firstLine = request.prompt.split(separator: "\n").first.map(String.init)
            let title = given.isEmpty ? firstLine ?? request.skill.map { "/\($0)" } : given
            started = newSession(in: project.id, title: title.flatMap { $0.isEmpty ? nil : $0 }, startedBy: caller, launchOptions: launchOptions,
                                 account: account)
        } else {
            started = newWorktreeSession(in: project.id, worktreeName: worktree, startedBy: caller, launchOptions: launchOptions,
                                         account: account)
        }
        selectedSessionID = focused
        guard let id = started else { return .failure(.init(SessionCLI.failure(409, "not_started", exit: .failed))) }
        mutate(userInitiated: false) { deck in
            deck.updateSession(id) {
                $0.startedBy = caller
                if !worktree.isEmpty, !given.isEmpty { $0.name = String(given.prefix(80)) }
            }
        }
        typeWhenClaudeIsUp(prompt, into: id)
        let name = deck.session(id)?.name ?? project.name
        logAgent(callerName, inbound: true, "claudedeck new · \(name) in \(project.name)" + (request.prompt.isEmpty ? "" : " (with a prompt)")
                 + (request.skill.map { " · skill \($0)" } ?? "") + (options.isEmpty ? "" : " · \(options.summary)"))
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
        return .success(SessionCLIStarted(id: id, name: name, projectId: project.id, project: project.name, worktree: worktree.isEmpty ? nil : worktree))
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
    func queueStartNotice(_ caller: UUID, _ line: String) {
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
            // A purchase spends money: its own dialog, whatever any setting says.
            if command == "domain-buy" { return await self?.ownerApprovesPurchase(caller, domain: target, summary: summary) ?? false }
            return await self?.ownerApproves(caller, command: command, target: target, summary: summary) ?? false
        }, log: { [weak self] line in
            Task { @MainActor in self?.logAgent(callerName, inbound: true, "claudedeck server \(line)") }
        }, decision: { [weak self] id in
            await MainActor.run { self?.decisions.decision(id) }
        })
        let outcome = await runner.run(command, method: method, form: form)
        if command == "domain-buy", (200..<300).contains(outcome.status) { domainBoughtNotice(outcome.json) }
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

    /// The owner's dialog for `server domain buy`: the panel's price summary and a plain "this is
    /// a real purchase". Cancel is the default (Return) and Escape; only "Buy" says yes; no
    /// answer in 2 minutes is a no.
    func ownerApprovesPurchase(_ caller: UUID, domain: String, summary: String?) async -> Bool {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return false
        }
        onSessionNotice?(caller, String(localized: "Asks to buy the domain \(domain) in ServerPlan. Answer in ClaudeDeck."))
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "\(callerName) wants to buy the domain \(domain)")
        alert.informativeText = (summary.map { $0 + "\n\n" } ?? "")
            + String(localized: "This is a real purchase: it's charged to the Namecheap balance and can't be undone.")
            + "\n\n" + String(localized: "A session asks through claudedeck server. Without an answer in 2 minutes it's refused.")
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        let buy = alert.addButton(withTitle: String(localized: "Buy"))
        cancel.keyEquivalent = "\r"
        buy.keyEquivalent = ""
        buy.hasDestructiveAction = true
        // Escape is Cancel too.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            return nil
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled, alert.window.isVisible { window.endSheet(alert.window, returnCode: .abort) }
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        timeout.cancel()
        if let escape { NSEvent.removeMonitor(escape) }
        return answer == .alertSecondButtonReturn
    }

    /// A Mac (and phone) notification once a session bought a domain.
    private func domainBoughtNotice(_ json: Data) {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let domain = object["domain"] as? String ?? "?"
        let charged = (object["charged_amount"] as? NSNumber).map { String(format: "%.2f", $0.doubleValue) } ?? "?"
        let currency = object["currency"] as? String ?? ""
        let years = (object["years"] as? NSNumber)?.intValue ?? 1
        ServerPlanController.shared.onNotice?(ServerPlanNotice(
            title: String(localized: "Domain bought: \(domain)"),
            body: String(localized: "\(years) year(s), charged \(charged) \(currency) to the Namecheap balance."),
            id: "serverplan-domain-\(domain)", deploymentID: nil, isFailure: false))
    }
}
