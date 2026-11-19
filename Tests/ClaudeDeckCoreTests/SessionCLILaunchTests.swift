import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck new` options (permission mode, allowed tools, model, effort, skill), per-project
/// presets, `new --queue` and `wait --all|--any`.
@Suite struct SessionCLILaunchTests {
    // MARK: Options

    @Test func parsesTheOptionsGiven() throws {
        let options = try SessionCLI.launchOptions([
            "permission_mode": "acceptedits", "allow": "Bash(git *)\nEdit\n\nEdit\nmcp__pencil__get_style",
            "model": "claude-opus-5-5[1m]", "effort": "XHigh",
        ]).get()
        #expect(options.permissionMode == "acceptEdits")
        #expect(options.allowedTools == ["Bash(git *)", "Edit", "mcp__pencil__get_style"])
        #expect(options.model == "claude-opus-5-5[1m]" && options.effort == "xhigh")
        // Nothing given: nothing set (a preset fills it in).
        #expect(try SessionCLI.launchOptions(["permission_mode": "", "allow": "", "model": " "]).get().isEmpty)
        for mode in SessionCLI.permissionModes {
            #expect(try SessionCLI.launchOptions(["permission_mode": mode]).get().permissionMode == mode)
        }
    }

    @Test func refusesBadOptions() {
        #expect(SessionCLI.launchOptions(["permission_mode": "yolo"]) == .failure(.badPermissionMode))
        #expect(SessionCLI.launchOptions(["effort": "extreme"]) == .failure(.badEffort))
        #expect(SessionCLI.launchOptions(["model": "--dangerously-skip-permissions"]) == .failure(.badModel))
        #expect(SessionCLI.launchOptions(["model": "opus; rm -rf ~"]) == .failure(.badModel))
        #expect(SessionCLI.launchOptions(["allow": "--dangerously-skip-permissions"]) == .failure(.badAllow))
        #expect(SessionCLI.launchOptions(["allow": "Bash(git *"]) == .failure(.badAllow))
        let many = (0...SessionCLI.maxAllowedTools).map { "Tool\($0)" }.joined(separator: "\n")
        #expect(SessionCLI.launchOptions(["allow": many]) == .failure(.badAllow))
        #expect(SessionCLI.LaunchRefusal.bypassOff.response.status == 403)
        #expect(SessionCLI.LaunchRefusal.bypassOff.response.headers[SessionCLI.exitHeader] == "4")
        #expect(SessionCLI.LaunchRefusal.unknownSkill.response.headers[SessionCLI.exitHeader] == "5")
        #expect(SessionCLI.LaunchRefusal.badAllow.response.headers[SessionCLI.exitHeader] == "2")
    }

    @Test func toolRules() {
        for rule in ["Edit", "Bash", "Bash(git *)", "Bash(npm run test:*)", "WebFetch(domain:example.com)", "mcp__pencil__get_style",
                     "Read(~/notes/**)", "Bash(echo \"a b\" | wc -l)"] {
            #expect(SessionCLI.isValidToolRule(rule), "\(rule)")
        }
        for rule in ["", "-x", "--model", "(x)", "Bash(", "Bash(x", "Bash()", "Ba sh", "Bash(a\nb)", "Edit\u{7}", "Bash(x)y",
                     String(repeating: "a", count: SessionCLI.maxToolRule + 1)] {
            #expect(!SessionCLI.isValidToolRule(rule), "\(rule)")
        }
    }

    @Test func modelNames() {
        for model in ["opus", "sonnet", "fable", "claude-opus-5-5", "claude-sonnet-4-5[1m]", "us.anthropic.claude-opus-4-1-v1:0",
                      "claude-3-5-sonnet@20241022"] {
            #expect(SessionCLI.isValidModel(model), "\(model)")
        }
        for model in ["", "-m", "a b", "opus\n", "x$(id)", String(repeating: "a", count: 101)] {
            #expect(!SessionCLI.isValidModel(model), "\(model)")
        }
    }

    /// Each value is its own argv entry, `--allowedTools` (variadic) last, and `claudedeck`
    /// allowed whenever permissions are set, so the session can still send and wait.
    @Test func argumentsForClaude() {
        let cli = "/Users/me/Library/Application Support/ClaudeDeck/bin/claudedeck"
        let options = ClaudeLaunchOptions(permissionMode: "dontAsk", allowedTools: ["Bash(git *)"], model: "opus", effort: "max")
        #expect(options.arguments(cliCommand: cli) == ["--permission-mode", "dontAsk", "--model", "opus", "--effort", "max",
                                                        "--allowedTools", "Bash(git *)", "Bash(claudedeck *)", "Bash(\(cli) *)"])
        // The command-line tool off: no rule for it.
        #expect(options.arguments(cliCommand: nil) == ["--permission-mode", "dontAsk", "--model", "opus", "--effort", "max",
                                                        "--allowedTools", "Bash(git *)"])
        // Only a model: permissions untouched, nothing added.
        #expect(ClaudeLaunchOptions(model: "sonnet").arguments(cliCommand: cli) == ["--model", "sonnet"])
        #expect(ClaudeLaunchOptions(permissionMode: "plan").arguments(cliCommand: cli)
            == ["--permission-mode", "plan", "--allowedTools", "Bash(claudedeck *)", "Bash(\(cli) *)"])
        #expect(ClaudeLaunchOptions().arguments(cliCommand: cli).isEmpty)
        // Already allowed: not twice.
        #expect(ClaudeLaunchOptions(allowedTools: ["Bash(claudedeck *)"]).arguments(cliCommand: "")
            == ["--allowedTools", "Bash(claudedeck *)"])
    }

    @Test func flagsOverThePreset() {
        let preset = ClaudeLaunchOptions(permissionMode: "acceptEdits", allowedTools: ["Edit", "Bash(swift test *)"], model: "opus", effort: "high")
        #expect(ClaudeLaunchOptions().over(preset) == preset)
        #expect(ClaudeLaunchOptions().over(nil).isEmpty)
        let mixed = ClaudeLaunchOptions(permissionMode: "plan", allowedTools: ["Read"], effort: "low").over(preset)
        #expect(mixed == ClaudeLaunchOptions(permissionMode: "plan", allowedTools: ["Read"], model: "opus", effort: "low"))
        #expect(ClaudeLaunchOptions(permissionMode: "default").over(preset).permissionMode == "default")
    }

    @Test func bypassOnlyWhileAllowed() {
        let bypass = ClaudeLaunchOptions(permissionMode: "bypassPermissions", model: "opus")
        #expect(bypass.effective(bypassAllowed: true) == bypass)
        #expect(bypass.effective(bypassAllowed: false) == ClaudeLaunchOptions(model: "opus"))
        let plan = ClaudeLaunchOptions(permissionMode: "plan")
        #expect(plan.effective(bypassAllowed: false) == plan)
    }

    // MARK: Routes

    @Test func routesAndScopes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/presets") == .route(.presets))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects/self/preset") == .route(.showPreset("self")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/%2FUsers%2Fme%2Fapp/preset") == .route(.setPreset("/Users/me/app")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/queue") == .route(.queue))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/queue/q_0123456789ab") == .route(.queueItem("q_0123456789ab")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/queue/q_0123456789ab/cancel") == .route(.cancelQueued("q_0123456789ab")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/queue/q_1/cancel") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/queue") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/wait") == .route(.waitMany))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/q_0123456789ab/wait") == .route(.wait("q_0123456789ab")))
        // Unchanged.
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/self/sessions") == .route(.newSession("self")))

        // A terminal a session opened may wait (also for several), but not set presets or queue.
        for route: SessionCLI.Route in [.presets, .showPreset("x"), .setPreset("x"), .queue, .queueItem("q_1"), .cancelQueued("q_1")] {
            #expect(route.scope == .start)
            #expect(!SessionCLI.openedScopes.contains(route.scope))
        }
        #expect(SessionCLI.Route.waitMany.scope == .wait && SessionCLI.openedScopes.contains(.wait))
    }

    // MARK: Waiting for several

    @Test func combineAllAndAny() {
        typealias E = SessionCLI.Exit
        let running = (running: true, exit: E.timeout)
        let done = (running: false, exit: E.ok)
        let failed = (running: false, exit: E.failed)
        let blocked = (running: false, exit: E.blocked)

        #expect(SessionCLI.combine([running, done], mode: .all) == (false, .timeout, nil))
        #expect(SessionCLI.combine([done, done], mode: .all) == (true, .ok, nil))
        #expect(SessionCLI.combine([done, failed], mode: .all) == (true, .failed, nil))
        #expect(SessionCLI.combine([failed, blocked, done], mode: .all) == (true, .blocked, nil))
        #expect(SessionCLI.combine([], mode: .all).done == false)

        #expect(SessionCLI.combine([running, running], mode: .any) == (false, .timeout, nil))
        #expect(SessionCLI.combine([running, failed, done], mode: .any) == (true, .failed, 1))
        #expect(SessionCLI.combine([blocked, done], mode: .any) == (true, .blocked, 0))
        #expect(SessionCLI.resultName(.blocked) == "blocked" && SessionCLI.resultName(.timeout) == "timeout")
    }

    @Test func waitManyEncodesEveryKey() throws {
        let id = UUID()
        let entry = SessionCLIWaitEntry(ref: "q_0123456789ab", id: id, queueId: "q_0123456789ab", result: "finished", exitCode: 0,
                                        state: "idle", detail: nil, running: false, exit: .ok)
        let waited = SessionCLIWaitedMany(mode: "any", result: "finished", first: "q_0123456789ab", sessions: [entry])
        let json = try #require(try JSONSerialization.jsonObject(with: AgentJSON.encode(waited)) as? [String: Any])
        #expect(json["mode"] as? String == "any" && json["first"] as? String == "q_0123456789ab")
        let first = try #require((json["sessions"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["ref", "id", "queue_id", "result", "exit_code", "state", "detail"])
        #expect(first["id"] as? String == id.uuidString && first["detail"] is NSNull)
        let text = SessionCLI.waitManyText([entry], texts: ["finished (exit 0)"])
        #expect(text == "q_0123456789ab \(id.uuidString.prefix(8)): finished (exit 0)")
    }

    // MARK: Queue

    private func entry(_ caller: UUID, status: CLIQueuedStart.Status = .queued, at date: Date = Date()) -> CLIQueuedStart {
        var entry = CLIQueuedStart(id: SessionCLI.newQueueID(), caller: caller, callerName: "s", projectID: UUID(), name: "", prompt: "p",
                                   worktree: "", skill: nil, options: ClaudeLaunchOptions(), queuedAt: date)
        entry.status = status
        if status != .queued { entry.finishedAt = date }
        return entry
    }

    @Test func queueIDs() {
        let id = SessionCLI.newQueueID()
        #expect(id.hasPrefix("q_") && id.count == 14 && SessionCLI.isQueueID(id))
        #expect(SessionCLI.newQueueID() != id)
        #expect(!SessionCLI.isQueueID("q_") && !SessionCLI.isQueueID("abcd1234") && !SessionCLI.isQueueID("q_xyz"))
    }

    @Test func queueLimitsPruningAndPosition() {
        let me = UUID(), other = UUID()
        var queue = (0..<SessionCLI.maxQueuedPerCaller).map { _ in entry(me) }
        #expect(SessionCLI.admitQueued(caller: me, queue: queue)?.status == 429)
        #expect(SessionCLI.errorCode(of: SessionCLI.admitQueued(caller: me, queue: queue)!) == "too_many_queued")
        #expect(SessionCLI.admitQueued(caller: other, queue: queue) == nil)
        // Finished entries don't count.
        queue = (0..<SessionCLI.maxQueuedPerCaller).map { _ in entry(me, status: .started) }
        #expect(SessionCLI.admitQueued(caller: me, queue: queue) == nil)
        queue = (0..<SessionCLI.maxQueued).map { _ in entry(UUID()) }
        #expect(SessionCLI.admitQueued(caller: me, queue: queue) != nil)

        let now = Date()
        let old = entry(me, status: .started, at: now.addingTimeInterval(-SessionCLI.queueKeep - 1))
        let recent = entry(me, status: .cancelled, at: now.addingTimeInterval(-60))
        let waitingLong = entry(me, at: now.addingTimeInterval(-SessionCLI.queueKeep * 3))
        let next = entry(other)
        let pruned = SessionCLI.pruneQueue([old, recent, waitingLong, next], now: now)
        #expect(pruned.map(\.id) == [recent.id, waitingLong.id, next.id])
        #expect(SessionCLI.queuePosition(next.id, in: pruned) == 2 && SessionCLI.queuePosition(recent.id, in: pruned) == nil)
    }

    @Test func queueListText() {
        let me = UUID()
        var started = entry(me, status: .started)
        started.sessionID = UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000000")
        let infos = [SessionCLIQueueInfo(entry(me), project: "web", mine: true, position: 1),
                     SessionCLIQueueInfo(started, project: "api", mine: false, position: nil)]
        let text = SessionCLI.queueText(infos)
        #expect(text.contains("queued #1") && text.contains("ABCDEF01") && text.contains("s (self)"))
        #expect(SessionCLI.queueText([]) == "the queue is empty")
    }

    // MARK: Skills

    @Test func skillPrompt() {
        #expect(SessionCLI.skillPrompt("review", prompt: "") == "/review")
        #expect(SessionCLI.skillPrompt("review", prompt: "the cart") == "/review the cart")
        #expect(SessionCLI.skillPrompt(nil, prompt: "hi") == "hi")
    }

    @Test func findsSkills() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func write(_ path: String, _ text: String = "---\nname: x\n---\n") throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("home/.claude/skills/review/SKILL.md")
        try write("home/.claude/skills/folder-name/SKILL.md", "---\nname: renamed\n---\n")
        try write("home/.claude/commands/deploy.md")
        try write("project/.claude/skills/local/SKILL.md")
        try write("plugins/figma/skills/figma-use/SKILL.md")
        let manifest = root.appending(path: "home/.claude/plugins/installed_plugins.json")
        try write("home/.claude/plugins/installed_plugins.json",
                  #"{"version":2,"plugins":{"figma@official":[{"installPath":"\#(root.appending(path: "plugins/figma").path)"}]}}"#)
        let config = [root.appending(path: "home/.claude")]
        let project = [root.appending(path: "project").path]
        func find(_ name: String) -> URL? { SkillCatalog.find(name, configDirs: config, projectPaths: project, pluginsManifest: manifest) }

        #expect(find("review")?.path.hasSuffix("skills/review/SKILL.md") == true)
        #expect(find("renamed") != nil && find("folder-name") != nil)
        #expect(find("deploy")?.lastPathComponent == "deploy.md")
        #expect(find("local") != nil)
        #expect(find("figma:figma-use") != nil && find("figma-use") != nil)
        #expect(find("other:figma-use") == nil && find("missing") == nil)
        // Never a path.
        #expect(find("../project/.claude/skills/local") == nil)
        #expect(!SkillCatalog.isValidInvocation("a/b") && !SkillCatalog.isValidInvocation("a:b:c") && !SkillCatalog.isValidInvocation(""))
        #expect(!SkillCatalog.isValidInvocation(".hidden") && SkillCatalog.isValidInvocation("gsd:plan-phase"))
    }

    // MARK: Stored

    @Test func storedAndOlderFilesStillRead() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/x")
        var session = DeckSession(projectID: project.id, name: "x")
        session.launchOptions = ClaudeLaunchOptions(permissionMode: "plan", allowedTools: ["Edit"], model: "opus", effort: "high")
        deck.sessions = [session]
        deck.settings.sessionsMayBypassPermissions = true
        deck.cliPresets = [CLIPreset(projectID: project.id, options: ClaudeLaunchOptions(permissionMode: "acceptEdits"), setBy: "s")]
        deck.cliQueue = [entry(UUID())]
        let decoded = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(decoded.sessions.first?.launchOptions == session.launchOptions)
        #expect(decoded.settings.sessionsMayBypassPermissions)
        #expect(decoded.cliPresets == deck.cliPresets && decoded.cliQueue == deck.cliQueue)

        // A deck.json from before: everything off and empty.
        let old = #"{"version":1,"projects":[],"sessions":[{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"a"}],"settings":{}}"#
        let older = try JSONDecoder().decode(DeckData.self, from: Data(old.utf8))
        #expect(older.sessions.first?.launchOptions == nil && !older.settings.sessionsMayBypassPermissions)
        #expect(older.cliPresets.isEmpty && older.cliQueue.isEmpty)
        // A broken entry doesn't take the rest with it.
        let broken = #"{"cliQueue":[{"id":"q_1"}],"cliPresets":[{"projectID":"nope"}]}"#
        let partly = try JSONDecoder().decode(DeckData.self, from: Data(broken.utf8))
        #expect(partly.cliQueue.isEmpty && partly.cliPresets.isEmpty)
    }
}
