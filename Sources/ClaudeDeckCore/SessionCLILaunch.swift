import Foundation

/// How a Claude session started with `claudedeck new` runs: its permission mode, the tools it may
/// use without asking, its model and effort. Given as flags to `new`, or kept per project as a
/// preset (`claudedeck preset set`). Stored on the session (`DeckSession.launchOptions`) so a
/// restart or a resume runs it the same way. Contract: docs/agents.md.
public struct ClaudeLaunchOptions: Codable, Sendable, Equatable {
    /// `claude --permission-mode` (one of `SessionCLI.permissionModes`).
    public var permissionMode: String?
    /// `claude --allowedTools`, one rule each (`Bash(git *)`, `Edit`, `mcp__server__tool`).
    public var allowedTools: [String]
    /// `claude --model`: an alias (`opus`, `sonnet`) or a full model id.
    public var model: String?
    /// `claude --effort` (one of `SessionCLI.efforts`).
    public var effort: String?

    public init(permissionMode: String? = nil, allowedTools: [String] = [], model: String? = nil, effort: String? = nil) {
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissionMode = try? c.decodeIfPresent(String.self, forKey: .permissionMode)
        allowedTools = (try? c.decodeIfPresent([String].self, forKey: .allowedTools)) ?? []
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        effort = try? c.decodeIfPresent(String.self, forKey: .effort)
    }

    public var isEmpty: Bool { permissionMode == nil && allowedTools.isEmpty && model == nil && effort == nil }

    /// What the session asks Claude Code to do about permissions (a mode or rules): then
    /// `claudedeck` itself is allowed too, so `send`, `wait` and the rest keep working in a mode
    /// that refuses what wasn't allowed (`dontAsk`).
    public var setsPermissions: Bool { permissionMode != nil || !allowedTools.isEmpty }

    /// This one's fields where they're set, else the preset's (a flag replaces the preset's
    /// value for that field; `--allow` replaces its whole list).
    public func over(_ preset: ClaudeLaunchOptions?) -> ClaudeLaunchOptions {
        guard let preset else { return self }
        return ClaudeLaunchOptions(permissionMode: permissionMode ?? preset.permissionMode,
                                   allowedTools: allowedTools.isEmpty ? preset.allowedTools : allowedTools,
                                   model: model ?? preset.model, effort: effort ?? preset.effort)
    }

    /// As good as skipping permissions: `bypassPermissions`, or a rule that allows every shell
    /// command (`Bash`, `Bash(*)`). Needs the same setting.
    public var skipsPermissions: Bool {
        permissionMode == SessionCLI.bypassMode || allowedTools.contains(where: SessionCLI.isBlanketShellRule)
    }

    /// `bypassPermissions` (and blanket shell rules) only while the owner allows it (Settings ›
    /// Agents); otherwise the session falls back to Claude Code's own default mode, without them.
    public func effective(bypassAllowed: Bool) -> ClaudeLaunchOptions {
        guard skipsPermissions, !bypassAllowed else { return self }
        var copy = self
        if copy.permissionMode == SessionCLI.bypassMode { copy.permissionMode = nil }
        copy.allowedTools.removeAll(where: SessionCLI.isBlanketShellRule)
        return copy
    }

    /// The arguments for `claude`, each one argv entry (no shell in between: TerminalRegistry
    /// runs `exec "$0" "$@"`). `--allowedTools` is variadic, so it comes last: the caller's next
    /// option (`--name`) ends it. `cliCommand`: the `claudedeck` script while the command-line
    /// tool is on, allowed whenever permissions are set.
    public func arguments(cliCommand: String?) -> [String] {
        var args: [String] = []
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        var tools = allowedTools
        if setsPermissions, let cliCommand {
            for rule in SessionCLI.cliRules(cliCommand) where !tools.contains(rule) { tools.append(rule) }
        }
        if !tools.isEmpty { args += ["--allowedTools"] + tools }
        return args
    }

    /// One line for `preset show` and the activity log.
    public var summary: String {
        var parts: [String] = []
        if let permissionMode { parts.append("permission-mode \(permissionMode)") }
        if let model { parts.append("model \(model)") }
        if let effort { parts.append("effort \(effort)") }
        if !allowedTools.isEmpty { parts.append("allow " + allowedTools.joined(separator: ", ")) }
        return parts.isEmpty ? "(nothing)" : parts.joined(separator: " · ")
    }
}

