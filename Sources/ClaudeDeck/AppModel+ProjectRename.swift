import ClaudeDeckCore
import Foundation

extension AppModel {
    /// Renames a project; with `folder`, its folder on disk too (and Claude's conversations of it).
    /// Returns why the folder couldn't be renamed (the name is changed only when it could).
    /// A moved folder takes ServerPlan's stored paths along (in the background, logged).
    @discardableResult
    func renameProject(_ id: UUID, to name: String, folder: Bool) -> String? {
        switch performProjectRename(id, to: name, folder: folder) {
        case .failure(let problem):
            return problem.message
        case .success(let moved):
            if let moved {
                Task { @MainActor [weak self] in _ = await self?.relocateServerPlanPaths(from: moved.old, to: moved.new, by: nil) }
            }
            return nil
        }
    }

    /// The rename itself (the UI's and `claudedeck project rename`'s): the folder first (refused
    /// while a session or terminal of the project runs), then the name. Returns the folder's move
    /// (nil: it didn't move).
    func performProjectRename(_ id: UUID, to name: String, folder: Bool) -> Result<(old: String, new: String)?, ProjectFolderRename.Problem> {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty else { return .failure(.badName) }
        guard let project = deck.project(id) else { return .failure(.missing) }
        var moved: (old: String, new: String)?
        if folder {
            let sessions = deck.sessions(in: id)
            if sessions.contains(where: { terminals.isRunning($0.id) }) { return .failure(.running) }
            do {
                let old = project.path
                let new = try ProjectFolderRename.newPath(for: old, name: trimmed)
                if new != old {
                    let inside = sessions.compactMap(\.workingDirectory)
                    let transcripts = try ProjectFolderRename.move(old, to: new, insideDirectories: inside)
                    Git.repairWorktrees(in: URL(fileURLWithPath: new))
                    mutate { $0.relocateProject(id, from: old, to: new, transcripts: transcripts) }
                    moved = (old, new)
                }
            } catch {
                return .failure(error)
            }
        }
        mutate { $0.updateProject(id) { $0.name = trimmed } }
        return .success(moved)
    }

    // MARK: ServerPlan

    /// A project folder moved: ServerPlan's stored paths under it (projects, project dirs, static
    /// sites' local_sync_path) follow, ids unchanged. A dry run first (stops on a conflict), then
    /// the real run with the panel's confirm. The folder already moved, so this needs no owner
    /// card: leaving ServerPlan pointing at a folder that's gone helps no one. Logged; `by`: the
    /// session that renamed it (nil: the owner).
    func relocateServerPlanPaths(from old: String, to new: String, by caller: UUID?) async -> ServerPlanPathRelocation.Summary {
        let who = caller.flatMap { deck.session($0)?.name } ?? "ClaudeDeck"
        let summary = await serverPlanRelocation(from: old, to: new)
        // No ServerPlan in this ClaudeDeck: nothing to say.
        guard summary.status != .serverplanOff else { return summary }
        let ok = summary.status != .failed && summary.status != .notSupported
        logAgent(who, inbound: caller != nil, "ServerPlan paths \(old) → \(new): " + Approvals.oneLine(summary.text), ok: ok)
        if summary.status == .failed || summary.status == .notSupported && !summary.stale.isEmpty {
            ServerPlanController.shared.onNotice?(ServerPlanNotice(
                title: String(localized: "ServerPlan paths weren't updated"),
                body: String(localized: "\(old) moved to \(new). \(summary.text)"),
                id: "serverplan-relocate-\(new)", deploymentID: nil, isFailure: true))
        }
        return summary
    }

