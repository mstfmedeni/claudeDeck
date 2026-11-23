import ClaudeDeckCore
import Foundation

/// `claudedeck project status get|set|clear`: the short status next to a project's name in the
/// sidebar (ProjectStatus.swift). Anyone with the CLI reads; a session writes its own project's
/// status, or any project's when the owner made its project a coordinator. Every write goes to
/// the Activity Log. Contract: docs/agents.md.
extension AppModel {
    func cliProjectStatus(_ caller: UUID, route: SessionCLI.Route, form: [String: String], json: Bool) -> AgentHTTPResponse {
        switch route {
        case .projectStatuses:
            let infos = deck.projects.map { SessionCLIProjectStatus(project: $0) }
            return SessionCLI.answer(200, infos, text: infos.isEmpty ? "no projects" : SessionCLI.projectStatusesText(infos),
                                     exit: .ok, json: json)
        case .showProjectStatus(let ref):
            switch statusProject(caller, ref) {
            case .failure(let refusal): return refusal.response
            case .success(let project):
                let info = SessionCLIProjectStatus(project: project)
                return SessionCLI.answer(200, info, text: SessionCLI.projectStatusText(info), exit: .ok, json: json)
            }
        case .setProjectStatus(let ref):
            return cliSetProjectStatus(caller, ref: ref, form: form, json: json)
        default:
            return SessionCLI.failure(404, "not_found", exit: .unknown)
        }
    }

    private func statusProject(_ caller: UUID, _ ref: String) -> Result<Project, AgentHTTPRequestRefusal> {
        switch SessionCLI.project(ref, callerProject: deck.session(caller)?.projectID, projects: deck.projects) {
        case .found(let id):
            if let project = deck.project(id) { return .success(project) }
            return .failure(.init(SessionCLI.failure(404, "unknown_project", exit: .unknown)))
        case .unknown: return .failure(.init(SessionCLI.failure(404, "unknown_project", exit: .unknown)))
        case .ambiguous: return .failure(.init(SessionCLI.failure(400, "ambiguous", exit: .usage)))
        }
    }

    private func cliSetProjectStatus(_ caller: UUID, ref: String, form: [String: String], json: Bool) -> AgentHTTPResponse {
        let callerSession = deck.session(caller)
        let callerName = callerSession?.name ?? "claudedeck"
        let project: Project
        switch statusProject(caller, ref) {
        case .failure(let refusal): return refusal.response
        case .success(let found): project = found
        }
        let clearing = form["clear"] == "1"
        let verb = clearing ? "clear" : "set"
        let coordinator = callerSession.flatMap { deck.project($0.projectID) }?.isCoordinator ?? false
        guard ProjectStatus.mayWrite(callerProject: callerSession?.projectID, target: project.id, callerIsCoordinator: coordinator) else {
            logAgent(callerName, inbound: true, "claudedeck project status \(verb) · \(project.name): refused (not its project)", ok: false)
            return SessionCLI.notYourProject
        }
        if clearing {
            mutate(userInitiated: false) { $0.updateProject(project.id) { $0.status = nil } }
            logAgent(callerName, inbound: true, "claudedeck project status clear · \(project.name)")
        } else {
            let status: ProjectStatus
            switch ProjectStatus.make(text: form["text"] ?? "", summary: form["summary"], tone: form["tone"], by: callerName) {
            case .failure(let refusal):
                logAgent(callerName, inbound: true, "claudedeck project status set · \(project.name): refused (\(refusal.rawValue))", ok: false)
                return SessionCLI.projectStatusRefusal(refusal)
            case .success(let made): status = made
            }
            mutate(userInitiated: false) { $0.updateProject(project.id) { $0.status = status } }
            logAgent(callerName, inbound: true, "claudedeck project status set · \(project.name) · “\(status.text)”"
                + (status.tone.map { " (\($0.rawValue))" } ?? ""))
        }
        let info = SessionCLIProjectStatus(project: deck.project(project.id) ?? project)
        return SessionCLI.answer(200, info, text: SessionCLI.projectStatusText(info), exit: .ok, json: json)
    }

    // MARK: The owner

    /// The project's context menu: "Clear Status".
    func clearProjectStatus(_ id: UUID) {
        guard let project = deck.project(id), project.status != nil else { return }
        mutate { $0.updateProject(id) { $0.status = nil } }
        logAgent("ClaudeDeck", inbound: false, "project status cleared by the owner · \(project.name)")
    }
}
