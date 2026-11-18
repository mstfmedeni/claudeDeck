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

    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
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