/// A project's options for the sessions `claudedeck new` starts in it, when the command gives none.
public struct CLIPreset: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var options: ClaudeLaunchOptions
    public var updatedAt: Date
    /// The session that set it (its name then).
    public var setBy: String

    public init(projectID: UUID, options: ClaudeLaunchOptions, updatedAt: Date = Date(), setBy: String) {
        self.projectID = projectID
        self.options = options
        self.updatedAt = updatedAt
        self.setBy = setBy
    }
}

/// A `claudedeck new --queue` that waits for room under the running cap or the caller's rate
/// limit. Kept in deck.json, so it survives a restart.
public struct CLIQueuedStart: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, started, cancelled, failed
    }

    /// `q_` and 12 hex digits.
    public var id: String
    public var caller: UUID
    public var callerName: String
    public var projectID: UUID
    public var name: String
    public var prompt: String
    public var worktree: String
    public var skill: String?
    /// The options given with the command (the preset is applied when it starts).
    public var options: ClaudeLaunchOptions
    public var queuedAt: Date
    public var status: Status
    public var sessionID: UUID?
    /// Why it was cancelled or failed (`cancelled`, `setting_off`, `caller_gone`, …).
    public var reason: String?
    public var finishedAt: Date?

    public init(id: String, caller: UUID, callerName: String, projectID: UUID, name: String, prompt: String, worktree: String,
                skill: String?, options: ClaudeLaunchOptions, queuedAt: Date = Date()) {
        self.id = id
        self.caller = caller
        self.callerName = callerName
        self.projectID = projectID
        self.name = name
        self.prompt = prompt
        self.worktree = worktree
        self.skill = skill
        self.options = options
        self.queuedAt = queuedAt
        self.status = .queued
    }
}

/// `GET /v1/cli/queue[/{id}]`, one entry (the prompt isn't repeated).
public struct SessionCLIQueueInfo: Encodable, Sendable, Equatable {
    public var queueId: String
    public var status: String
    public var sessionId: UUID?
    public var projectId: UUID
    public var project: String
    public var name: String
    public var caller: String
    public var mine: Bool
    public var position: Int?
    public var queuedAt: Date
    public var reason: String?

    public init(_ entry: CLIQueuedStart, project: String, mine: Bool, position: Int?) {
        queueId = entry.id
        status = entry.status.rawValue
        sessionId = entry.sessionID
        projectId = entry.projectID
        self.project = project
        name = entry.name
        caller = entry.callerName
        self.mine = mine
        self.position = position
        queuedAt = entry.queuedAt
        reason = entry.reason
    }

    private enum CodingKeys: String, CodingKey {
        case queueId, status, sessionId, projectId, project, name, caller, mine, position, queuedAt, reason
    }

    /// Every key is always there (null when unknown).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(queueId, forKey: .queueId)
        try c.encode(status, forKey: .status)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(project, forKey: .project)
        try c.encode(name, forKey: .name)
        try c.encode(caller, forKey: .caller)
        try c.encode(mine, forKey: .mine)
        try c.encode(position, forKey: .position)
        try c.encode(queuedAt, forKey: .queuedAt)
        try c.encode(reason, forKey: .reason)
    }
}

/// `claudedeck new --queue` when there's no room: `{"queued": true, "queue_id": "q_…"}`.
public struct SessionCLIQueued: Encodable, Sendable, Equatable {
    public var queued = true
    public var queueId: String
    public var position: Int
    /// What it waits for: `too_many_running` or `too_many_starts`.
    public var reason: String

    public init(queueId: String, position: Int, reason: String) {
        self.queueId = queueId
        self.position = position
        self.reason = reason
    }
}

/// `claudedeck preset show`.
public struct SessionCLIPresetInfo: Encodable, Sendable, Equatable {
    public var projectId: UUID
    public var project: String
    public var permissionMode: String?
    public var allow: [String]
    public var model: String?
    public var effort: String?
    public var setBy: String?
    public var updatedAt: Date?

    public init(projectId: UUID, project: String, preset: CLIPreset?) {
        self.projectId = projectId
        self.project = project
        permissionMode = preset?.options.permissionMode
        allow = preset?.options.allowedTools ?? []
        model = preset?.options.model
        effort = preset?.options.effort
        setBy = preset?.setBy
        updatedAt = preset?.updatedAt
    }

