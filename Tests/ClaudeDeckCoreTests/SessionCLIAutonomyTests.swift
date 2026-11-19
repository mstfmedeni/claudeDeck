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
        // sync: the v1 token has `deploy`, but the panel says it's version 1.
        for name in ["scan", "db-create", "domain-add", "zone-add", "static-add", "sync"] {
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

    @Test func staticSites() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "static-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "dist"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dist = dir.appending(path: "dist").path
        let transport = RouteTransport([
            "GET /domains": [(200, fixture("v11-domains.json"))],
            "POST /domains/quick-static": [(201, #"{"id":7,"fqdn":"example.com","target":"/opt/static/example-com"}"#),
                                           (400, #"{"error":"bad_request","message":"gecersiz: example.com icin statik site zaten var"}"#)],
            "POST /domains": [(201, #"{"id":8}"#)],
            "POST /domains/5/sync": [(200, #"{"success":true,"message":"Files synced to /opt/static/api-example-com"}"#),
                                     (403, #"{"error":"forbidden","message":"local_path kayitli bir proje dizininde degil"}"#)],
        ])
        let log = Box<[String]>([]), asked = Box<[String]>([])
        let r = try runner(transport, me: fixture("v11-me.json"), asked: asked, log: log)

        // static add: the root site, autonomous.
        let added = await r.run("static-add", method: "POST", form: ["server": "2", "base": "Example.com"])
        #expect(added.exit == .ok)
        let quick = try #require(transport.posts.last)
        #expect(quick.count == 2 && quick["server_id"] as? Int == 2 && quick["base_domain"] as? String == "example.com")
        let again = await r.run("static-add", method: "POST", form: ["server": "2", "base": "example.com"])
        #expect(again.status == 400 && again.exit == .failed && again.text.contains("gecersiz"))
        #expect(await r.run("static-add", method: "POST", form: ["server": "2", "base": "nodot"]).exit == .usage)

        // domain add --static: no project or port; clean URLs and the target by default.
        let site = await r.run("domain-add", method: "POST", form: ["static": "1", "server": "2", "subdomain": "docs", "base": "example.com"])
        #expect(site.exit == .ok)
        let body = try #require(transport.posts.last)
        #expect(body["type"] as? String == "static" && body["server_id"] as? Int == 2 && body["subdomain"] as? String == "docs")
        #expect(body["target"] as? String == "/opt/static/docs-example-com" && body["clean_urls"] as? Bool == true)
        #expect(body["ssl_enabled"] as? Bool == true && body["port"] == nil && body["project_name"] == nil && body["confirm"] == nil)
        _ = await r.run("domain-add", method: "POST", form: ["static": "1", "server": "2", "subdomain": "docs", "base": "example.com",
                                                            "target": "/opt/static/x", "clean_urls": "0"])
        #expect(transport.posts.last?["target"] as? String == "/opt/static/x" && transport.posts.last?["clean_urls"] as? Bool == false)
        #expect(ServerPlanCLI.staticTarget(subdomain: "", base: "my.example.com") == "/opt/static/my-example-com")

        // sync: by FQDN; the panel's message is the answer.
        let synced = await r.run("sync", method: "POST", form: ["domain": "api.example.com", "path": dist])
        #expect(synced.exit == .ok && synced.text == "Files synced to /opt/static/api-example-com")
        #expect(transport.posts.last?["local_path"] as? String == dist)
        let outside = await r.run("sync", method: "POST", form: ["domain": "5", "path": dist])
        #expect(outside.status == 403 && outside.exit == .refused && outside.text.contains("not_in_project_dir"))
        // Not a folder, or not absolute: never sent.
        let before = transport.requests.count
        #expect(await r.run("sync", method: "POST", form: ["domain": "5", "path": dir.appending(path: "missing").path]).exit == .usage)
        #expect(await r.run("sync", method: "POST", form: ["domain": "5", "path": "dist"]).exit == .usage)
        #expect(transport.requests.count == before)
        #expect(asked.value.isEmpty) // never the owner's dialog
        #expect(log.value.contains { $0.hasPrefix("sync api.example.com") })

        // A v1.1 panel that doesn't have them yet: 404 is "not available".
        let older = try runner(RouteTransport(["GET /domains": [(200, fixture("v11-domains.json"))]]), me: fixture("v11-me.json"))
        #expect(await older.run("static-add", method: "POST", form: ["server": "2", "base": "example.com"]).text.contains("doesn't offer this yet"))
        #expect(await older.run("sync", method: "POST", form: ["domain": "5", "path": dist]).text.contains("doesn't offer this yet"))
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

    // MARK: v1.2

    private static let projects = #"[{"id":9,"display_name":"new-api","default_server_id":2}]"#

    private func body(_ request: URLRequest?) -> [String: Any] {
        (request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    @Test func sqlReadsAndOwnerGatedWrites() async throws {
        let read = #"{"database":"new_api","columns":["id","email"],"rows":[["1","a@x"],["2",null]],"row_count":2,"truncated":false}"#
        let replies: [String: [(Int, String)]] = [
            "GET /projects": [(200, Self.projects)],
            "POST /projects/9/sql": [(200, read)],
        ]
        let transport = RouteTransport(replies)
        let asked = Box<[String]>([])
        let r = try runner(transport, me: fixture("v12-me.json"), asked: asked)
        let rows = await r.run("sql", method: "POST", form: ["project": "new-api", "query": "select id, email from users", "local": "1"])
        #expect(rows.exit == .ok && rows.text.contains("a@x") && rows.text.contains("NULL") && rows.text.contains("(2 rows (new_api))"))
        let sent = body(transport.requests.last)
        #expect(sent["query"] as? String == "select id, email from users" && sent["target"] as? String == "local" && sent["write"] == nil)
        #expect(asked.value.isEmpty && transport.requests.last?.timeoutInterval == 60)

        // A write: 428 → the owner's dialog with the database name; refused: never confirmed.
        let gate = (428, #"{"error":"confirm_required","summary":"new_api veritabaninda yazan SQL: update t","confirm":"new_api"}"#)
        let refusedT = RouteTransport(["GET /projects": [(200, Self.projects)], "POST /projects/9/sql": [gate]])
        let refused = await (try runner(refusedT, me: fixture("v12-me.json"), approve: false, asked: asked)).run(
            "sql", method: "POST", form: ["project": "9", "query": "update t set a = 1", "write": "1"])
        #expect(refused.exit == .refused && asked.value == ["sql new_api"])
        #expect(refusedT.posts.count == 1 && refusedT.posts[0]["write"] as? Bool == true && refusedT.posts[0]["confirm"] == nil)
        let approvedT = RouteTransport(["GET /projects": [(200, Self.projects)],
                                        "POST /projects/9/sql": [gate, (200, #"{"database":"new_api","write":true,"output":"UPDATE 3\n"}"#)]])
        let done = await (try runner(approvedT, me: fixture("v12-me.json"), approve: true)).run(
            "sql", method: "POST", form: ["project": "9", "query": "update t set a = 1", "write": "1"])
        #expect(done.exit == .ok && done.text == "UPDATE 3" && approvedT.posts.last?["confirm"] as? String == "new_api")
        #expect(approvedT.requests.last?.timeoutInterval == 90)
        // No query: never sent. A token without the sql scope: not offered.
        #expect(await r.run("sql", method: "POST", form: ["project": "9", "query": " "]).exit == .usage)
        let noScope = try runner(RouteTransport([:]), me: fixture("v11-me.json"))
        #expect(await noScope.run("sql", method: "POST", form: ["project": "9", "query": "select 1"]).text.contains("doesn't offer this yet"))
        #expect(ServerPlanCLI.commands["sql"]?.gate == .owner)
    }

    @Test func envRescanAndLocalEnv() async throws {
        let transport = RouteTransport([
            "GET /projects": [(200, Self.projects)],
            "POST /projects/9/env/rescan": [(200, #"{"dry_run":true,"added":[{"key":"NEW_FLAG","is_secret":false,"value":"leak"},{"key":"STRIPE_SECRET","is_secret":true}]}"#)],
            "GET /projects/9/local-env": [(200, #"[{"key":"DB_NAME","value":"new_api_dev","is_secret":false},{"key":"API_KEY","value":"leaked-if-shown","is_secret":true}]"#)],
            "PUT /projects/9/local-env": [(200, #"{"written":["DEBUG"]}"#)],
            "DELETE /projects/9/local-env/DEBUG": [(200, #"{"deleted":"DEBUG"}"#)],
        ])
        let r = try runner(transport, me: fixture("v12-me.json"))
        let rescan = await r.run("env-rescan", method: "POST", form: ["project": "new-api", "dry_run": "1"])
        #expect(rescan.exit == .ok && rescan.text == "would add: NEW_FLAG, STRIPE_SECRET (secret)")
        #expect(transport.posts.last?["dry_run"] as? Bool == true && !String(decoding: rescan.json, as: UTF8.self).contains("leak"))

        let env = await r.run("local-env-get", method: "GET", form: ["project": "9"])
        #expect(env.text.contains("new_api_dev") && !env.text.contains("leaked") && !String(decoding: env.json, as: UTF8.self).contains("leaked"))
        let set = await r.run("local-env-set", method: "POST", form: ["project": "9", "vars": "DEBUG=1\n"])
        #expect(set.exit == .ok && (transport.posts.last?["vars"] as? [String: String]) == ["DEBUG": "1"])
        #expect(transport.requests.last?.httpMethod == "PUT")
        // One removed, one without an override (404: not "not available").
        let unset = await r.run("local-env-unset", method: "POST", form: ["project": "9", "keys": "DEBUG,NOPE"])
        #expect(unset.exit == .ok && unset.text.contains("removed: DEBUG") && unset.text.contains("no local override: NOPE"))
        #expect(await r.run("local-env-unset", method: "POST", form: ["project": "9", "keys": "NOPE"]).exit == .unknown)
    }

    @Test func localRunAndStatus() async throws {
        let transport = RouteTransport([
            "GET /projects": [(200, Self.projects)],
            "POST /projects/9/local-run": [(200, #"{"success":true,"port":18009,"local_url":"http://localhost:18009","container_name":"local-new-api","db_host":"10.0.0.5"}"#),
                                           (409, #"{"error":"conflict","message":"Bu proje zaten lokalde calisiyor"}"#)],
            "GET /projects/9/local-status": [(200, #"{"running":true,"status":"building","port":18009}"#),
                                             (200, #"{"running":true,"status":"running","port":18009,"local_url":"http://localhost:18009"}"#)],
            "GET /projects/9/local-logs": [(200, "line 1\nline 2\n")],
        ])
        let r = try runner(transport, me: fixture("v12-me.json"))
        let started = await r.run("local-run", method: "POST", form: ["project": "new-api", "port": "18009", "no_cache": "1", "server": "2"])
        #expect(started.exit == .ok && started.text.contains("http://localhost:18009"))
        let sent = transport.posts.last ?? [:]
        #expect(sent["port"] as? Int == 18009 && sent["no_cache"] as? Bool == true && sent["server_id"] as? Int == 2)
        let again = await r.run("local-run", method: "POST", form: ["project": "9"])
        #expect(again.status == 409 && again.text.contains("zaten lokalde"))
        // --wait: polls past "building"; answers once it's running.
        let status = await r.run("local-status", method: "GET", form: ["project": "9", "wait": "25"])
        #expect(status.exit == .ok && status.next == "running" && status.text.contains("local: running http://localhost:18009"))
        // Not running (never started, or stopped): --wait ends with exit 1.
        let quiet = RouteTransport(["GET /projects": [(200, Self.projects)],
                                    "GET /projects/9/local-status": [(200, #"{"running":false}"#)]])
        let stopped = await (try runner(quiet, me: fixture("v12-me.json"))).run("local-status", method: "GET", form: ["project": "9", "wait": "1"])
        #expect(stopped.exit == .failed && stopped.next == "not_running")
        let logs = await r.run("local-logs", method: "GET", form: ["project": "9", "tail": "50"])
        #expect(logs.text == "line 1\nline 2" && transport.requests.last?.value(forHTTPHeaderField: "Accept") == "text/plain")
        #expect(transport.requests.last?.url?.query == "tail=50")
        // Not running locally: 404 stays "unknown", not "not available".
        let none = await (try runner(RouteTransport(["GET /projects": [(200, Self.projects)]]), me: fixture("v12-me.json")))
            .run("local-logs", method: "GET", form: ["project": "9"])
        #expect(none.exit == .unknown)
    }

    @Test func cloneForLocalAndJobs() async throws {
        let transport = RouteTransport([
            "GET /projects": [(200, Self.projects)],
            "GET /projects/9/settings": [(200, fixture("v11-settings.json"))],
            "GET /projects/9/env": [(200, fixture("v11-env.json"))],
            "POST /servers/2/pg/databases/new_api/clone-for-local": [(202, #"{"job_id":"ab12","source":"new_api","target":"new_api_dev","local_env":{"DB_NAME":"new_api_dev"}}"#)],
            "GET /pg/clone-jobs/ab12": [(200, #"{"id":"ab12","status":"running","events":[{"step":"prepare","message":"creating","progress":10}]}"#),
                                       (200, #"{"id":"ab12","status":"success","events":[{"step":"prepare","message":"creating","progress":10},{"step":"done","message":"done","progress":100}]}"#)],
            "POST /servers/1/pg/databases/shop/clone": [(202, #"{"job_id":"cd34","source":"shop","target":"shop_copy"}"#)],
        ])
        let log = Box<[String]>([])
        let r = try runner(transport, me: fixture("v12-me.json"), log: log)
        // Server and source database from the project (settings, DB_NAME).
        let clone = await r.run("db-clone-local", method: "POST", form: ["project": "new-api"])
        #expect(clone.exit == .ok && clone.next == "ab12" && clone.text.contains("new_api → new_api_dev") && clone.text.contains("deploy env is unchanged"))
        #expect(transport.posts.last?["project_id"] as? Int == 9 && transport.posts.last?["target_name"] == nil)
        let first = await r.run("clone-status", method: "GET", form: ["id": "ab12", "wait": "25", "since": "0"])
        #expect(first.exit == .timeout && first.text == "[10%] creating" && first.next == "1")
        let done = await r.run("clone-status", method: "GET", form: ["id": "ab12", "wait": "25", "since": "1"])
        #expect(done.exit == .ok && done.text == "[100%] done\nclone ab12: success")
        #expect(await r.run("clone-status", method: "GET", form: ["id": "../x"]).exit == .usage)
        // The panel's clone with a project switches the deploy DB_NAME: said so.
        let pg = await r.run("pg-clone", method: "POST", form: ["server": "1", "database": "shop", "target": "shop_copy", "project": "new-api"])
        #expect(pg.exit == .ok && pg.next == "cd34" && pg.text.contains("warning: new-api's deploy env DB_NAME now points at shop_copy"))
        #expect(transport.posts.last?["project_id"] as? Int == 9 && transport.posts.last?["target_name"] as? String == "shop_copy")
        #expect(log.value.contains { $0.contains("switches the deploy DB_NAME") })
        #expect(await r.run("pg-clone", method: "POST", form: ["server": "1", "database": "shop; drop", "target": "x"]).exit == .usage)
    }

    @Test func projectGatesAndWrappers() async throws {
        let gate = (428, #"{"error":"confirm_required","summary":"new-api: git commit + push","confirm":"new-api"}"#)
        let replies: [String: [(Int, String)]] = [
            "GET /projects": [(200, Self.projects)],
            "GET /projects/9/settings": [(200, fixture("v11-settings.json"))],
            "GET /projects/9/branches": [(200, #"{"branches":["main","develop"],"current_branch":"main"}"#)],
            "POST /projects/9/git-push": [gate],
            "POST /projects/9/switch-branch": [gate],
            "POST /projects/9/diagnose/fix": [gate],
            "POST /deployments/301/cancel": [(428, #"{"error":"confirm_required","summary":"new-api deploy #301 iptal edilecek","confirm":"new-api"}"#)],
            "POST /projects/9/pull-deploy": [(200, #"{"success":true,"deployment_id":302}"#)],
            "POST /projects/9/diagnose": [(200, #"{"project":"new-api","server":"hetzner-1","container_name":"new-api","checks":[{"label":"Network","status":"error","message":"not on traefik-net","fix_available":true,"fix_action":"fix_network"}]}"#)],
            "POST /projects/9/build": [(200, #"{"success":true,"output":"Step 1\nStep 2","image":"new-api:latest"}"#)],
        ]
        let transport = RouteTransport(replies)
        let asked = Box<[String]>([])
        let r = try runner(transport, me: fixture("v12-me.json"), approve: false, asked: asked)
        let branches = await r.run("branches", method: "GET", form: ["project": "9"])
        #expect(branches.text == "* main\n  develop")
        #expect(await r.run("git-push", method: "POST", form: ["project": "new-api"]).exit == .refused)
        #expect(await r.run("switch-branch", method: "POST", form: ["project": "9", "branch": "develop"]).exit == .refused)
        #expect(await r.run("diagnose-fix", method: "POST", form: ["project": "9", "action": "fix_network"]).exit == .refused)
        #expect(await r.run("deploy-cancel", method: "POST", form: ["id": "301"]).exit == .refused)
        #expect(asked.value == ["git-push new-api", "switch-branch new-api", "diagnose-fix new-api", "deploy-cancel new-api"])
        #expect(transport.posts.allSatisfy { $0["confirm"] == nil })
        #expect(await r.run("diagnose-fix", method: "POST", form: ["project": "9", "action": "rm -rf"]).exit == .usage)
        #expect(await r.run("switch-branch", method: "POST", form: ["project": "9", "branch": "--force"]).exit == .usage)

        // pull-deploy: the project's server, prints the deployment id (for --wait).
        let pull = await r.run("pull-deploy", method: "POST", form: ["project": "9", "force": "1"])
        #expect(pull.exit == .ok && pull.text == "302" && transport.posts.last?["server_id"] as? Int == 2 && transport.posts.last?["force_rebuild"] as? Bool == true)
        let diagnose = await r.run("diagnose", method: "GET", form: ["project": "9"])
        #expect(diagnose.text.contains("new-api on hetzner-1") && diagnose.text.contains("fix_network"))
        let build = await r.run("build", method: "POST", form: ["project": "9", "no_cache": "1"])
        #expect(build.text == "Step 1\nStep 2\nimage: new-api:latest" && transport.requests.last?.timeoutInterval == 1200)
        #expect(ServerPlanCLI.commands.values.filter { $0.gate == .auto }.map(\.name) == ["deploy"])

        // Approved: sent again with the panel's confirmation.
        let approved = RouteTransport(replies.merging(["POST /projects/9/git-push": [gate, (200, #"{"success":true,"log":"To origin"}"#)]]) { $1 })
        let pushed = await (try runner(approved, me: fixture("v12-me.json"), approve: true)).run("git-push", method: "POST", form: ["project": "9"])
        #expect(pushed.exit == .ok && pushed.text == "To origin" && approved.posts.last?["confirm"] as? String == "new-api")
    }

    @Test func domainsCloudflareAndPostgres() async throws {
        let domains = #"[{"id":5,"fqdn":"api.example.com","subdomain":"api","base_domain":"example.com","type":"go_app","target":"new-api","port":6079,"server_id":2,"project_name":"new-api","ssl_enabled":true,"clean_urls":false,"websocket_enabled":true}]"#
        let transport = RouteTransport([
            "GET /domains": [(200, domains)],
            "GET /servers": [(200, fixture("servers.json"))],
            "GET /projects": [(200, Self.projects)],
            "PUT /domains/5": [(428, #"{"error":"confirm_required","summary":"api.example.com DNS kaydi degisecek","confirm":"api.example.com"}"#),
                               (200, #"{"id":5}"#)],
            "POST /domains/5/purge-cache": [(200, #"{"success":true,"message":"Cache temizlendi: api.example.com"}"#)],
            "POST /cloudflare/ssl-full": [(200, #"{"success":true,"message":"SSL modu 'Full'"}"#)],
            "GET /cloudflare/ssl": [(200, #"{"domain":"example.com","ssl_mode":"flexible","is_full":false}"#)],
            "GET /servers/1/pg/users": [(200, #"[{"name":"appuser","is_superuser":true,"databases":["a","b"]}]"#)],
            "POST /servers/1/pg/users": [(200, #"{"success":true,"username":"bob","password":"leaked-if-shown"}"#)],
            "POST /servers/1/pg/users/bob/grant": [(200, #"{"success":true,"message":"Erisim yetkisi verildi"}"#)],
            "GET /servers/1/env": [(200, #"[{"key":"REGION","value":"eu"},{"key":"SENTRY_TOKEN","value":null}]"#)],
            "POST /servers/1/env": [(201, #"{"success":true}"#)],
        ])
        let asked = Box<[String]>([])
        let r = try runner(transport, me: fixture("v12-me.json"), approve: true, asked: asked)
        // domain set: the current row, the change, everything else as it is.
        let set = await r.run("domain-set", method: "POST", form: ["domain": "api.example.com", "server": "prod-eu-1", "clean_urls": "1"])
        #expect(set.exit == .ok && asked.value == ["domain-set api.example.com"])
        let put = try #require(transport.posts.last)
        #expect(put["server_id"] as? Int == 1 && put["port"] as? Int == 6079 && put["websocket_enabled"] as? Bool == true)
        #expect(put["clean_urls"] as? Bool == true && put["target"] as? String == "new-api" && put["confirm"] as? String == "api.example.com")
        #expect(await r.run("domain-set", method: "POST", form: ["domain": "5"]).exit == .usage)

        #expect(await r.run("domain-purge", method: "POST", form: ["domain": "5"]).text == "Cache temizlendi: api.example.com")
        let ssl = await r.run("ssl", method: "GET", form: ["base": "Example.com"])
        #expect(ssl.text.contains("ssl_mode: flexible") && transport.requests.last?.url?.query == "domain=example.com")
        #expect(await r.run("ssl-full", method: "POST", form: ["base": "example.com"]).exit == .ok && transport.posts.last?["base_domain"] as? String == "example.com")
        #expect(await r.run("zone-purge", method: "POST", form: ["base": "nodot"]).exit == .usage)

        #expect(await r.run("pg-users", method: "GET", form: ["server": "1"]).text.contains("a,b"))
        let user = await r.run("pg-user-add", method: "POST", form: ["server": "1", "username": "bob", "project": "new-api"])
        #expect(user.exit == .ok && !String(decoding: user.json, as: UTF8.self).contains("leaked") && !user.text.contains("leaked"))
        #expect(transport.posts.last?["project_id"] as? Int == 9 && transport.posts.last?["username"] as? String == "bob")
        let grant = await r.run("pg-grant", method: "POST", form: ["server": "1", "username": "bob", "database": "shop", "revoke": "0"])
        #expect(grant.text == "Erisim yetkisi verildi" && transport.posts.last?["revoke"] == nil)

        let senv = await r.run("server-env-get", method: "GET", form: ["server": "1"])
        #expect(senv.text.contains("SENTRY_TOKEN") && senv.text.contains("(secret)"))
        let written = await r.run("server-env-set", method: "POST", form: ["server": "1", "vars": "REGION=eu-2\nDSN=x\n"])
        #expect(written.text == "written: DSN, REGION" && transport.posts.suffix(2).map { $0["key"] as? String } == ["DSN", "REGION"])

        // An older (v1.1) panel: a read-only v1.2 wrapper's 404 is "not available".
        let older = try runner(RouteTransport(["GET /projects": [(200, Self.projects)]]), me: fixture("v11-me.json"))
        #expect(await older.run("branches", method: "GET", form: ["project": "9"]).text.contains("doesn't offer this yet"))
        #expect(await older.run("pg-databases", method: "GET", form: ["server": "1"]).text.contains("doesn't offer this yet"))
    }
}
