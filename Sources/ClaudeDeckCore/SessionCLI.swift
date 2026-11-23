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
        /// For `wait`: the Claude session stopped on its plan's usage limit and waits for the
        /// reset (no other account to move to, or moving is off). One that moves to another
        /// account keeps running: `wait` keeps waiting for it.
        case limited = 6
        /// An owner approval is still pending: `claudedeck server … --no-wait`, the first answer of
        /// a gated call (the script then long-polls `approval wait`), or `approval wait --timeout`
        /// that ran out. The call goes on in ClaudeDeck once the owner answers.
        case pendingApproval = 75
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
        /// The deck's projects (`claudedeck projects`).
        case projects
        /// Adding projects, starting Claude sessions and resuming stopped ones it started (also
        /// needs Settings › "Sessions may add projects and start Claude sessions").
        case start
        /// ServerPlan through the app (also needs "Sessions may use ServerPlan").
        case server
        /// A question for the owner that doesn't block (`claudedeck decide`), and reading the answers.
        case decide
        /// Moving itself to another Claude account (`claudedeck account switch`).
        case account
        /// Reserving simulators of its own (`claudedeck sim`; also needs "Sessions may reserve simulators").
        case simulators
        /// Token and cost usage per project (`claudedeck usage`; read-only).
        case usage
        /// Ending itself or a session it started, and removing such a session from the deck
        /// (also needs Settings › "Sessions may close sessions they started").
        case close
        /// Build slots (`claudedeck slot`, `claudedeck heavy`): also for terminals a session opened,
        /// where the builds run.
        case slots
        /// Re-running a terminal's command in its own pane (`claudedeck restart`): its own
        /// terminals, and with Settings › "Sessions may restart their project's command terminals"
        /// the terminals with a startup command in its project.
        case restart
        /// Compacting its own context, or that of a Claude session it started (`claudedeck compact`).
        case compact
        /// Asking the owner to turn Claude Code's Remote Control off (`claudedeck remote-control
        /// off`): only ever through an approval the owner gives.
        case remoteControl
        /// Setting a project's status line (`claudedeck project status set|clear`): its own
        /// project, or any with the owner's coordinator switch on its project. Reading is `list`.
        case projectStatus
        /// Renaming a project and moving its folder (`claudedeck project rename`): Claude sessions
        /// only, and only from a project the owner marked as a coordinator.
        case projectRename
    }

    /// Claude sessions and the user's own terminals.
    public static let fullScopes: Set<Scope> = Set(Scope.allCases)
    /// A terminal a session opened runs what that session wrote: it may look and tell, not act.
    public static let openedScopes: Set<Scope> = [.list, .capture, .wait, .notify, .usage, .slots]

    /// Claude sessions only: the owner's own plain terminals don't rename projects.
    public static let claudeOnlyScopes: Set<Scope> = [.projectRename]

    public static func scopes(openedBy: UUID?, kind: SessionKind = .claude) -> Set<Scope> {
        guard openedBy == nil else { return openedScopes }
        return kind == .claude ? fullScopes : fullScopes.subtracting(claudeOnlyScopes)
    }

    // MARK: Routes

    public enum Route: Equatable, Sendable {
        case list
        case open
        case send(String)
        case capture(String)
        case wait(String)
        case notify
        case ask
        case projects
        case addProject
        /// `{ref}`: a project id, a unique prefix of one, its name, its path, or `self`.
        case newSession(String)
        /// `/v1/cli/server/{command}`: one of `ServerPlanCLI.commands` (any method; the table checks it).
        case server(String)
        /// `GET /v1/cli/presets`: every project's preset.
        case presets
        /// `GET`/`POST /v1/cli/projects/{ref}/preset`.
        case showPreset(String)
        case setPreset(String)
        /// `GET /v1/cli/queue`, `GET /v1/cli/queue/{id}`, `POST /v1/cli/queue/{id}/cancel`.
        case queue
        case queueItem(String)
        case cancelQueued(String)
        /// `GET /v1/cli/wait?ids=…&mode=all|any`.
        case waitMany
        /// `POST /v1/cli/decisions`: a new decision for the owner.
        case decide
        /// `GET /v1/cli/decisions`.
        case decisions
        /// `GET /v1/cli/decisions/{id}`.
        case decision(String)
        /// `POST /v1/cli/decisions/{id}/cancel`: withdraw a pending one.
        case cancelDecision(String)
        /// `claudedeck approval status|wait|cancel ID`: an approval a `server` call waits on
        /// (`GET /v1/cli/approvals/{id}`, `GET …/wait`, `POST …/cancel`).
        case approval(String)
        case waitApproval(String)
        case cancelApproval(String)
        /// `GET /v1/cli/accounts`: the Claude accounts and their usage.
        case accounts
        /// `GET /v1/cli/accounts/current`: the caller's account.
        case currentAccount
        /// `POST /v1/cli/accounts/switch`: the caller moves itself to another account.
        case switchAccount
        /// `GET /v1/cli/sim`: the simulators sessions hold.
        case simList
        /// `POST /v1/cli/sim/acquire`.
        case simAcquire
        /// `POST /v1/cli/sim/release`.
        case simRelease
        /// `POST /v1/cli/sim/prune`: deletes ClaudeDeck's unused pool simulators (`dry_run`, `older_than`).
        case simPrune
        /// `GET /v1/cli/usage`.
        case usage
        /// `GET /v1/cli/sessions/{ref}/status`: state, who started it, stall watch, simulators.
        case status(String)
        /// `POST /v1/cli/sessions/{ref}/close`.
        case close(String)
        /// `POST /v1/cli/sessions/{ref}/remove`: a session that isn't running leaves the deck.
        case remove(String)
        /// `POST /v1/cli/sessions/{ref}/restart`: its process is stopped and its command re-run in the same pane.
        case restart(String)
        /// `POST /v1/cli/sessions/{ref}/compact`: `/compact` is typed into it (after its turn when busy).
        case compact(String)
        /// `POST /v1/cli/sessions/{ref}/resume`: a stopped (or removed) Claude session it started
        /// is resumed with its conversation (`prompt`, `queue=1`).
        case resume(String)
        /// `POST /v1/cli/remote-control/off` (`target`: a session ref or `all`): an approval for
        /// the owner; once approved, Remote Control is turned off there.
        case remoteControlOff
        /// `GET /v1/cli/load`: the Mac's load level, its numbers and the build slots.
        case load
        /// `POST /v1/cli/slot/{kind}/acquire` and `…/release` (kind: `build`).
        case slotAcquire(String)
        case slotRelease(String)
        /// `GET /v1/cli/project-status`: every project's status line.
        case projectStatuses
        /// `GET`/`POST /v1/cli/projects/{ref}/status` (`clear=1` removes it).
        case showProjectStatus(String)
        case setProjectStatus(String)
        /// `POST /v1/cli/projects/{ref}/rename` (`name`, `folder=1`).
        case renameProject(String)

        public var scope: Scope {
            switch self {
            case .list: .list
            case .open: .open
            case .send: .send
            case .capture: .capture
            case .wait: .wait
            case .notify: .notify
            case .ask: .ask
            case .projects: .projects
            case .addProject, .newSession, .presets, .showPreset, .setPreset, .queue, .queueItem, .cancelQueued, .resume: .start
            case .server, .approval, .waitApproval, .cancelApproval: .server
            case .waitMany: .wait
            case .decide, .decisions, .decision, .cancelDecision: .decide
            case .accounts, .currentAccount: .list
            case .switchAccount: .account
            case .simList, .simAcquire, .simRelease, .simPrune: .simulators
            case .usage: .usage
            case .status: .list
            case .close, .remove: .close
            case .restart: .restart
            case .compact: .compact
            case .remoteControlOff: .remoteControl
            case .load: .list
            case .slotAcquire, .slotRelease: .slots
            case .projectStatuses, .showProjectStatus: .list
            case .setProjectStatus: .projectStatus
            case .renameProject: .projectRename
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
        if let status = projectStatusMatch(method: method, rest: rest) { return status }
        switch rest.count {
        case 1 where rest[0] == "sessions": return expect("GET", .list)
        case 1 where rest[0] == "terminals": return expect("POST", .open)
        case 1 where rest[0] == "notify": return expect("POST", .notify)
        case 1 where rest[0] == "ask": return expect("POST", .ask)
        case 1 where rest[0] == "projects": return method == "POST" ? .route(.addProject) : expect("GET", .projects)
        case 3 where rest[0] == "projects" && rest[2] == "sessions": return expect("POST", .newSession(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "projects" && rest[2] == "rename": return expect("POST", .renameProject(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "projects" && rest[2] == "preset":
            let ref = AgentHTTP.percentDecode(rest[1])
            return method == "POST" ? .route(.setPreset(ref)) : expect("GET", .showPreset(ref))
        case 1 where rest[0] == "presets": return expect("GET", .presets)
        case 1 where rest[0] == "queue": return expect("GET", .queue)
        case 2 where rest[0] == "queue": return expect("GET", .queueItem(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "queue" && rest[2] == "cancel": return expect("POST", .cancelQueued(AgentHTTP.percentDecode(rest[1])))
        case 1 where rest[0] == "wait": return expect("GET", .waitMany)
        case 2 where rest[0] == "server": return .route(.server(rest[1]))
        case 2 where rest[0] == "approvals": return expect("GET", .approval(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "approvals" && rest[2] == "wait": return expect("GET", .waitApproval(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "approvals" && rest[2] == "cancel": return expect("POST", .cancelApproval(AgentHTTP.percentDecode(rest[1])))
        case 1 where rest[0] == "decisions": return method == "POST" ? .route(.decide) : expect("GET", .decisions)
        case 2 where rest[0] == "decisions": return expect("GET", .decision(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "decisions" && rest[2] == "cancel": return expect("POST", .cancelDecision(AgentHTTP.percentDecode(rest[1])))
        case 1 where rest[0] == "accounts": return expect("GET", .accounts)
        case 2 where rest[0] == "accounts" && rest[1] == "current": return expect("GET", .currentAccount)
        case 2 where rest[0] == "accounts" && rest[1] == "switch": return expect("POST", .switchAccount)
        case 1 where rest[0] == "sim": return expect("GET", .simList)
        case 2 where rest[0] == "sim" && rest[1] == "acquire": return expect("POST", .simAcquire)
        case 2 where rest[0] == "sim" && rest[1] == "release": return expect("POST", .simRelease)
        case 2 where rest[0] == "sim" && rest[1] == "prune": return expect("POST", .simPrune)
        case 1 where rest[0] == "usage": return expect("GET", .usage)
        case 1 where rest[0] == "load": return expect("GET", .load)
        case 2 where rest[0] == "remote-control" && rest[1] == "off": return expect("POST", .remoteControlOff)
        case 3 where rest[0] == "slot" && rest[2] == "acquire": return expect("POST", .slotAcquire(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "slot" && rest[2] == "release": return expect("POST", .slotRelease(AgentHTTP.percentDecode(rest[1])))
        case 3 where rest[0] == "sessions":
            let ref = AgentHTTP.percentDecode(rest[1])
            switch rest[2] {
            case "send": return expect("POST", .send(ref))
            case "screen": return expect("GET", .capture(ref))
            case "wait": return expect("GET", .wait(ref))
            case "status": return expect("GET", .status(ref))
            case "close": return expect("POST", .close(ref))
            case "remove": return expect("POST", .remove(ref))
            case "restart": return expect("POST", .restart(ref))
            case "compact": return expect("POST", .compact(ref))
            case "resume": return expect("POST", .resume(ref))
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
    /// A Claude session the caller started (`claudedeck new`, `targetStartedBy`) is its own too.
    /// `projectCommandTerminal`: the target is a terminal with a startup command in the caller's
    /// project and the owner allows restarting those (`isProjectCommandTerminal` and the setting).
    public static func delivery(caller: UUID, target: UUID, targetKind: SessionKind, targetOpenedBy: UUID?,
                                besideCaller: Bool, mayTypeIntoClaude: Bool, targetStartedBy: UUID? = nil,
                                projectCommandTerminal: Bool = false) -> Delivery {
        guard target != caller else { return .refuse("cannot_send_to_self") }
        switch targetKind {
        case .shell:
            return targetOpenedBy == caller || besideCaller || projectCommandTerminal ? .type : .refuse("not_yours")
        case .claude:
            return mayTypeIntoClaude || targetStartedBy == caller ? .type : .note
        }
    }

    // MARK: Closing

    /// `close`: the caller itself, or a session it started or a terminal it opened (directly or
    /// through sessions it started: `startedBy`/`openedBy` all the way up). Never one the owner
    /// started (neither), nor a terminal another session opened. `startedBy` gives each session's
    /// starter, `openedBy` each terminal's opener (`claudedeck open`).
    public static func mayClose(caller: UUID, target: UUID, startedBy: [UUID: UUID], openedBy: [UUID: UUID] = [:]) -> Bool {
        if target == caller { return true }
        var current = target
        // Bounded: a broken deck with a loop can't hang the API.
        for _ in 0..<64 {
            guard let parent = startedBy[current] ?? openedBy[current] else { return false }
            if parent == caller { return true }
            current = parent
        }
        return false
    }

    /// Whether `close` also removes the session from the deck: `--remove` always does, `--keep`
    /// never does, otherwise Settings › "Closed sessions are removed from the list" decides.
    /// (`--remove` wins over `--keep`; the script refuses both together.)
    public static func removesAfterClose(form: [String: String], setting: Bool) -> Bool {
        if form["remove"] == "1" { return true }
        if form["keep"] == "1" { return false }
        return setting
    }

    public enum RemoveCheck: Equatable, Sendable {
        case allowed
        /// The owner's session, or one another session started (`403 not_yours`).
        case notYours
        /// Its process still runs (`409 still_running`: `close` it).
        case stillRunning
    }

    /// `remove`: the same sessions `close` may end (`mayClose`), and only once they've stopped.
    public static func mayRemove(caller: UUID, target: UUID, startedBy: [UUID: UUID], openedBy: [UUID: UUID] = [:],
                                 running: Bool) -> RemoveCheck {
        guard mayClose(caller: caller, target: target, startedBy: startedBy, openedBy: openedBy) else { return .notYours }
        return running ? .stillRunning : .allowed
    }

    // MARK: Restarting

    /// An automatic terminal of the caller's project: a plain terminal with a startup command
    /// (e.g. `cd api; make run`) in the same project as the caller.
    public static func isProjectCommandTerminal(callerProject: UUID?, targetKind: SessionKind, targetProject: UUID,
                                                targetCommand: String?) -> Bool {
        guard targetKind == .shell, let callerProject, callerProject == targetProject else { return false }
        return !(targetCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public enum RestartCheck: Equatable, Sendable {
        case allowed
        /// The caller itself (`400 cannot_restart_self`).
        case isSelf
        /// A command terminal of its project while the owner's setting is off (`403 restart_off`).
        case restartOff
        /// A Claude session it started while "Sessions may close sessions they started" is off (`403 close_off`).
        case closeOff
        /// Anything else (`403 not_yours`): other projects, the owner's Claude sessions, plain
        /// terminals without a command, terminals other sessions opened elsewhere.
        case notYours
    }

    /// `restart`: its own terminals (opened by it or by sessions it started: `mayClose`) always;
    /// a terminal with a startup command in its own project only with `mayRestartProjectTerminals`;
    /// a Claude session only when it started it, under the close rules (`mayCloseSessions`).
    public static func mayRestart(caller: UUID, callerProject: UUID?, target: UUID, targetKind: SessionKind,
                                  targetProject: UUID, targetCommand: String?, startedBy: [UUID: UUID],
                                  openedBy: [UUID: UUID], mayRestartProjectTerminals: Bool,
                                  mayCloseSessions: Bool) -> RestartCheck {
        guard target != caller else { return .isSelf }
        let own = mayClose(caller: caller, target: target, startedBy: startedBy, openedBy: openedBy)
        switch targetKind {
        case .claude:
            guard own else { return .notYours }
            return mayCloseSessions ? .allowed : .closeOff
        case .shell:
            if own { return .allowed }
            guard isProjectCommandTerminal(callerProject: callerProject, targetKind: targetKind,
                                           targetProject: targetProject, targetCommand: targetCommand) else { return .notYours }
            return mayRestartProjectTerminals ? .allowed : .restartOff
        }
    }

    // MARK: Compacting

    public enum CompactCheck: Equatable, Sendable {
        case allowed
        /// A plain terminal (`400 not_claude`).
        case notClaude
        /// The owner's session, or one another session started (`403 not_yours`).
        case notYours
    }

    /// `compact`: a Claude session only; the caller itself, or a session it started (directly or
    /// through sessions it started), the same chain `close` follows (`mayClose`). No setting:
    /// compacting loses nothing the transcript doesn't keep.
    public static func mayCompact(caller: UUID, target: UUID, targetKind: SessionKind, startedBy: [UUID: UUID],
                                  openedBy: [UUID: UUID] = [:]) -> CompactCheck {
        guard targetKind == .claude else { return .notClaude }
        return mayClose(caller: caller, target: target, startedBy: startedBy, openedBy: openedBy) ? .allowed : .notYours
    }

    /// What `compact` does with a running Claude session in this state: type `/compact` now (idle,
    /// or at its usage limit, where it sits at the prompt), once its turn is over (working), or
    /// refuse (`409 blocked`: it waits on a permission or a question).
    public enum CompactTiming: Equatable, Sendable {
        case now
        case afterTurn
        case blocked
    }

    public static func compactTiming(_ progress: Progress) -> CompactTiming {
        // At a usage limit /compact (an API call) would fail: it waits for the turn the session
        // runs once it is resumed (after the reset or an account switch).
        switch progress {
        case .finished, .stopped: .now
        case .blocked: .blocked
        case .running, .failed, .limited: .afterTurn
        }
    }

    /// A deferred `/compact` (`compact self`, or a busy session) is given up after this long (logged).
    public static let compactLimit: TimeInterval = 30 * 60

    /// How long `close` waits for Claude to leave after `/exit` before it gives up (or, with
    /// `--force`, ends the process).
    public static let closeGrace: TimeInterval = 15
    /// `close self` without `--force`: `/exit` waits in the prompt queue until the current turn
    /// is over; after this long the close is given up (logged).
    public static let selfCloseLimit: TimeInterval = 30 * 60

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
        /// A Claude session stopped on its plan's usage limit, waiting for the reset (when known).
        case limited(Date?)

        public var exit: Exit {
            switch self {
            case .running: .timeout
            case .finished, .stopped: .ok
            case .failed: .failed
            case .blocked: .blocked
            case .limited: .limited
            }
        }

        public var result: String {
            switch self {
            case .running: "timeout"
            case .finished: "finished"
            case .failed: "failed"
            case .blocked: "blocked"
            case .stopped: "stopped"
            case .limited: "limited"
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
        // A server still runs: `wait` doesn't return for it.
        case .working, .service: return .running
        case .finished, .failed:
            switch fallback {
            // Still starting, or a code of its own (the command `open` ran): that's newer.
            case .running, .finished(.some), .failed: return fallback
            case .stopped, .limited: return fallback
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
        case .limited(let reset): "limited: usage limit reached" + (reset.map { ", resets \(ISO8601DateFormatter().string(from: $0))" } ?? "")
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
    /// Claude sessions: the account it runs on (`default` or an account's name); nil for terminals.
    public var account: String?
    /// When its usage limit resets, while it waits for that (state `limit_reached`).
    public var limitResetsAt: Date?

    public init(id: UUID, name: String, kind: String, state: String, detail: String?, projectId: UUID, project: String,
                pane: Int?, isSelf: Bool, openedBySelf: Bool, openedBy: UUID?, account: String? = nil, limitResetsAt: Date? = nil) {
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
        self.account = account
        self.limitResetsAt = limitResetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, state, detail, projectId, project, pane, isSelf = "self", openedBySelf = "mine", openedBy, account, limitResetsAt
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
        try c.encode(account, forKey: .account)
        try c.encode(limitResetsAt, forKey: .limitResetsAt)
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
    /// `claudedeck new`: at most 5 Claude sessions in 10 minutes per calling session.
    public var starts = SessionCLILimiter(max: 5, window: 10 * 60)
    /// `claudedeck project add`: at most 10 new projects an hour per calling session.
    public var projectAdds = SessionCLILimiter(max: 10, window: 60 * 60)
    /// `claudedeck decide`: at most 10 questions in 10 minutes per calling session.
    public var decisions = SessionCLILimiter(max: 10, window: 10 * 60)
    /// "Session X started session Y" notices waiting to go out together (a burst is one notification).
    public var startNotices: [UUID: [String]] = [:]

    public init() {}

    /// The session's token (kept while it lives), with these scopes.
    public mutating func token(for session: UUID, scopes: Set<SessionCLI.Scope>) -> String {
        let token = grants[session]?.token ?? AgentBearer.newToken()
        grants[session] = Grant(token: token, scopes: scopes)
        return token
    }

    /// A session reattached from the session helper keeps the token its process was started with.
    public mutating func adopt(_ token: String, for session: UUID, scopes: Set<SessionCLI.Scope>) {
        grants[session] = Grant(token: token, scopes: scopes)
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
    /// `claude`, `terminal`, `note`; for a stopped Claude session a session closed: `resumed`
    /// (it's resuming with the text as its first message) or `resume_queued` (it waits in the
    /// start queue, `queueId`, and the text with it).
    public var delivered: String
    public var noteId: UUID?
    public var queueId: String?
    public init(delivered: String, noteId: UUID? = nil, queueId: String? = nil) {
        self.delivered = delivered
        self.noteId = noteId
        self.queueId = queueId
    }
}

/// `GET /v1/cli/sessions/{ref}/wait`.
public struct SessionCLIWaited: Encodable, Sendable, Equatable {
    /// `finished`, `failed`, `blocked`, `stopped` or `timeout`.
    public var result: String
    public var exitCode: Int32?
    public var state: String
    public var detail: String?
    /// `limited`: when the usage limit resets (nil: unknown, or not limited).
    public var resetsAt: Date?
    public init(_ progress: SessionCLI.Progress, state: String, detail: String?) {
        result = progress.result
        exitCode = progress.exitCode
        self.state = state
        self.detail = detail
        if case .limited(let reset) = progress { resetsAt = reset }
    }

    private enum CodingKeys: String, CodingKey { case result, exitCode, state, detail, resetsAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result, forKey: .result)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
        if resetsAt != nil { try c.encode(resetsAt, forKey: .resetsAt) }
    }
}

/// `POST /v1/cli/sessions/{ref}/close`. `closed`: it has ended (false while `close self` waits for
/// the turn to end: `pending`); `forced`: its process was ended with a signal instead of `/exit`.
/// `removed`: it was also removed from the deck (for `close self`: it will be, once it has ended).
public struct SessionCLIClosed: Encodable, Sendable, Equatable {
    public var closed: Bool
    public var id: UUID
    public var forced: Bool
    public var pending: Bool
    public var removed: Bool
    public init(closed: Bool, id: UUID, forced: Bool, pending: Bool = false, removed: Bool = false) {
        self.closed = closed
        self.id = id
        self.forced = forced
        self.pending = pending
        self.removed = removed
    }

    private enum CodingKeys: String, CodingKey { case closed, id, forced, pending, removed }

    /// `pending` only for `close self`, `removed` only when true
    /// (`{"closed":true,"id":…,"forced":false}` otherwise).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(closed, forKey: .closed)
        try c.encode(id, forKey: .id)
        try c.encode(forced, forKey: .forced)
        if pending { try c.encode(pending, forKey: .pending) }
        if removed { try c.encode(removed, forKey: .removed) }
    }
}

/// `POST /v1/cli/sessions/{ref}/compact`: `{"compacting":true,"id":…,"pending":false}`.
/// `pending`: `/compact` waits for the current turn to end (always for `compact self`).
public struct SessionCLICompacting: Encodable, Sendable, Equatable {
    public var compacting: Bool
    public var id: UUID
    public var pending: Bool
    public init(compacting: Bool = true, id: UUID, pending: Bool) {
        self.compacting = compacting
        self.id = id
        self.pending = pending
    }
}

/// `POST /v1/cli/sessions/{ref}/remove`: `{"removed":true,"id":…}`.
/// `restart`'s answer: `running` says whether an old process was stopped first (false: it had
/// stopped, and was only started).
public struct SessionCLIRestarted: Encodable, Sendable, Equatable {
    public var restarted: Bool
    public var id: UUID
    public var running: Bool
    public init(restarted: Bool, id: UUID, running: Bool) {
        self.restarted = restarted
        self.id = id
        self.running = running
    }
}

public struct SessionCLIRemoved: Encodable, Sendable, Equatable {
    public var removed: Bool
    public var id: UUID
    public init(removed: Bool, id: UUID) {
        self.removed = removed
        self.id = id
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
