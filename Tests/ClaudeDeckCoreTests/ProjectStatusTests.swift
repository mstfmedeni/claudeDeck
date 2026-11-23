import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck project status`: the write rule, the limits, staleness, deck.json, the remote
/// snapshot and the script's arguments (against a stand-in curl).
@Suite struct ProjectStatusTests {
    // MARK: Rules

    @Test func onlyItsOwnProjectUnlessCoordinator() {
        let mine = UUID(), other = UUID()
        #expect(ProjectStatus.mayWrite(callerProject: mine, target: mine, callerIsCoordinator: false))
        #expect(!ProjectStatus.mayWrite(callerProject: mine, target: other, callerIsCoordinator: false))
        #expect(ProjectStatus.mayWrite(callerProject: mine, target: other, callerIsCoordinator: true))
        #expect(!ProjectStatus.mayWrite(callerProject: nil, target: other, callerIsCoordinator: false))
    }

    @Test func limitsAndCleanup() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let made = try ProjectStatus.make(text: "  1.0 \n in   review ", summary: "\n Done: build 12.\nNext: notes.\n ",
                                          tone: "WAIT", by: "lead", now: now).get()
        #expect(made == ProjectStatus(text: "1.0 in review", summary: "Done: build 12.\nNext: notes.", tone: .wait, updatedAt: now, updatedBy: "lead"))
        // Empty summary and tone: none.
        let plain = try ProjectStatus.make(text: "Design", summary: "  ", tone: "", by: nil).get()
        #expect(plain.summary == nil && plain.tone == nil)
        #expect(ProjectStatus.make(text: " \n ", summary: nil, tone: nil, by: nil) == .failure(.emptyText))
        #expect(ProjectStatus.make(text: String(repeating: "a", count: 80), summary: nil, tone: nil, by: nil).isSuccess)
        #expect(ProjectStatus.make(text: String(repeating: "a", count: 81), summary: nil, tone: nil, by: nil) == .failure(.textTooLong))
        #expect(ProjectStatus.make(text: "x", summary: String(repeating: "ş", count: 600), tone: nil, by: nil).isSuccess)
        #expect(ProjectStatus.make(text: "x", summary: String(repeating: "ş", count: 601), tone: nil, by: nil) == .failure(.summaryTooLong))
        #expect(ProjectStatus.make(text: "x", summary: nil, tone: "green", by: nil) == .failure(.badTone))
        // The refusals the command shows.
        let refusal = SessionCLI.projectStatusRefusal(.textTooLong)
        #expect(refusal.status == 400 && refusal.headers[SessionCLI.exitHeader] == "2")
        #expect(String(decoding: refusal.body, as: UTF8.self).contains(#""error":"text_too_long""#))
        #expect(SessionCLI.notYourProject.status == 403 && SessionCLI.notYourProject.headers[SessionCLI.exitHeader] == "4")
    }

    @Test func displayTruncation() {
        #expect(ProjectStatus.displayText("Yayında · 22 Kas") == "Yayında · 22 Kas")
        #expect(ProjectStatus.displayText(String(repeating: "a", count: 24)) == String(repeating: "a", count: 24))
        let cut = ProjectStatus.displayText("1.0.1 bekliyor (PPO) ve TestFlight")
        #expect(cut.count == 24 && cut.hasSuffix("…") && cut.hasPrefix("1.0.1 bekliyor (PPO) ve"))
        // No space left before the ellipsis.
        #expect(ProjectStatus.displayText("abcdefghijklmnopqrstuvw xyz") == "abcdefghijklmnopqrstuvw…")
        #expect(ProjectStatus.displayText("abcdefghijklmnopqrstuv xyz") == "abcdefghijklmnopqrstuv…")
    }

    @Test func staleAfterAWeek() {
        let now = Date()
        #expect(!ProjectStatus(text: "x", updatedAt: now.addingTimeInterval(-6 * 86_400)).isStale(now: now))
        #expect(ProjectStatus(text: "x", updatedAt: now.addingTimeInterval(-7 * 86_400 - 1)).isStale(now: now))
        let info = SessionCLIProjectStatus(project: {
            var p = Project(path: "/tmp/app")
            p.status = ProjectStatus(text: "Design", updatedAt: now.addingTimeInterval(-8 * 86_400))
            return p
        }(), now: now)
        #expect(info.stale && SessionCLI.projectStatusText(info).contains("(stale)"))
    }

    // MARK: Persistence

    @Test func oldDeckFilesDecodeAndNewOnesRoundTrip() throws {
        let old = #"{"id":"5A1B2C3D-0000-4000-8000-000000000001","path":"/tmp/app","name":"app","pinned":false,"collapsed":false}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        #expect(project.status == nil && project.coordinator == nil && !project.isCoordinator)

        var withStatus = project
        withStatus.status = ProjectStatus(text: "1.0 incelemede", summary: "Son: gönderildi", tone: .wait,
                                          updatedAt: Date(timeIntervalSince1970: 1_800_000_000), updatedBy: "lead")
        withStatus.isCoordinator = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Project.self, from: encoder.encode(withStatus))
        #expect(back == withStatus)
        // Off is not stored.
        withStatus.isCoordinator = false
        #expect(withStatus.coordinator == nil)

        // A tone a newer version writes, or a broken status, never breaks the deck.
        let odd = #"{"id":"5A1B2C3D-0000-4000-8000-000000000001","path":"/tmp/app","name":"app","pinned":false,"collapsed":false,"status":{"text":"x","tone":"purple","updatedAt":12}}"#
        let oddProject = try JSONDecoder().decode(Project.self, from: Data(odd.utf8))
        #expect(oddProject.status?.text == "x" && oddProject.status?.tone == nil)

        // The whole deck.
        var deck = DeckData()
        deck.projects = [withStatus]
        let data = try encoder.encode(deck)
        #expect(try decoder.decode(DeckData.self, from: data).projects.first?.status?.text == "1.0 incelemede")
    }

    @Test func remoteSnapshotCarriesItOptionally() throws {
        let id = UUID()
        let status = ProjectStatus(text: "Live", tone: .ok, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), updatedBy: "lead")
        let project = RemoteProject(id: id, name: "app", pinned: true, path: "/tmp/app", status: status)
        let back = try JSONDecoder().decode(RemoteProject.self, from: JSONEncoder().encode(project))
        #expect(back.status == status)
        // From an older host: no status.
        let old = #"{"id":"\#(id.uuidString)","name":"app"}"#
        #expect(try JSONDecoder().decode(RemoteProject.self, from: Data(old.utf8)).status == nil)
        // An older phone's decoder skips the unknown key; the plain project encodes without it.
        #expect(!String(decoding: try JSONEncoder().encode(RemoteProject(id: id, name: "app")), as: UTF8.self).contains("status"))
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.projectStatus))
    }

    // MARK: Routes and scopes

    @Test func routesAndScopes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/project-status") == .route(.projectStatuses))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/project-status") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects/self/status") == .route(.showProjectStatus("self")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/%2Ftmp%2Fapp/status") == .route(.setProjectStatus("/tmp/app")))
        #expect(SessionCLI.match(method: "DELETE", path: "/v1/cli/projects/app/status") == .methodNotAllowed)
        // The routes next to it are unchanged.
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects/app/preset") == .route(.showPreset("app")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects") == .route(.projects))
        // Reading is for everyone with the CLI; writing is a Claude session's, not a terminal it opened.
        #expect(SessionCLI.Route.projectStatuses.scope == .list && SessionCLI.Route.showProjectStatus("x").scope == .list)
        #expect(SessionCLI.Route.setProjectStatus("x").scope == .projectStatus)
        #expect(SessionCLI.fullScopes.contains(.projectStatus) && !SessionCLI.openedScopes.contains(.projectStatus))
        #expect(SessionCLI.openedScopes.contains(.list))

        var book = SessionCLIBook()
        let opened = book.token(for: UUID(), scopes: SessionCLI.scopes(openedBy: UUID()))
        let claude = book.token(for: UUID(), scopes: SessionCLI.scopes(openedBy: nil))
        func status(_ method: String, _ path: String, _ token: String) -> Int {
            let request = AgentHTTPRequest(method: method, path: path, query: [:], headers: ["authorization": "Bearer \(token)"], body: Data())
            switch SessionCLI.resolve(request, book: book) {
            case .failure(let refusal): return refusal.response.status
            case .success: return 200
            }
        }
        #expect(status("POST", "/v1/cli/projects/self/status", claude) == 200)
        #expect(status("POST", "/v1/cli/projects/self/status", opened) == 403)
        #expect(status("GET", "/v1/cli/projects/self/status", opened) == 200)
        #expect(status("GET", "/v1/cli/project-status", opened) == 200)
    }

    @Test func textAnswers() {
        var project = Project(path: "/tmp/app", name: "app")
        #expect(SessionCLI.projectStatusText(SessionCLIProjectStatus(project: project)) == "app: no status")
        project.status = ProjectStatus(text: "1.0 in review", summary: "Next: notes", tone: .wait, updatedAt: Date(), updatedBy: "lead")
        let text = SessionCLI.projectStatusText(SessionCLIProjectStatus(project: project))
        #expect(text.hasPrefix("app: 1.0 in review [wait] · ") && text.contains(" by lead") && text.hasSuffix("\nNext: notes"))
        let table = SessionCLI.projectStatusesText([SessionCLIProjectStatus(project: project), SessionCLIProjectStatus(project: Project(path: "/tmp/b"))])
        #expect(table.hasPrefix("ID") && table.contains("1.0 in review") && table.split(separator: "\n").count == 3)
    }

    // MARK: The script

    private struct Run {
        var code: Int32
        var out: String
        var err: String
        var calls: [[String]]
    }

    /// The script against a stand-in curl that answers `answer` (body, "HTTP EXIT").
    private func run(_ args: [String], answer: (body: String, status: String)? = nil, stdin: String? = nil) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudedeck-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claudedeck")
        try Data(SessionCLI.script.utf8).write(to: script)
        if let answer {
            try Data(answer.body.utf8).write(to: dir.appending(path: "body"))
            try Data(answer.status.utf8).write(to: dir.appending(path: "status"))
        }
        let curl = dir.appending(path: "curl")
        try Data(#"""
        #!/bin/sh
        d=$(dirname "$0")
        for a in "$@"; do printf '%s\037' "$a"; done >> "$d/calls"
        printf '\036' >> "$d/calls"
        [ -f "$d/status" ] || { printf '\n000 '; exit 7; }
        cat "$d/body"; printf '\n'; cat "$d/status"
        """#.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + args
        process.environment = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": dir.path, "CLAUDEDECK_CONNECT_RETRIES": "0",
                               "CLAUDEDECK_CLI_TOKEN": "tok-123", "CLAUDEDECK_CLI_URL": "http://127.0.0.1:47832/v1/cli"]
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = (try? String(contentsOf: dir.appending(path: "calls"), encoding: .utf8)) ?? ""
        let calls = raw.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        return Run(code: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self), calls: calls)
    }

    private let base = "http://127.0.0.1:47832/v1/cli"

    @Test func scriptArguments() throws {
        let set = try run(["project", "status", "set", "self", "--text", "1.0 incelemede", "--summary", "Son: gönderildi",
                           "--tone", "wait"], answer: ("app: 1.0 incelemede [wait]", "200 0"))
        #expect(set.code == 0 && set.out == "app: 1.0 incelemede [wait]\n")
        let call = try #require(set.calls.first)
        #expect(call.last == base + "/projects/self/status" && !call.contains("-G"))
        #expect(call.contains("text=1.0 incelemede") && call.contains("summary=Son: gönderildi") && call.contains("tone=wait")
                && call.contains("format=text"))

        // --summary - reads stdin; a path is sent absolute and escaped; --json.
        let piped = try run(["project", "status", "set", "/tmp/my app", "--text=Design", "--summary", "-", "--json"],
                            answer: ("{}", "200 0"), stdin: "line one\nline two\n")
        let pipedCall = try #require(piped.calls.first)
        #expect(pipedCall.contains("summary=line one\nline two") && pipedCall.contains("format=json") && pipedCall.contains("tone="))
        #expect(pipedCall.last == base + "/projects/%2Ftmp%2Fmy%20app/status")

        // get: one project, or all of them.
        let one = try #require(try run(["project", "status", "get", "web"], answer: ("web: no status", "200 0")).calls.first)
        #expect(one.contains("-G") && one.last == base + "/projects/web/status")
        let all = try #require(try run(["project", "status", "get", "--json"], answer: ("[]", "200 0")).calls.first)
        #expect(all.contains("-G") && all.last == base + "/project-status" && all.contains("format=json"))
        #expect(try run(["project", "status"], answer: ("[]", "200 0")).calls.first?.last == base + "/project-status")

        let clear = try #require(try run(["project", "status", "clear", "self"], answer: ("app: no status", "200 0")).calls.first)
        #expect(clear.contains("clear=1") && clear.last == base + "/projects/self/status")

        // Usage errors: exit 2, nothing sent.
        for args in [["project", "status", "set", "self"], ["project", "status", "set", "self", "--text", ""],
                     ["project", "status", "set", "--text", "x"], ["project", "status", "set", "self", "--text", "x", "--tone", "green"],
                     ["project", "status", "clear"], ["project", "status", "get", "a", "b"], ["project", "status", "frob"],
                     ["project", "status", "get", "--text", "x"], ["project", "status", "set", "self", "--text"]] {
            let usage = try run(args)
            #expect(usage.code == 2 && usage.calls.isEmpty, "\(args)")
        }
        // project add still works as before.
        #expect(try run(["project", "add", "/tmp/x"], answer: ("id", "200 0")).calls.first?.last == base + "/projects")
        #expect(try run(["project"]).code == 2)

        // Refusals: the code and the server's message.
        let refused = try run(["project", "status", "set", "other", "--text", "x"],
                              answer: (#"{"error":"not_your_project","message":"a session sets its own project's status"}"#, "403 4"))
        #expect(refused.code == 4 && refused.err.contains("not_your_project") && refused.err.contains("its own project"))
        let long = try run(["project", "status", "set", "self", "--text", "x"],
                           answer: (#"{"error":"text_too_long","message":"--text is at most 80 characters"}"#, "400 2"))
        #expect(long.code == 2 && long.err.contains("at most 80"))
    }

    @Test func helpAndSkill() throws {
        let help = try run(["help"]).out
        #expect(help.contains("claudedeck project status set PROJECT --text TEXT"))
        #expect(help.contains("\n  claudedeck project status get [PROJECT] [--json]\n"))
        #expect(SessionCLI.skill.contains("### Project status (leads)"))
        #expect(SessionCLI.skill.contains("update it at each milestone"))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
