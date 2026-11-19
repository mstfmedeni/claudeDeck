import Foundation

/// A "Fix with Claude" request for one failed ServerPlan deploy, so the button isn't offered twice
/// (the deploy counterpart of `CIRepairRequest`).
public struct DeployRepairRequest: Codable, Sendable, Equatable {
    /// `DeployRepair.key(…)`.
    public var key: String
    public var requestedAt: Date
    public var sessionID: UUID?

    public init(key: String, requestedAt: Date = Date(), sessionID: UUID? = nil) {
        self.key = key
        self.requestedAt = requestedAt
        self.sessionID = sessionID
    }
}

public enum DeployRepair {
    public static let maxRequests = 200

    /// One deploy of one panel. A new deploy gets a new id, so a new failure is offered again.
    public static func key(panel: URL, deploymentID: Int) -> String {
        "\(panel.host() ?? "")#deploy:\(deploymentID)"
    }

    /// The message typed into the session.
    public static func prompt(project: String, server: String?, deployment: ServerPlanDeployment, log: String) -> String {
        var text = "The ServerPlan deploy #\(deployment.id) of \(project)"
        if let server { text += " to \(server)" }
        text += " failed"
        if let branch = deployment.branch { text += " (branch \(branch)" + (deployment.commit.map { ", commit \($0.prefix(12))" } ?? "") + ")" }
        text += ".\n"
        if let summary = deployment.errorSummary, !summary.isEmpty { text += "Error: \(summary)\n" }
        text += "ServerPlan builds the Docker image locally (docker build), transfers it over SSH and runs it there. "
        text += "Find the cause in this project, fix it, check that `docker build` succeeds locally if possible, and commit the fix. "
        text += "Don't deploy; I'll redeploy from ServerPlan.\n"
        let trimmed = CIRepair.trimLog(log)
        text += "Deploy log (tail):\n```\n\(trimmed.isEmpty ? "(no log output)" : trimmed)\n```"
        return text
    }

    /// The ClaudeDeck project whose folder is `repoPath` (symlinks and `..` resolved), if any.
    public static func project(forRepoPath repoPath: String?, in projects: [Project]) -> Project? {
        guard let repoPath, !repoPath.isEmpty else { return nil }
        let wanted = normalize(repoPath)
        return projects.first { normalize($0.path) == wanted }
    }

    /// ServerPlan projects by the ClaudeDeck project whose folder holds them (the same folder or a
    /// subfolder). With nested projects (a worktree inside its main project) the deepest one wins.
    /// Keeps ServerPlan's order. Resolves symlinks: call it once per change, not per row.
    public static func projectsByDeckProject(_ serverProjects: [ServerPlanProject], in projects: [Project]) -> [UUID: [ServerPlanProject]] {
        let roots = projects.map { (id: $0.id, path: normalize($0.path)) }.filter { $0.path.count > 1 }
        var result: [UUID: [ServerPlanProject]] = [:]
        for serverProject in serverProjects {
            guard let repoPath = serverProject.repoPath, !repoPath.isEmpty else { continue }
            let path = normalize(repoPath)
            let owner = roots
                .filter { path == $0.path || path.hasPrefix($0.path + "/") }
                .max { $0.path.count < $1.path.count }
            if let owner { result[owner.id, default: []].append(serverProject) }
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        // Symlinks resolve only on an existing path (and "/private/tmp/x" becomes "/tmp/x" only
        // when it exists): resolve the deepest existing folder and keep the rest as written.
        var rest: [String] = []
        while url.path.count > 1, !FileManager.default.fileExists(atPath: url.path) {
            rest.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for component in rest { url.appendPathComponent(component) }
        var p = url.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

extension DeckData {
    public func deployRepairRequest(_ key: String) -> DeployRepairRequest? {
        deployRepairRequests.last { $0.key == key }
    }

    /// Records a repair request (newest `DeployRepair.maxRequests` kept).
    public mutating func recordDeployRepair(_ request: DeployRepairRequest) {
        deployRepairRequests.removeAll { $0.key == request.key }
        deployRepairRequests.append(request)
        if deployRepairRequests.count > DeployRepair.maxRequests {
            deployRepairRequests.removeFirst(deployRepairRequests.count - DeployRepair.maxRequests)
        }
    }
}
