import Foundation

/// `claudedeck`: a command for the terminals ClaudeDeck starts (Settings › Agents › Command-line
/// tool for sessions). It talks to the local API under `/v1/cli` with a token that only its own
/// session has (`CLAUDEDECK_CLI_TOKEN`, never the API's), so a session can do what its token's
/// scopes allow and nothing more. The command itself is a shell script (SessionCLIScript.swift);
/// the rules are here. Contract: docs/agents.md.
public enum SessionCLI {
    public static let prefix = "/v1/cli"

    /// The environment a session's terminal gets (only while the setting is on).
    public enum Env {
        public static let session = "CLAUDEDECK_SESSION"
        public static let token = "CLAUDEDECK_CLI_TOKEN"
        public static let url = "CLAUDEDECK_CLI_URL"
        public static let command = "CLAUDEDECK_CLI"
    }

    /// The command's exit codes: stable, documented, and sent by the API in `X-ClaudeDeck-Exit`.
    public enum Exit: Int32, Sendable, CaseIterable {
        /// Done; for `wait`: the command exited 0, or Claude is idle.
        case ok = 0
        /// For `wait`: the command exited non-zero. Otherwise any error (API off, not running…).
        case failed = 1
        /// Bad arguments, or not inside a ClaudeDeck session.
        case usage = 2
        /// For `wait`: Claude waits on a permission or a question.
        case blocked = 3
        /// The session's token doesn't allow it (scope, consent, rate limit, feature off).
        case refused = 4
        /// No such session or terminal.
        case unknown = 5
        /// For `wait`: still running when the timeout passed (like timeout(1)).
        case timeout = 124
    }

    /// The exit code for an answer: the API's header when there is one, else from the status.
    public static func exit(status: Int, header: String?) -> Exit {
        if let header, let raw = Int32(header.trimmingCharacters(in: .whitespaces)), let code = Exit(rawValue: raw) { return code }
        switch status {
        case 200..<300: return .ok
        case 400: return .usage
        case 401, 403, 429: return .refused
        case 404: return .unknown
        default: return .failed
        }
    }

    // MARK: Scopes

    public enum Scope: String, CaseIterable, Sendable, Codable {
        /// Every session's id, name, kind and state.
        case list
        /// A plain terminal next to itself.
        case open
        /// Typing into its own terminals; another Claude session gets a note unless the user allows typing.
        case send
        /// A session's screen and scrollback as text.
        case capture
        /// Until a command finishes or Claude stops.
        case wait
        /// A notification for the user.
        case notify
        /// A question for the user (a note) or an agent (`claudedeck-ask`'s rules).
        case ask
    }

    /// Claude sessions and the user's own terminals.
    public static let fullScopes: Set<Scope> = Set(Scope.allCases)
    /// A terminal a session opened runs what that session wrote: it may look and tell, not act.
    public static let openedScopes: Set<Scope> = [.list, .capture, .wait, .notify]

    public static func scopes(openedBy: UUID?) -> Set<Scope> { openedBy == nil ? fullScopes : openedScopes }

    // MARK: Routes

    public enum Route: Equatable, Sendable {
        case list
        case open
        case send(String)
        case capture(String)
        case wait(String)
        case notify
        case ask

        public var scope: Scope {
            switch self {
            case .list: .list
            case .open: .open
            case .send: .send
            case .capture: .capture
            case .wait: .wait
            case .notify: .notify
            case .ask: .ask
            }
        }
    }

    public enum Match: Equatable, Sendable {
        case route(Route)
        case notFound
        case methodNotAllowed
    }

    public static func handles(_ path: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }

