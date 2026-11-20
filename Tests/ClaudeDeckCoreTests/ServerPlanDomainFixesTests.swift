import Foundation
import Testing
@testable import ClaudeDeckCore

/// Root domains ("@" / "" subdomain) resolve and list by their bare base domain; slow domain and
/// database calls get 3 minutes; a `domain add` whose answer timed out but whose row exists counts
/// as created; `server ratelimit` (agent API 1.5). Never a real panel.
@Suite struct ServerPlanDomainFixesTests {
    /// Answers by "METHOD /path" in order (the last answer repeats); `nil` throws a timeout.
    private final class Transport: ServerPlanTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var replies: [String: [(Int, Data)?]]

        init(_ replies: [String: [(Int, String)?]]) {
            self.replies = replies.mapValues { $0.map { $0.map { ($0.0, Data($0.1.utf8)) } } }
        }

        var requests: [URLRequest] { lock.withLock { _requests } }
        func body(_ index: Int) -> [String: Any] {
            (requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        func timeout(of key: String) -> TimeInterval? {
            requests.first { "\($0.httpMethod ?? "GET") \($0.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: ""))" == key }?.timeoutInterval
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: "")
            let key = "\(request.httpMethod ?? "GET") \(path)"
            let reply: (Int, Data)?? = lock.withLock {
                _requests.append(request)
                guard var list = replies[key], !list.isEmpty else { return .some((404, Data(#"{"error":"not_found"}"#.utf8))) }
                let first = list.removeFirst()
                replies[key] = list.isEmpty ? [first] : list
                return .some(first)
            }
            guard let reply = reply ?? nil else { throw URLError(.timedOut) }
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

    static let me = #"{"user":{"id":1,"username":"medeni"},"scopes":["read","deploy","domains","dns","projects_write","databases"],"server_version":"1.5","features":["ratelimit"]}"#
    /// As the panel sends them: no `fqdn`; the static root with "@" (quick-static), one with "".
    static let domains = #"""
    [{"id":123,"server_id":1,"subdomain":"@","base_domain":"veilnum.com","type":"static","target":"/opt/static/veilnum-com","port":0},
     {"id":124,"server_id":1,"subdomain":"","base_domain":"quietext.com","type":"go_app","target":"quietext","port":8080,"project_name":"quietext"},
     {"id":125,"server_id":1,"subdomain":"api","base_domain":"quietext.com","type":"go_app","target":"quietext-api","port":8081,"project_name":"quietext-api"}]
    """#

    private func runner(_ transport: Transport, me: String? = Self.me, approve: Bool = false, asked: Box<[String]> = Box([])) throws -> ServerPlanCLI.Runner {
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
        let me = try me.map { try JSONDecoder().decode(ServerPlanMe.self, from: Data($0.utf8)) }
        var runner = ServerPlanCLI.Runner(client: client, me: me, approve: { command, target, summary in
            asked.value.append("\(command) \(target) | \(summary ?? "")")
            return approve
        })
        runner.retryDelay = .zero
        return runner
    }

    // MARK: Root domains

    @Test func rootDomainsResolveAndList() async throws {
        #expect(ServerPlanCLI.fqdn(["subdomain": "@", "base_domain": "veilnum.com"]) == "veilnum.com")
        #expect(ServerPlanCLI.fqdn(["subdomain": "", "base_domain": "veilnum.com"]) == "veilnum.com")
        #expect(ServerPlanCLI.fqdn(["subdomain": "api", "base_domain": "quietext.com"]) == "api.quietext.com")
        #expect(ServerPlanCLI.fqdn(["fqdn": "given.example", "subdomain": "x", "base_domain": "y.example"]) == "given.example")
        let folder = FileManager.default.temporaryDirectory.appending(path: "sp-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = Transport(["GET /domains": [(200, Self.domains)],
                                   "POST /domains/123/sync": [(200, #"{"success":true,"message":"Files synced to /opt/static/veilnum-com"}"#)]])
        let r = try runner(transport)
        let synced = await r.run("sync", method: "POST", form: ["domain": "veilnum.com", "path": folder.path])
        #expect(synced.exit == .ok && synced.text.contains("veilnum-com"))
        #expect(transport.timeout(of: "POST /domains/123/sync") == 180)
        let list = await r.run("domain-list", method: "GET", form: [:])
        #expect(list.text.contains("veilnum.com") && list.text.contains("api.quietext.com") && list.text.contains("static"))
        let rows = try #require(ServerPlanCLI.array(list.json))
        #expect(rows.map { ServerPlanCLI.value($0, "fqdn") } == ["veilnum.com", "quietext.com", "api.quietext.com"])
        // The bare root of a go_app domain ("" subdomain) resolves the same way.
        _ = await r.run("domain-apply", method: "POST", form: ["domain": "quietext.com"])
        #expect(transport.requests.last?.url?.path.hasSuffix("/domains/124/apply") == true)
        #expect(transport.timeout(of: "POST /domains/124/apply") == 180)
    }

    // MARK: Slow calls

    @Test func slowCallsGetThreeMinutes() {
        for (method, path) in [("POST", "/domains"), ("PUT", "/domains/5"), ("POST", "/domains/quick-static"), ("POST", "/domains/5/sync"),
                               ("POST", "/domains/5/apply"), ("POST", "/domains/5/deploy-nginx"), ("POST", "/projects/3/auto-create-db"),
                               ("POST", "/servers/1/pg/databases/app/clone"), ("POST", "/servers/1/pg/databases/app/clone-for-local"),
                               ("POST", "/domains/purchase"), ("POST", "/project-dirs/2/scan")] {
            #expect(ServerPlanCLI.slowCallTimeout(method: method, path: path) == 180, "\(method) \(path)")
        }
        for (method, path) in [("GET", "/domains"), ("POST", "/domains/5/purge-cache"), ("DELETE", "/domains/5"), ("POST", "/projects/3/deploy")] {
            #expect(ServerPlanCLI.slowCallTimeout(method: method, path: path) == nil, "\(method) \(path)")
        }
    }

    @Test func domainAddTimeoutButCreated() async throws {
        let created = #"[{"id":200,"server_id":1,"subdomain":"api","base_domain":"quietext.com","type":"go_app","target":"quietext-api","port":8081}]"#
        // Before: not there; the POST times out; the first look finds it.
        let transport = Transport(["GET /projects": [(200, #"[{"id":7,"display_name":"quietext-api","default_server_id":1}]"#)],
                                   "GET /projects/7/settings": [(200, #"{"default_server_id":1,"default_port":8081}"#)],
                                   "GET /domains": [(200, "[]"), (200, created)],
                                   "POST /domains": [nil]])
        let out = await (try runner(transport)).run("domain-add", method: "POST", form: ["project": "quietext-api", "subdomain": "api", "base": "quietext.com"])
        #expect(out.exit == .ok && out.text.contains("created; the panel answered slowly"))
        #expect(ServerPlanCLI.object(out.json)?["slow_answer"] as? Bool == true)
        #expect(transport.timeout(of: "POST /domains") == 180)
        // Not created after all: the timeout stands (exit 1, unreachable).
        let missing = Transport(["GET /servers": [(200, #"[{"id":1,"name":"prod"}]"#)], "GET /domains": [(200, "[]")], "POST /domains": [nil]])
        let failed = await (try runner(missing)).run("domain-add", method: "POST", form: ["static": "1", "server": "1", "subdomain": "docs", "base": "veilnum.com"])
        #expect(failed.exit == .failed && failed.text.contains("serverplan_unreachable"))
        #expect(missing.requests.filter { $0.httpMethod == "GET" }.count == 4)
        // There before the POST: a timeout isn't taken as "created".
        let existing = Transport(["GET /domains": [(200, Self.domains)], "POST /domains": [nil]])
        let stale = await (try runner(existing)).run("domain-add", method: "POST", form: ["static": "1", "server": "1", "subdomain": "@", "base": "veilnum.com"])
        #expect(stale.exit == .failed)
        // An answer in time is passed through as before.
        let quick = Transport(["GET /domains": [(200, "[]")], "POST /domains": [(201, #"{"id":201,"subdomain":"docs","base_domain":"veilnum.com"}"#)]])
        let fine = await (try runner(quick)).run("domain-add", method: "POST", form: ["static": "1", "server": "1", "subdomain": "docs", "base": "veilnum.com"])
        #expect(fine.exit == .ok && !fine.text.contains("slowly"))
    }

    // MARK: Rate limiting (1.5)

    @Test func rateLimitOfferedAndParsed() throws {
        let show = try #require(ServerPlanCLI.commands["ratelimit-show"]), set = try #require(ServerPlanCLI.commands["ratelimit-set"])
        let clear = try #require(ServerPlanCLI.commands["ratelimit-clear"])
        #expect(show.gate == .none && set.gate == .owner && clear.gate == .owner && set.scope == "dns" && show.scope == "read")
        func me(_ version: String?, features: [String] = [], scopes: [String] = ["read", "dns"]) -> ServerPlanMe {
            ServerPlanMe(user: "x", scopes: scopes, serverVersion: version, features: features)
        }
        #expect(ServerPlanCLI.offers(set, me: me("1.5")) && ServerPlanCLI.offers(set, me: me("1.4", features: ["ratelimit"])))
        #expect(!ServerPlanCLI.offers(set, me: me("1.4")) && !ServerPlanCLI.offers(set, me: me("1.5", scopes: ["read"])) && ServerPlanCLI.offers(show, me: me("1.5", scopes: ["read"])))
        #expect(try ServerPlanCLI.rateLimitRate(nil) == (20, 10) && ServerPlanCLI.rateLimitRate("100/1m") == (100, 60) && ServerPlanCLI.rateLimitRate("5/30s") == (5, 30))
        #expect(throws: (any Error).self) { try ServerPlanCLI.rateLimitRate("fast") }
        #expect(try ServerPlanCLI.rateLimitPaths(nil) == ["/init"] && ServerPlanCLI.rateLimitPaths("/init, /v1/*") == ["/init", "/v1/*"])
        #expect(throws: (any Error).self) { try ServerPlanCLI.rateLimitPaths(#"/x" or true"#) }
        #expect(throws: (any Error).self) { try ServerPlanCLI.rateLimitHost("not a host") }
        #expect(try ServerPlanCLI.rateLimitHost("API.Example.com") == "api.example.com")
    }

    static let rule = #"{"description":"serverplan: api.x.com /init","expression":"(http.host eq \"api.x.com\" and (http.request.uri.path eq \"/init\"))","action":"block","ratelimit":{"characteristics":["ip.src","cf.colo.id"],"period":10,"requests_per_period":20,"mitigation_timeout":10}}"#

    @Test func rateLimitShowSetClear() async throws {
        let transport = Transport([
            "GET /ratelimit": [(200, #"{"zone_rules":[\#(Self.rule)]}"#)],
            "POST /ratelimit": [(200, #"{"rule":\#(Self.rule)}"#)],
        ])
        let r = try runner(transport)
        let shown = await r.run("ratelimit-show", method: "GET", form: ["host": "api.x.com"])
        #expect(shown.exit == .ok && shown.text.contains("20 per 10s") && shown.text.contains("ip.src") && shown.text.contains("zone of x.com"))
        #expect(transport.requests[0].url?.query == "host=api.x.com")
        // No rule yet: set goes through without asking, with the defaults.
        let set = await r.run("ratelimit-set", method: "POST", form: ["host": "api.x.com", "paths": "", "rate": ""])
        #expect(set.exit == .ok && set.text.hasPrefix("set: serverplan: api.x.com /init"))
        let body = transport.body(1)
        #expect(body["paths"] as? [String] == ["/init"] && body["requests"] as? Int == 20 && body["period"] as? Int == 10 && body["confirm"] == nil)
        let empty = Transport(["GET /ratelimit": [(200, #"{"zone_rules":[]}"#)]])
        #expect(await (try runner(empty)).run("ratelimit-show", method: "GET", form: ["host": "x.com"]).text.contains("no rate-limit rule"))
    }

    @Test func rateLimitReplaceAndClearAskTheOwner() async throws {
        let gate = (428, #"{"error":"confirm_required","message":"Onay gerekli","summary":"zone'daki mevcut rate-limit kurali degisecek","confirm":"api.x.com"}"#)
        let transport = Transport(["POST /ratelimit": [gate, gate, (200, #"{"rule":\#(Self.rule)}"#)],
                                   "POST /ratelimit/clear": [(428, #"{"error":"confirm_required","summary":"kaldirilacak","confirm":"api.x.com"}"#), (200, #"{"cleared":true}"#)]])
        let asked = Box<[String]>([])
        let refused = await (try runner(transport, asked: asked)).run("ratelimit-set", method: "POST",
                                                                       form: ["host": "api.x.com", "paths": "/init,/v1/*", "rate": "100/1m"])
        #expect(refused.exit == .refused && asked.value == ["ratelimit-set api.x.com | zone'daki mevcut rate-limit kurali degisecek"])
        #expect(transport.requests.count == 1 && transport.body(0)["paths"] as? [String] == ["/init", "/v1/*"] && transport.body(0)["period"] as? Int == 60)
        let approved = await (try runner(transport, approve: true)).run("ratelimit-set", method: "POST", form: ["host": "api.x.com"])
        #expect(approved.exit == .ok && transport.body(2)["confirm"] as? String == "api.x.com")
        let cleared = await (try runner(transport, approve: true)).run("ratelimit-clear", method: "POST", form: ["host": "api.x.com"])
        #expect(cleared.exit == .ok && cleared.text.contains("cleared") && transport.body(4)["confirm"] as? String == "api.x.com")
    }

    @Test func rateLimitRefusalsWithHints() async throws {
        let cases: [(Int, String, Int, SessionCLI.Exit, String)] = [
            (412, #"{"error":"not_configured","message":"Cloudflare token ayarli degil"}"#, 412, .refused, "Entegrasyonlar › Cloudflare"),
            (404, #"{"error":"not_found","message":"Cloudflare zone bulunamadi: x"}"#, 404, .unknown, "zone add x.com"),
            (400, #"{"error":"bad_request","message":"gecersiz path"}"#, 400, .usage, "paths like /init"),
            (502, #"{"error":"cloudflare_error","message":"Authentication error (10000)"}"#, 502, .failed, "Zone WAF › Edit"),
        ]
        for (status, body, expected, exit, hint) in cases {
            let transport = Transport(["GET /ratelimit": [(status, body)]])
            let out = await (try runner(transport)).run("ratelimit-show", method: "GET", form: ["host": "api.x.com"])
            #expect(out.status == expected && out.exit == exit && out.text.contains(hint), "\(status)")
        }
        // An older panel without the route.
        let old = Transport([:])
        let missing = await (try runner(old)).run("ratelimit-show", method: "GET", form: ["host": "api.x.com"])
        #expect(missing.status == 501)
        let bad = await (try runner(old)).run("ratelimit-set", method: "POST", form: ["host": "api.x.com", "rate": "lots"])
        #expect(bad.exit == .usage && old.requests.count == 1)
    }
}
