import Foundation

/// `claudedeck projects`, `project add` and `new`: a session adds projects and starts Claude
/// sessions on its own (Settings › Agents › "Sessions may add projects and start Claude sessions",
/// off by default). No prompt per action; the guardrails are here: rate limits per calling
/// session, a cap on running sessions started this way, and the path rules for `project add`.
extension SessionCLI {
    /// At most this many Claude sessions started with `claudedeck new` run at once (all callers).
    public static let maxRunningStarted = 8

    /// Whether another session may start: the global cap first (it consumes nothing), then the
    /// caller's rate limit.
    public static func admitStart(caller: UUID, runningStarted: Int, book: inout SessionCLIBook, now: Date = Date()) -> AgentHTTPResponse? {
        guard runningStarted < maxRunningStarted else { return failure(429, "too_many_running", exit: .refused) }
        guard book.starts.allow(caller, now: now) else { return failure(429, "too_many_starts", exit: .refused) }
        return nil
    }

    // MARK: Project paths

    public enum PathRefusal: String, Error, Sendable, Equatable {
        /// Not an absolute path.
        case notAbsolute = "not_absolute"
        /// The system's folders (and `/` itself) are never projects.
        case systemPath = "system_path"
        /// `--create` only makes folders under the user's home.
        case outsideHome = "outside_home"
        case noSuchFolder = "no_such_folder"
        case notAFolder = "not_a_folder"

        public var response: AgentHTTPResponse {
            switch self {
            case .notAbsolute: failure(400, rawValue, exit: .usage)
            case .systemPath, .outsideHome: failure(403, rawValue, exit: .refused)
            case .noSuchFolder, .notAFolder: failure(404, rawValue, exit: .failed)
            }
        }
    }

    /// Folders that are never added or created (resolved, so `/etc` is `/private/etc`).
    public static let systemFolders = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db",
                                       "/private/var/root", "/Library", "/Applications", "/dev", "/cores", "/Volumes", "/opt/homebrew"]

    /// The folder `project add` uses: absolute, symlinks and `..` resolved, never a system folder
    /// or `/`. With `create`, a missing folder is made, but only below one of `createRoots`
    /// (the user's home; not its Library) and never the root itself.
    public static func projectFolder(_ raw: String, create: Bool, createRoots: [String],
                                     fileManager: FileManager = .default) -> Result<String, PathRefusal> {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("/") else { return .failure(.notAbsolute) }
        let path = resolved(raw)
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        guard path != "/", !systemFolders.contains(where: under) else { return .failure(.systemPath) }
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isFolder) {
            return isFolder.boolValue ? .success(path) : .failure(.notAFolder)
        }
        guard create else { return .failure(.noSuchFolder) }
        let roots = createRoots.map(resolved).filter { $0 != "/" }
        guard roots.contains(where: { root in path.hasPrefix(root + "/") && !path.hasPrefix(root + "/Library/") && !path.hasPrefix(root + "/.") }) else {
            return .failure(.outsideHome)
        }
        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return .failure(.noSuchFolder)
        }
        return .success(path)
    }

    /// `..` and symlinks resolved, also for a path whose last parts don't exist yet.
    public static func resolved(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            missing.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var base = url.resolvingSymlinksInPath().path
        // `resolvingSymlinksInPath` keeps /tmp and /var (it strips /private): the real folders count.
        for link in ["/tmp", "/var", "/etc"] where base == link || base.hasPrefix(link + "/") { base = "/private" + base }
        return missing.reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
    }

    // MARK: Projects

    public enum ProjectMatch: Equatable, Sendable {
        case found(UUID)
        case unknown
        case ambiguous
    }

    /// `ref`: `self` (the caller's project), an id or a unique prefix of one (4+ characters), a
    /// name (any case) or a folder path.
    public static func project(_ ref: String, callerProject: UUID?, projects: [Project]) -> ProjectMatch {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.isEmpty || ref.lowercased() == "self" { return callerProject.map(ProjectMatch.found) ?? .unknown }
        if let id = UUID(uuidString: ref) { return projects.contains { $0.id == id } ? .found(id) : .unknown }
        if ref.hasPrefix("/") {
            let path = resolved(ref)
            return projects.first { $0.path == ref || resolved($0.path) == path }.map { .found($0.id) } ?? .unknown
        }
        let named = projects.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return .found(named[0].id) }
        if named.count > 1 { return .ambiguous }
        guard ref.count >= 4, ref.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return .unknown }
        let prefixed = projects.filter { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }
        switch prefixed.count {
        case 0: return .unknown
        case 1: return .found(prefixed[0].id)
        default: return .ambiguous
        }
    }

    public static func projectsText(_ projects: [SessionCLIProject]) -> String {
        let header = ["ID", "SESSIONS", "GROUP", "NAME", "PATH"]
        let rows = projects.map { [String($0.id.uuidString.prefix(8)), String($0.sessions), $0.group ?? "-", $0.name, $0.path] }
        return table([header] + rows)
    }

    /// Columns padded to their widest cell (the last one isn't).
    public static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        let widths = (0..<max(0, first.count - 1)).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// The notification for sessions a caller started in a burst: one line, or a count.
    public static func startNotice(_ lines: [String]) -> String {
        lines.count == 1 ? lines[0] : String(localized: "Started \(lines.count) sessions: ") + lines.joined(separator: "; ")
    }
}

/// `GET /v1/cli/projects`, one entry; also what `project add` answers.
public struct SessionCLIProject: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var group: String?
    public var sessions: Int
    /// `project add`: the folder was already a project (nothing changed).
    public var existing: Bool?

    public init(id: UUID, name: String, path: String, group: String?, sessions: Int, existing: Bool? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.group = group
        self.sessions = sessions
        self.existing = existing
    }
}

/// `POST /v1/cli/projects/{ref}/sessions`.
public struct SessionCLIStarted: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var projectId: UUID
    public var project: String
    public var worktree: String?

    public init(id: UUID, name: String, projectId: UUID, project: String, worktree: String?) {
        self.id = id
        self.name = name
        self.projectId = projectId
        self.project = project
        self.worktree = worktree
    }
}