    /// `{ref}` is a session id, a unique prefix of one (4+ characters) or `self`.
    public static func match(method: String, path: String) -> Match {
        var path = path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "cli" else { return .notFound }
        let rest = Array(parts.dropFirst(2))
        func expect(_ wanted: String, _ route: Route) -> Match { method == wanted ? .route(route) : .methodNotAllowed }
        switch rest.count {
        case 1 where rest[0] == "sessions": return expect("GET", .list)
        case 1 where rest[0] == "terminals": return expect("POST", .open)
        case 1 where rest[0] == "notify": return expect("POST", .notify)
        case 1 where rest[0] == "ask": return expect("POST", .ask)
        case 3 where rest[0] == "sessions":
            let ref = AgentHTTP.percentDecode(rest[1])
            switch rest[2] {
            case "send": return expect("POST", .send(ref))
            case "screen": return expect("GET", .capture(ref))
            case "wait": return expect("GET", .wait(ref))
            default: return .notFound
            }
        default: return .notFound
        }
    }

    /// The token first (401), then the route (404/405), then the token's scope (403).
    public static func resolve(_ request: AgentHTTPRequest, book: SessionCLIBook) -> Result<(caller: UUID, route: Route), AgentHTTPRequestRefusal> {
        guard let caller = book.caller(for: request.header("authorization")) else {
            return .failure(.init(failure(401, "unauthorized", exit: .refused)))
        }
        switch match(method: request.method, path: request.path) {
        case .notFound: return .failure(.init(failure(404, "not_found", exit: .unknown)))
        case .methodNotAllowed: return .failure(.init(failure(405, "method_not_allowed", exit: .usage)))
        case .route(let route):
            guard caller.scopes.contains(route.scope) else { return .failure(.init(failure(403, "not_allowed", exit: .refused))) }
            return .success((caller.session, route))
        }
    }

    /// Which session `ref` names among `sessions` (in the deck's order).
    public enum Target: Equatable, Sendable {
        case found(UUID)
        case unknown
        case ambiguous
    }

