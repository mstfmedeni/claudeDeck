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

// MARK: - Cleared failures

/// A ServerPlan failure as the sidebar shows it: what failed (`key`) and what it said
/// (`signature`). The same key with another signature is a new failure.
public struct ServerIssue: Sendable, Hashable {
    public var key: String
    public var signature: String

    public init(key: String, signature: String) {
        self.key = key
        self.signature = signature
    }

    /// A failed deploy. A redeploy has a new id, so its failure is a new issue.
    public static func deploy(panel: URL, deploymentID: Int, status: String = "failed") -> ServerIssue {
        ServerIssue(key: DeployRepair.key(panel: panel, deploymentID: deploymentID), signature: status)
    }

    /// A server that can't be reached or whose Docker doesn't answer (`signature`: the message).
    public static func server(panel: URL, serverID: Int, message: String) -> ServerIssue {
        ServerIssue(key: serverKey(panel: panel, serverID: serverID), signature: message)
    }

    /// The panel itself failing (refresh errors, a revoked token).
    public static func panel(_ panel: URL, message: String) -> ServerIssue {
        ServerIssue(key: panelKey(panel), signature: message)
    }

    public static func serverKey(panel: URL, serverID: Int) -> String { "\(panel.host() ?? "")#server:\(serverID)" }
    public static func panelKey(_ panel: URL) -> String { "\(panel.host() ?? "")#panel" }
}

/// A failure the owner cleared (on this Mac, or from the phone). Local only: the panel keeps it.
public struct DismissedServerIssue: Codable, Sendable, Equatable {
    public var key: String
    public var signature: String
    public var dismissedAt: Date

    public init(key: String, signature: String, dismissedAt: Date = Date()) {
        self.key = key
        self.signature = signature
        self.dismissedAt = dismissedAt
    }
}

public enum ServerIssues {
    /// Cleared failures are forgotten after this long, unless the failure is still listed.
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let maxEntries = 500
}

extension DeckData {
    /// Whether this failure was cleared (the same key with the same signature).
    public func isDismissed(_ issue: ServerIssue) -> Bool {
        dismissedServerIssues.contains { $0.key == issue.key && $0.signature == issue.signature }
    }

    /// Clears failures (one entry per key: clearing it again replaces the old signature).
    public mutating func dismissServerIssues(_ issues: [ServerIssue], now: Date = Date()) {
        guard !issues.isEmpty else { return }
        let keys = Set(issues.map(\.key))
        dismissedServerIssues.removeAll { keys.contains($0.key) }
        var seen: Set<String> = []
        for issue in issues where seen.insert(issue.key).inserted {
            dismissedServerIssues.append(DismissedServerIssue(key: issue.key, signature: issue.signature, dismissedAt: now))
        }
        if dismissedServerIssues.count > ServerIssues.maxEntries {
            dismissedServerIssues.removeFirst(dismissedServerIssues.count - ServerIssues.maxEntries)
        }
    }

    /// Forgets the clearing of failures that went away (a server back up, the panel answering
    /// again), so the next time it fails it shows. Returns whether anything changed.
    @discardableResult
    public mutating func forgetServerIssues(_ keys: Set<String>) -> Bool {
        let before = dismissedServerIssues.count
        dismissedServerIssues.removeAll { keys.contains($0.key) }
        return dismissedServerIssues.count != before
    }

    /// Drops entries older than `ServerIssues.maxAge`, except those whose failure is still
    /// listed (`active`: their keys), which would otherwise come back. Returns whether anything changed.
    @discardableResult
    public mutating func pruneDismissedServerIssues(keeping active: Set<String> = [], now: Date = Date()) -> Bool {
        let before = dismissedServerIssues.count
        dismissedServerIssues.removeAll { now.timeIntervalSince($0.dismissedAt) > ServerIssues.maxAge && !active.contains($0.key) }
        return dismissedServerIssues.count != before
    }
}