    private enum CodingKeys: String, CodingKey { case projectId, project, permissionMode, allow, model, effort, setBy, updatedAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(project, forKey: .project)
        try c.encode(permissionMode, forKey: .permissionMode)
        try c.encode(allow, forKey: .allow)
        try c.encode(model, forKey: .model)
        try c.encode(effort, forKey: .effort)
        try c.encode(setBy, forKey: .setBy)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// `claudedeck wait --all|--any`: one entry per id, in the order given.
public struct SessionCLIWaitEntry: Encodable, Sendable, Equatable {
    /// The id as given (a session id, a prefix, or a queue id).
    public var ref: String
    public var id: UUID?
    public var queueId: String?
    /// `finished`, `failed`, `blocked`, `stopped`, `timeout` (still running or queued), or for a
    /// queue id that won't start: `cancelled` / `queue_failed`.
    public var result: String
    public var exitCode: Int32?
    public var state: String
    public var detail: String?
    /// Still running (or queued).
    public var running: Bool
    public var exit: SessionCLI.Exit

    public init(ref: String, id: UUID?, queueId: String?, result: String, exitCode: Int32?, state: String, detail: String?,
                running: Bool, exit: SessionCLI.Exit) {
        self.ref = ref
        self.id = id
        self.queueId = queueId
        self.result = result
        self.exitCode = exitCode
        self.state = state
        self.detail = detail
        self.running = running
        self.exit = exit
    }

    private enum CodingKeys: String, CodingKey { case ref, id, queueId, result, exitCode, state, detail }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encode(id, forKey: .id)
        try c.encode(queueId, forKey: .queueId)
        try c.encode(result, forKey: .result)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(state, forKey: .state)
        try c.encode(detail, forKey: .detail)
    }
}

/// `GET /v1/cli/wait`.
public struct SessionCLIWaitedMany: Encodable, Sendable, Equatable {
    public var mode: String
    /// `finished`, `failed`, `blocked` or `timeout` for the whole wait.
    public var result: String
    /// `--any`: the first id (in the order given) that stopped running.
    public var first: String?
    public var sessions: [SessionCLIWaitEntry]

    public init(mode: String, result: String, first: String?, sessions: [SessionCLIWaitEntry]) {
        self.mode = mode
        self.result = result
        self.first = first
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey { case mode, result, first, sessions }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(result, forKey: .result)
        try c.encode(first, forKey: .first)
        try c.encode(sessions, forKey: .sessions)
    }
}

extension SessionCLI {
    // MARK: Launch options

