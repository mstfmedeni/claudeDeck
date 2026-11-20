import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck`: the routes and scopes of a session's own token, the consent rule, waiting, and
/// the script itself (run against a stand-in curl).
@Suite struct SessionCLITests {
    private func request(_ method: String, _ path: String, token: String? = nil, query: [String: String] = [:]) -> AgentHTTPRequest {
        AgentHTTPRequest(method: method, path: path, query: query,
                         headers: token.map { ["authorization": "Bearer \($0)"] } ?? [:], body: Data())
    }

    // MARK: Routes and scopes

    @Test func routes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions") == .route(.list))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/") == .route(.list))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/terminals") == .route(.open))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/self/send") == .route(.send("self")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/C0000000/screen") == .route(.capture("C0000000")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/abcd/wait") == .route(.wait("abcd")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/notify") == .route(.notify))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/ask") == .route(.ask))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/x/send") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/x/kill") == .notFound)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli") == .notFound)
        #expect(SessionCLI.match(method: "GET", path: "/v1/projects") == .notFound)
        #expect(SessionCLI.handles("/v1/cli/sessions") && SessionCLI.handles("/v1/cli"))
        #expect(!SessionCLI.handles("/v1/client") && !SessionCLI.handles("/v1/projects") && !SessionCLI.handles(AgentAsk.path))
    }

    /// The routes agents (and the WhatsApp Reader daemon) use answer exactly as before, and the
    /// old router knows nothing of `/v1/cli`.
    @Test func existingRoutesAreUnchanged() throws {
        let id = UUID()
        #expect(AgentRoute.match(method: "GET", path: "/v1/projects") == .route(.projects))
        #expect(AgentRoute.match(method: "POST", path: "/v1/sessions/\(id)/prompt") == .route(.prompt(session: id)))
        #expect(AgentRoute.match(method: "GET", path: "/v1/sessions/\(id)/messages") == .route(.messages(session: id)))
        #expect(AgentRoute.match(method: "POST", path: "/v1/notes") == .route(.notes))
        #expect(AgentRoute.match(method: "POST", path: "/v1/projects/\(id)/sessions") == .route(.newSession(project: id)))
        #expect(AgentRoute.match(method: "GET", path: "/v1/cli/sessions") == .notFound)
        #expect(try AgentRoute.resolve(request("GET", "/v1/projects", token: "secret"), token: "secret").get() == .projects)
        // A session's CLI token is no API token.
        var book = SessionCLIBook()
        let cliToken = book.token(for: id, scopes: SessionCLI.fullScopes)
        #expect((try? AgentRoute.resolve(request("GET", "/v1/projects", token: cliToken), token: "secret").get()) == nil)
        // And the API's token is no CLI token.
        guard case .failure(let refusal) = SessionCLI.resolve(request("GET", "/v1/cli/sessions", token: "secret"), book: book) else {
            Issue.record("API token passed"); return
        }
        #expect(refusal.response.status == 401)
        // Old answers carry no extra header: the bytes on the wire are what they were.
        let old = AgentHTTPResponse.error(404, "not_found").encoded()
        #expect(String(decoding: old, as: UTF8.self) == "HTTP/1.1 404 Not Found\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"error\":\"not_found\"}")
    }

    @Test func tokenScopes() throws {
        var book = SessionCLIBook()
        let claude = UUID(), opened = UUID()
        let claudeToken = book.token(for: claude, scopes: SessionCLI.scopes(openedBy: nil))
        let openedToken = book.token(for: opened, scopes: SessionCLI.scopes(openedBy: claude))
        #expect(book.token(for: claude, scopes: SessionCLI.fullScopes) == claudeToken) // kept while the session lives
        #expect(claudeToken != openedToken)

        func status(_ method: String, _ path: String, _ token: String?) -> Int {
            switch SessionCLI.resolve(request(method, path, token: token), book: book) {
            case .failure(let refusal): refusal.response.status
            case .success: 200
            }
        }
        for (method, path) in [("GET", "/v1/cli/sessions"), ("POST", "/v1/cli/terminals"), ("POST", "/v1/cli/sessions/x/send"),
                               ("GET", "/v1/cli/sessions/x/screen"), ("GET", "/v1/cli/sessions/x/wait"), ("POST", "/v1/cli/notify"),
                               ("POST", "/v1/cli/ask")] {
            #expect(status(method, path, claudeToken) == 200, "\(path)")
        }
        // A terminal a session opened may look and tell, not act.
        #expect(status("GET", "/v1/cli/sessions", openedToken) == 200)
        #expect(status("GET", "/v1/cli/sessions/x/screen", openedToken) == 200)
        #expect(status("GET", "/v1/cli/sessions/x/wait", openedToken) == 200)
        #expect(status("POST", "/v1/cli/notify", openedToken) == 200)
        #expect(status("POST", "/v1/cli/terminals", openedToken) == 403)
        #expect(status("POST", "/v1/cli/sessions/x/send", openedToken) == 403)
        #expect(status("POST", "/v1/cli/ask", openedToken) == 403)
        // No token or someone else's: 401 before anything else.
        #expect(status("GET", "/v1/cli/nothing", nil) == 401)
        #expect(status("GET", "/v1/cli/sessions", "made-up-token-0123456789") == 401)
        #expect(status("GET", "/v1/cli/nothing", claudeToken) == 404)
        #expect(status("DELETE", "/v1/cli/sessions", claudeToken) == 405)
        // Every refusal tells the command its exit code.
        if case .failure(let refusal) = SessionCLI.resolve(request("POST", "/v1/cli/terminals", token: openedToken), book: book) {
            #expect(refusal.response.headers[SessionCLI.exitHeader] == "4")
        }
        // Restarting a terminal clears what `wait` knew, not the token.
        book.exitFiles[opened] = URL(fileURLWithPath: "/tmp/x.exit")
        book.sentAt[opened] = Date()
        book.restarted(opened)
        #expect(book.exitFiles[opened] == nil && book.sentAt[opened] == nil)
        #expect(status("GET", "/v1/cli/sessions", openedToken) == 200)
        book.forget(claude)
        #expect(status("GET", "/v1/cli/sessions", claudeToken) == 401)
    }

    @Test func targets() {
        let a = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "D1234567-0000-0000-0000-000000000003")!
        let all = [a, b, c]
        #expect(SessionCLI.target("self", caller: b, sessions: all) == .found(b))
        #expect(SessionCLI.target(a.uuidString.lowercased(), caller: b, sessions: all) == .found(a))
        #expect(SessionCLI.target("d1234567", caller: a, sessions: all) == .found(c))
        #expect(SessionCLI.target("C0000000", caller: a, sessions: all) == .ambiguous)
        #expect(SessionCLI.target("D12", caller: a, sessions: all) == .unknown) // too short
        #expect(SessionCLI.target(UUID().uuidString, caller: a, sessions: all) == .unknown)
        #expect(SessionCLI.target("acme", caller: a, sessions: all) == .unknown)
    }

    // MARK: Consent

    @Test func consentRule() {
        let me = UUID(), other = UUID(), target = UUID()
        func delivery(_ kind: SessionKind, openedBy: UUID? = nil, beside: Bool = false, mayType: Bool = false, to: UUID? = nil) -> SessionCLI.Delivery {
            SessionCLI.delivery(caller: me, target: to ?? target, targetKind: kind, targetOpenedBy: openedBy, besideCaller: beside, mayTypeIntoClaude: mayType)
        }
        // Its own terminals: ones it opened, or plain terminals in a pane beside it.
        #expect(delivery(.shell, openedBy: me) == .type)
        #expect(delivery(.shell, beside: true) == .type)
        // Anyone else's terminal: no.
        #expect(delivery(.shell, openedBy: other) == .refuse("not_yours"))
        #expect(delivery(.shell) == .refuse("not_yours"))
        #expect(delivery(.shell, mayType: true) == .refuse("not_yours"))
        // Another Claude session: a note unless the user lets sessions type into Claude, even beside it.
        #expect(delivery(.claude) == .note)
        #expect(delivery(.claude, beside: true) == .note)
        #expect(delivery(.claude, mayType: true) == .type)
        #expect(delivery(.claude, mayType: true, to: me) == .refuse("cannot_send_to_self"))
        #expect(delivery(.shell, openedBy: me, to: me) == .refuse("cannot_send_to_self"))
    }

    @Test func settingsAreOffByDefaultAndOldFilesDecode() throws {
        #expect(!DeckSettings().sessionCLIEnabled && !DeckSettings().sessionsMayTypeIntoClaude)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"agentAPIEnabled":true,"agentAPIPort":47700}"#.utf8))
        #expect(!old.sessionCLIEnabled && !old.sessionsMayTypeIntoClaude && old.agentAPIPort == 47700)
        let opener = UUID()
        let session = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"t","kind":"shell","openedBy":"\#(opener.uuidString)"}"#
        #expect(try JSONDecoder().decode(DeckSession.self, from: Data(session.utf8)).openedBy == opener)
        let older = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"t"}"#
        #expect(try JSONDecoder().decode(DeckSession.self, from: Data(older.utf8)).openedBy == nil)
    }

    // MARK: Waiting

    @Test func claudeProgress() {
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SessionCLI.claudeProgress(state: "idle", updatedAt: sent.addingTimeInterval(-60), sentAt: nil) == .finished(0))
        #expect(SessionCLI.claudeProgress(state: "running", updatedAt: nil, sentAt: nil) == .running)
        #expect(SessionCLI.claudeProgress(state: "starting", updatedAt: nil, sentAt: nil) == .running)
        #expect(SessionCLI.claudeProgress(state: "needsPermission", updatedAt: nil, sentAt: nil) == .blocked("needsPermission"))
        #expect(SessionCLI.claudeProgress(state: "needsAnswer", updatedAt: nil, sentAt: nil) == .blocked("needsAnswer"))
        #expect(SessionCLI.claudeProgress(state: "stopped", updatedAt: nil, sentAt: nil) == .stopped)
        // Right after a send, the idle it was already in doesn't count…
        #expect(SessionCLI.claudeProgress(state: "idle", updatedAt: sent.addingTimeInterval(-5), sentAt: sent, now: sent.addingTimeInterval(1)) == .running)
        // …a hook update after it does…
        #expect(SessionCLI.claudeProgress(state: "idle", updatedAt: sent.addingTimeInterval(3), sentAt: sent, now: sent.addingTimeInterval(4)) == .finished(0))
        // …and without hooks it gives up waiting for one.
        #expect(SessionCLI.claudeProgress(state: "idle", updatedAt: nil, sentAt: sent, now: sent.addingTimeInterval(SessionCLI.sendGrace + 1)) == .finished(0))
    }

    @Test func shellProgress() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func progress(running: Bool = true, pending: Bool = false, command: Int32? = nil, process: Int32? = nil, busy: Bool = false,
                      sent: TimeInterval? = nil, editing: Bool = true, output: TimeInterval? = nil) -> SessionCLI.Progress {
            SessionCLI.shellProgress(running: running, commandPending: pending, commandExit: command, processExit: process,
                                     foregroundBusy: busy, sentAt: sent.map { now.addingTimeInterval(-$0) }, lineEditing: editing,
                                     lastOutput: output.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(progress(pending: true) == .running)
        #expect(progress(command: 0) == .finished(0))
        #expect(progress(command: 2) == .failed(2))
        #expect(progress(command: 130) == .failed(130))
        #expect(progress(busy: true) == .running)
        #expect(progress() == .finished(nil))
        #expect(progress(sent: 0.5) == .running)
        #expect(progress(sent: 10) == .finished(nil))
        // After a send, output that hasn't settled yet (a shell still starting, a builtin printing).
        #expect(progress(sent: 10, output: 0.5) == .running)
        #expect(progress(sent: 10, output: 5) == .finished(nil))
        #expect(progress(sent: 10, output: 11) == .finished(nil)) // printed before the send
        // The shell hasn't reached its prompt yet (rc files): busy, but not forever (sh has no line editor).
        #expect(progress(sent: 5, editing: false) == .running)
        #expect(progress(sent: SessionCLI.shellReadyLimit + 1, editing: false) == .finished(nil))
        #expect(progress(editing: false) == .finished(nil)) // nothing was sent
        // The shell itself ended.
        #expect(progress(running: false, process: 0) == .finished(0))
        #expect(progress(running: false, pending: true, process: 1) == .failed(1))
        #expect(progress(running: false, command: 3, process: 0) == .failed(3))
        #expect(progress(running: false) == .stopped)
        #expect(SessionCLI.exitCode(waitStatus: 0) == 0)
        #expect(SessionCLI.exitCode(waitStatus: 3 << 8) == 3)
        #expect(SessionCLI.exitCode(waitStatus: 9) == 137) // SIGKILL
    }

    @Test func exitCodes() {
        #expect(SessionCLI.Progress.finished(0).exit == .ok)
        #expect(SessionCLI.Progress.finished(nil).exit == .ok)
        #expect(SessionCLI.Progress.stopped.exit == .ok)
        #expect(SessionCLI.Progress.failed(2).exit == .failed)
        #expect(SessionCLI.Progress.blocked("needsAnswer").exit == .blocked)
        #expect(SessionCLI.Progress.running.exit == .timeout)
        // Stable numbers: documented in docs/agents.md and the skill.
        #expect(SessionCLI.Progress.limited(nil).exit == .limited)
        #expect(SessionCLI.Exit.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 124])
        #expect(SessionCLI.exit(status: 200, header: "124") == .timeout)
        #expect(SessionCLI.exit(status: 200, header: nil) == .ok)
        #expect(SessionCLI.exit(status: 400, header: nil) == .usage)
        #expect(SessionCLI.exit(status: 403, header: nil) == .refused)
        #expect(SessionCLI.exit(status: 429, header: nil) == .refused)
        #expect(SessionCLI.exit(status: 404, header: nil) == .unknown)
        #expect(SessionCLI.exit(status: 409, header: nil) == .failed)
        #expect(SessionCLI.exit(status: 409, header: "3") == .blocked)
        let answer = SessionCLI.answer(200, ["a": "b"], text: "hello", exit: .blocked, json: false)
        #expect(answer.body == Data("hello".utf8) && answer.contentType.hasPrefix("text/plain"))
        #expect(String(decoding: answer.encoded(), as: UTF8.self).contains("\r\nX-ClaudeDeck-Exit: 3\r\n"))
        let json = SessionCLI.answer(200, ["a": "b"], text: "hello", exit: .ok, json: true)
        #expect(json.body == Data(#"{"a":"b"}"#.utf8))
    }

    @Test func waitedJSONKeepsEveryKey() throws {
        let data = try AgentJSON.encode(SessionCLIWaited(.finished(nil), state: "idle", detail: nil))
        #expect(String(decoding: data, as: UTF8.self) == #"{"detail":null,"exit_code":null,"result":"finished","state":"idle"}"#)
        #expect(SessionCLI.waitText(.failed(2), detail: nil) == "failed (exit 2)")
        #expect(SessionCLI.waitText(.blocked("needsPermission"), detail: "Bash") == "blocked: needs permission — Bash")
    }

    // MARK: Capture and list

    @Test func captureText() {
        func line(_ text: String) -> [TermCell] { text.map { TermCell(text: String($0)) } }
        let wide = [TermCell(text: "界", width: 2), TermCell(text: "", width: 0), TermCell(text: "x")]
        let lines = [line("   "), line("$ npm test   "), wide, line(""), line("ok    "), line("  "), line("")]
        #expect(SessionCLI.text(of: lines, last: nil, trim: false) == "\n$ npm test\n界x\n\nok\n\n")
        #expect(SessionCLI.text(of: lines, last: nil, trim: true) == "$ npm test\n界x\n\nok")
        #expect(SessionCLI.text(of: lines, last: 2, trim: true) == "\nok")
        #expect(SessionCLI.text(of: lines, last: 0, trim: true) == "")
    }

    @Test func listTextAndJSON() throws {
        let me = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        let dev = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
        let project = UUID()
        let infos = [
            SessionCLIInfo(id: me, name: "acme", kind: "claude", state: "running", detail: nil, projectId: project, project: "acme",
                           pane: 1, isSelf: true, openedBySelf: false, openedBy: nil),
            SessionCLIInfo(id: dev, name: "acme · npm run dev", kind: "terminal", state: "running", detail: nil, projectId: project,
                           project: "acme", pane: nil, isSelf: false, openedBySelf: true, openedBy: me),
        ]
        #expect(SessionCLI.listText(infos) == """
        ID        KIND      STATE    PANE  WHOSE  NAME
        C0000000  claude    running  1     self   acme
        D0000000  terminal  running  -     mine   acme · npm run dev
        """)
        let json = String(decoding: try AgentJSON.encode(infos[1]), as: UTF8.self)
        #expect(json.contains(#""self":false"#) && json.contains(#""mine":true"#) && json.contains(#""pane":null"#))
        #expect(json.contains(#""opened_by":"\#(me.uuidString)""#))
    }

    @Test func limiter() {
        var limiter = SessionCLILimiter(max: 2, window: 60)
        let session = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = limiter.allow(session, now: start), second = limiter.allow(session, now: start)
        let third = limiter.allow(session, now: start.addingTimeInterval(30))
        let later = limiter.allow(session, now: start.addingTimeInterval(61))
        #expect(first && second && !third && later)
    }

    // MARK: The script

    /// Runs `claudedeck` with a stand-in `curl` that logs its arguments and answers
    /// `body` with `status` ("<http> <exit header>"), one answer per call.
    private struct Run {
        var code: Int32
        var out: String
        var err: String
        var curlCalls: [[String]]
    }

    private func run(_ args: [String], answers: [(body: String, status: String)] = [], session: Bool = true,
                     home: URL? = nil, cwd: URL? = nil, slowFirstAnswer: Int? = nil) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudedeck-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claudedeck")
        try Data(SessionCLI.script.utf8).write(to: script)
        for (index, answer) in answers.enumerated() {
            try Data(answer.body.utf8).write(to: dir.appending(path: "body\(index)"))
            try Data(answer.status.utf8).write(to: dir.appending(path: "status\(index)"))
        }
        if let slowFirstAnswer { try Data("\(slowFirstAnswer)".utf8).write(to: dir.appending(path: "sleep0")) }
        let curl = dir.appending(path: "curl")
        try Data(#"""
        #!/bin/sh
        d=$(dirname "$0")
        n=$(cat "$d/count" 2>/dev/null || echo 0)
        echo $((n + 1)) > "$d/count"
        for a in "$@"; do printf '%s\037' "$a"; done >> "$d/calls"
        printf '\036' >> "$d/calls"
        [ -f "$d/status$n" ] || { printf '\n000 '; exit 7; }
        [ -f "$d/sleep$n" ] && sleep "$(cat "$d/sleep$n")"
        cat "$d/body$n"; printf '\n'; cat "$d/status$n"
        """#.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + args
        var env = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": (home ?? dir).path]
        if session {
            env["CLAUDEDECK_CLI_TOKEN"] = "tok-123"
            env["CLAUDEDECK_CLI_URL"] = "http://127.0.0.1:47832/v1/cli"
        }
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = (try? String(contentsOf: dir.appending(path: "calls"), encoding: .utf8)) ?? ""
        let calls = raw.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        return Run(code: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self), curlCalls: calls)
    }

    @Test func scriptSyntaxAndNoSecret() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "claudedeck-syntax-\(UUID().uuidString)")
        try Data(SessionCLI.script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", file.path]
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        #expect(SessionCLI.script.hasPrefix("#!/bin/sh\n"))
        #expect(SessionCLI.script.contains("$CLAUDEDECK_CLI_TOKEN") && !SessionCLI.script.contains("47647"))
    }

    @Test func usageErrorsExitTwo() throws {
        #expect(try run(["help"]).code == 0)
        #expect(try run(["help"]).out.contains("claudedeck wait ID"))
        #expect(try run(["frobnicate"]).code == 2)
        #expect(try run(["list"], session: false).code == 2) // not in a ClaudeDeck session
        #expect(try run(["open", "--split", "diagonal", "--", "ls"]).code == 2)
        #expect(try run(["send"]).code == 2)
        #expect(try run(["send", "abcd"]).code == 2) // nothing to send
        #expect(try run(["send", "ab/../cd", "x"]).code == 2)
        #expect(try run(["capture", "abcd", "--lines", "many"]).code == 2)
        #expect(try run(["wait", "abcd", "--timeout", "-1"]).code == 2)
        #expect(try run(["notify"]).code == 2)
        #expect(try run(["ask"]).code == 2)
        // None of these reached the API.
        #expect(try run(["send", "abcd"]).curlCalls.isEmpty)
    }

    /// `claudedeck account …` and `new --account` (Settings › Accounts).
    @Test func accountCommands() throws {
        let list = try run(["account", "list", "--json"], answers: [("[]", "200 0")])
        #expect(list.code == 0 && list.curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/accounts")
        #expect(try run(["account"], answers: [("x", "200 0")]).curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/accounts")
        let current = try run(["account", "current"], answers: [("work", "200 0")])
        #expect(current.out == "work\n" && current.curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/accounts/current")
        let move = try run(["account", "switch", "--to", "work-2"], answers: [("switching", "200 0")])
        let call = try #require(move.curlCalls.first)
        #expect(call.contains("to=work-2") && !call.contains("-G") && call.last == "http://127.0.0.1:47832/v1/cli/accounts/switch")
        let none = try run(["account", "switch"], answers: [(#"{"error":"no_account"}"#, "409 1")])
        #expect(none.code == 1 && none.err.contains("no other account has room"))
        // Bad names and options never reach the API.
        #expect(try run(["account", "switch", "--to", "Work Account"]).code == 2)
        #expect(try run(["account", "list", "--to", "x"]).code == 2)
        #expect(try run(["account", "frob"]).code == 2)
        let new = try run(["new", "--account", "auto", "--prompt", "hi"], answers: [("id", "200 0")])
        #expect(new.curlCalls.first?.contains("account=auto") == true)
        #expect(try run(["new", "--account", "../x"]).code == 2)
        #expect(try run(["help"]).out.contains("claudedeck account switch"))
        // wait: 6 when the session waits for its usage limit to reset.
        #expect(try run(["wait", "abcd1234"], answers: [("limited: usage limit reached", "200 6")]).code == 6)
    }

    @Test func requestsAndExitCodes() throws {
        let list = try run(["list", "--json"], answers: [("[]", "200 0")])
        #expect(list.code == 0 && list.out == "[]\n")
        let call = try #require(list.curlCalls.first)
        #expect(call.contains("Authorization: Bearer tok-123") && call.contains("-G") && call.contains("format=json"))
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/sessions")

        let send = try run(["send", "d1234567", "npm test", "--enter"], answers: [("terminal: typed into dev", "200 0")])
        #expect(send.code == 0 && send.out == "terminal: typed into dev\n")
        let sent = try #require(send.curlCalls.first)
        #expect(sent.contains("text=npm test") && sent.contains("enter=1") && sent.last == "http://127.0.0.1:47832/v1/cli/sessions/d1234567/send")
        // Text that starts with a dash, after --.
        #expect(try run(["send", "self", "--", "-v"], answers: [("ok", "200 0")]).curlCalls.first?.contains("text=-v") == true)

        // The API's exit code wins; errors go to stderr.
        let blocked = try run(["send", "abcd", "x", "--enter"], answers: [(#"{"error":"blocked"}"#, "409 3")])
        #expect(blocked.code == 3 && blocked.err.contains("blocked") && blocked.out.isEmpty)
        let refused = try run(["send", "abcd", "x"], answers: [(#"{"error":"not_yours"}"#, "403 4")])
        #expect(refused.code == 4 && refused.err.contains("not_yours"))
        #expect(try run(["capture", "abcd"], answers: [(#"{"error":"unknown_session"}"#, "404 5")]).code == 5)
        // The routes are off: 404 without the header.
        let off = try run(["list"], answers: [(#"{"error":"not_found"}"#, "404 ")])
        #expect(off.code == 4 && off.err.contains("off"))
        // Nothing listening.
        let down = try run(["list"])
        #expect(down.code == 1 && down.err.contains("isn't answering"))
    }

    @Test func openQuotesSeveralWordsAndKeepsOneLine() throws {
        let several = try run(["open", "--name", "web", "--", "npm", "run", "it's"], answers: [("ID", "200 0")])
        #expect(several.code == 0 && several.out == "ID\n")
        let call = try #require(several.curlCalls.first)
        #expect(call.contains("command=npm run 'it'\\''s'") && call.contains("name=web") && call.contains("split=right"))
        #expect(try run(["open", "--", "sh", "-c", "echo a; sleep 1"], answers: [("ID", "200 0")]).curlCalls.first?
            .contains("command=sh -c 'echo a; sleep 1'") == true)
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/terminals")
        let one = try run(["open", "--split=down", "npm run dev && echo up"], answers: [("ID", "200 0")])
        #expect(one.curlCalls.first?.contains("command=npm run dev && echo up") == true)
        #expect(one.curlCalls.first?.contains("split=down") == true)
    }

    @Test func waitAsksAgainUntilItsOwnTimeout() throws {
        // No limit: the 25-second windows repeat until an answer.
        let done = try run(["wait", "abcd"], answers: [("timeout: still running", "200 124"), ("timeout: still running", "200 124"),
                                                       ("failed (exit 2)", "200 1")])
        #expect(done.code == 1 && done.out == "failed (exit 2)\n" && done.curlCalls.count == 3)
        #expect(done.curlCalls[0].contains("timeout=25"))
        // A short timeout is a window of that length; once it has passed, 124.
        let short = try run(["wait", "abcd", "--timeout", "1"], answers: [("timeout: still running", "200 124"), ("x", "200 0")],
                            slowFirstAnswer: 2)
        #expect(short.code == 124 && short.curlCalls.count == 1 && short.curlCalls[0].contains("timeout=1"))
        #expect(short.out == "timeout: still running\n")
        // Time left: it asks again.
        let again = try run(["wait", "abcd", "--timeout", "60"], answers: [("timeout: still running", "200 124"), ("finished (exit 0)", "200 0")])
        #expect(again.code == 0 && again.curlCalls.count == 2 && again.curlCalls[0].contains("timeout=25"))
        #expect(try run(["wait", "abcd"], answers: [("blocked: asking a question", "200 3")]).code == 3)
    }

    @Test func skillSetupKeepsTheUsersEdits() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "claudedeck-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: ".claude/skills/claudedeck/SKILL.md")

        let first = try run(["skill", "setup"], session: false, home: home)
        #expect(first.code == 0 && first.out.contains("installed"))
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.hasPrefix(SessionCLI.skill + "\n<!-- claudedeck-skill sha256:"))
        #expect(written.contains("name: claudedeck") && written.contains("description: "))

        #expect(try run(["skill", "setup"], session: false, home: home).out.contains("up to date"))

        // Edited by hand: kept, unless --force.
        try Data((written + "My own note.\n").utf8).write(to: file)
        let kept = try run(["skill", "setup", "--user"], session: false, home: home)
        #expect(kept.code == 4 && kept.err.contains("--force"))
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("My own note.\n"))
        let forced = try run(["skill", "setup", "--force"], session: false, home: home)
        #expect(forced.code == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == written)

        // A file the user wrote without the hash line is theirs too.
        try Data("---\nname: claudedeck\n---\nmine\n".utf8).write(to: file)
        #expect(try run(["skill", "setup"], session: false, home: home).code == 4)

        // An older ClaudeDeck version's skill (hash matches its own text) is replaced.
        let older = "---\nname: claudedeck\n---\nolder text\n"
        let hash = try shasum(older)
        try Data((older + "<!-- claudedeck-skill sha256:\(hash) -->\n").utf8).write(to: file)
        #expect(try run(["skill", "setup"], session: false, home: home).out.contains("installed"))
        #expect(try String(contentsOf: file, encoding: .utf8) == written)

        // --project: the repository's .claude/skills.
        let project = home.appending(path: "repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let local = try run(["skill", "setup", "--project"], session: false, home: home, cwd: project)
        #expect(local.code == 0)
        #expect(FileManager.default.fileExists(atPath: project.appending(path: ".claude/skills/claudedeck/SKILL.md").path))
    }

    private func shasum(_ text: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(String(decoding: data, as: UTF8.self).prefix(64))
    }

    @Test func skillIsEnglishWithFrontmatter() {
        let skill = SessionCLI.skill
        #expect(skill.hasPrefix("---\nname: claudedeck\ndescription: "))
        #expect(skill.contains("CLAUDEDECK_SESSION") && skill.contains("| 124 |"))
        // The heredoc that carries it must not end early.
        #expect(!skill.split(separator: "\n").contains("SKILL"))
    }

    // MARK: Projects, sessions and ServerPlan in the script

    @Test func projectAndNewArguments() throws {
        let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let add = try run(["project", "add", "./svc", "--name", "Svc", "--group", "Services", "--create"], answers: [("PID", "200 0")], cwd: cwd)
        #expect(add.code == 0 && add.out == "PID\n")
        let call = try #require(add.curlCalls.first)
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/projects" && !call.contains("-G"))
        #expect(call.contains("create=1") && call.contains("name=Svc") && call.contains("group=Services"))
        #expect(call.contains { $0.hasPrefix("path=/") && $0.hasSuffix("/svc") })
        #expect(try run(["project", "add"]).code == 2)
        #expect(try run(["project", "remove", "/x"]).code == 2)
        #expect(try run(["projects", "--json"], answers: [("[]", "200 0")]).curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/projects")

        let new = try run(["new", "--project", "web shop", "--prompt", "Fix the cart", "--worktree", "cart"], answers: [("SID", "200 0")])
        #expect(new.code == 0 && new.out == "SID\n")
        let started = try #require(new.curlCalls.first)
        #expect(started.last == "http://127.0.0.1:47832/v1/cli/projects/web%20shop/sessions")
        #expect(started.contains("prompt=Fix the cart") && started.contains("worktree=cart"))
        #expect(try run(["new"], answers: [("SID", "200 0")]).curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/projects/self/sessions")
        let path = try run(["new", "--project", "/Users/x/app"], answers: [("SID", "200 0")])
        #expect(path.curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/projects/%2FUsers%2Fx%2Fapp/sessions")
        #expect(try run(["new", "--bogus"]).code == 2)
        // Off, rate-limited or unknown: the API's codes, with a hint.
        let off = try run(["new"], answers: [(#"{"error":"setting_off"}"#, "403 4")])
        #expect(off.code == 4 && off.err.contains("Settings"))
        #expect(try run(["new", "--project", "nope"], answers: [(#"{"error":"unknown_project"}"#, "404 5")]).code == 5)
    }

    @Test func serverArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        let list = try run(["server", "list"], answers: [("ID  NAME", "200 0")])
        #expect(list.code == 0 && list.curlCalls.first?.last == base + "list" && list.curlCalls.first?.contains("-G") == true)
        let logs = try run(["server", "logs", "prod", "api", "--tail", "50"], answers: [("line", "200 0")])
        #expect(logs.curlCalls.first?.contains("tail=50") == true && logs.curlCalls.first?.contains("container=api") == true)
        #expect(try run(["server", "logs", "prod"]).code == 2)
        #expect(try run(["server", "logs", "prod", "api", "--tail", "lots"]).code == 2)
        #expect(try run(["server", "container", "prod", "api", "delete"]).code == 2)
        #expect(try run(["server", "deploy-status", "abc"]).code == 2)
        #expect(try run(["server", "frobnicate"]).code == 2)
        #expect(try run(["server", "list"]).curlCalls.count == 1)
        #expect(try run(["server", "frobnicate"]).curlCalls.isEmpty)

        // deploy --wait: the id, then the log until the end (124 = ask again).
        let deploy = try run(["server", "deploy", "web", "--wait"], answers: [("301", "202 0"), ("building…", "200 124 1:building"),
                                                                              ("done line\ndeploy #301: success", "200 0 2:success")])
        #expect(deploy.code == 0 && deploy.out == "301\nbuilding…\ndone line\ndeploy #301: success\n")
        #expect(deploy.curlCalls.count == 3 && deploy.curlCalls[0].last == base + "deploy" && deploy.curlCalls[0].contains("project=web"))
        #expect(deploy.curlCalls[1].contains("id=301") && deploy.curlCalls[1].contains("since=0"))
        #expect(deploy.curlCalls[2].contains("since=1") && deploy.curlCalls[2].contains("status=building"))
        let failed = try run(["server", "deploy-status", "301", "--wait"], answers: [("deploy #301: failed\nerror: boom", "200 1 9:failed")])
        #expect(failed.code == 1 && failed.out.contains("error: boom"))
        // The owner said no.
        let refused = try run(["server", "container", "prod", "api", "restart"], answers: [(#"{"error":"owner_refused","message":"no"}"#, "403 4")])
        #expect(refused.code == 4 && refused.err.contains("owner"))
        let missing = try run(["server", "scan", "/x"], answers: [(#"{"error":"not_available","message":"not available: ServerPlan doesn't offer this yet"}"#, "501 4")])
        #expect(missing.code == 4 && missing.err.contains("doesn't offer this yet"))
    }

    @Test func serverContainerArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        // Reads: one GET each, to their own command.
        for (verb, command) in [("status", "container-inspect"), ("inspect", "container-inspect"), ("env", "container-env"), ("stats", "container-stats")] {
            let call = try #require(try run(["server", "container", "prod", "api", verb], answers: [("ok", "200 0")]).curlCalls.first)
            #expect(call.last == base + command && call.contains("-G") && call.contains("server=prod") && call.contains("container=api"), "\(verb)")
        }
        // `container … logs` is `logs …`, with --grep / --since passed on.
        let logs = try #require(try run(["server", "container", "prod", "api", "logs", "--tail", "300", "--grep", "error", "--since", "10m"],
                                        answers: [("line", "200 0")]).curlCalls.first)
        #expect(logs.last == base + "logs" && logs.contains("tail=300") && logs.contains("grep=error") && logs.contains("since=10m"))
        #expect(try run(["server", "logs", "prod", "api", "--since", "yesterday; rm"]).code == 2)
        // Owner-gated ones: POST, the long wait.
        for verb in ["recreate", "pull", "remove"] {
            let call = try #require(try run(["server", "container", "prod", "api", verb], answers: [("done", "200 0")]).curlCalls.first)
            #expect(call.last == base + "container-\(verb)" && !call.contains("-G") && call.contains("container=api"), "\(verb)")
        }
        let restart = try #require(try run(["server", "container", "prod", "api", "restart"], answers: [("done", "200 0")]).curlCalls.first)
        #expect(restart.last == base + "container" && restart.contains("action=restart"))
        #expect(try run(["server", "container", "prod", "api", "delete"]).code == 2)
        #expect(try run(["server", "container", "prod", "api", "exec"]).curlCalls.isEmpty)
        // Server-wide.
        let stats = try #require(try run(["server", "stats", "prod"], answers: [("server: cpu 1%", "200 0")]).curlCalls.first)
        #expect(stats.last == base + "stats" && stats.contains("-G") && stats.contains("server=prod"))
        #expect(try run(["server", "stats"]).code == 2)
        let disk = try #require(try run(["server", "disk", "prod"], answers: [("TYPE", "200 0")]).curlCalls.first)
        #expect(disk.last == base + "disk")
        let prune = try #require(try run(["server", "prune", "prod", "--images", "unused", "--volumes", "--no-build-cache"],
                                         answers: [("done", "200 0")]).curlCalls.first)
        #expect(prune.last == base + "prune" && prune.contains("images=unused") && prune.contains("volumes=1")
            && prune.contains("build_cache=0") && prune.contains("containers=1"))
        let plain = try #require(try run(["server", "prune", "prod"], answers: [("done", "200 0")]).curlCalls.first)
        #expect(plain.contains("images=dangling") && plain.contains("volumes=0") && plain.contains("build_cache=1"))
        #expect(try run(["server", "prune", "prod", "--images", "everything"]).code == 2)
        let refused = try run(["server", "prune", "prod"], answers: [(#"{"error":"owner_refused","message":"no"}"#, "403 4")])
        #expect(refused.code == 4)
        let missing = try run(["server", "container", "prod", "api", "recreate"],
                              answers: [(#"{"error":"not_available","message":"not available: ServerPlan doesn't offer this yet"}"#, "501 4")])
        #expect(missing.code == 4 && missing.err.contains("doesn't offer this yet"))
    }

    @Test func serverRateLimitArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        let show = try #require(try run(["server", "ratelimit", "show", "api.x.com"], answers: [("no rule", "200 0")]).curlCalls.first)
        #expect(show.last == base + "ratelimit-show" && show.contains("-G") && show.contains("host=api.x.com"))
        let set = try #require(try run(["server", "ratelimit", "set", "api.x.com", "--paths", "/init,/v1/*", "--rate", "100/1m"],
                                       answers: [("set", "200 0")]).curlCalls.first)
        #expect(set.last == base + "ratelimit-set" && !set.contains("-G") && set.contains("paths=/init,/v1/*") && set.contains("rate=100/1m"))
        let plain = try #require(try run(["server", "ratelimit", "set", "api.x.com"], answers: [("set", "200 0")]).curlCalls.first)
        #expect(plain.contains("paths=") && plain.contains("rate="))
        let clear = try #require(try run(["server", "ratelimit", "clear", "api.x.com"], answers: [("cleared", "200 0")]).curlCalls.first)
        #expect(clear.last == base + "ratelimit-clear" && clear.contains("host=api.x.com"))
        #expect(try run(["server", "ratelimit", "show"]).code == 2)
        #expect(try run(["server", "ratelimit", "drop", "api.x.com"]).code == 2)
        #expect(try run(["server", "ratelimit", "clear", "api.x.com", "--rate", "1/1s"]).code == 2)
        let refused = try run(["server", "ratelimit", "clear", "api.x.com"], answers: [(#"{"error":"owner_refused","message":"no"}"#, "403 4")])
        #expect(refused.code == 4)
    }

    @Test func staticSiteArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        let quick = try run(["server", "static", "add", "prod", "example.com"], answers: [("added", "201 0")])
        let call = try #require(quick.curlCalls.first)
        #expect(quick.code == 0 && call.last == base + "static-add" && call.contains("server=prod") && call.contains("base=example.com"))
        #expect(try run(["server", "static", "add", "prod"]).code == 2)
        #expect(try run(["server", "static", "list", "prod", "example.com"]).curlCalls.isEmpty)

        let site = try run(["server", "domain", "add", "--static", "prod", "docs", "example.com", "--no-clean-urls", "--target", "/opt/static/x"],
                           answers: [("added", "201 0")])
        let added = try #require(site.curlCalls.first)
        #expect(added.last == base + "domain-add" && added.contains("static=1") && added.contains("server=prod"))
        #expect(added.contains("subdomain=docs") && added.contains("clean_urls=0") && added.contains("target=/opt/static/x"))
        let plain = try #require(try run(["server", "domain", "add", "--static", "prod", "docs", "example.com"], answers: [("added", "201 0")]).curlCalls.first)
        #expect(plain.contains("clean_urls=1") && plain.contains("target="))
        #expect(try run(["server", "domain", "add", "--static", "prod", "example.com"]).code == 2)

        // sync: the folder goes out absolute, with symlinks resolved.
        let dir = FileManager.default.temporaryDirectory.appending(path: "cli-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "site/dist"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "link"), withDestinationURL: dir.appending(path: "site"))
        // realpath(3), not resolvingSymlinksInPath (that one drops /private on macOS).
        let real = try #require(realpath(dir.appending(path: "site/dist").path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let synced = try run(["server", "sync", "docs.example.com", "link/dist"], answers: [("Files synced to /opt/static/docs-example-com", "200 0")], cwd: dir)
        let sent = try #require(synced.curlCalls.first)
        #expect(synced.code == 0 && synced.out.contains("Files synced") && sent.last == base + "sync")
        #expect(sent.contains("domain=docs.example.com") && sent.contains("path=\(real)"))
        let missing = try run(["server", "sync", "docs.example.com", dir.appending(path: "nope").path])
        #expect(missing.code == 2 && missing.curlCalls.isEmpty)
        #expect(try run(["server", "sync", "docs.example.com"]).code == 2)
        let outside = try run(["server", "sync", "5", dir.path], answers: [(#"{"error":"not_in_project_dir","message":"inside a registered project dir"}"#, "403 4")])
        #expect(outside.code == 4 && outside.err.contains("registered project dir"))
    }

    @Test func domainCheckAndBuyArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        let check = try run(["server", "domain", "check", "shop-example.com"], answers: [("shop-example.com: available", "200 0")])
        let checked = try #require(check.curlCalls.first)
        #expect(check.code == 0 && checked.last == base + "domain-check" && checked.contains("-G") && checked.contains("domain=shop-example.com"))
        #expect(try run(["server", "domain", "check"]).code == 2)

        // buy: the approval goes along; the command waits for the owner and the registrar.
        let bought = try run(["server", "domain", "buy", "shop-example.com", "--approval", "d_00000000aa", "--years", "2", "--no-dns"],
                             answers: [("bought: shop-example.com for 2 years", "201 0")])
        let call = try #require(bought.curlCalls.first)
        #expect(bought.code == 0 && bought.out.contains("bought: shop-example.com") && call.last == base + "domain-buy")
        #expect(call.contains("domain=shop-example.com") && call.contains("approval=d_00000000aa") && call.contains("years=2"))
        #expect(call.contains("no_dns=1") && call.contains("330") && !call.contains("-G"))
        let plain = try #require(try run(["server", "domain", "buy", "shop-example.com", "--approval", "d_00000000aa"],
                                         answers: [("bought", "201 0")]).curlCalls.first)
        #expect(plain.contains("years=1") && plain.contains("no_dns=0"))
        let json = try run(["server", "domain", "buy", "shop-example.com", "--approval", "d_00000000aa", "--json"], answers: [(#"{"order_id":"7001"}"#, "201 0")])
        #expect(json.out.contains("7001") && json.curlCalls.first?.contains("format=json") == true)

        // Nothing goes out without an approval, or with a bad --years.
        let none = try run(["server", "domain", "buy", "shop-example.com"])
        #expect(none.code == 2 && none.curlCalls.isEmpty && none.err.contains("claudedeck decide"))
        #expect(try run(["server", "domain", "buy", "shop-example.com", "--approval", "d_00000000aa", "--years", "3"]).curlCalls.isEmpty)
        #expect(try run(["server", "domain", "buy", "--approval", "d_00000000aa"]).code == 2)

        // The app's refusals: the exit code and the hint pass through.
        for (body, status, code, hint) in [
            (#"{"error":"bad_approval","message":"d_00000000aa doesn't mention shop-example.com; ask the owner first with claudedeck decide, then pass its id"}"#, "400 2", 2, "claudedeck decide"),
            (#"{"error":"owner_refused","message":"the owner didn't approve the purchase in ClaudeDeck; nothing was bought"}"#, "403 4", 4, "nothing was bought"),
            (#"{"error":"purchase_disabled","message":"kapali; agent purchases are turned off in ServerPlan › Entegrasyonlar › Namecheap"}"#, "412 4", 4, "Entegrasyonlar"),
            (#"{"error":"conflict","message":"Domain musait degil; already bought, or not available: see claudedeck server domain check"}"#, "409 1", 1, "already bought"),
            (#"{"error":"price_cap","message":"Fiyat 40.00; over the owner's yearly price cap"}"#, "403 4", 4, "price cap"),
            (#"{"error":"insufficient_balance","message":"yetersiz; the Namecheap balance is too low; the owner tops it up"}"#, "402 4", 4, "balance is too low"),
        ] {
            let refused = try run(["server", "domain", "buy", "shop-example.com", "--approval", "d_00000000aa"], answers: [(body, status)])
            #expect(refused.code == Int32(code) && refused.err.contains(hint), "\(status) \(refused.err)")
        }
    }

    @Test func balanceArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        let plain = try run(["server", "balance"], answers: [("available: 15.00 USD\nLOW: under the threshold", "200 0")])
        let call = try #require(plain.curlCalls.first)
        #expect(plain.code == 0 && plain.out.contains("LOW") && call.last == base + "balance" && call.contains("-G") && call.contains("refresh=0"))
        let fresh = try run(["server", "balance", "--refresh", "--json"], answers: [(#"{"available_balance":15}"#, "200 0")])
        let refreshed = try #require(fresh.curlCalls.first)
        #expect(fresh.out.contains("available_balance") && refreshed.contains("refresh=1") && refreshed.contains("format=json"))
        // No arguments; unknown options are refused before anything goes out.
        let extra = try run(["server", "balance", "now"])
        #expect(extra.code == 2 && extra.curlCalls.isEmpty)
        #expect(try run(["server", "balance", "--force-it"]).curlCalls.isEmpty)
        // The app's refusals pass through: no Namecheap in the panel (4), an older panel (4), Namecheap down (1).
        for (body, status, code, hint) in [
            (#"{"error":"not_configured","message":"Namecheap ayarlari yapilmamis; Namecheap (or the registrant contact) isn't set up in ServerPlan › Entegrasyonlar › Namecheap"}"#, "412 4", 4, "Entegrasyonlar"),
            (#"{"error":"not_available","message":"not available: ServerPlan doesn't offer this yet"}"#, "501 4", 4, "doesn't offer this yet"),
            (#"{"error":"registrar_error","message":"timeout"}"#, "502 1", 1, "timeout"),
        ] {
            let refused = try run(["server", "balance"], answers: [(body, status)])
            #expect(refused.code == Int32(code) && refused.err.contains(hint), "\(status) \(refused.err)")
        }
    }

    @Test func envSetKeepsSecretsOffTheCommandLine() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cli-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("API_KEY=s3cret\n".utf8).write(to: dir.appending(path: ".env"))
        let set = try run(["server", "env", "set", "web", "--from-file", dir.appending(path: ".env").path, "--secret", "API_KEY", "DEBUG=1"],
                          answers: [("written: API_KEY (secret), DEBUG", "200 0")])
        #expect(set.code == 0 && !set.out.contains("s3cret"))
        let call = try #require(set.curlCalls.first)
        #expect(call.contains { $0.hasPrefix("vars=") && $0.contains("API_KEY=s3cret") && $0.contains("DEBUG=1") })
        #expect(call.contains("secret=API_KEY") && call.last == "http://127.0.0.1:47832/v1/cli/server/env-set")
        #expect(try run(["server", "env", "set", "web"]).code == 2)
        #expect(try run(["server", "env", "set", "web", "NOTANASSIGNMENT"]).code == 2)
        #expect(try run(["server", "env", "get", "web"], answers: [("KEY", "200 0")]).curlCalls.first?.contains("-G") == true)
    }

    @Test func v12ServerArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/server/"
        // env rescan, sql
        let rescan = try #require(try run(["server", "env", "rescan", "web", "--dry-run"], answers: [("would add: A", "200 0")]).curlCalls.first)
        #expect(rescan.last == base + "env-rescan" && rescan.contains("project=web") && rescan.contains("dry_run=1"))
        #expect(try run(["server", "env", "get", "web", "--dry-run"]).code == 2)
        // env rm: one row id; waits for the owner.
        let rm = try run(["server", "env", "rm", "web", "7", "--json"], answers: [(#"{"deleted":7,"key":"LOG_LEVEL","remaining_copies":1}"#, "200 0")])
        let rmCall = try #require(rm.curlCalls.first)
        #expect(rm.code == 0 && rm.out.contains("remaining_copies") && rmCall.last == base + "env-rm")
        #expect(rmCall.contains("project=web") && rmCall.contains("id=7") && rmCall.contains("150") && rmCall.contains("format=json"))
        #expect(try run(["server", "env", "rm", "web"]).code == 2)
        #expect(try run(["server", "env", "rm", "web", "abc"]).code == 2)
        #expect(try run(["server", "env", "rm", "web", "7", "8"]).code == 2)
        #expect(try run(["server", "env", "rm", "web", "7", "--dry-run"]).code == 2)
        let refused = try run(["server", "env", "rm", "web", "7"], answers: [(#"{"error":"owner_refused","message":"the owner didn't approve it in ClaudeDeck"}"#, "403 4")])
        #expect(refused.code == 4 && refused.err.contains("owner refused"))
        let sql = try #require(try run(["server", "sql", "web", "select 1", "--local"], answers: [("?column?", "200 0")]).curlCalls.first)
        #expect(sql.last == base + "sql" && sql.contains("query=select 1") && sql.contains("local=1") && sql.contains("write=0"))
        let write = try #require(try run(["server", "sql", "web", "update t set a = 1", "--write"], answers: [("UPDATE 1", "200 0")]).curlCalls.first)
        #expect(write.contains("write=1") && write.contains("220")) // waits for the owner
        #expect(try run(["server", "sql", "web"]).code == 2)

        // local run --wait: started, then status polls until running.
        let local = try run(["server", "local", "run", "web", "--port", "8081", "--no-cache", "--wait"],
                            answers: [("local run started: http://localhost:8081", "200 0"), ("local: building", "200 124 building"),
                                      ("local: running http://localhost:8081", "200 0 running")])
        #expect(local.code == 0 && local.out.contains("local run started") && local.out.contains("local: running"))
        #expect(local.curlCalls.count == 3 && local.curlCalls[0].last == base + "local-run" && local.curlCalls[0].contains("no_cache=1"))
        #expect(local.curlCalls[1].last == base + "local-status" && local.curlCalls[1].contains("wait=25"))
        #expect(local.curlCalls[2].contains("since=building"))
        let failed = try run(["server", "local", "status", "web", "--wait"], answers: [("local: failed\nerror: build", "200 1 failed")])
        #expect(failed.code == 1 && failed.out.contains("error: build"))
        #expect(try run(["server", "local", "logs", "web", "--tail", "20"], answers: [("x", "200 0")]).curlCalls.first?.contains("tail=20") == true)
        #expect(try run(["server", "local", "restart", "web"]).code == 2)

        // local-env: values from a file or stdin; unset by keys.
        let unset = try #require(try run(["server", "local-env", "unset", "web", "DB_NAME", "DEBUG"], answers: [("removed", "200 0")]).curlCalls.first)
        #expect(unset.last == base + "local-env-unset" && unset.contains("keys=DB_NAME,DEBUG"))
        let lset = try #require(try run(["server", "local-env", "set", "web", "DEBUG=1"], answers: [("written", "200 0")]).curlCalls.first)
        #expect(lset.last == base + "local-env-set" && lset.contains { $0.hasPrefix("vars=DEBUG=1") })
        #expect(try run(["server", "local-env", "set", "web", "--secret", "X"]).code == 2)
        #expect(try run(["server", "local-env", "rescan", "web"]).code == 2)
        let senv = try #require(try run(["server", "server-env", "set", "prod", "REGION=eu"], answers: [("written", "200 0")]).curlCalls.first)
        #expect(senv.last == base + "server-env-set" && senv.contains("server=prod"))

        // clone-for-local --wait: the job id comes back in the next header.
        let clone = try run(["server", "db", "clone-for-local", "web", "--target", "web_dev", "--wait"],
                            answers: [("clone job ab12: web → web_dev", "202 0 ab12"), ("[10%] prepare", "200 124 1"), ("clone ab12: success", "200 0 3")])
        #expect(clone.code == 0 && clone.curlCalls.count == 3 && clone.curlCalls[0].contains("target=web_dev"))
        #expect(clone.curlCalls[1].last == base + "clone-status" && clone.curlCalls[1].contains("id=ab12") && clone.curlCalls[2].contains("since=1"))
        let pg = try #require(try run(["server", "pg", "clone", "prod", "web", "web_copy", "--project", "web"], answers: [("job", "202 0 j1")]).curlCalls.first)
        #expect(pg.last == base + "pg-clone" && pg.contains("database=web") && pg.contains("target=web_copy") && pg.contains("project=web"))
        #expect(try run(["server", "pg", "grant", "prod", "bob"]).code == 2)
        #expect(try run(["server", "pg", "user-add", "prod", "bob", "web"], answers: [("ok", "200 0")]).curlCalls.first?.contains("username=bob") == true)

        // git, diagnose, cancel, pull-deploy
        let push = try #require(try run(["server", "git", "push", "web"], answers: [("pushed", "200 0")]).curlCalls.first)
        #expect(push.last == base + "git-push")
        let switched = try #require(try run(["server", "git", "switch", "web", "develop"], answers: [("ok", "200 0")]).curlCalls.first)
        #expect(switched.last == base + "switch-branch" && switched.contains("branch=develop"))
        #expect(try run(["server", "git", "switch", "web"]).code == 2)
        #expect(try run(["server", "diagnose", "fix", "web", "fix_network"], answers: [("ok", "200 0")]).curlCalls.first?.last == base + "diagnose-fix")
        #expect(try run(["server", "diagnose", "web"], answers: [("ok", "200 0")]).curlCalls.first?.contains("-G") == true)
        #expect(try run(["server", "deploy-cancel", "abc"]).code == 2)
        let pull = try run(["server", "pull-deploy", "web", "--wait"], answers: [("302", "200 0"), ("deploy #302: success", "200 0 5:success")])
        #expect(pull.code == 0 && pull.curlCalls.count == 2 && pull.curlCalls[1].contains("id=302"))

        // domain set: tri-state flags; cloudflare subcommands
        let dset = try #require(try run(["server", "domain", "set", "api.example.com", "--port", "8081", "--no-websocket"], answers: [("ok", "200 0")]).curlCalls.first)
        #expect(dset.last == base + "domain-set" && dset.contains("port=8081") && dset.contains("websocket=0") && dset.contains("ssl="))
        #expect(try run(["server", "cloudflare", "purge", "example.com"], answers: [("ok", "200 0")]).curlCalls.first?.last == base + "zone-purge")
        #expect(try run(["server", "cloudflare", "ssl", "example.com"], answers: [("ok", "200 0")]).curlCalls.first?.contains("-G") == true)
        #expect(try run(["server", "cloudflare", "frob", "example.com"]).code == 2)
        #expect(try run(["server", "cloudflare"], answers: [("ok", "200 0")]).curlCalls.first?.last == base + "cloudflare")
    }

    // MARK: new options, presets, queue, wait --all|--any

    @Test func newSendsItsOptions() throws {
        let new = try run(["new", "--project", "web", "--permission-mode", "dontAsk", "--allow", "Bash(git *)", "--allow=Edit",
                           "--model", "opus", "--effort=high", "--skill", "/review", "--queue", "--prompt", "the cart"],
                          answers: [("SID", "200 0")])
        #expect(new.code == 0 && new.out == "SID\n")
        let call = try #require(new.curlCalls.first)
        #expect(call.contains("permission_mode=dontAsk") && call.contains("allow=Bash(git *)\nEdit"))
        #expect(call.contains("model=opus") && call.contains("effort=high") && call.contains("skill=review") && call.contains("queue=1"))
        #expect(call.contains("prompt=the cart") && call.last == "http://127.0.0.1:47832/v1/cli/projects/web/sessions")
        // Without them: empty values, as before.
        let plain = try #require(try run(["new"], answers: [("SID", "200 0")]).curlCalls.first)
        #expect(plain.contains("permission_mode=") && plain.contains("allow=") && plain.contains("queue=0"))

        // Checked before anything is sent.
        for args in [["new", "--permission-mode", "yolo"], ["new", "--effort", "extreme"], ["new", "--skill", "a/b"],
                     ["new", "--allow"], ["new", "--allow", ""], ["new", "--model"]] {
            let bad = try run(args)
            #expect(bad.code == 2 && bad.curlCalls.isEmpty, "\(args)")
        }
        let off = try run(["new", "--permission-mode", "bypassPermissions"], answers: [(#"{"error":"bypass_off"}"#, "403 4")])
        #expect(off.code == 4 && off.err.contains("bypass_off") && off.err.contains("Settings"))
        // Queued: the queue id is the answer.
        let queued = try run(["new", "--queue"], answers: [("q_0123456789ab", "200 0")])
        #expect(queued.code == 0 && queued.out == "q_0123456789ab\n")
    }

    @Test func presetCommands() throws {
        let set = try run(["preset", "set", "./app", "--permission-mode", "acceptEdits", "--allow", "Bash(swift test *)", "--json"],
                          answers: [("{}", "200 0")], cwd: URL(fileURLWithPath: "/tmp"))
        let call = try #require(set.curlCalls.first)
        #expect(set.code == 0 && call.contains("permission_mode=acceptEdits") && call.contains("allow=Bash(swift test *)"))
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/projects/%2Fprivate%2Ftmp%2Fapp/preset" && !call.contains("-G"))
        let show = try #require(try run(["preset", "show", "self"], answers: [("web: model opus", "200 0")]).curlCalls.first)
        #expect(show.contains("-G") && show.last == "http://127.0.0.1:47832/v1/cli/projects/self/preset")
        #expect(try run(["preset"], answers: [("no presets", "200 0")]).curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/presets")
        let clear = try #require(try run(["preset", "clear", "web"], answers: [("web: no preset", "200 0")]).curlCalls.first)
        #expect(clear.contains("clear=1"))
        #expect(try run(["preset", "set", "web"]).code == 2) // nothing to set
        #expect(try run(["preset", "set"]).code == 2)
        #expect(try run(["preset", "show", "web", "--model", "opus"]).code == 2)
        #expect(try run(["preset", "frob"]).code == 2)
    }

    @Test func queueCommands() throws {
        #expect(try run(["queue"], answers: [("the queue is empty", "200 0")]).curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/queue")
        let show = try run(["queue", "show", "q_0123456789ab"], answers: [("SID", "200 0")])
        #expect(show.out == "SID\n" && show.curlCalls.first?.last == "http://127.0.0.1:47832/v1/cli/queue/q_0123456789ab")
        let cancel = try #require(try run(["queue", "cancel", "q_0123456789ab"], answers: [("cancelled", "200 0")]).curlCalls.first)
        #expect(!cancel.contains("-G") && cancel.last == "http://127.0.0.1:47832/v1/cli/queue/q_0123456789ab/cancel")
        let theirs = try run(["queue", "cancel", "q_0123456789ab"], answers: [(#"{"error":"not_yours"}"#, "403 4")])
        #expect(theirs.code == 4)
        #expect(try run(["queue", "show"]).code == 2)
        #expect(try run(["queue", "show", "q_../x"]).code == 2)
        #expect(try run(["queue", "drop", "q_1"]).code == 2)
    }

    @Test func waitForSeveral() throws {
        let all = try run(["wait", "--all", "abcd1234", "q_0123456789ab", "--timeout", "60"],
                          answers: [("timeout", "200 124"), ("abcd1234: finished (exit 0)", "200 0")])
        #expect(all.code == 0 && all.curlCalls.count == 2)
        let call = all.curlCalls[0]
        #expect(call.contains("ids=abcd1234,q_0123456789ab") && call.contains("mode=all") && call.contains("timeout=25"))
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/wait")
        let any = try run(["wait", "--any", "abcd", "ef01"], answers: [("ef01: blocked: needs permission", "200 3")])
        #expect(any.code == 3 && any.curlCalls.first?.contains("mode=any") == true)
        // A queue id on its own goes to the single wait.
        #expect(try run(["wait", "q_0123456789ab"], answers: [("finished", "200 0")]).curlCalls.first?.last
            == "http://127.0.0.1:47832/v1/cli/sessions/q_0123456789ab/wait")
        #expect(try run(["wait", "abcd", "ef01"]).code == 2) // several without --all/--any
        #expect(try run(["wait", "--all"]).code == 2)
        #expect(try run(["wait", "--all", "--any", "abcd"]).code == 2)
        #expect(try run(["wait", "--any", "abcd", "x/y"]).code == 2)
    }

    // MARK: Decisions in the script

    @Test func decideArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/decisions"
        let asked = try run(["decide", "Which DB?", "--options", "Redis,SQLite", "--recommend", "Redis", "--context", "why", "--project", "shop"],
                            answers: [("d_0123456789", "200 0")])
        #expect(asked.code == 0 && asked.out == "d_0123456789\n")
        let call = try #require(asked.curlCalls.first)
        #expect(call.last == base && !call.contains("-G"))
        #expect(call.contains("question=Which DB?") && call.contains("options=Redis,SQLite") && call.contains("recommend=Redis"))
        #expect(call.contains("context=why") && call.contains("project=shop") && call.contains("format=text"))
        // Options before the question, --json, a question after --.
        let json = try run(["decide", "--json", "--options=A,B", "--", "-starts with a dash"], answers: [("{}", "200 0")])
        #expect(json.curlCalls.first?.contains("question=-starts with a dash") == true && json.curlCalls.first?.contains("format=json") == true)
        #expect(try run(["decide"]).code == 2)
        #expect(try run(["decide", "a", "b"]).code == 2)
        #expect(try run(["decide", "q", "--bogus"]).code == 2)
        #expect(try run(["decide", "q"], session: false).code == 2)
        let bad = try run(["decide", "q", "--options", "A,B", "--recommend", "C"], answers: [(#"{"error":"bad_recommend"}"#, "400 2")])
        #expect(bad.code == 2 && bad.err.contains("--recommend"))
        let limited = try run(["decide", "q"], answers: [(#"{"error":"too_many"}"#, "429 4")])
        #expect(limited.code == 4)

        let get = try run(["decision", "get", "d_0123456789"], answers: [("answered: Redis", "200 0")])
        #expect(get.code == 0 && get.out == "answered: Redis\n")
        #expect(get.curlCalls.first?.last == base + "/d_0123456789" && get.curlCalls.first?.contains("-G") == true)
        #expect(try run(["decision", "get", "1234"]).curlCalls.isEmpty)
        #expect(try run(["decision", "get", "d_../x"]).code == 2)
        #expect(try run(["decision", "get"]).code == 2)
        #expect(try run(["decision", "show", "d_1"]).code == 2)
        #expect(try run(["decision", "get", "d_404"], answers: [(#"{"error":"unknown_decision"}"#, "404 5")]).code == 5)

        let list = try run(["decisions", "--pending"], answers: [("ID  STATUS", "200 0")])
        #expect(list.curlCalls.first?.last == base && list.curlCalls.first?.contains("pending=1") == true)
        #expect(try run(["decisions", "--all"]).code == 2)
        #expect(SessionCLI.skill.contains("claudedeck decide") && SessionCLI.skill.contains("keep working"))
    }

    @Test func decisionCancelAndSupersedes() throws {
        let base = "http://127.0.0.1:47832/v1/cli/decisions"
        let cancelled = try run(["decision", "cancel", "d_0123456789", "--reason", "artık gerekmiyor"],
                                answers: [("cancelled d_0123456789", "200 0")])
        #expect(cancelled.code == 0 && cancelled.out == "cancelled d_0123456789\n")
        let call = try #require(cancelled.curlCalls.first)
        #expect(call.last == base + "/d_0123456789/cancel" && !call.contains("-G"))
        #expect(call.contains("reason=artık gerekmiyor") && call.contains("format=text"))
        let json = try run(["decision", "cancel", "--json", "--reason=x", "d_0123456789"], answers: [("{}", "200 0")])
        #expect(json.curlCalls.first?.contains("format=json") == true && json.curlCalls.first?.contains("reason=x") == true)
        // Usage errors never reach the API.
        #expect(try run(["decision", "cancel"]).code == 2)
        #expect(try run(["decision", "cancel", "1234"]).curlCalls.isEmpty)
        #expect(try run(["decision", "cancel", "d_1", "d_2"]).code == 2)
        #expect(try run(["decision", "cancel", "d_1", "--reason"]).code == 2)
        #expect(try run(["decision", "get", "d_1", "--reason", "x"]).code == 2)
        // Refusals: whose it is, already answered, unknown.
        let notYours = try run(["decision", "cancel", "d_1"], answers: [(#"{"error":"not_yours"}"#, "403 4")])
        #expect(notYours.code == 4 && notYours.err.contains("only the session that asked it"))
        let answered = try run(["decision", "cancel", "d_1"], answers: [(#"{"error":"already_answered"}"#, "409 4")])
        #expect(answered.code == 4 && answered.err.contains("already_answered") && answered.err.contains("answered it already"))
        #expect(try run(["decision", "cancel", "d_1"], answers: [(#"{"error":"unknown_decision"}"#, "404 5")]).code == 5)

        // --supersedes goes with the question; a bad id never reaches the API.
        let replaced = try run(["decide", "Hangi veritabanı?", "--supersedes", "d_0123456789"], answers: [("d_abcdefabcd", "200 0")])
        #expect(replaced.code == 0 && replaced.out == "d_abcdefabcd\n" && replaced.err.isEmpty)
        #expect(replaced.curlCalls.first?.contains("supersedes=d_0123456789") == true)
        #expect(try run(["decide", "q", "--supersedes", "nope"]).curlCalls.isEmpty)
        #expect(try run(["decide", "q", "--supersedes"]).code == 2)
        let refused = try run(["decide", "q", "--supersedes=d_1"], answers: [(#"{"error":"already_answered"}"#, "409 4")])
        #expect(refused.code == 4 && refused.out.isEmpty)
    }

    @Test func decideNotes() throws {
        // The same question waiting: its id on stdout, a note on stderr, exit 0.
        let duplicate = try run(["decide", "Hangi veritabanı?"], answers: [("d_0123456789", "200 e=0 n= m=already_pending:d_0123456789")])
        #expect(duplicate.code == 0 && duplicate.out == "d_0123456789\n")
        #expect(duplicate.err == "decide: already pending as d_0123456789\n")
        // Not Turkish: asked anyway, with a warning.
        let english = try run(["decide", "Which DB?"], answers: [("d_0123456780", "200 e=0 n= m=not_turkish")])
        #expect(english.code == 0 && english.out == "d_0123456780\n")
        #expect(english.err == "decide: owner-facing text should be Turkish (soru Türkçe olmalı)\n")
        let both = try run(["decide", "Which DB?", "--json"], answers: [("{}", "200 e=0 n= m=already_pending:d_0123456789,not_turkish")])
        #expect(both.code == 0 && both.err.contains("already pending as d_0123456789\n") && both.err.contains("should be Turkish"))
        // No note: nothing on stderr. The older status line (no prefixes) still reads.
        let plain = try run(["decide", "Hangi?"], answers: [("d_0123456781", "200 e=0 n= m=")])
        #expect(plain.code == 0 && plain.err.isEmpty)
        let older = try run(["decide", "Hangi?"], answers: [("d_0123456782", "200 0")])
        #expect(older.code == 0 && older.err.isEmpty)
        // A real curl's -w line carries the prefixes: a missing exit header still falls back by HTTP status.
        let noExit = try run(["decision", "get", "d_1"], answers: [(#"{"error":"x"}"#, "404 e= n= m=")])
        #expect(noExit.code == 4)
        #expect(SessionCLI.skill.contains("--supersedes") && SessionCLI.skill.contains("decision cancel") && SessionCLI.skill.contains("Turkish"))
    }

    // MARK: Closing

    @Test func closeRouteAndScope() throws {
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/self/close") == .route(.close("self")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/q_0123456789/close") == .route(.close("q_0123456789")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/abcd/close") == .methodNotAllowed)
        #expect(SessionCLI.Route.close("x").scope == .close)
        #expect(SessionCLI.fullScopes.contains(.close) && !SessionCLI.openedScopes.contains(.close))
        var book = SessionCLIBook()
        let claude = UUID(), opened = UUID()
        let claudeToken = book.token(for: claude, scopes: SessionCLI.scopes(openedBy: nil))
        let openedToken = book.token(for: opened, scopes: SessionCLI.scopes(openedBy: claude))
        func refusal(_ token: String) -> AgentHTTPResponse? {
            if case .failure(let refusal) = SessionCLI.resolve(request("POST", "/v1/cli/sessions/self/close", token: token), book: book) { return refusal.response }
            return nil
        }
        #expect(refusal(claudeToken) == nil)
        // A terminal another session opened may not close anything, itself included.
        let refused = try #require(refusal(openedToken))
        #expect(refused.status == 403 && refused.headers[SessionCLI.exitHeader] == "4")
    }

    @Test func closeOnlyItselfAndWhatItStarted() {
        let me = UUID(), child = UUID(), grandchild = UUID(), sibling = UUID(), parent = UUID(), owners = UUID()
        // I started child, child started grandchild; parent started me and sibling; nobody started owners.
        let startedBy = [child: me, grandchild: child, sibling: parent, me: parent]
        #expect(SessionCLI.mayClose(caller: me, target: me, startedBy: startedBy))
        #expect(SessionCLI.mayClose(caller: me, target: child, startedBy: startedBy))
        #expect(SessionCLI.mayClose(caller: me, target: grandchild, startedBy: startedBy))
        #expect(!SessionCLI.mayClose(caller: me, target: sibling, startedBy: startedBy))
        #expect(!SessionCLI.mayClose(caller: me, target: parent, startedBy: startedBy)) // the one that started me
        #expect(!SessionCLI.mayClose(caller: me, target: owners, startedBy: startedBy)) // the owner's
        #expect(!SessionCLI.mayClose(caller: child, target: me, startedBy: startedBy))
        #expect(SessionCLI.mayClose(caller: parent, target: grandchild, startedBy: startedBy))
        // A loop in a broken deck ends.
        let a = UUID(), b = UUID()
        #expect(!SessionCLI.mayClose(caller: me, target: a, startedBy: [a: b, b: a]))
    }

    @Test func closeSettingAndAnswer() throws {
        #expect(!DeckSettings().sessionsMayCloseSessions)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"sessionCLIEnabled":true,"sessionsMayStartSessions":true}"#.utf8))
        #expect(old.sessionsMayStartSessions && !old.sessionsMayCloseSessions)
        var on = DeckSettings()
        on.sessionsMayCloseSessions = true
        #expect(try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(on)).sessionsMayCloseSessions)
        let id = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        let data = try JSONEncoder().encode(SessionCLIClosed(closed: true, id: id, forced: false))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["closed"] as? Bool == true && object["forced"] as? Bool == false && object["id"] as? String == id.uuidString)
        #expect(object.count == 3)
        let pending = try JSONEncoder().encode(SessionCLIClosed(closed: false, id: id, forced: false, pending: true))
        #expect(String(decoding: pending, as: UTF8.self).contains(#""pending":true"#))
        #expect(SessionCLI.closeGrace == 15)
    }

    @Test func closeArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/sessions/"
        let closed = try run(["close", "d1234567"], answers: [("closed", "200 0")])
        #expect(closed.code == 0 && closed.out == "closed\n")
        let call = try #require(closed.curlCalls.first)
        #expect(call.last == base + "d1234567/close" && !call.contains("-G"))
        #expect(call.contains("force=0") && call.contains("format=text") && call.contains("60"))
        let forced = try run(["close", "--force", "self", "--json"], answers: [(#"{"closed":false,"pending":true}"#, "200 0")])
        #expect(forced.curlCalls.first?.contains("force=1") == true && forced.curlCalls.first?.contains("format=json") == true)
        #expect(forced.curlCalls.first?.last == base + "self/close")
        #expect(try run(["close", "q_0123456789"], answers: [("closed", "200 0")]).curlCalls.first?.last == base + "q_0123456789/close")
        // Usage: nothing reaches the API.
        for args in [["close"], ["close", "a", "b"], ["close", "a/../b"], ["close", "abcd", "--bogus"]] {
            let usage = try run(args)
            #expect(usage.code == 2 && usage.curlCalls.isEmpty, "\(args)")
        }
        #expect(try run(["close", "abcd"], session: false).code == 2)
        // The API's refusals, with hints.
        let off = try run(["close", "abcd"], answers: [(#"{"error":"close_off"}"#, "403 4")])
        #expect(off.code == 4 && off.err.contains("Sessions may close sessions they started"))
        let mine = try run(["close", "abcd"], answers: [(#"{"error":"not_yours"}"#, "403 4")])
        #expect(mine.code == 4 && mine.err.contains("sessions it started"))
        #expect(try run(["close", "abcd"], answers: [(#"{"error":"unknown_session"}"#, "404 5")]).code == 5)
        let busy = try run(["close", "abcd"], answers: [(#"{"error":"busy"}"#, "409 1")])
        #expect(busy.code == 1 && busy.err.contains("--force"))
        #expect(try run(["close", "abcd"], answers: [(#"{"error":"blocked"}"#, "409 3")]).code == 3)
        let slow = try run(["close", "abcd"], answers: [(#"{"error":"still_running"}"#, "409 124")])
        #expect(slow.code == 124 && slow.err.contains("--force"))
        #expect(try run(["help"]).out.contains("claudedeck close ID|self"))
        #expect(SessionCLI.skill.contains("claudedeck close") && SessionCLI.skill.contains("close_off"))
    }

    // MARK: Removing

    @Test func removeRouteAndScope() {
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/abcd/remove") == .route(.remove("abcd")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/q_0123456789/remove") == .route(.remove("q_0123456789")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/abcd/remove") == .methodNotAllowed)
        #expect(SessionCLI.Route.remove("x").scope == .close)
        #expect(!SessionCLI.openedScopes.contains(SessionCLI.Route.remove("x").scope))
    }

    @Test func removeOwnershipRules() {
        let me = UUID(), child = UUID(), grandchild = UUID(), sibling = UUID(), parent = UUID(), owners = UUID()
        let startedBy = [child: me, grandchild: child, sibling: parent, me: parent]
        // Only stopped sessions of its own.
        #expect(SessionCLI.mayRemove(caller: me, target: child, startedBy: startedBy, running: false) == .allowed)
        #expect(SessionCLI.mayRemove(caller: me, target: grandchild, startedBy: startedBy, running: false) == .allowed)
        #expect(SessionCLI.mayRemove(caller: me, target: child, startedBy: startedBy, running: true) == .stillRunning)
        // Itself is always running while it asks.
        #expect(SessionCLI.mayRemove(caller: me, target: me, startedBy: startedBy, running: true) == .stillRunning)
        // Never the owner's, a sibling's, or the one that started it; ownership is checked first.
        #expect(SessionCLI.mayRemove(caller: me, target: owners, startedBy: startedBy, running: false) == .notYours)
        #expect(SessionCLI.mayRemove(caller: me, target: owners, startedBy: startedBy, running: true) == .notYours)
        #expect(SessionCLI.mayRemove(caller: me, target: sibling, startedBy: startedBy, running: false) == .notYours)
        #expect(SessionCLI.mayRemove(caller: me, target: parent, startedBy: startedBy, running: false) == .notYours)
        #expect(SessionCLI.mayRemove(caller: child, target: me, startedBy: startedBy, running: false) == .notYours)
    }

    @Test func removeAfterCloseFlagsAndSetting() {
        #expect(SessionCLI.removesAfterClose(form: [:], setting: true))
        #expect(!SessionCLI.removesAfterClose(form: [:], setting: false))
        #expect(!SessionCLI.removesAfterClose(form: ["keep": "1"], setting: true))
        #expect(SessionCLI.removesAfterClose(form: ["remove": "1"], setting: false))
        #expect(SessionCLI.removesAfterClose(form: ["remove": "1", "keep": "1"], setting: false))
        #expect(SessionCLI.removesAfterClose(form: ["remove": "0", "keep": "0"], setting: true))
    }

    @Test func removeSettingDefaultsOnAndDecodes() throws {
        #expect(DeckSettings().removeClosedSessions)
        // A settings file from before the setting: on (the owner's request).
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"sessionsMayCloseSessions":true}"#.utf8))
        #expect(old.sessionsMayCloseSessions && old.removeClosedSessions)
        var off = DeckSettings()
        off.removeClosedSessions = false
        #expect(try !JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(off)).removeClosedSessions)
        let explicit = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"removeClosedSessions":false}"#.utf8))
        #expect(!explicit.removeClosedSessions)
    }

    @Test func removeAnswers() throws {
        let id = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!
        let closed = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SessionCLIClosed(closed: true, id: id, forced: false, removed: true))) as? [String: Any])
        #expect(closed["removed"] as? Bool == true && closed.count == 4)
        let kept = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SessionCLIClosed(closed: true, id: id, forced: false))) as? [String: Any])
        #expect(kept["removed"] == nil)
        let removed = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SessionCLIRemoved(removed: true, id: id))) as? [String: Any])
        #expect(removed["removed"] as? Bool == true && removed["id"] as? String == id.uuidString && removed.count == 2)
    }

    @Test func removedSessionHandsOverWhatItStarted() {
        var deck = DeckData()
        let project = UUID()
        let a = DeckSession(projectID: project, name: "a")
        var b = DeckSession(projectID: project, name: "b")
        var c = DeckSession(projectID: project, name: "c")
        let owners = DeckSession(projectID: project, name: "owner's")
        var d = DeckSession(projectID: project, name: "d")
        b.startedBy = a.id
        c.startedBy = b.id
        d.startedBy = owners.id
        deck.sessions = [a, b, c, owners, d]
        // Removing b: c now counts as a's, so a can still close it.
        deck.handOverStartedSessions(of: b.id)
        deck.removeSession(b.id)
        #expect(deck.session(c.id)?.startedBy == a.id)
        let starters = Dictionary(uniqueKeysWithValues: deck.sessions.compactMap { s in s.startedBy.map { (s.id, $0) } })
        #expect(SessionCLI.mayClose(caller: a.id, target: c.id, startedBy: starters))
        // Removing the owner's session: what it started never becomes the owner's own.
        deck.handOverStartedSessions(of: owners.id)
        deck.removeSession(owners.id)
        #expect(deck.session(d.id)?.startedBy == owners.id)
    }

    @Test func removeArguments() throws {
        let base = "http://127.0.0.1:47832/v1/cli/sessions/"
        // close: --remove / --keep reach the API; neither: the setting decides there.
        let plain = try run(["close", "abcd"], answers: [("closed and removed", "200 0")])
        #expect(plain.code == 0 && plain.out == "closed and removed\n")
        let plainCall = try #require(plain.curlCalls.first)
        #expect(!plainCall.contains("remove=1") && !plainCall.contains("keep=1"))
        let remove = try #require(try run(["close", "abcd", "--remove"], answers: [("closed and removed", "200 0")]).curlCalls.first)
        #expect(remove.contains("remove=1") && !remove.contains("keep=1") && remove.last == base + "abcd/close")
        let keep = try #require(try run(["close", "--keep", "abcd", "--json"], answers: [(#"{"closed":true}"#, "200 0")]).curlCalls.first)
        #expect(keep.contains("keep=1") && !keep.contains("remove=1") && keep.contains("format=json") && keep.contains("force=0"))
        let selfRemove = try #require(try run(["close", "self", "--remove", "--force"], answers: [("closing (then removed)", "200 0")]).curlCalls.first)
        #expect(selfRemove.contains("remove=1") && selfRemove.contains("force=1") && selfRemove.last == base + "self/close")
        let both = try run(["close", "abcd", "--remove", "--keep"])
        #expect(both.code == 2 && both.curlCalls.isEmpty && both.err.contains("not both"))
        // remove
        let removed = try run(["remove", "d1234567"], answers: [("removed", "200 0")])
        #expect(removed.code == 0 && removed.out == "removed\n")
        let call = try #require(removed.curlCalls.first)
        #expect(call.last == base + "d1234567/remove" && call.contains("format=text") && !call.contains("-G"))
        #expect(try run(["remove", "q_0123456789", "--json"], answers: [(#"{"removed":true}"#, "200 0")]).curlCalls.first?.contains("format=json") == true)
        for args in [["remove"], ["remove", "a", "b"], ["remove", "a/../b"], ["remove", "abcd", "--force"]] {
            let usage = try run(args)
            #expect(usage.code == 2 && usage.curlCalls.isEmpty, "\(args)")
        }
        #expect(try run(["remove", "abcd"], session: false).code == 2)
        let running = try run(["remove", "abcd"], answers: [(#"{"error":"still_running"}"#, "409 1")])
        #expect(running.code == 1 && running.err.contains("claudedeck close ID --remove"))
        let mine = try run(["remove", "abcd"], answers: [(#"{"error":"not_yours"}"#, "403 4")])
        #expect(mine.code == 4 && mine.err.contains("sessions it started"))
        let off = try run(["remove", "abcd"], answers: [(#"{"error":"close_off"}"#, "403 4")])
        #expect(off.code == 4 && off.err.contains("Sessions may close sessions they started"))
        #expect(try run(["remove", "abcd"], answers: [(#"{"error":"unknown_session"}"#, "404 5")]).code == 5)
        // close's own still_running hint is unchanged.
        #expect(try run(["close", "abcd"], answers: [(#"{"error":"still_running"}"#, "409 124")]).err.contains("close --force"))
        let help = try run(["help"]).out
        #expect(help.contains("claudedeck remove ID") && help.contains("--remove|--keep"))
        #expect(SessionCLI.skill.contains("claudedeck remove ID") && SessionCLI.skill.contains("merged and handed off"))
    }
}