    private func serverPlanRelocation(from old: String, to new: String) async -> ServerPlanPathRelocation.Summary {
        guard let client = ServerPlanController.shared.client else { return .init(status: .serverplanOff) }
        let prefixes: (old: String, new: String)
        switch ServerPlanPathRelocation.prefixes(old, new) {
        case .failure(let problem): return .init(status: .failed, message: problem.message)
        case .success(let given): prefixes = given
        }
        let me = (try? await client.me()) ?? ServerPlanController.shared.me
        guard me?.features.contains(ServerPlanPathRelocation.feature) == true else {
            // Best effort: which of its paths ClaudeDeck can see still point at the old folder.
            async let projects = try? client.raw("GET", "/projects")
            async let dirs = try? client.raw("GET", "/project-dirs")
            async let domains = try? client.raw("GET", "/domains")
            let stale = ServerPlanPathRelocation.stalePaths(projects: await projects, dirs: await dirs, domains: await domains, under: prefixes.old)
            return .init(status: .notSupported, stale: stale)
        }
        do {
            let dry = ServerPlanPathRelocation.Answer.parse(
                try await client.raw("POST", ServerPlanPathRelocation.path,
                                     json: ServerPlanPathRelocation.body(old: prefixes.old, new: prefixes.new, dryRun: true)), dryRun: true)
            guard dry.count > 0 else { return .init(status: .nothing, warnings: dry.warnings) }
            let confirm = dry.oldPrefix ?? prefixes.old
            let real: Data
            do {
                real = try await client.raw("POST", ServerPlanPathRelocation.path,
                                            json: ServerPlanPathRelocation.body(old: prefixes.old, new: prefixes.new, dryRun: false, confirm: confirm))
            } catch ServerPlanError.confirmRequired(_, let expected?) where expected != confirm {
                // The panel normalized the prefix differently: its own value is the confirm.
                real = try await client.raw("POST", ServerPlanPathRelocation.path,
                                            json: ServerPlanPathRelocation.body(old: prefixes.old, new: prefixes.new, dryRun: false, confirm: expected))
            }
            let result = ServerPlanPathRelocation.Answer.parse(real, dryRun: false)
            return .init(status: result.count > 0 ? .relocated : .nothing, count: result.count, changes: result.changes, warnings: result.warnings)
        } catch {
            return .init(status: .failed, message: (error as? ServerPlanError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: claudedeck project rename

    /// `claudedeck project rename PROJECT NEWNAME [--folder]`: sessions of a coordinator project
    /// only, and only while nothing of the target project runs.
    func cliRenameProject(_ caller: UUID, project ref: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard let session = deck.session(caller) else { return SessionCLI.failure(404, "unknown_session", exit: .unknown) }
        let callerName = session.name
        // A plain terminal never gets the scope; this holds even for a token from before.
        guard session.kind == .claude else { return SessionCLI.failure(403, "not_allowed", exit: .refused) }
        let project: Project
        switch SessionCLI.project(ref, callerProject: session.projectID, projects: deck.projects) {
        case .found(let id):
            guard let found = deck.project(id) else { return SessionCLI.failure(404, "unknown_project", exit: .unknown) }
            project = found
        case .unknown: return SessionCLI.failure(404, "unknown_project", exit: .unknown)
        case .ambiguous: return SessionCLI.failure(400, "ambiguous", exit: .usage)
        }
        let name = (form["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = form["folder"] == "1"
        let running = deck.sessions(in: project.id).filter { terminals.isRunning($0.id) }.map {
            SessionCLI.RunningSession(id: $0.id, name: $0.name, kind: $0.kind == .shell ? "terminal" : "claude")
        }
        switch SessionCLI.projectRenameCheck(callerProject: deck.project(session.projectID), name: name, running: running) {
        case .notCoordinator:
            logAgent(callerName, inbound: true, "claudedeck project rename · \(project.name): refused (not a coordinator project)", ok: false)
            return SessionCLI.failure(403, "not_coordinator", exit: .refused)
        case .badName:
            return SessionCLI.projectRenameFailure(.badName)
        case .sessionsRunning(let list):
            logAgent(callerName, inbound: true, "claudedeck project rename · \(project.name): refused (\(list.count) running)", ok: false)
            return SessionCLI.sessionsRunningFailure(list)
        case .allowed:
            break
        }
        let oldName = project.name, oldPath = project.path
        switch performProjectRename(project.id, to: name, folder: folder) {
        case .failure(let problem):
            logAgent(callerName, inbound: true, "claudedeck project rename · \(oldName): \(problem.message)", ok: false)
            return SessionCLI.projectRenameFailure(problem)
        case .success(let moved):
            let current = deck.project(project.id)
            logAgent(callerName, inbound: true, "claudedeck project rename · \(oldName) → \(current?.name ?? name)"
                     + (moved.map { " (folder \($0.old) → \($0.new))" } ?? ""))
            var serverplan: ServerPlanPathRelocation.Summary?
            if let moved { serverplan = await relocateServerPlanPaths(from: moved.old, to: moved.new, by: caller) }
            let renamed = SessionCLIProjectRenamed(id: project.id, name: current?.name ?? name, oldName: oldName,
                                                   path: current?.path ?? oldPath, oldPath: oldPath, folderMoved: moved != nil,
                                                   serverplan: serverplan)
            return SessionCLI.answer(200, renamed, text: renamed.text, exit: .ok, json: json)
        }
    }
}