    /// What `claude --permission-mode` accepts (Claude Code 2.1: `manual` is the new name of
    /// `default`, which it still takes).
    public static let permissionModes = ["default", "manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]
    public static let bypassMode = "bypassPermissions"
    /// `claude --effort`.
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public static let maxAllowedTools = 50
    public static let maxToolRule = 300

    /// The rules that let a session run `claudedeck` (by name on PATH and by its absolute path).
    public static func cliRules(_ command: String) -> [String] {
        var rules = ["Bash(claudedeck *)"]
        if !command.isEmpty, !command.contains(")"), !command.contains("\n") { rules.append("Bash(\(command) *)") }
        return rules
    }

    public enum LaunchRefusal: String, Error, Sendable, Equatable {
        case badPermissionMode = "bad_permission_mode"
        case badAllow = "bad_allow"
        case badModel = "bad_model"
        case badEffort = "bad_effort"
        case badSkill = "bad_skill"
        case unknownSkill = "unknown_skill"
        /// `bypassPermissions` without Settings › Agents › "Sessions may start sessions that skip permissions".
        case bypassOff = "bypass_off"

        public var response: AgentHTTPResponse {
            switch self {
            case .unknownSkill: failure(404, rawValue, exit: .unknown)
            case .bypassOff: failure(403, rawValue, exit: .refused)
            default: failure(400, rawValue, exit: .usage)
            }
        }
    }

    /// A tool rule for `--allowedTools`: a tool name (`Edit`, `mcp__server__tool`), optionally
    /// with a pattern in parentheses (`Bash(git *)`, `WebFetch(domain:example.com)`). One line,
    /// printable, never an option (`-…`).
    public static func isValidToolRule(_ rule: String) -> Bool {
        guard !rule.isEmpty, rule.count <= maxToolRule, let first = rule.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        guard !rule.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let name: Substring
        if let open = rule.firstIndex(of: "(") {
            // A pattern, not empty: `Bash()` isn't a rule.
            guard rule.hasSuffix(")"), rule.index(after: open) < rule.index(before: rule.endIndex) else { return false }
            name = rule[..<open]
        } else {
            name = Substring(rule)
        }
        return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// A rule that allows any shell command: `Bash` (or `PowerShell`) with no pattern, or one
    /// that's only wildcards (`Bash(*)`, `Bash(:*)`, `Bash( * )`).
    public static func isBlanketShellRule(_ rule: String) -> Bool {
        let name = rule.split(separator: "(", maxSplits: 1).first.map(String.init) ?? rule
        guard ["bash", "powershell"].contains(name.trimmingCharacters(in: .whitespaces).lowercased()) else { return false }
        guard let open = rule.firstIndex(of: "(") else { return true }
        return rule[rule.index(after: open)...].allSatisfy { "*: )".contains($0) }
    }

    /// A model alias or id: `opus`, `claude-opus-5-5`, `claude-sonnet-4-5[1m]`, `us.anthropic.…`.
    public static func isValidModel(_ model: String) -> Bool {
        guard !model.isEmpty, model.count <= 100, let first = model.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-[]:/@".contains($0)) }
    }

    /// `new` and `preset set`: `permission_mode`, `allow` (one rule per line), `model`, `effort`.
    /// Only what's given is set; the rest stays nil (so a preset fills it in).
    public static func launchOptions(_ form: [String: String]) -> Result<ClaudeLaunchOptions, LaunchRefusal> {
        func value(_ key: String) -> String? {
            let text = (form[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        var options = ClaudeLaunchOptions()
        if let mode = value("permission_mode") {
            guard let known = permissionModes.first(where: { $0.caseInsensitiveCompare(mode) == .orderedSame }) else {
                return .failure(.badPermissionMode)
            }
            options.permissionMode = known
        }
        if let allow = form["allow"] {
            let rules = allow.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard rules.count <= maxAllowedTools, rules.allSatisfy(isValidToolRule) else { return .failure(.badAllow) }
            for rule in rules where !options.allowedTools.contains(rule) { options.allowedTools.append(rule) }
        }
        if let model = value("model") {
            guard isValidModel(model) else { return .failure(.badModel) }
            options.model = model
        }
        if let effort = value("effort") {
            guard let known = efforts.first(where: { $0 == effort.lowercased() }) else { return .failure(.badEffort) }
            options.effort = known
        }
        return .success(options)
    }

    // MARK: Skills

    /// `new --skill`: what's typed first, `/name` and the prompt as its arguments.
    public static func skillPrompt(_ skill: String?, prompt: String) -> String {
        guard let skill, !skill.isEmpty else { return prompt }
        return prompt.isEmpty ? "/\(skill)" : "/\(skill) \(prompt)"
    }

    // MARK: Queue

    /// At most this many `new --queue` wait at once per calling session, and in all.
    public static let maxQueuedPerCaller = 20
    public static let maxQueued = 50
    /// Finished entries (started, cancelled, failed) are kept this long for `queue show` and `wait`.
    public static let queueKeep: TimeInterval = 24 * 60 * 60

    public static func newQueueID() -> String {
        "q_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    public static func isQueueID(_ ref: String) -> Bool {
        ref.hasPrefix("q_") && ref.count > 2 && ref.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    /// Whether another may be queued (`nil`) or why not.
    public static func admitQueued(caller: UUID, queue: [CLIQueuedStart]) -> AgentHTTPResponse? {
        let waiting = queue.filter { $0.status == .queued }
        guard waiting.count < maxQueued, waiting.filter({ $0.caller == caller }).count < maxQueuedPerCaller else {
            return failure(429, "too_many_queued", exit: .refused)
        }
        return nil
    }

    /// The finished entries older than `queueKeep` go (the waiting ones always stay).
    public static func pruneQueue(_ queue: [CLIQueuedStart], now: Date = Date()) -> [CLIQueuedStart] {
        queue.filter { $0.status == .queued || now.timeIntervalSince($0.finishedAt ?? $0.queuedAt) < queueKeep }
    }

    /// 1-based place among the waiting entries.
    public static func queuePosition(_ id: String, in queue: [CLIQueuedStart]) -> Int? {
        queue.filter { $0.status == .queued }.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    public static func queueText(_ infos: [SessionCLIQueueInfo]) -> String {
        guard !infos.isEmpty else { return "the queue is empty" }
        let header = ["QUEUE ID", "STATUS", "SESSION", "PROJECT", "CALLER", "NAME"]
        let rows = infos.map { info in
            [info.queueId, info.status + (info.position.map { " #\($0)" } ?? "") + (info.reason.map { " (\($0))" } ?? ""),
             info.sessionId.map { String($0.uuidString.prefix(8)) } ?? "-", info.project, info.caller + (info.mine ? " (self)" : ""),
             info.name.isEmpty ? "-" : info.name]
        }
        return table([header] + rows)
    }

    // MARK: Waiting for several

    public enum WaitMode: String, Sendable, CaseIterable {
        case all, any
    }

    /// Whether `wait --all|--any` is over, its exit code, and for `--any` which entry ended it.
    /// `--all`: every one stopped running; then 3 if any needs the user, else 1 if any failed
    /// (or won't start), else 0. `--any`: the first (in the order given) that stopped, with its
    /// own code. Not over: 124.
    public static func combine(_ entries: [(running: Bool, exit: Exit)], mode: WaitMode) -> (done: Bool, exit: Exit, first: Int?) {
        switch mode {
        case .any:
            guard let index = entries.firstIndex(where: { !$0.running }) else { return (false, .timeout, nil) }
            return (true, entries[index].exit, index)
        case .all:
            guard !entries.isEmpty, !entries.contains(where: \.running) else { return (false, .timeout, nil) }
            if entries.contains(where: { $0.exit == .blocked }) { return (true, .blocked, nil) }
            if entries.contains(where: { $0.exit != .ok }) { return (true, .failed, nil) }
            return (true, .ok, nil)
        }
    }

    public static func waitManyText(_ entries: [SessionCLIWaitEntry], texts: [String]) -> String {
        zip(entries, texts).map { entry, text in
            // A queue id that started: "q_… SESSION: …"; otherwise the id as given.
            guard let id = entry.id else { return "\(entry.ref): \(text)" }
            return (entry.queueId.map { "\($0) " } ?? "") + "\(id.uuidString.prefix(8)): \(text)"
        }.joined(separator: "\n")
    }

    /// The `error` of a failure's JSON body (`{"error": "too_many_running"}`).
    public static func errorCode(of response: AgentHTTPResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? String
    }

    /// The result name for a whole wait.
    public static func resultName(_ exit: Exit) -> String {
        switch exit {
        case .ok: "finished"
        case .blocked: "blocked"
        case .timeout: "timeout"
        default: "failed"
        }
    }
}

extension SkillCatalog {
    /// `name` or `plugin:name`: letters, digits, `.`, `_`, `-`.
    public static func isValidInvocation(_ name: String) -> Bool {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), name.count <= 120 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter || first.isNumber else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
        }
    }

    /// The `SKILL.md` (or a command's `.md`) that `/name` would run in a session in one of
    /// `projectPaths`: the user's skills and commands (`configDirs`, e.g. `~/.claude` and
    /// `$CLAUDE_CONFIG_DIR`), the projects' `.claude/skills` and `.claude/commands`, and the
    /// installed plugins' (`plugin:name`, or a plain name any plugin has). nil: none.
    public static func find(_ name: String, configDirs: [URL], projectPaths: [String], pluginsManifest: URL) -> URL? {
        guard isValidInvocation(name) else { return nil }
        let fm = FileManager.default
        func lookup(_ base: URL, _ skill: String) -> URL? {
            let file = base.appending(path: "skills/\(skill)/SKILL.md")
            if fm.fileExists(atPath: file.path) { return file }
            let command = base.appending(path: "commands/\(skill).md")
            if fm.fileExists(atPath: command.path) { return command }
            // A skill whose frontmatter names it differently from its folder.
            return skills(in: base.appending(path: "skills"), scope: .user).first { $0.name == skill }?.file
        }
        let parts = name.split(separator: ":").map(String.init)
        let plugins = installedPlugins(manifest: pluginsManifest)
        if parts.count == 2 {
            for plugin in plugins where plugin.name == parts[0] {
                if let file = lookup(URL(fileURLWithPath: plugin.installPath), parts[1]) { return file }
            }
            return nil
        }
        let bases = configDirs + projectPaths.map { URL(fileURLWithPath: $0).appending(path: ".claude") }
        for base in bases {
            if let file = lookup(base, name) { return file }
        }
        for plugin in plugins {
            if let file = lookup(URL(fileURLWithPath: plugin.installPath), name) { return file }
        }
        return nil
    }
}
