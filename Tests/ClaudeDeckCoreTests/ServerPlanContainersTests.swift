import Foundation
import Testing
@testable import ClaudeDeckCore

/// Containers and server resources (ServerPlanContainers.swift, ServerPlanCLIContainers.swift):
/// parsing what a 1.4 panel sends and the proposed 1.5 shapes, the container ↔ project ↔ domain
/// rule, log search, and the `claudedeck server` commands with their gates. Never a real panel.
@Suite struct ServerPlanContainersTests {
    /// Answers by "METHOD /path" in order (the last answer repeats) and records every request.
    private final class Transport: ServerPlanTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var replies: [String: [(Int, Data)]]

        init(_ replies: [String: [(Int, String)]]) {
            self.replies = replies.mapValues { $0.map { ($0.0, Data($0.1.utf8)) } }
        }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var keys: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: ""))" } }
        func body(_ index: Int) -> [String: Any] {
            (requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path.replacingOccurrences(of: ServerPlanContract.basePath, with: "")
            let key = "\(request.httpMethod ?? "GET") \(path)"
            let reply: (Int, Data) = lock.withLock {
                _requests.append(request)
                guard var list = replies[key], !list.isEmpty else { return (404, Data(#"{"error":"not_found","message":"Bulunamadi"}"#.utf8)) }
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

    static let servers = #"[{"id":1,"name":"prod-eu-1","status":"online"},{"id":2,"name":"staging","status":"online"}]"#
    static let containers = #"""
    [{"name":"acme-storefront","image":"acme-storefront:205","state":"running","status":"Up 2 hours (healthy)","ports":"0.0.0.0:3000->3000/tcp"},
     {"name":"payments-api","image":"payments-api:207","state":"exited","status":"Exited (1) 29 minutes ago","ports":""},
     {"name":"nginx-docs-example-com","image":"nginx:alpine","state":"running","status":"Up 3 days","ports":""}]
    """#
    static let projects = #"[{"id":11,"display_name":"payments-api","default_server_id":1},{"id":12,"display_name":"Acme-Storefront","default_server_id":1}]"#
    static let domains = #"""
    [{"id":5,"server_id":1,"subdomain":"shop","base_domain":"acme.example","type":"go_app","target":"acme-storefront","port":3000,"project_name":"Acme-Storefront"},
     {"id":6,"server_id":1,"subdomain":"","base_domain":"acme.example","type":"go_app","target":"","port":3000,"project_name":"acme-storefront"},
     {"id":7,"server_id":1,"subdomain":"docs","base_domain":"example.com","type":"static","target":"/opt/static/docs-example-com"},
     {"id":8,"server_id":2,"subdomain":"shop","base_domain":"staging.example","type":"go_app","target":"acme-storefront"}]
    """#
    static let me14 = #"{"user":{"id":1,"username":"medeni"},"scopes":["read","logs","containers","projects_write"],"server_version":"1.4","features":["env","domains","log_stream"]}"#
    static let me15 = #"{"user":{"id":1,"username":"medeni"},"scopes":["read","logs","containers","projects_write"],"server_version":"1.5","features":["env","domains","log_stream","container_details","container_inspect","container_stats","server_stats","log_query","container_exec","container_recreate","image_update","container_remove","docker_prune"]}"#

    private func client(_ transport: Transport) -> ServerPlanClient {
        ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_test"), transport: transport)
    }

    private func runner(_ transport: Transport, me: String? = Self.me14, approve: Bool = false, asked: Box<[String]> = Box([]),
                        log: Box<[String]> = Box([])) throws -> ServerPlanCLI.Runner {
        let me = try me.map { try JSONDecoder().decode(ServerPlanMe.self, from: Data($0.utf8)) }
        return ServerPlanCLI.Runner(client: client(transport), me: me, approve: { command, target, summary in
            asked.value.append("\(command) \(target) | \(summary ?? "")")
            return approve
        }, log: { log.value.append($0) })
    }

    // MARK: Parsing

    @Test func containerDetailsFromStatusAndFields() throws {
        let list = try ServerPlanClient.decode([ServerPlanContainer].self, from: Data(Self.containers.utf8))
        let shop = list[0], payments = list[1]
        #expect(shop.health == .healthy && shop.uptime == "2 hours" && shop.condition == .running && shop.exitCode == nil)
        #expect(shop.portList == ["3000→3000/tcp"] && shop.imageTag == "205" && shop.containerID == nil && shop.domains == nil)
        #expect(payments.exitCode == 1 && payments.condition == .failed && payments.condition.isProblem && payments.uptime == nil && payments.portList.isEmpty)
        // 1.5 fields where the panel sends them; the old shape still reads.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/serverplan/containers-1.json")
        let fixture = try ServerPlanClient.decode([ServerPlanContainer].self, from: Data(contentsOf: url))
        let rich = try #require(fixture.first { $0.name == "acme-storefront" })
        #expect(rich.containerID == "3f2a9c1b7d4e" && rich.projectID == 12 && rich.domains == ["shop.acme.example"])
        #expect(rich.health == ServerPlanContainerHealth.healthy && rich.portList == ["3000→3000/tcp"])
        let postgres = try #require(fixture.first { $0.name == "postgres" })
        #expect(postgres.health == ServerPlanContainerHealth.unhealthy && postgres.condition == ServerPlanContainerCondition.unhealthy)
        #expect(postgres.portList == ["5432/tcp"] && postgres.projectID == nil)
        let starting = ServerPlanContainer(name: "x", state: "running", status: "Up 3 seconds (health: starting)")
        #expect(starting.health == .starting && starting.condition == .starting)
        #expect(ServerPlanContainer(name: "x", state: "restarting", status: "Restarting (1) 5 seconds ago").condition == .restarting)
        #expect(ServerPlanContainer(name: "x", state: "exited", status: "Exited (0) 2 days ago").condition == .stopped)
        #expect(ServerPlanContainer(name: "x", image: "ghcr.io/acme/web").imageTag == nil)
    }

    @Test func serverNumbersFromStringsAndFields() throws {
        let old = try ServerPlanClient.decode(ServerPlanHealth.self, from: Data(#"{"reachable":true,"cpu":"4.2%","memory":"4.7Gi/61Gi","disk":"120G/437G (29%)","load_avg":"0.91 0.74 0.66"}"#.utf8))
        let sample = ServerPlanServerSample(old)
        #expect(sample.cpuPercent == 4.2 && sample.diskPercent == 29 && sample.load1 == 0.91)
        #expect(abs((sample.memPercent ?? 0) - 4.7 / 61 * 100) < 0.01 && sample.netRxBytes == nil)
        let new = try ServerPlanClient.decode(ServerPlanHealth.self, from: Data(#"""
        {"reachable":true,"cpu":"12.3%","cpu_percent":12.3,"cores":4,"mem_used_bytes":1000,"mem_total_bytes":4000,"disk_used_bytes":25,"disk_total_bytes":100,"load1":0.5,"net_rx_bytes":"2048","net_tx_bytes":1024}
        """#.utf8))
        let numbers = ServerPlanServerSample(new)
        #expect(numbers.cpuPercent == 12.3 && numbers.memPercent == 25 && numbers.diskPercent == 25 && numbers.load1 == 0.5)
        #expect(numbers.netRxBytes == 2048 && numbers.netTxBytes == 1024 && new.cores == 4)
        // free -h without the "i", df without the percentage.
        let plain = ServerPlanServerSample(ServerPlanHealth(cpu: "50%", memory: "1.0G/4.0G", disk: "10G/40G"))
        #expect(plain.memPercent == 25 && plain.diskPercent == 25 && plain.cpuPercent == 50)
    }

    @Test func byteSizes() {
        #expect(ByteSize.parse("150MiB") == Double(150 * 1024 * 1024))
        #expect(ByteSize.parse("12.6MB") == 12_600_000)
        #expect(ByteSize.parse("0B") == 0 && ByteSize.parse("4.1kB") == 4100 && ByteSize.parse("2Gi") == 2 * 1024 * 1024 * 1024)
        #expect(ByteSize.parse("lots") == nil && ByteSize.parse("3 parsecs") == nil)
        let pair = ByteSize.pair("150MiB / 3.84GiB")
        #expect(pair?.used == 150 * 1024 * 1024 && pair.map { $0.total > 4e9 } == true)
        #expect(ByteSize.pair("120G/437G (29%)")?.total == Double(437 * 1024 * 1024 * 1024))
    }

    @Test func containerStatsBothShapes() throws {
        let numbers = try ServerPlanClient.decode([ServerPlanContainerStats].self, from: Data(#"""
        [{"name":"api","cpu_percent":1.85,"mem_used_bytes":157286400,"mem_limit_bytes":4123000000,"mem_percent":3.81,"net_rx_bytes":12582912,"net_tx_bytes":3145728,"block_read_bytes":0,"block_write_bytes":4096,"pids":11}]
        """#.utf8))
        #expect(numbers[0].cpuPercent == 1.85 && numbers[0].pids == 11 && numbers[0].memPercent == 3.81 && numbers[0].blockWriteBytes == 4096)
        // docker's display strings (the panel's GetContainerStats today).
        let strings = try ServerPlanClient.decode(ServerPlanContainerStats.self, from: Data(#"{"name":"api","cpu":"1.85%","mem":"150MiB / 600MiB","net":"12.6MB / 3.1MB","block":"0B / 4.1kB"}"#.utf8))
        #expect(strings.cpuPercent == 1.85 && strings.memPercent == 25 && strings.netRxBytes == 12_600_000 && strings.blockWriteBytes == 4100)
    }

    @Test func inspectAndDisk() throws {
        let inspect = try ServerPlanClient.decode(ServerPlanContainerInspect.self, from: Data(#"""
        {"name":"api","started_at":"2026-11-20T09:12:04.123456789Z","finished_at":"0001-01-01T00:00:00Z","restart_count":3,"restart_policy":"unless-stopped",
         "oom_killed":false,"networks":["traefik-network"],"mounts":[{"source":"/opt/volumes/api","destination":"/data","rw":true}],"env_keys":["PORT","DATABASE_URL"],"env":{"PORT":"3000"}}
        """#.utf8))
        #expect(inspect.restartCount == 3 && inspect.startedAt != nil && inspect.finishedAt == nil && inspect.mounts.first?.destination == "/data")
        #expect(inspect.envKeys == ["PORT", "DATABASE_URL"])
        let disk = try ServerPlanClient.decode(ServerPlanDockerDisk.self, from: Data(#"""
        {"images":{"count":12,"active":4,"size_bytes":5000,"reclaimable_bytes":3000},"volumes":{"count":2,"active":1,"size_bytes":900,"reclaimable_bytes":400},
         "build_cache":{"count":30,"active":0,"size_bytes":700,"reclaimable_bytes":700}}
        """#.utf8))
        #expect(disk.containers.count == 0 && disk.reclaimable(ServerPlanPruneOptions()) == 3700)
        #expect(disk.reclaimable(ServerPlanPruneOptions(images: .none, containers: false, volumes: true, buildCache: false)) == 400)
    }

    @Test func envSecretsNeverKept() throws {
        let env = try ServerPlanClient.decode([ServerPlanEnvVar].self, from: Data(#"[{"id":1,"key":"DB_NAME","value":"x","is_secret":false},{"id":2,"key":"API_KEY","value":"leaked","is_secret":true}]"#.utf8))
        #expect(env[0].value == "x" && env[1].value == nil && env[1].envID == 2)
    }

    // MARK: Containers, projects, domains

    @Test func containerToProjectAndDomains() throws {
        let containers = try ServerPlanClient.decode([ServerPlanContainer].self, from: Data(Self.containers.utf8))
        let projects = try ServerPlanClient.decode([ServerPlanProject].self, from: Data(Self.projects.utf8))
        let domains = try ServerPlanClient.decode([ServerPlanDomain].self, from: Data(Self.domains.utf8))
        let shop = containers[0], payments = containers[1], docs = containers[2]
        // By target and by project_name; the other server's domain isn't this container's.
        #expect(ServerPlanContainerMatch.domains(for: shop, serverID: 1, in: domains) == ["acme.example", "shop.acme.example"])
        #expect(ServerPlanContainerMatch.domains(for: shop, serverID: 2, in: domains) == ["shop.staging.example"])
        #expect(ServerPlanContainerMatch.domains(for: docs, serverID: 1, in: domains) == ["docs.example.com"])
        #expect(ServerPlanContainerMatch.project(for: shop, serverID: 1, projects: projects, domains: domains)?.id == 12)
        #expect(ServerPlanContainerMatch.project(for: payments, serverID: 1, projects: projects, domains: domains)?.id == 11)
        #expect(ServerPlanContainerMatch.project(for: docs, serverID: 1, projects: projects, domains: domains) == nil)
        // The panel's own answer wins.
        var given = shop
        given.projectID = 11
        given.domains = ["x.example"]
        #expect(ServerPlanContainerMatch.project(for: given, serverID: 1, projects: projects, domains: domains)?.id == 11)
        #expect(ServerPlanContainerMatch.domains(for: given, serverID: 1, in: domains) == ["x.example"])
        // Older fixtures: only an FQDN.
        let old = try ServerPlanClient.decode(ServerPlanDomain.self, from: Data(#"{"id":5,"fqdn":"api.example.com","server_id":2,"project_name":"new-api","port":6079}"#.utf8))
        #expect(old.fqdn == "api.example.com" && old.baseDomain == "example.com")
    }

    // MARK: Logs

    @Test func logSeverityAndFilter() {
        #expect(ServerPlanLogSeverity.of("2026/11/20 panic: runtime error: nil map") == .error)
        #expect(ServerPlanLogSeverity.of(#"{"level":"error","msg":"db down"}"#) == .error)
        #expect(ServerPlanLogSeverity.of("Traceback (most recent call last):") == .error)
        #expect(ServerPlanLogSeverity.of("WARN slow query 1.2s") == .warning)
        #expect(ServerPlanLogSeverity.of("GET /health 200 2ms") == .normal)
        #expect(ServerPlanLogSeverity.of("build finished with 0 errors") == .normal)
        #expect(ServerPlanLogSeverity.of("terrors and mirrors") == .normal)
        let lines = ["GET /health 200", "ERROR db down", "warn: retry", "GET /api 500 failed"]
        #expect(lines.filter(ServerPlanLogFilter(query: "get").matches) == ["GET /health 200", "GET /api 500 failed"])
        #expect(lines.filter(ServerPlanLogFilter(errorsOnly: true).matches) == ["ERROR db down", "GET /api 500 failed"])
        #expect(lines.filter(ServerPlanLogFilter(query: "re: /(health|api) [25]00").matches).count == 2)
        let broken = ServerPlanLogFilter(query: "re: (")
        #expect(broken.invalidRegex && lines.filter(broken.matches).isEmpty)
        #expect(ServerPlanLogFilter.grep(lines, "DB") == ["ERROR db down"] && ServerPlanLogFilter.grep(lines, "") == lines)
    }

    @Test func seriesAndRates() {
        var series = MetricSeries(capacity: 3)
        for value in [1.0, 2, 3, 4] { series.append(value) }
        series.append(nil)
        series.append(.nan)
        #expect(series.values == [2, 3, 4] && series.peak == 4 && series.last == 4)
        var rate = CounterRate()
        let start = Date()
        #expect(rate.rate(1000, at: start) == nil)
        #expect(rate.rate(3000, at: start.addingTimeInterval(10)) == 200)
        // A reset (the server rebooted) gives no rate, then counting goes on.
        #expect(rate.rate(10, at: start.addingTimeInterval(20)) == nil)
        #expect(rate.rate(110, at: start.addingTimeInterval(30)) == 10)
    }

    @Test func repairPrompt() {
        let lines = (1...250).map { "line \($0)" }
        let prompt = ContainerLogRepair.prompt(container: "api", server: "prod", image: "api:12", project: "api", status: "Exited (1)", lines: lines)
        #expect(prompt.contains("api on the server prod") && prompt.contains("ServerPlan project api") && prompt.contains("Exited (1)"))
        #expect(prompt.contains("line 250") && !prompt.contains("line 50\n") && prompt.contains("Don't deploy"))
    }

    // MARK: Actions on the wire

    @Test func actionPathsMethodsAndConfirm() async throws {
        let transport = Transport([
            "DELETE /servers/1/containers/api": [(428, #"{"error":"confirm_required","summary":"api silinir","confirm":"api"}"#), (200, #"{"success":true}"#)],
            "POST /servers/1/docker/prune": [(428, #"{"error":"confirm_required","summary":"1.2 GB","confirm":"prod"}"#),
                                             (200, #"{"success":true,"reclaimed_bytes":1200000000}"#)],
            "POST /servers/1/containers/api/pull": [(200, #"{"success":true,"updated":false}"#)],
            "DELETE /projects/12/env/7": [(428, #"{"error":"confirm_required","summary":"API_KEY silinir","confirm":"API_KEY"}"#)],
        ])
        let c = client(transport)
        let remove = ServerPlanAction.containerOp(serverID: 1, serverName: "prod", name: "api", op: .remove)
        #expect(try await c.preview(remove).expected == "api")
        #expect(try await c.perform(#require(ServerPlanConfirmation(remove, expected: "api"))) == .done)
        #expect(transport.keys[0] == "DELETE /servers/1/containers/api" && transport.body(0)["confirm"] == nil && transport.body(1)["confirm"] as? String == "api")
        let prune = ServerPlanAction.prune(serverID: 1, serverName: "prod", options: ServerPlanPruneOptions(images: .unused, volumes: true))
        #expect(prune.confirmTarget == "prod")
        let preview = try await c.preview(prune)
        let result = try await c.perform(#require(ServerPlanConfirmation(prune, expected: preview.expected)))
        #expect(result == .answer(["reclaimed_bytes": "1200000000"]))
        #expect(transport.body(2)["images"] as? String == "unused" && transport.body(2)["volumes"] as? Bool == true && transport.body(2)["confirm"] == nil)
        #expect(transport.body(3)["confirm"] as? String == "prod" && transport.body(3)["build_cache"] as? Bool == true)
        let pull = ServerPlanAction.containerOp(serverID: 1, serverName: "prod", name: "api", op: .pull)
        #expect(try await c.perform(#require(ServerPlanConfirmation(pull))) == .answer(["updated": "false"]))
        let env = ServerPlanAction.envDelete(projectID: 12, projectName: "shop", envID: 7, key: "API_KEY")
        #expect(try await c.preview(env).summary == "API_KEY silinir" && env.confirmTarget == "API_KEY")
        // A container name the panel would refuse never leaves the Mac.
        await #expect(throws: ServerPlanError.self) {
            try await c.preview(.containerOp(serverID: 1, serverName: "prod", name: "../x", op: .recreate))
        }
    }

    @Test func execTicketNamesTheContainer() async throws {
        let transport = Transport(["POST /ws-ticket": [(200, #"{"ticket":"t1","expires_in":60,"url":"/api/v1/agent/ws/terminal?ticket=t1"}"#)]])
        _ = try await client(transport).terminalTicket(serverID: 1, cols: 80, rows: 24, command: .exec, container: "api")
        #expect(transport.body(0)["command"] as? String == "exec" && transport.body(0)["container"] as? String == "api")
        _ = try await client(transport).terminalTicket(serverID: 1, cols: 80, rows: 24)
        #expect(transport.body(1)["container"] == nil && transport.body(1)["command"] as? String == "shell")
        #expect(ServerPlanTerminalTarget(serverID: 1, serverName: "p", container: "api").command == .exec)
        #expect(ServerPlanTerminalTarget(serverID: 1, serverName: "p", runClaude: true).command == .claude)
        // Saved before containers existed: decodes as a server shell.
        let old = try JSONDecoder().decode(ServerPlanTerminalTarget.self, from: Data(#"{"serverID":1,"serverName":"p","runClaude":false}"#.utf8))
        #expect(old.container == nil && old.command == .shell)
    }

    // MARK: The phone

    @Test func phoneMessagesRoundTrip() throws {
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.serverPlanContainers))
        let row = RemoteServerPlan.Container(name: "api", condition: "unhealthy", status: "Up 2 hours (unhealthy)", image: "api:3",
                                             domains: ["api.example.com"], cpuPercent: 1.5)
        #expect(row.isRunning && !RemoteServerPlan.Container(name: "x", condition: "failed", status: nil, image: nil).isRunning)
        for message in [RemoteMessage.serverPlanContainersRequest(serverID: 1, logsOf: "api"),
                        .serverPlanContainers(serverID: 1, containers: [row], logsOf: "api", logs: ["ERROR x"], error: nil),
                        .serverPlanContainerAction(serverID: 1, container: "api", verb: "restart"),
                        .serverPlanContainerActionResult(serverID: 1, container: "api", verb: "restart", error: "Not approved on the Mac.")] {
            #expect(try RemoteMessage.decode(message.frame()) == message)
        }
        #expect(RemoteServerPlan.isValidContainerName("api_1.web") && !RemoteServerPlan.isValidContainerName("../etc") && !RemoteServerPlan.isValidContainerName(""))
        #expect(RemoteServerPlan.containerVerbs == ["start", "stop", "restart"])
    }

    // MARK: The CLI table

    @Test func gatesAndOffers() throws {
        let me14 = try JSONDecoder().decode(ServerPlanMe.self, from: Data(Self.me14.utf8))
        let me15 = try JSONDecoder().decode(ServerPlanMe.self, from: Data(Self.me15.utf8))
        let gated = ["container-stats", "container-recreate", "container-pull", "container-remove", "disk", "prune"]
        for name in gated {
            let command = try #require(ServerPlanCLI.commands[name])
            #expect(command.featureOnly && !ServerPlanCLI.offers(command, me: me14) && ServerPlanCLI.offers(command, me: me15), "\(name)")
            // A version alone never offers them; nor does an unknown panel.
            #expect(!ServerPlanCLI.offers(command, me: ServerPlanMe(user: "x", scopes: me15.scopes, serverVersion: "9.0")), "\(name)")
            #expect(!ServerPlanCLI.offers(command, me: nil), "\(name)")
        }
        for name in ["container-recreate", "container-pull", "container-remove", "prune"] {
            #expect(ServerPlanCLI.commands[name]?.gate == .owner && ServerPlanCLI.commands[name]?.method == "POST", "\(name)")
        }
        for name in ["container-inspect", "stats", "container-env"] {
            let command = try #require(ServerPlanCLI.commands[name])
            #expect(command.gate == .none && command.method == "GET" && ServerPlanCLI.offers(command, me: me14), "\(name)")
        }
        #expect(ServerPlanCLI.commands["container"]?.gate == .owner)
        // The prune needs the containers scope, like the panel.
        let noScope = ServerPlanMe(user: "x", scopes: ["read"], serverVersion: "1.5", features: me15.features)
        #expect(!ServerPlanCLI.offers(ServerPlanCLI.commands["prune"]!, me: noScope) && ServerPlanCLI.offers(ServerPlanCLI.commands["disk"]!, me: noScope))
        #expect(ServerPlanCLI.isValidSince("10m") && ServerPlanCLI.isValidSince("2026-11-20T10:00:00Z") && !ServerPlanCLI.isValidSince("yesterday"))
    }

    @Test func inspectOnA14Panel() async throws {
        let transport = Transport(["GET /servers": [(200, Self.servers)], "GET /servers/1/containers": [(200, Self.containers)],
                                   "GET /domains": [(200, Self.domains)], "GET /projects": [(200, Self.projects)]])
        let r = try runner(transport)
        let out = await r.run("container-inspect", method: "GET", form: ["server": "prod-eu-1", "container": "acme-storefront"])
        #expect(out.exit == .ok)
        #expect(out.text.contains("state: running (healthy)") && out.text.contains("up: 2 hours") && out.text.contains("domains: acme.example, shop.acme.example"))
        #expect(out.text.contains("project: Acme-Storefront (#12)") && out.text.contains("ports: 3000→3000/tcp"))
        let json = try #require(ServerPlanCLI.object(out.json))
        #expect(json["project_id"] as? Int == 12 && json["condition"] as? String == "running" && json["inspect"] == nil)
        // No panel inspect call without the feature.
        #expect(!transport.keys.contains("GET /servers/1/containers/acme-storefront"))
        let unknown = await r.run("container-inspect", method: "GET", form: ["server": "1", "container": "nope"])
        #expect(unknown.exit == .unknown && unknown.text.contains("acme-storefront"))
        let bad = await r.run("container-inspect", method: "GET", form: ["server": "1", "container": "a b"])
        #expect(bad.exit == .usage)
    }

    @Test func inspectWithThePanels() async throws {
        let transport = Transport(["GET /servers": [(200, Self.servers)], "GET /servers/1/containers": [(200, Self.containers)],
                                   "GET /domains": [(200, Self.domains)], "GET /projects": [(200, Self.projects)],
                                   "GET /servers/1/containers/payments-api": [(200, #"{"name":"payments-api","restart_count":7,"oom_killed":true,"env_keys":["PORT"]}"#)]])
        let out = await (try runner(transport, me: Self.me15)).run("container-inspect", method: "GET", form: ["server": "1", "container": "payments-api"])
        #expect(out.text.contains("restarts: 7") && out.text.contains("oom killed: yes") && out.text.contains("state: exited, exit code 1"))
        #expect((ServerPlanCLI.object(out.json)?["inspect"] as? [String: Any])?["restart_count"] as? Int == 7)
    }

    @Test func containerEnvGoesThroughItsProject() async throws {
        let transport = Transport(["GET /servers": [(200, Self.servers)], "GET /servers/1/containers": [(200, Self.containers)],
                                   "GET /domains": [(200, Self.domains)], "GET /projects": [(200, Self.projects)],
                                   "GET /projects/12/env": [(200, #"[{"id":1,"key":"PORT","value":"3000","is_secret":false},{"id":2,"key":"API_KEY","value":"leaked","is_secret":true}]"#)]])
        let r = try runner(transport)
        let out = await r.run("container-env", method: "GET", form: ["server": "1", "container": "acme-storefront"])
        #expect(out.exit == .ok && out.text.contains("PORT") && out.text.contains("(secret)") && !out.text.contains("leaked"))
        #expect(!String(decoding: out.json, as: UTF8.self).contains("leaked"))
        let none = await r.run("container-env", method: "GET", form: ["server": "1", "container": "nginx-docs-example-com"])
        #expect(none.exit == .unknown && none.text.contains("no_project"))
    }

    @Test func logsGrepHereSinceOnlyOnThePanel() async throws {
        let text = "GET /health 200\nERROR db down\nGET /api 200\n"
        let transport = Transport(["GET /servers/1/containers/api/logs": [(200, text)]])
        let old = try runner(transport)
        let grep = await old.run("logs", method: "GET", form: ["server": "1", "container": "api", "tail": "100", "grep": "error"])
        #expect(grep.text == "ERROR db down" && transport.requests.last?.url?.query?.contains("grep") == false)
        let since = await old.run("logs", method: "GET", form: ["server": "1", "container": "api", "since": "10m"])
        #expect(since.status == 501 && since.exit == .refused && transport.requests.count == 1)
        // A log_query panel filters itself.
        let new = try runner(transport, me: Self.me15)
        let both = await new.run("logs", method: "GET", form: ["server": "1", "container": "api", "tail": "50", "since": "10m", "grep": "db"])
        let query = transport.requests.last?.url?.query ?? ""
        #expect(both.exit == .ok && query.contains("since=10m") && query.contains("grep=db") && query.contains("tail=50"))
        let bad = await new.run("logs", method: "GET", form: ["server": "1", "container": "api", "since": "yesterday"])
        #expect(bad.exit == .usage)
    }

    @Test func serverStatsWithAndWithoutContainers() async throws {
        let health = #"{"reachable":true,"docker_ok":true,"cpu":"4.2%","memory":"1.0G/4.0G","disk":"9G/40G (22%)","load_avg":"0.10 0.20 0.30"}"#
        let transport = Transport(["GET /servers": [(200, Self.servers)], "GET /servers/1/health": [(200, health)],
                                   "GET /servers/1/containers/stats": [(200, #"[{"name":"api","cpu_percent":1.5,"mem_used_bytes":1048576,"mem_limit_bytes":4194304,"pids":3}]"#)]])
        let old = await (try runner(transport)).run("stats", method: "GET", form: ["server": "prod-eu-1"])
        #expect(old.exit == .ok && old.text.contains("cpu: 4.2%") && old.text.contains("mem: 25.0%") && old.text.contains("disk: 22.0%"))
        #expect(old.text.contains("container_stats") && !transport.keys.contains("GET /servers/1/containers/stats"))
        let new = await (try runner(transport, me: Self.me15)).run("stats", method: "GET", form: ["server": "1"])
        #expect(new.text.contains("NAME") && new.text.contains("api") && new.text.contains("1.5%") && new.text.contains("25.0%"))
    }

    @Test func gatedContainerActionsAskTheOwner() async throws {
        let gate = (428, #"{"error":"confirm_required","summary":"api @ prod-eu-1: yeniden olusturulur","confirm":"api"}"#)
        let transport = Transport(["GET /servers": [(200, Self.servers)],
                                   "POST /servers/1/containers/api/recreate": [gate, gate, (200, #"{"success":true,"id":"9a8b"}"#)]])
        // Not offered by a 1.4 panel: nothing is sent.
        let old = await (try runner(transport)).run("container-recreate", method: "POST", form: ["server": "1", "container": "api"])
        #expect(old.status == 501 && transport.requests.isEmpty)
        // Refused: no second (confirmed) call.
        let asked = Box<[String]>([]), log = Box<[String]>([])
        let refused = await (try runner(transport, me: Self.me15, approve: false, asked: asked, log: log)).run("container-recreate", method: "POST",
                                                                                                             form: ["server": "prod-eu-1", "container": "api"])
        #expect(refused.exit == .refused && refused.text.contains("owner_refused"))
        #expect(asked.value == ["container recreate api | api @ prod-eu-1: yeniden olusturulur"])
        #expect(transport.keys.filter { $0.hasPrefix("POST") }.count == 1)
        // Approved: sent again with the confirmation.
        let approved = await (try runner(transport, me: Self.me15, approve: true, log: log)).run("container-recreate", method: "POST",
                                                                                                form: ["server": "1", "container": "api"])
        #expect(approved.exit == .ok && approved.text.contains("recreate api on prod-eu-1"))
        let posts = transport.requests.enumerated().filter { $0.element.httpMethod == "POST" }
        #expect(posts.count == 3 && transport.body(posts[2].offset)["confirm"] as? String == "api")
        #expect(log.value.contains { $0.contains("refused") } && log.value.contains { $0.contains("approved by the owner") })
    }

    @Test func pruneAsksWithTheServerName() async throws {
        let transport = Transport(["GET /servers": [(200, Self.servers)],
                                   "POST /servers/2/docker/prune": [(428, #"{"error":"confirm_required","summary":"staging: 3.1 GB silinir","confirm":"staging"}"#),
                                                                    (200, #"{"success":true,"reclaimed_bytes":3100000000}"#)]])
        let asked = Box<[String]>([])
        let out = await (try runner(transport, me: Self.me15, approve: true, asked: asked)).run("prune", method: "POST",
            form: ["server": "staging", "images": "unused", "volumes": "0", "build_cache": "1", "containers": "1"])
        #expect(out.exit == .ok && out.text.contains("reclaimed") && asked.value.first?.hasPrefix("prune staging") == true)
        #expect(transport.body(1)["images"] as? String == "unused" && transport.body(2)["confirm"] as? String == "staging"
            && transport.body(2)["volumes"] as? Bool == false)
    }
}
