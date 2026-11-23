import Foundation

/// `claudedeck project rename PROJECT NEWNAME [--folder]`: what the project's Rename… does
/// (with "Rename the folder too" for `--folder`), for sessions of a coordinator project only.
extension SessionCLI {
    /// A session or terminal of the project that is running (`409 sessions_running`).
    public struct RunningSession: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        /// `claude` or `terminal`.
        public var kind: String
        public init(id: UUID, name: String, kind: String) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public enum ProjectRenameCheck: Equatable, Sendable {
        case allowed
        /// The caller's own project isn't a coordinator (`403 not_coordinator`).
        case notCoordinator
        /// Empty name (`400 bad_name`).
        case badName
        /// Something of the project runs (`409 sessions_running`); nothing is changed.
        case sessionsRunning([RunningSession])
    }

    /// The order: who asks (only from a coordinator project), what it asks for, then whether the
    /// project is idle. Running sessions refuse a name-only rename too: the owner's rule is that a
    /// project is renamed only while nothing of it runs.
    public static func projectRenameCheck(callerProject: Project?, name: String, running: [RunningSession]) -> ProjectRenameCheck {
        guard callerProject?.isCoordinator == true else { return .notCoordinator }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .badName }
        return running.isEmpty ? .allowed : .sessionsRunning(running)
    }

    /// `409 sessions_running`: JSON in text mode too (the script prints `message`), with the list.
    public static func sessionsRunningFailure(_ running: [RunningSession]) -> AgentHTTPResponse {
        let list = running.map { "\($0.name) (\($0.id.uuidString.prefix(8)), \($0.kind))" }.joined(separator: ", ")
        let body = SessionsRunningBody(error: "sessions_running", message: "stop these first: \(list)", sessions: running)
        var response = AgentHTTPResponse.json(409, body)
        response.headers[exitHeader] = String(Exit.failed.rawValue)
        return response
    }

    struct SessionsRunningBody: Encodable {
        var error: String
        var message: String
        var sessions: [RunningSession]
    }

    /// A refusal with a message (`{"error","message"}`), JSON in text mode too.
    public static func failure(_ status: Int, _ code: String, message: String, exit: Exit) -> AgentHTTPResponse {
        var response = AgentHTTPResponse.json(status, ["error": code, "message": message])
        response.headers[exitHeader] = String(exit.rawValue)
        return response
    }

    /// `ProjectFolderRename.Problem` as the command's answer.
    public static func projectRenameFailure(_ problem: ProjectFolderRename.Problem) -> AgentHTTPResponse {
        switch problem {
        case .badName: failure(400, "bad_name", message: problem.message, exit: .usage)
        case .exists: failure(409, "exists", message: problem.message, exit: .failed)
        case .missing: failure(409, "missing", message: problem.message, exit: .failed)
        case .running: failure(409, "sessions_running", message: problem.message, exit: .failed)
        case .failed(let reason): failure(500, "rename_failed", message: reason, exit: .failed)
        }
    }
}

/// `POST /v1/cli/projects/{ref}/rename`.
public struct SessionCLIProjectRenamed: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var oldName: String
    public var path: String
    public var oldPath: String
    /// The folder moved (`--folder`, and the name differed from the folder's).
    public var folderMoved: Bool
    /// What ServerPlan did with its paths; nil when the folder didn't move.
    public var serverplan: ServerPlanPathRelocation.Summary?

    public init(id: UUID, name: String, oldName: String, path: String, oldPath: String, folderMoved: Bool,
                serverplan: ServerPlanPathRelocation.Summary?) {
        self.id = id
        self.name = name
        self.oldName = oldName
        self.path = path
        self.oldPath = oldPath
        self.folderMoved = folderMoved
        self.serverplan = serverplan
    }

    public var text: String {
        var lines = ["renamed: \(oldName) → \(name)"]
        if folderMoved { lines.append("folder: \(oldPath) → \(path)") }
        if let serverplan { lines.append("serverplan: " + serverplan.text) }
        return lines.joined(separator: "\n")
    }
}
