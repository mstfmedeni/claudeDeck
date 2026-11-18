import Foundation
import Testing
@testable import ClaudeDeckCore

/// Records every request and answers by "METHOD /path" (without the API's base), in order.
private final class RouteTransport: ServerPlanTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var replies: [String: [(Int, Data)]]

    init(_ replies: [String: [(Int, String)]]) {
        self.replies = replies.mapValues { $0.map { ($0.0, Data($0.1.utf8)) } }
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var posts: [[String: Any]] {
        requests.filter { $0.httpMethod != "GET" }.map { ($0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
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

private func fixture(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/serverplan/\(name)")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite struct SessionCLIAutonomyTests {
    private func request(_ method: String, _ path: String, token: String) -> AgentHTTPRequest {
        AgentHTTPRequest(method: method, path: path, query: [:], headers: ["authorization": "Bearer \(token)"], body: Data())
    }

    // MARK: Routes and scopes

    @Test func routesAndScopes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects") == .route(.projects))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects") == .route(.addProject))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/self/sessions") == .route(.newSession("self")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/projects/%2Ftmp%2Fx/sessions") == .route(.newSession("/tmp/x")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/projects/self/sessions") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/server/list") == .route(.server("list")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/server/deploy") == .route(.server("deploy")))
        #expect(SessionCLI.match(method: "PUT", path: "/v1/cli/projects") == .methodNotAllowed)
        // The existing routes are unchanged.
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "GET", path: "/v1/projects") == .notFound)
        #expect(SessionCLI.Route.addProject.scope == .start && SessionCLI.Route.newSession("x").scope == .start)
        #expect(SessionCLI.Route.server("list").scope == .server && SessionCLI.Route.projects.scope == .projects)

        var book = SessionCLIBook()
        let me = UUID(), opened = UUID()
        let full = book.token(for: me, scopes: SessionCLI.scopes(openedBy: nil))
        let restricted = book.token(for: opened, scopes: SessionCLI.scopes(openedBy: me))
        for (method, path) in [("GET", "/v1/cli/projects"), ("POST", "/v1/cli/projects"),
                               ("POST", "/v1/cli/projects/self/sessions"), ("GET", "/v1/cli/server/list")] {
            if case .success(let resolved) = SessionCLI.resolve(request(method, path, token: full), book: book) {
                #expect(resolved.caller == me)
            } else {
                Issue.record("full token refused for \(path)")
            }
            // A terminal a session opened can't add, start or use ServerPlan.
            guard case .failure(let refusal) = SessionCLI.resolve(request(method, path, token: restricted), book: book) else {
                Issue.record("restricted token allowed \(path)"); continue
            }
            #expect(refusal.response.status == 403 && refusal.response.headers[SessionCLI.exitHeader] == "4")
        }
    }

    @Test func settingsOffByDefaultAndOldDecks() throws {
        #expect(!DeckSettings().sessionsMayStartSessions && !DeckSettings().sessionsMayUseServerPlan)
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"sessionCLIEnabled":true}"#.utf8))
        #expect(old.sessionCLIEnabled && !old.sessionsMayStartSessions && !old.sessionsMayUseServerPlan)
        let starter = UUID()
        let session = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"c","startedBy":"\#(starter.uuidString)"}"#
        #expect(try JSONDecoder().decode(DeckSession.self, from: Data(session.utf8)).startedBy == starter)
        let older = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","name":"c"}"#
        #expect(try JSONDecoder().decode(DeckSession.self, from: Data(older.utf8)).startedBy == nil)
    }

    @Test func aSessionTheCallerStartedTakesItsText() {
        let me = UUID(), other = UUID(), target = UUID()
        func delivery(startedBy: UUID?) -> SessionCLI.Delivery {
            SessionCLI.delivery(caller: me, target: target, targetKind: .claude, targetOpenedBy: nil, besideCaller: false,
                                mayTypeIntoClaude: false, targetStartedBy: startedBy)
        }
        #expect(delivery(startedBy: me) == .type)
        #expect(delivery(startedBy: other) == .note)
        #expect(delivery(startedBy: nil) == .note)
        // Started sessions keep the full scopes (their own claudedeck works).
        #expect(SessionCLI.scopes(openedBy: nil).isSuperset(of: [.projects, .start, .server]))
        #expect(SessionCLI.openedScopes.isDisjoint(with: [.projects, .start, .server]))
    }

    // MARK: Project paths

    @Test func projectFolderRules() throws {
        let root = SessionCLI.resolved(FileManager.default.temporaryDirectory.appending(path: "cli-home-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: root + "/existing", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/file.txt"))
        defer { try? FileManager.default.removeItem(atPath: root) }
        let roots = [root]

        #expect(SessionCLI.projectFolder("relative/path", create: false, createRoots: roots) == .failure(.notAbsolute))
        #expect(SessionCLI.projectFolder("/", create: false, createRoots: roots) == .failure(.systemPath))
        #expect(SessionCLI.projectFolder("/usr/local/bin", create: false, createRoots: roots) == .failure(.systemPath))
        #expect(SessionCLI.projectFolder("/etc/new-thing", create: true, createRoots: roots) == .failure(.systemPath))
        #expect(SessionCLI.projectFolder("/System/Library", create: false, createRoots: roots) == .failure(.systemPath))
        #expect(SessionCLI.projectFolder(root + String(repeating: "/..", count: 30) + "/usr/bin", create: false, createRoots: roots) == .failure(.systemPath))
        #expect(SessionCLI.projectFolder(root + "/existing", create: false, createRoots: roots) == .success(root + "/existing"))
        #expect(SessionCLI.projectFolder(root + "/existing/", create: false, createRoots: roots) == .success(root + "/existing"))
        #expect(SessionCLI.projectFolder(root + "/file.txt", create: false, createRoots: roots) == .failure(.notAFolder))
        #expect(SessionCLI.projectFolder(root + "/missing", create: false, createRoots: roots) == .failure(.noSuchFolder))
        // --create: only below the home folder, not its Library or dot folders, never the root itself.
        #expect(SessionCLI.projectFolder("/private/tmp/cli-outside-\(UUID().uuidString)", create: true, createRoots: roots) == .failure(.outsideHome))
        #expect(SessionCLI.projectFolder(root + "/Library/Thing", create: true, createRoots: roots) == .failure(.outsideHome))
        #expect(SessionCLI.projectFolder(root + "/.ssh/x", create: true, createRoots: roots) == .failure(.outsideHome))
        #expect(SessionCLI.projectFolder(root + "/new/api", create: true, createRoots: roots) == .success(root + "/new/api"))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root + "/new/api", isDirectory: &isFolder) && isFolder.boolValue)
        // Refusals carry the documented exit codes.
        #expect(SessionCLI.PathRefusal.outsideHome.response.headers[SessionCLI.exitHeader] == "4")
        #expect(SessionCLI.PathRefusal.notAbsolute.response.headers[SessionCLI.exitHeader] == "2")
    }

    @Test func projectAddIsIdempotentAndProjectsResolve() {
        var deck = DeckData()
        let first = deck.addProject(path: "/tmp/cli-idem/app")
        let again = deck.addProject(path: "/tmp/cli-idem/app/")
        #expect(first.id == again.id && deck.projects.count == 1)
        let other = deck.addProject(path: "/tmp/cli-idem/Other")
        // By path (the same folder through /private), name (any case), id, prefix, or self.
        #expect(SessionCLI.project("/private/tmp/cli-idem/app", callerProject: nil, projects: deck.projects) == .found(first.id))
        #expect(SessionCLI.project("other", callerProject: nil, projects: deck.projects) == .found(other.id))
        #expect(SessionCLI.project(first.id.uuidString, callerProject: nil, projects: deck.projects) == .found(first.id))
        #expect(SessionCLI.project(String(other.id.uuidString.prefix(8)), callerProject: nil, projects: deck.projects) == .found(other.id))
        #expect(SessionCLI.project("self", callerProject: other.id, projects: deck.projects) == .found(other.id))
        #expect(SessionCLI.project("self", callerProject: nil, projects: deck.projects) == .unknown)
        #expect(SessionCLI.project("nope", callerProject: nil, projects: deck.projects) == .unknown)
        #expect(SessionCLI.project(UUID().uuidString, callerProject: nil, projects: deck.projects) == .unknown)
    }

    // MARK: Rate limits and caps

    @Test func startLimitsAndCap() {
        var book = SessionCLIBook()
        let caller = UUID(), other = UUID()
        let now = Date()
        for i in 0..<5 { #expect(SessionCLI.admitStart(caller: caller, runningStarted: i, book: &book, now: now) == nil) }
        let sixth = SessionCLI.admitStart(caller: caller, runningStarted: 5, book: &book, now: now.addingTimeInterval(60))
        #expect(sixth?.status == 429 && sixth?.headers[SessionCLI.exitHeader] == "4")
        // Another session has its own budget; ten minutes later the caller does again.
        #expect(SessionCLI.admitStart(caller: other, runningStarted: 5, book: &book, now: now) == nil)
        #expect(SessionCLI.admitStart(caller: caller, runningStarted: 6, book: &book, now: now.addingTimeInterval(601)) == nil)
        // The global cap: refused without using up the caller's budget.
        var fresh = SessionCLIBook()
        #expect(SessionCLI.admitStart(caller: caller, runningStarted: SessionCLI.maxRunningStarted, book: &fresh, now: now)?.status == 429)
        for _ in 0..<5 { #expect(SessionCLI.admitStart(caller: caller, runningStarted: 0, book: &fresh, now: now) == nil) }
        // Projects: 10 an hour.
        var allowed = 0
        for _ in 0..<10 where book.projectAdds.allow(caller, now: now) { allowed += 1 }
        let eleventh = book.projectAdds.allow(caller, now: now.addingTimeInterval(3599))
        let anHourLater = book.projectAdds.allow(caller, now: now.addingTimeInterval(3601))
        #expect(allowed == 10 && !eleventh && anHourLater)
        #expect(SessionCLI.startNotice(["a"]) == "a")
        #expect(SessionCLI.startNotice(["a", "b"]).contains("a; b"))
    }

    // MARK: ServerPlan through the app

    private func runner(_ transport: RouteTransport, me: String = fixture("me.json"), approve: Bool = false,
                        asked: Box<[String]> = Box([]), log: Box<[String]> = Box([])) throws -> ServerPlanCLI.Runner {
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        let me = try JSONDecoder().decode(ServerPlanMe.self, from: Data(me.utf8))
        return ServerPlanCLI.Runner(client: client, me: me, approve: { command, target, _ in
            asked.value.append("\(command) \(target)")
            return approve
        }, log: { log.value.append($0) })
    }

    @Test func deployIsConfirmedAutomatically() async throws {
        let transport = RouteTransport([
            "GET /projects": [(200, fixture("projects.json"))],
            "POST /projects/11/deploy": [(428, #"{"error":"confirm_required","summary":"payments-api deploys","confirm":"payments-api"}"#),
                                         (202, #"{"deployment_id":301}"#)],
        ])
        let asked = Box<[String]>([]), log = Box<[String]>([])
        let outcome = await (try runner(transport, asked: asked, log: log)).run("deploy", method: "POST", form: ["project": "payments-api"])
        #expect(outcome.exit == .ok && outcome.text == "301")
        #expect(transport.posts.count == 2)
        #expect(transport.posts[0]["confirm"] == nil && transport.posts[1]["confirm"] as? String == "payments-api")
        #expect(asked.value.isEmpty) // never the owner's dialog
        #expect(log.value.contains { $0.contains("confirmed automatically") })
        // v1.1: no 428 at all, one POST.
        let plain = RouteTransport(["GET /projects": [(200, fixture("projects.json"))], "POST /projects/11/deploy": [(202, #"{"deployment_id":302}"#)]])
        let second = await (try runner(plain)).run("deploy", method: "POST", form: ["project": "11"])
        #expect(second.text == "302" && plain.posts.count == 1)
    }

    @Test func containerActionsWaitForTheOwner() async throws {
        let replies: [String: [(Int, String)]] = [
            "GET /servers": [(200, fixture("servers.json"))],
            "POST /servers/1/containers/api/restart": [(428, #"{"error":"confirm_required","summary":"api restarts","confirm":"api"}"#), (200, "{}")],
        ]
        let refused = RouteTransport(replies)
        let asked = Box<[String]>([])
        let outcome = await (try runner(refused, approve: false, asked: asked)).run("container", method: "POST",
                                                                                 form: ["server": "prod-eu-1", "container": "api", "action": "restart"])
        #expect(outcome.exit == .refused && outcome.status == 403)
        #expect(asked.value == ["container restart api"])
        // Only the preview went out; never a confirm.
        #expect(refused.posts.count == 1 && refused.posts.allSatisfy { $0["confirm"] == nil })

        let approved = RouteTransport(replies)
        let done = await (try runner(approved, approve: true)).run("container", method: "POST", form: ["server": "1", "container": "api", "action": "restart"])
        #expect(done.exit == .ok && approved.posts.last?["confirm"] as? String == "api")

        // A bad action never reaches the panel.
        let bad = RouteTransport(replies)
        #expect(await (try runner(bad)).run("container", method: "POST", form: ["server": "1", "container": "api", "action": "delete"]).exit == .usage)
        #expect(bad.posts.isEmpty)
    }

    @Test func otherConfirmationsAreNotAutomatic() async throws {
        let transport = RouteTransport([
            "GET /domains": [(200, fixture("v11-domains.json"))],
            "POST /domains/5/dns-sync": [(428, #"{"error":"confirm_required","summary":"api.example.com DNS kaydi degisecek: 1.1.1.1 → 2.2.2.2","confirm":"api.example.com"}"#)],
            "POST /domains/5/namecheap/nameservers": [(428, #"{"error":"confirm_required","summary":"custom NS"}"#)],
        ])
        let asked = Box<[String]>([])
        let r = try runner(transport, me: fixture("v11-me.json"), approve: false, asked: asked)
        #expect(await r.run("dns-sync", method: "POST", form: ["domain": "api.example.com"]).exit == .refused)
        #expect(await r.run("ns-set", method: "POST", form: ["domain": "5"]).exit == .refused)
        // ns: confirmed with the base domain when the panel doesn't name it.
        #expect(asked.value == ["dns-sync api.example.com", "ns-set example.com"])
        #expect(transport.posts.allSatisfy { $0["confirm"] == nil })
        #expect(ServerPlanCLI.commands.values.filter { $0.gate == .auto }.map(\.name) == ["deploy"])
    }

    @Test func olderPanelsDontOfferV11() async throws {
        let transport = RouteTransport([:])
        let r = try runner(transport) // v1 /me: no projects_write, databases, domains, dns
        for name in ["scan", "db-create", "domain-add", "zone-add"] {
            let outcome = await r.run(name, method: "POST", form: ["project": "1", "dir": "11", "name": "example.com"])
            #expect(outcome.exit == .refused && outcome.text.contains("ServerPlan doesn't offer this yet"))
        }
        #expect(transport.requests.isEmpty)
        // A read-only v1.1 command on a panel that says it's version 1: not asked at all.
        #expect(await r.run("dirs", method: "GET", form: [:]).text.contains("doesn't offer this yet"))
        #expect(transport.requests.isEmpty)
        // Version unknown: tried, and a 404 means the panel doesn't have it.
        let unknown = try runner(transport, me: #"{"user":"x","scopes":["read"]}"#)
        #expect(await unknown.run("ports", method: "GET", form: ["server": "1"]).text.contains("doesn't offer this yet"))
        #expect(transport.requests.count == 1)
        #expect(await r.run("list", method: "POST", form: [:]).exit == .usage)
        #expect(await r.run("frobnicate", method: "GET", form: [:]).exit == .usage)
    }

    @Test func v11Commands() async throws {
        let transport = RouteTransport([
            "GET /projects": [(200, #"[{"id":9,"display_name":"new-api"}]"#)],
            "GET /servers/2/ports": [(200, fixture("v11-ports.json"))],
            "GET /project-dirs": [(200, fixture("v11-project-dirs.json"))],
            "POST /project-dirs/11/scan": [(200, fixture("v11-scan.json"))],
            "GET /projects/9/settings": [(200, fixture("v11-settings.json"))],
            "PUT /projects/9/settings": [(200, "{}")],
            "GET /projects/9/env": [(200, fixture("v11-env.json"))],
            "POST /projects/9/env/bulk": [(200, #"{"env_vars":[{"key":"API_KEY","value":"s3cret"}]}"#)],
            "POST /projects/9/auto-create-db": [(409, #"{"error":"conflict","message":"exists"}"#)],
            "POST /domains": [(201, #"{"id":6,"fqdn":"api.example.com"}"#)],
        ])
        let r = try runner(transport, me: fixture("v11-me.json"))
        let ports = await r.run("ports", method: "GET", form: ["server": "2"])
        #expect(ports.exit == .ok && ports.text.contains("suggested: 6079") && ports.text.contains("FlowRadar-api"))

        // A project's path inside a registered dir: scan that dir, answer with the project.
        let scanned = await r.run("scan", method: "POST", form: ["dir": "/Users/demo/Projects/new-api"])
        #expect(scanned.exit == .ok && scanned.text == "project #9 new-api")
        #expect(await r.run("scan", method: "POST", form: ["dir": "/elsewhere/x"]).exit == .unknown)

        // set: the current settings merged in (the panel clears what's left out).
        let set = await r.run("project-set", method: "POST", form: ["project": "new-api", "port": "6080"])
        #expect(set.exit == .ok)
        let put = try #require(transport.requests.last { $0.httpMethod == "PUT" })
        let body = try #require(JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        #expect(body["default_server_id"] as? Int == 2 && body["default_port"] as? Int == 6080)
        #expect(body["volume_path"] as? String == "/data/new-api" && body["dockerfile_path"] as? String == "Dockerfile")

        // Secrets never shown, even if the panel sent one.
        let env = await r.run("env-get", method: "GET", form: ["project": "9"])
        #expect(!env.text.contains("leaked-if-shown") && !String(decoding: env.json, as: UTF8.self).contains("leaked-if-shown"))
        let written = await r.run("env-set", method: "POST", form: ["project": "9", "vars": "API_KEY=s3cret\n# c\nexport DEBUG='1'\n", "secret": "API_KEY"])
        #expect(written.exit == .ok && !written.text.contains("s3cret") && !String(decoding: written.json, as: UTF8.self).contains("s3cret"))
        let bulk = try #require(transport.posts.last?["env_vars"] as? [[String: Any]])
        #expect(bulk.count == 2 && bulk.contains { $0["key"] as? String == "API_KEY" && $0["is_secret"] as? Bool == true })

        let db = await r.run("db-create", method: "POST", form: ["project": "9"])
        #expect(db.exit == .failed && db.status == 409 && db.text.contains("conflict"))

        // domain add: server and port from the project's settings.
        let domain = await r.run("domain-add", method: "POST", form: ["project": "new-api", "subdomain": "api", "base": "example.com"])
        #expect(domain.exit == .ok)
        let added = try #require(transport.posts.last)
        #expect(added["server_id"] as? Int == 2 && added["port"] as? Int == 6079 && added["project_name"] as? String == "new-api")
        #expect(added["type"] as? String == "go_app" && added["confirm"] == nil)
    }

    @Test func deployStatusAndErrors() async throws {
        let failed = #"{"id":207,"project_id":11,"status":"failed","error_summary":"npm ci failed","log":"step 1\nstep 2\nnpm ERR!"}"#
        let transport = RouteTransport(["GET /deployments/207": [(200, failed)], "GET /deployments/208": [(200, #"{"id":208,"status":"building","log":"a"}"#)]])
        let r = try runner(transport)
        let status = await r.run("deploy-status", method: "GET", form: ["id": "207"])
        #expect(status.exit == .failed && status.text.contains("npm ci failed") && status.text.contains("npm ERR!"))
        #expect(status.next == "3:failed")
        // Waiting from line 3: nothing new but the end.
        let waited = await r.run("deploy-status", method: "GET", form: ["id": "207", "wait": "25", "since": "3", "status": "building"])
        #expect(waited.exit == .failed && !waited.text.contains("step 1") && waited.text.contains("deploy #207: failed"))
        // Still running, new lines: answered at once with them (exit 124: ask again).
        let running = await r.run("deploy-status", method: "GET", form: ["id": "208", "wait": "25", "since": "0"])
        #expect(running.exit == .timeout && running.text.hasPrefix("a"))
        #expect(ServerPlanCLI.outcome(for: ServerPlanError.unauthorized(nil)).exit == .refused)
        #expect(ServerPlanCLI.outcome(for: ServerPlanError.notFound).exit == .unknown)
        #expect(ServerPlanCLI.envAssignments("A=1\nB=\"two words\"\n bad line\n1X=no").count == 2)
    }
}