    public static func target(_ ref: String, caller: UUID, sessions: [UUID]) -> Target {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if ref.lowercased() == "self" { return .found(caller) }
        if let id = UUID(uuidString: ref) { return sessions.contains(id) ? .found(id) : .unknown }
        guard ref.count >= 4, ref.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return .unknown }
        let matches = sessions.filter { $0.uuidString.lowercased().hasPrefix(ref.lowercased()) }
        switch matches.count {
        case 0: return .unknown
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    // MARK: Sending

    public enum Delivery: Equatable, Sendable {
        /// Typed into the terminal.
        case type
        /// Left for the user as a note beside the session.
        case note
        case refuse(String)
    }

    /// Its own terminals (ones it opened, or plain terminals in a pane beside it) take the text;
    /// another Claude session gets it only with the user's "May type into Claude", else as a note;
    /// anyone else's plain terminal, and the session itself, are refused.
    public static func delivery(caller: UUID, target: UUID, targetKind: SessionKind, targetOpenedBy: UUID?,
                                besideCaller: Bool, mayTypeIntoClaude: Bool) -> Delivery {
        guard target != caller else { return .refuse("cannot_send_to_self") }
        switch targetKind {
        case .shell:
            return targetOpenedBy == caller || besideCaller ? .type : .refuse("not_yours")
        case .claude:
            return mayTypeIntoClaude ? .type : .note
        }
    }

    // MARK: Waiting

    public enum Progress: Equatable, Sendable {
        case running
        /// The command exited 0, Claude is idle, or the terminal is at its prompt (code unknown: nil).
        case finished(Int32?)
        case failed(Int32)
        /// Claude waits on the user: `needsPermission` or `needsAnswer`.
        case blocked(String)
        /// Not running (never started, or ended without a code to go by).
        case stopped

        public var exit: Exit {
            switch self {
            case .running: .timeout
            case .finished, .stopped: .ok
            case .failed: .failed
            case .blocked: .blocked
            }
        }

        public var result: String {
            switch self {
            case .running: "timeout"
            case .finished: "finished"
            case .failed: "failed"
            case .blocked: "blocked"
            case .stopped: "stopped"
            }
        }

        public var exitCode: Int32? {
            switch self {
            case .finished(let code): code
            case .failed(let code): code
            default: nil
            }
        }
    }

    /// A Claude session, from its state (`AppModel.stateName`) and its hook's time. After a send,
    /// the idle it was already in doesn't count: only a hook update newer than the send does
    /// (for at most `sendGrace`, in case the hooks are missing).
    public static let sendGrace: TimeInterval = 60

    public static func claudeProgress(state: String, updatedAt: Date?, sentAt: Date?, now: Date = Date()) -> Progress {
        if let sentAt, (updatedAt ?? .distantPast) <= sentAt, now.timeIntervalSince(sentAt) < sendGrace, state != "stopped" {
            return .running
        }
        switch state {
        case "idle": return .finished(0)
        case "needsPermission", "needsAnswer": return .blocked(state)
        case "stopped": return .stopped
        default: return .running
        }
    }

    /// A typed command may take a moment to start (the Return goes in after the text, and a shell
    /// still reading its rc files takes the line seconds later): after a send, a terminal counts as
    /// busy for `shellSendGrace`, then until its line editor has the terminal again (for at most
    /// `shellReadyLimit`: `sh` and `dash` have none) and its output has been quiet for `shellQuiet`.
    public static let shellSendGrace: TimeInterval = 2
    public static let shellReadyLimit: TimeInterval = 30
    public static let shellQuiet: TimeInterval = 1.5

    /// A plain terminal. `commandPending`: the command `open` started hasn't written its exit
    /// code yet; `commandExit`: that code; `processExit`: the shell's own, once it ended;
    /// `foregroundBusy`: something other than the shell has the terminal (a command is running);
    /// `lineEditing`: the shell sits in its line editor; `lastOutput`: when it last printed
    /// something (known once the command typed into it).
    public static func shellProgress(running: Bool, commandPending: Bool, commandExit: Int32?, processExit: Int32?,
                                     foregroundBusy: Bool, sentAt: Date?, lineEditing: Bool = true, lastOutput: Date? = nil,
                                     now: Date = Date()) -> Progress {
        guard running else {
            if let code = commandPending ? processExit : commandExit ?? processExit {
                return code == 0 ? .finished(0) : .failed(code)
            }
            return .stopped
        }
        if commandPending || foregroundBusy { return .running }
        if let sentAt {
            let since = now.timeIntervalSince(sentAt)
            if since < shellSendGrace || (!lineEditing && since < shellReadyLimit) { return .running }
            if let lastOutput, lastOutput > sentAt, now.timeIntervalSince(lastOutput) < shellQuiet { return .running }
        }
        if let commandExit { return commandExit == 0 ? .finished(0) : .failed(commandExit) }
        return .finished(nil)
    }

    /// A terminal with Program Status (ProgramStatus.swift): what its program says wins over the
    /// guesses above, except that a command typed a moment ago (`fallback` still `.running`) isn't
    /// reported done by the previous command's result. Blocked is "blocked" (exit 3 for `wait`).
    public static func programProgress(_ program: ProgramStatus.State?, exitCode: Int32?, fallback: Progress) -> Progress {
        guard let program else { return fallback }
        switch program {
        case .blocked: return .blocked(blockedState)
        case .working: return .running
        case .finished, .failed:
            switch fallback {
            // Still starting, or a code of its own (the command `open` ran): that's newer.
            case .running, .finished(.some), .failed: return fallback
            case .stopped: return fallback
            case .blocked, .finished(nil):
                if program == .failed { return .failed(exitCode ?? 1) }
                return .finished(exitCode ?? 0)
            }
        }
    }

    /// The `state` of a terminal whose program waits for the user (`list`, `wait`).
    public static let blockedState = "blocked"

    /// The code in a `waitpid` status: the exit code, or 128 + the signal.
    public static func exitCode(waitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// One long-poll answers within this many seconds; the command asks again until its own timeout.
    public static let maxWaitWindow = 25

    public static func waitText(_ progress: Progress, detail: String?) -> String {
        switch progress {
        case .running: "timeout: still running"
        case .finished(let code): code.map { "finished (exit \($0))" } ?? "finished"
        case .failed(let code): "failed (exit \(code))"
        case .blocked(let state): "blocked: "
            + (state == "needsPermission" ? "needs permission" : state == blockedState ? "needs input" : "asking a question")
            + (detail.map { " — \($0)" } ?? "")
        case .stopped: "stopped: not running"
        }
    }

    // MARK: Opening

    public enum Split: String, Sendable, CaseIterable {
        case right, left, down, none

        /// `down` is placed like `right`: ClaudeDeck's panes sit side by side.
        public var before: Bool { self == .left }
    }

    // MARK: Capture

    /// A screen (`TermScreen.lines`) as text: trailing spaces cut from every line; `trim` also
    /// drops blank lines at the top and bottom; `last` keeps the last N lines (after trimming).
    public static func text(of lines: [[TermCell]], last: Int?, trim: Bool) -> String {
        var rows = lines.map { line in
            String(line.filter { $0.width != 0 }.map(\.text).joined().reversed().drop(while: { $0 == " " }).reversed())
        }
        if trim {
            while rows.last?.isEmpty == true { rows.removeLast() }
            while rows.first?.isEmpty == true { rows.removeFirst() }
        }
        if let last { rows = Array(rows.suffix(max(0, last))) }
        return rows.joined(separator: "\n")
    }

    // MARK: Listing

    public static func listText(_ sessions: [SessionCLIInfo]) -> String {
        let header = ["ID", "KIND", "STATE", "PANE", "WHOSE", "NAME"]
        let rows = sessions.map { info in
            [String(info.id.uuidString.prefix(8)), info.kind, info.state, info.pane.map(String.init) ?? "-",
             info.isSelf ? "self" : info.openedBySelf ? "mine" : "-", info.name]
        }
        let all = [header] + rows
        let widths = (0..<(header.count - 1)).map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    // MARK: Answers

    /// JSON, or the `text` when the command didn't ask for `--json`; the exit code in a header.
    public static func answer<T: Encodable>(_ status: Int, _ value: T, text: String, exit: Exit, json: Bool) -> AgentHTTPResponse {
        var response: AgentHTTPResponse = json
            ? .json(status, value)
            : AgentHTTPResponse(status: status, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
        response.headers[exitHeader] = String(exit.rawValue)
        return response
    }

    public static func failure(_ status: Int, _ code: String, exit: Exit) -> AgentHTTPResponse {
        var response = AgentHTTPResponse.error(status, code)
        response.headers[exitHeader] = String(exit.rawValue)
        return response
    }

    public static let exitHeader = "X-ClaudeDeck-Exit"

    /// Form bodies (`curl --data-urlencode`) and queries alike.
    public static func form(_ body: Data) -> [String: String] {
        String(data: body, encoding: .utf8).map(AgentHTTP.queryItems) ?? [:]
    }

    public static let maxText = 16_000
    public static let maxNotice = 1_000
}

/// `GET /v1/cli/sessions`, one entry.
public struct SessionCLIInfo: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// `claude` or `terminal`.
    public var kind: String
    public var state: String
    public var detail: String?
    public var projectId: UUID
    public var project: String
    /// Its place among the visible panes, 1 = leftmost; nil when not on screen.
    public var pane: Int?
    public var isSelf: Bool
    /// The caller opened it (`claudedeck open`).
    public var openedBySelf: Bool
    public var openedBy: UUID?

    public init(id: UUID, name: String, kind: String, state: String, detail: String?, projectId: UUID, project: String,
                pane: Int?, isSelf: Bool, openedBySelf: Bool, openedBy: UUID?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.detail = detail
        self.projectId = projectId
        self.project = project
        self.pane = pane
        self.isSelf = isSelf
        self.openedBySelf = openedBySelf
        self.openedBy = openedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, state, detail, projectId, project, pane, isSelf = "self", openedBySelf = "mine", openedBy
    }

    /// Every key is always there (null when unknown).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(project, forKey: .project)
        try c.encode(pane, forKey: .pane)
        try c.encode(isSelf, forKey: .isSelf)
        try c.encode(openedBySelf, forKey: .openedBySelf)
        try c.encode(openedBy, forKey: .openedBy)
    }
}

/// What the app keeps for the command: each session's token and scopes, and what `wait` goes by.
/// In memory only: a session gets a new token whenever it starts.
public struct SessionCLIBook: Sendable {
    public struct Grant: Sendable, Equatable {
        public var token: String
        public var scopes: Set<SessionCLI.Scope>
    }

    public private(set) var grants: [UUID: Grant] = [:]
    /// Terminals `open` started with a command, until it writes its exit code here.
    public var exitFiles: [UUID: URL] = [:]
    /// That command's exit code.
    public var commandExits: [UUID: Int32] = [:]
    /// A terminal's shell ended with this code.
    public var processExits: [UUID: Int32] = [:]
    /// The command last typed text with Return into this session.
    public var sentAt: [UUID: Date] = [:]
    public var notices = SessionCLILimiter(max: 10, window: 10 * 60)

    public init() {}

    /// The session's token (kept while it lives), with these scopes.
    public mutating func token(for session: UUID, scopes: Set<SessionCLI.Scope>) -> String {
        let token = grants[session]?.token ?? AgentBearer.newToken()
        grants[session] = Grant(token: token, scopes: scopes)
        return token
    }

    /// Whose token this is (`Authorization: Bearer …`), compared in constant time.
    public func caller(for header: String?) -> (session: UUID, scopes: Set<SessionCLI.Scope>)? {
        guard let presented = AgentBearer.credential(from: header) else { return nil }
        var found: (UUID, Set<SessionCLI.Scope>)?
        for (session, grant) in grants where AgentBearer.matches(presented, expected: grant.token) { found = (session, grant.scopes) }
        return found
    }

    /// The terminal starts again: what `wait` knew was about the previous run (the token stays).
    public mutating func restarted(_ session: UUID) {
        exitFiles[session] = nil
        commandExits[session] = nil
        processExits[session] = nil
        sentAt[session] = nil
    }

    public mutating func forget(_ session: UUID) {
        grants[session] = nil
        exitFiles[session] = nil
        commandExits[session] = nil
        processExits[session] = nil
        sentAt[session] = nil
    }
}

/// At most `max` in `window` per session (notifications and questions from the command).
public struct SessionCLILimiter: Sendable, Equatable {
    public let max: Int
    public let window: TimeInterval
    private var times: [UUID: [Date]] = [:]

    public init(max: Int, window: TimeInterval) {
        self.max = max
        self.window = window
    }

    public mutating func allow(_ session: UUID, now: Date = Date()) -> Bool {
        var recent = (times[session] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < max else { times[session] = recent; return false }
        recent.append(now)
        times[session] = recent
        return true
    }
}

/// `POST /v1/cli/terminals`.
public struct SessionCLIOpened: Encodable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var cwd: String
    public var command: String?
    /// In a pane beside the caller; false: started, only in the sidebar.
    public var shown: Bool
    public init(id: UUID, name: String, cwd: String, command: String?, shown: Bool) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.shown = shown
    }
}

/// `POST /v1/cli/sessions/{ref}/send`: `terminal`, `claude` or `note`.
public struct SessionCLISent: Encodable, Sendable, Equatable {
    public var delivered: String
    public var noteId: UUID?
    public init(delivered: String, noteId: UUID? = nil) {
        self.delivered = delivered
        self.noteId = noteId
    }
}

/// `GET /v1/cli/sessions/{ref}/wait`.
public struct SessionCLIWaited: Encodable, Sendable, Equatable {
    /// `finished`, `failed`, `blocked`, `stopped` or `timeout`.
    public var result: String
    public var exitCode: Int32?
    public var state: String
    public var detail: String?
    public init(_ progress: SessionCLI.Progress, state: String, detail: String?) {
        result = progress.result
        exitCode = progress.exitCode
        self.state = state
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case result, exitCode, state, detail }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result, forKey: .result)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
    }
}

/// `GET /v1/cli/sessions/{ref}/screen`.
public struct SessionCLIScreen: Encodable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}
