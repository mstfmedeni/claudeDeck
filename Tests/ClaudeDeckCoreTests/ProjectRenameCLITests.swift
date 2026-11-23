import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck project rename` (SessionCLIProjectRename.swift) and ServerPlan's paths following a
/// moved folder (ServerPlanPathRelocation.swift, `server paths relocate`). Never a real panel,
/// never the real deck or folders.
@Suite struct ProjectRenameCLITests {
    // MARK: Scope and route

    @Test func routeAndScope() {
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/WhatsCode/rename") == .route(.renameProject("WhatsCode")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/%2FUsers%2Fme%2FvNum/rename") == .route(.renameProject("/Users/me/vNum")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects/x/rename") == .methodNotAllowed)
        #expect(SessionCLI.Route.renameProject("x").scope == .projectRename)
        // Claude sessions only: not a terminal a session opened, not the owner's plain terminals.
        #expect(SessionCLI.scopes(openedBy: nil).contains(.projectRename))
        #expect(SessionCLI.scopes(openedBy: nil, kind: .claude).contains(.projectRename))
        #expect(!SessionCLI.scopes(openedBy: nil, kind: .shell).contains(.projectRename))
        #expect(SessionCLI.scopes(openedBy: nil, kind: .shell).contains(.list))
        #expect(!SessionCLI.scopes(openedBy: UUID(), kind: .shell).contains(.projectRename))
        #expect(!SessionCLI.openedScopes.contains(.projectRename))

        var book = SessionCLIBook()
        let claude = UUID(), shell = UUID()
        let claudeToken = book.token(for: claude, scopes: SessionCLI.scopes(openedBy: nil, kind: .claude))
        let shellToken = book.token(for: shell, scopes: SessionCLI.scopes(openedBy: nil, kind: .shell))
        func status(_ token: String) -> Int {
            let request = AgentHTTPRequest(method: "POST", path: "/v1/cli/projects/x/rename", query: [:],
                                           headers: ["authorization": "Bearer \(token)"], body: Data())
            switch SessionCLI.resolve(request, book: book) {
            case .failure(let refusal): return refusal.response.status
            case .success: return 200
            }
        }
        #expect(status(claudeToken) == 200)
        #expect(status(shellToken) == 403)
    }

    // MARK: Permission and running sessions

    @Test func onlyFromACoordinatorProject() {
        var coordinator = Project(path: "/tmp/AppFactory")
        coordinator.isCoordinator = true
        let plain = Project(path: "/tmp/Other")
        #expect(SessionCLI.projectRenameCheck(callerProject: coordinator, name: "Pasporo", running: []) == .allowed)
        #expect(SessionCLI.projectRenameCheck(callerProject: plain, name: "Pasporo", running: []) == .notCoordinator)
        #expect(SessionCLI.projectRenameCheck(callerProject: nil, name: "Pasporo", running: []) == .notCoordinator)
        #expect(SessionCLI.projectRenameCheck(callerProject: coordinator, name: "  ", running: []) == .badName)
        // Permission comes first: a non-coordinator learns nothing about the target's sessions.
        let running = [SessionCLI.RunningSession(id: UUID(), name: "dev", kind: "terminal")]
        #expect(SessionCLI.projectRenameCheck(callerProject: plain, name: "x", running: running) == .notCoordinator)
    }

    @Test func runningSessionsRefuseWithTheirIdsAndNames() throws {
        var coordinator = Project(path: "/tmp/AppFactory")
        coordinator.isCoordinator = true
        let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let running = [SessionCLI.RunningSession(id: a, name: "WhatsCode · build", kind: "claude"),
                       SessionCLI.RunningSession(id: b, name: "api", kind: "terminal")]
        #expect(SessionCLI.projectRenameCheck(callerProject: coordinator, name: "Pasporo", running: running) == .sessionsRunning(running))

        let response = SessionCLI.sessionsRunningFailure(running)
        #expect(response.status == 409)
        #expect(response.headers[SessionCLI.exitHeader] == "1")
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(object["error"] as? String == "sessions_running")
        let message = try #require(object["message"] as? String)
        #expect(message.contains("WhatsCode · build (AAAAAAAA, claude)") && message.contains("api (BBBBBBBB, terminal)"))
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["id"] as? String } == [a.uuidString, b.uuidString])
        #expect(sessions.map { $0["name"] as? String } == ["WhatsCode · build", "api"])
    }

    @Test func folderProblemsMapToCodes() throws {
        func code(_ problem: ProjectFolderRename.Problem) throws -> (Int, String?, String?) {
            let response = SessionCLI.projectRenameFailure(problem)
            let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            return (response.status, object?["error"] as? String, response.headers[SessionCLI.exitHeader])
        }
        #expect(try code(.badName) == (400, "bad_name", "2"))
        #expect(try code(.exists) == (409, "exists", "1"))
        #expect(try code(.missing) == (409, "missing", "1"))
        #expect(try code(.running) == (409, "sessions_running", "1"))
        #expect(try code(.failed("disk")) == (500, "rename_failed", "1"))
    }

    /// The owner's first real renames are siblings: WhatsCode → Pasporo inside SMS-VERIFICATION,
    /// vNum → Dialvo inside Projects. A new parent isn't a thing (as in the UI).
    @Test func newNamesStayInTheSameParent() throws {
        #expect(try ProjectFolderRename.newPath(for: "/Users/me/Desktop/Projects/SMS-VERIFICATION/WhatsCode", name: "Pasporo")
            == "/Users/me/Desktop/Projects/SMS-VERIFICATION/Pasporo")
        #expect(try ProjectFolderRename.newPath(for: "/Users/me/Desktop/Projects/vNum", name: "Dialvo") == "/Users/me/Desktop/Projects/Dialvo")
        #expect(throws: ProjectFolderRename.Problem.badName) { try ProjectFolderRename.newPath(for: "/a/WhatsCode", name: "SMS-VERIFICATION/Pasporo") }
    }

    /// A rename in a temporary folder: the deck follows the folder (sessions' working
    /// directories), and nothing outside it is touched.
    @Test func deckFollowsTheMovedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rename-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "SMS-VERIFICATION/WhatsCode").path
        let sibling = root.appending(path: "SMS-VERIFICATION/WhatsCode2").path
        try FileManager.default.createDirectory(atPath: old + "/.claude/worktrees/fix", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        var deck = DeckData()
        let project = Project(path: old, name: "WhatsCode")
        let other = Project(path: sibling, name: "WhatsCode2")
        deck.projects = [project, other]
        let session = deck.addSession(to: project.id, kind: .claude, name: "s")!
        deck.updateSession(session.id) { $0.workingDirectory = old + "/.claude/worktrees/fix" }
        let otherSession = deck.addSession(to: other.id, kind: .shell, name: "t")!
        deck.updateSession(otherSession.id) { $0.workingDirectory = sibling }

        let new = try ProjectFolderRename.newPath(for: old, name: "Pasporo")
        let transcripts = try ProjectFolderRename.move(old, to: new, claudeRoot: root.appending(path: "claude"))
        deck.relocateProject(project.id, from: old, to: new, transcripts: transcripts)
        #expect(deck.project(project.id)?.path == new)
        #expect(deck.session(session.id)?.workingDirectory == new + "/.claude/worktrees/fix")
        #expect(deck.session(otherSession.id)?.workingDirectory == sibling)
        #expect(FileManager.default.fileExists(atPath: sibling))
        #expect(FileManager.default.fileExists(atPath: new + "/.claude/worktrees/fix"))
    }

    // MARK: deck.json

    @Test func coordinatorDecodesFromOldAndNewDecks() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","path":"/a/WhatsCode","name":"WhatsCode","pinned":false,"collapsed":false}"#
        let decoded = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        #expect(decoded.coordinator == nil && !decoded.isCoordinator)

        let marked = #"{"id":"\#(id.uuidString)","path":"/a/AppFactory","name":"AppFactory","pinned":true,"collapsed":false,"coordinator":true}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(marked.utf8)).isCoordinator)

        var project = decoded
        project.isCoordinator = true
        let encoded = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        #expect(encoded.contains(#""coordinator":true"#))
        project.isCoordinator = false
        #expect(project.coordinator == nil)
        #expect(!String(decoding: try JSONEncoder().encode(project), as: UTF8.self).contains("coordinator"))
    }

    // MARK: Prefixes

    @Test func prefixesMatchWholePathComponents() {
        let old = "/Users/me/Projects/SMS-VERIFICATION/WhatsCode", new = "/Users/me/Projects/SMS-VERIFICATION/Pasporo"
        #expect(ServerPlanPathRelocation.relocated(old, from: old, to: new) == new)
        #expect(ServerPlanPathRelocation.relocated(old + "/web/dist", from: old, to: new) == new + "/web/dist")
        #expect(ServerPlanPathRelocation.relocated(old + "2", from: old, to: new) == nil)
        #expect(ServerPlanPathRelocation.relocated(old + "2/web", from: old, to: new) == nil)
        #expect(ServerPlanPathRelocation.relocated(old + "-old", from: old, to: new) == nil)
        #expect(ServerPlanPathRelocation.relocated("/Users/me/Projects/SMS-VERIFICATION", from: old, to: new) == nil)
        // Trailing slashes and dots don't change the match.
        #expect(ServerPlanPathRelocation.relocated(old + "/", from: old + "/", to: new + "/") == new)
        #expect(ServerPlanPathRelocation.relocated(old + "/./web", from: old, to: new) == new + "/web")
    }

    @Test func prefixValidation() throws {
        #expect(ServerPlanPathRelocation.normalized("/a/b/") == "/a/b")
        #expect(ServerPlanPathRelocation.normalized("/a//b/../c") == "/a/c")
        #expect(ServerPlanPathRelocation.normalized("/") == nil)
        #expect(ServerPlanPathRelocation.normalized("a/b") == nil)
        func problem(_ a: String, _ b: String) -> ServerPlanPathRelocation.PrefixProblem? {
            if case .failure(let problem) = ServerPlanPathRelocation.prefixes(a, b) { return problem }
            return nil
        }
        #expect(problem("relative", "/b") == .notAbsolute)
        #expect(problem("/", "/b") == .notAbsolute)
        #expect(problem("/a/b/", "/a/b") == .same)
        #expect(problem("/a/b", "/a/b/c") == .nested)
        #expect(problem("/a/b/c", "/a/b") == .nested)
        #expect(problem("/a/WhatsCode", "/a/WhatsCode2") == nil) // siblings, not nested
        let ok = try ServerPlanPathRelocation.prefixes("/a/vNum/", "/a/Dialvo").get()
        #expect(ok.old == "/a/vNum" && ok.new == "/a/Dialvo")
    }

    @Test func stalePathsWhenThePanelCantRelocate() {
        let projects = Data(#"[{"id":3,"path":"/a/WhatsCode"},{"id":4,"path":"/a/WhatsCode2"},{"id":5,"repo_path":"/a/WhatsCode/api"}]"#.utf8)
        let dirs = Data(#"[{"id":1,"path":"/a","local_path":"/a"}]"#.utf8)
        let domains = Data(#"[{"id":7,"local_sync_path":"/a/WhatsCode/site/dist"},{"id":8,"local_sync_path":null}]"#.utf8)
        let stale = ServerPlanPathRelocation.stalePaths(projects: projects, dirs: dirs, domains: domains, under: "/a/WhatsCode")
        #expect(stale == ["projects #3 path: /a/WhatsCode", "projects #5 repo_path: /a/WhatsCode/api",
                          "domains #7 local_sync_path: /a/WhatsCode/site/dist"])
    }

    // MARK: Answers

    @Test func answersParseTolerantly() {
        let contract = #"""
        {"dry_run":true,"old_prefix":"/a/WhatsCode","new_prefix":"/a/Pasporo","count":2,"skipped_deleted":1,"warnings":["x"],
         "changes":[{"table":"projects","id":3,"name":"WhatsCode","field":"path","old":"/a/WhatsCode","new":"/a/Pasporo"},
                    {"table":"domains","id":"7","name":"docs.pasporo.app","field":"local_sync_path","old":"/a/WhatsCode/dist","new":"/a/Pasporo/dist"}]}
        """#
        let answer = ServerPlanPathRelocation.Answer.parse(Data(contract.utf8), dryRun: false)
        #expect(answer.dryRun && answer.count == 2 && answer.skippedDeleted == 1 && answer.warnings == ["x"])
        #expect(answer.changes.map(\.id) == ["3", "7"] && answer.changes[1].field == "local_sync_path")
        #expect(answer.text.hasPrefix("would change 2 path(s) under /a/WhatsCode → /a/Pasporo (1 deleted row(s) left alone)"))
        #expect(answer.text.contains("domains #7 docs.pasporo.app local_sync_path: /a/WhatsCode/dist → /a/Pasporo/dist"))

        // Grouped by table, no count, other key names.
        let grouped = #"{"changes":{"projects":[{"id":3,"from":"/a/x","to":"/a/y"}],"project_dirs":[]}}"#
        let other = ServerPlanPathRelocation.Answer.parse(Data(grouped.utf8), dryRun: true)
        #expect(other.count == 1 && other.changes.first?.table == "projects" && other.changes.first?.new == "/a/y")
        #expect(ServerPlanPathRelocation.Answer.parse(Data("nope".utf8), dryRun: false).count == 0)
    }

    // MARK: server paths relocate

    private final class Transport: ServerPlanTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var replies: [String: [(Int, Data)]]

        init(_ replies: [String: [(Int, String)]]) {
            self.replies = replies.mapValues { $0.map { ($0.0, Data($0.1.utf8)) } }
        }

        var requests: [URLRequest] { lock.withLock { _requests } }
        func body(_ index: Int) -> [String: Any] {
            (requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: "")
            let key = "\(request.httpMethod ?? "GET") \(path)"
            let reply: (Int, Data) = lock.withLock {
                _requests.append(request)
                guard var list = replies[key], !list.isEmpty else { return (404, Data(#"{"error":"not_found"}"#.utf8)) }
                let first = list.removeFirst()
                replies[key] = list.isEmpty ? [first] : list
                return first
            }
            return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let (data, response) = try await data(for: request)
            return (response, AsyncThrowingStream { $0.yield(data); $0.finish() })
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static let meWith = #"{"user":{"id":1,"username":"medeni"},"scopes":["read","projects_write"],"server_version":"1.5","features":["paths_relocate"]}"#
    static let meWithout = #"{"user":{"id":1,"username":"medeni"},"scopes":["read","projects_write"],"server_version":"1.5","features":["env"]}"#
    static let dryAnswer = #"{"dry_run":true,"old_prefix":"/a/WhatsCode","new_prefix":"/a/Pasporo","changes":[{"table":"projects","id":3,"name":"WhatsCode","field":"path","old":"/a/WhatsCode","new":"/a/Pasporo"}],"count":1,"skipped_deleted":0,"warnings":[]}"#
    static let realAnswer = #"{"dry_run":false,"old_prefix":"/a/WhatsCode","new_prefix":"/a/Pasporo","changes":[{"table":"projects","id":3,"name":"WhatsCode","field":"path","old":"/a/WhatsCode","new":"/a/Pasporo"}],"count":1,"skipped_deleted":0,"warnings":["Eski klasor hala duruyor: /a/WhatsCode"]}"#
    static let confirm = #"{"error":"confirm_required","message":"Onay gerekli","summary":"1 kayittaki yerel yol degisecek: /a/WhatsCode → /a/Pasporo","confirm":"/a/WhatsCode"}"#

    private func runner(_ transport: Transport, me: String, approve: Bool, asked: Box<[String]>) throws -> ServerPlanCLI.Runner {
        let me = try JSONDecoder().decode(ServerPlanMe.self, from: Data(me.utf8))
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        return ServerPlanCLI.Runner(client: client, me: me, approve: { command, target, summary in
            asked.value.append("\(command) \(target) | \(summary ?? "")")
            return approve
        })
    }

    @Test func dryRunGoesStraightThrough() async throws {
        let transport = Transport(["POST /paths/relocate": [(200, Self.dryAnswer)]])
        let asked = Box<[String]>([])
        let outcome = try await runner(transport, me: Self.meWith, approve: false, asked: asked)
            .run("paths-relocate", method: "POST", form: ["old": "/a/WhatsCode/", "new": "/a/Pasporo", "dry_run": "1"])
        #expect(outcome.status == 200 && outcome.exit == .ok)
        #expect(outcome.text.contains("would change 1 path(s)"))
        #expect(asked.value.isEmpty)
        #expect(transport.requests.count == 1)
        let body = transport.body(0)
        #expect(body["old_prefix"] as? String == "/a/WhatsCode" && body["new_prefix"] as? String == "/a/Pasporo")
        #expect(body["dry_run"] as? Bool == true && body["confirm"] == nil)
    }

    @Test func realRunWaitsForTheOwner() async throws {
        let transport = Transport(["POST /paths/relocate": [(428, Self.confirm), (200, Self.realAnswer)]])
        let asked = Box<[String]>([])
        let outcome = try await runner(transport, me: Self.meWith, approve: true, asked: asked)
            .run("paths-relocate", method: "POST", form: ["old": "/a/WhatsCode", "new": "/a/Pasporo", "dry_run": "0"])
        #expect(outcome.status == 200)
        #expect(outcome.text.contains("changed 1 path(s)") && outcome.text.contains("warning: Eski klasor"))
        #expect(asked.value == ["paths-relocate /a/WhatsCode | 1 kayittaki yerel yol degisecek: /a/WhatsCode → /a/Pasporo"])
        #expect(transport.requests.count == 2 && transport.body(1)["confirm"] as? String == "/a/WhatsCode")

        let refusedTransport = Transport(["POST /paths/relocate": [(428, Self.confirm)]])
        let refused = try await runner(refusedTransport, me: Self.meWith, approve: false, asked: Box([]))
            .run("paths-relocate", method: "POST", form: ["old": "/a/WhatsCode", "new": "/a/Pasporo"])
        #expect(refused.status == 403 && refused.exit == .refused && refusedTransport.requests.count == 1)
    }

    @Test func notOfferedWithoutTheFeature() async throws {
        let transport = Transport([:])
        let outcome = try await runner(transport, me: Self.meWithout, approve: true, asked: Box([]))
            .run("paths-relocate", method: "POST", form: ["old": "/a/WhatsCode", "new": "/a/Pasporo", "dry_run": "1"])
        #expect(outcome.status == 501 && outcome.exit == .refused)
        #expect(outcome.text.contains("not available"))
        #expect(transport.requests.isEmpty)
    }

    @Test func badPrefixesNeverReachThePanel() async throws {
        let transport = Transport([:])
        let runner = try runner(transport, me: Self.meWith, approve: true, asked: Box([]))
        let nested = await runner.run("paths-relocate", method: "POST", form: ["old": "/a/x", "new": "/a/x/y", "dry_run": "1"])
        #expect(nested.status == 400 && nested.exit == .usage && nested.text.hasPrefix("nested_prefix"))
        let relative = await runner.run("paths-relocate", method: "POST", form: ["old": "a/x", "new": "/a/y"])
        #expect(relative.status == 400)
        #expect(transport.requests.isEmpty)
    }

    @Test func collisionIsAConflict() async throws {
        let transport = Transport(["POST /paths/relocate": [(409, #"{"error":"conflict","message":"Hedef yolda zaten kayit var","conflicts":[]}"#)]])
        let outcome = try await runner(transport, me: Self.meWith, approve: true, asked: Box([]))
            .run("paths-relocate", method: "POST", form: ["old": "/a/WhatsCode", "new": "/a/Pasporo", "dry_run": "1"])
        #expect(outcome.status == 409 && outcome.exit == .failed && outcome.text.contains("Hedef yolda zaten kayit var"))
    }

    @Test func summaryText() {
        let change = ServerPlanPathRelocation.Change(table: "projects", id: "3", name: "WhatsCode", field: "path", old: "/a/W", new: "/a/P")
        #expect(ServerPlanPathRelocation.Summary(status: .relocated, count: 1, changes: [change]).text
            == "updated 1 path(s)\n  projects #3 WhatsCode path: /a/W → /a/P")
        #expect(ServerPlanPathRelocation.Summary(status: .notSupported, stale: ["projects #3 path: /a/W"]).text
            .contains("doesn't support moving paths yet (paths_relocate); still pointing at the old folder:\n  projects #3 path: /a/W"))
        let renamed = SessionCLIProjectRenamed(id: UUID(), name: "Pasporo", oldName: "WhatsCode", path: "/a/P", oldPath: "/a/W",
                                               folderMoved: true, serverplan: .init(status: .nothing))
        #expect(renamed.text == "renamed: WhatsCode → Pasporo\nfolder: /a/W → /a/P\nserverplan: no paths under the old folder")
    }
}
