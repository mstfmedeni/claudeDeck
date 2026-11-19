import Foundation
import Testing
@testable import ClaudeDeckCore

/// Records requests and answers from a script, instead of the network.
private final class StubTransport: ServerPlanTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> Reply

    init(_ respond: @escaping @Sendable (URLRequest) -> Reply) { self.respond = respond }

    var requests: [URLRequest] { lock.withLock { _requests } }

    private func reply(_ request: URLRequest) -> (Reply, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let reply = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply, response)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (reply, response) = reply(request)
        return (reply.body, response)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (reply, response) = reply(request)
        // Odd-sized chunks: lines and events split across them.
        let body = reply.body
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            var index = 0
            while index < body.count {
                let end = min(index + 7, body.count)
                continuation.yield(body.subdata(in: index..<end))
                index = end
            }
            continuation.finish()
        }
        return (response, stream)
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/serverplan/\(name)")
    return try Data(contentsOf: url)
}

private let config = ServerPlanConfig(baseURL: URL(string: "http://127.0.0.1:5099")!, token: "spk_7_s3cret")

private func json(_ request: URLRequest) -> [String: Any] {
    (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

@Suite struct ServerPlanClientTests {
    // MARK: Config and auth

    @Test func configFromTypedAddress() {
        #expect(ServerPlanConfig(address: " 127.0.0.1:5050/ ", token: "t")?.baseURL.absoluteString == "http://127.0.0.1:5050")
        #expect(ServerPlanConfig(address: "https://panel.example/sp", token: "t")?.baseURL.absoluteString == "https://panel.example/sp")
        #expect(ServerPlanConfig(address: "", token: "t") == nil)
        #expect(ServerPlanConfig(address: "http://127.0.0.1:5050", token: "  ") == nil)
        #expect(ServerPlanConfig(address: "ftp://x", token: "t") == nil)
    }

    @Test func everyRequestCarriesTheBearerToken() async throws {
        let transport = StubTransport { _ in .init(status: 200, body: try! fixture("me.json")) }
        let client = ServerPlanClient(config: config, transport: transport)
        let me = try await client.me()
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer spk_7_s3cret")
        #expect(request.url?.absoluteString == "http://127.0.0.1:5099/api/v1/agent/me")
        #expect(me.user == "demo")
        #expect(me.allows(.terminal))
        #expect(me.has(feature: ServerPlanContract.Feature.terminalClaude))
    }

    @Test func pathUnderABasePath() throws {
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "https://x.example/panel")!, token: "t"))
        #expect(try client.url("/servers/1/health").absoluteString == "https://x.example/panel/api/v1/agent/servers/1/health")
        // A pasted "/api…" address doesn't land on the panel's session routes.
        for pasted in ["http://127.0.0.1:5050/api", "http://127.0.0.1:5050/api/", "http://127.0.0.1:5050/api/v1/agent", "http://127.0.0.1:5050/api/servers"] {
            let pastedClient = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: pasted)!, token: "t"))
            #expect(try pastedClient.url("/me").absoluteString == "http://127.0.0.1:5050/api/v1/agent/me")
        }
        #expect(try client.url("/servers/1/containers/\(ServerPlanClient.pathComponent("a b/c"))/logs").absoluteString
                == "https://x.example/panel/api/v1/agent/servers/1/containers/a%20b%2Fc/logs")
    }

    @Test func errorsMapToCases() async {
        let cases: [(Int, String, [String: String], ServerPlanError)] = [
            (401, #"{"error":"unauthorized","message":"Geçersiz token"}"#, [:], .unauthorized("Geçersiz token")),
            (403, #"{"error":"forbidden","message":"Yetkiniz yok"}"#, [:], .forbidden("Yetkiniz yok")),
            (404, #"{"error":"not_found","message":"Bulunamadı"}"#, [:], .notFound),
            (429, #"{"error":"rate_limited","message":"Yavaş"}"#, ["Retry-After": "12"], .rateLimited(retryAfter: 12)),
            (500, #"{"error":"internal","message":"Hata"}"#, [:], .http(status: 500, code: "internal", message: "Hata")),
        ]
        for (status, body, headers, expected) in cases {
            let client = ServerPlanClient(config: config, transport: StubTransport { _ in .init(status: status, body: Data(body.utf8), headers: headers) })
            await #expect(throws: expected) { try await client.servers() }
        }
    }

    // MARK: Decoding

    @Test func decodesServers() throws {
        let servers = try ServerPlanClient.decode([ServerPlanServer].self, from: try fixture("servers.json"))
        #expect(servers.map(\.name) == ["prod-eu-1", "staging", "mail-relay"])
        #expect(servers[0].effectiveStatus == .online)
        #expect(servers[0].checkedAt != nil)  // nanosecond fractions and a +03:00 offset
        #expect(servers[2].effectiveStatus == .offline)
        #expect(servers[2].checkedAt == nil)
        #expect(servers[0].host == "203.0.113.10")
    }

    @Test func decodesProjectsAndDeployments() throws {
        let projects = try ServerPlanClient.decode([ServerPlanProject].self, from: try fixture("projects.json"))
        #expect(projects.count == 4)
        #expect(projects[0].name == "payments-api")
        #expect(projects[0].lastDeploy?.status == .failed)
        #expect(projects[0].repoPath == "/tmp/ClaudeDeckDemo/projects/payments-api")
        #expect(projects[2].lastDeploy?.status.isRunning == true)
        #expect(projects[3].lastDeploy == nil && projects[3].defaultServerID == nil)

        let deployment = try ServerPlanClient.decode(ServerPlanDeployment.self, from: try fixture("deployment-207.json"))
        #expect(deployment.status == .failed)
        #expect(deployment.step == "build")
        #expect(deployment.errorSummary?.hasPrefix("docker build failed") == true)
        #expect(deployment.log?.contains("missing go.sum entry") == true)
        #expect(deployment.finishedAt != nil)

        let list = try ServerPlanClient.decode([ServerPlanDeployment].self, from: try fixture("deployments.json"))
        #expect(list.map(\.status) == [.building, .failed, .success])
    }

    @Test func decodesContainersAndHealth() throws {
        let containers = try ServerPlanClient.decode([ServerPlanContainer].self, from: try fixture("containers-1.json"))
        #expect(containers.filter(\.isRunning).count == 3)
        let health = try ServerPlanClient.decode(ServerPlanHealth.self, from: try fixture("health-1.json"))
        #expect(health.cpu == "4.2%" && health.memory == "4.7Gi/61Gi" && health.disk == "120G/437G (29%)")
        #expect(health.dockerOK == true && health.loadAverage == "0.91 0.74 0.66" && health.checkedAt != nil)
        let down = try ServerPlanClient.decode(ServerPlanHealth.self, from: try fixture("health-unreachable.json"))
        #expect(down.reachable == false && down.error?.contains("i/o timeout") == true && down.cpu == nil)
        let numeric = try ServerPlanClient.decode(ServerPlanHealth.self, from: Data(#"{"cpu":12.5,"mem":40,"disk":"9%"}"#.utf8))
        #expect(numeric.cpu == "12.5" && numeric.memory == "40")
    }

    @Test func emptyBranchAndNullsAreNil() throws {
        let deployment = try ServerPlanClient.decode(ServerPlanDeployment.self, from: Data(#"{"id":3,"branch":"","commit":null,"error":null,"status":"success"}"#.utf8))
        #expect(deployment.branch == nil && deployment.commit == nil && deployment.errorSummary == nil)
        let servers = try ServerPlanClient.decode([ServerPlanServer].self, from: try fixture("servers.json"))
        #expect(servers[2].reachable == nil && servers[2].effectiveStatus == .offline)
    }

    @Test func logStreamEnd() {
        #expect(ServerPlanLogLine(ServerSentEvent(event: "log", data: #"{"line":"boom","stream":"stderr"}"#)) == ServerPlanLogLine(line: "boom", stream: "stderr"))
        #expect(ServerPlanLogLine.endReason(ServerSentEvent(event: "end", data: #"{"reason":"log stream ended"}"#)) == "log stream ended")
        #expect(ServerPlanLogLine.endReason(ServerSentEvent(event: "log", data: "x")) == nil)
    }

    @Test func toleratesUnknownValues() throws {
        let deployment = try ServerPlanClient.decode(ServerPlanDeployment.self, from: Data(#"{"id":"9","status":"exploded","extra":1}"#.utf8))
        #expect(deployment.id == 9 && deployment.status == .unknown)
        let me = try ServerPlanClient.decode(ServerPlanMe.self, from: Data(#"{"user":"legacy","scopes":["read"]}"#.utf8))
        #expect(me.user == "legacy" && !me.allows(.deploy))
    }

    // MARK: Confirm gate

    @Test func confirmationMustMatchTheTarget() {
        let action = ServerPlanAction.deploy(projectID: 11, projectName: "payments-api", serverID: 1, forceRebuild: false)
        #expect(ServerPlanConfirmation(action)?.target == "payments-api")
        #expect(ServerPlanConfirmation(action, name: "payments") == nil)
        #expect(ServerPlanConfirmation(action, name: "") == nil)
        // The name the server asks for wins over the local guess.
        #expect(ServerPlanConfirmation(action, expected: "payments-api-main")?.target == "payments-api-main")
        #expect(ServerPlanConfirmation(action, name: "payments-api", expected: "payments-api-main") == nil)
    }

    @Test func previewSendsNoConfirmAndReadsThe428() async throws {
        let transport = StubTransport { _ in .init(status: 428, body: try! fixture("confirm-required.json")) }
        let client = ServerPlanClient(config: config, transport: transport)
        let action = ServerPlanAction.deploy(projectID: 11, projectName: "payments-api", serverID: 1, forceRebuild: true)
        let preview = try await client.preview(action)
        #expect(preview.expected == "payments-api")
        #expect(preview.summary?.contains("prod-eu-1") == true)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/agent/projects/11/deploy")
        let body = json(request)
        #expect(body["confirm"] == nil)
        #expect(body["server_id"] as? Int == 1 && body["force_rebuild"] as? Bool == true)
    }

    @Test func previewRefusesAServerThatActedWithoutConfirm() async {
        let client = ServerPlanClient(config: config, transport: StubTransport { _ in .init(status: 202, body: Data(#"{"deployment_id":1}"#.utf8)) })
        await #expect(throws: ServerPlanError.self) {
            try await client.preview(.container(serverID: 1, serverName: "prod-eu-1", name: "api", verb: .restart))
        }
    }

    @Test func performSendsTheConfirmedName() async throws {
        let transport = StubTransport { request in
            json(request)["confirm"] as? String == "payments-api"
                ? .init(status: 202, body: Data(#"{"deployment_id":209,"stream_url":"/api/v1/agent/deployments/209/stream"}"#.utf8))
                : .init(status: 428, body: try! fixture("confirm-required.json"))
        }
        let client = ServerPlanClient(config: config, transport: transport)
        let action = ServerPlanAction.deploy(projectID: 11, projectName: "payments-api", serverID: nil, forceRebuild: false)
        let result = try await client.perform(try #require(ServerPlanConfirmation(action)))
        #expect(result == .deployStarted(ServerPlanDeployStarted(deploymentID: 209, streamURL: "/api/v1/agent/deployments/209/stream")))
        #expect(json(try #require(transport.requests.first))["server_id"] == nil)
    }

    @Test func containerActionPathAndStaleConfirm() async throws {
        let transport = StubTransport { _ in .init(status: 428, body: Data(#"{"error":"confirm_required","message":"Onay","summary":"api yeniden başlatılır","confirm":"api"}"#.utf8)) }
        let client = ServerPlanClient(config: config, transport: transport)
        let action = ServerPlanAction.container(serverID: 1, serverName: "prod-eu-1", name: "api", verb: .restart)
        await #expect(throws: ServerPlanError.confirmRequired(summary: "api yeniden başlatılır", expected: "api")) {
            try await client.perform(try #require(ServerPlanConfirmation(action)))
        }
        #expect(transport.requests.first?.url?.path() == "/api/v1/agent/servers/1/containers/api/restart")
        #expect(json(try #require(transport.requests.first))["confirm"] as? String == "api")
    }

    @Test func containerNamesAreCheckedBeforeAnyRequest() async {
        #expect(ServerPlanClient.isValidContainerName("payments-api_1.web"))
        #expect(!ServerPlanClient.isValidContainerName("-api"))
        #expect(!ServerPlanClient.isValidContainerName("a/b"))
        #expect(!ServerPlanClient.isValidContainerName(""))
        #expect(!ServerPlanClient.isValidContainerName(String(repeating: "a", count: 129)))
        let transport = StubTransport { _ in .init(status: 200, body: Data()) }
        let client = ServerPlanClient(config: config, transport: transport)
        await #expect(throws: ServerPlanError.self) { try await client.containerLogs(serverID: 1, container: "../etc") }
        await #expect(throws: ServerPlanError.self) {
            try await client.preview(.container(serverID: 1, serverName: "s", name: "x y", verb: .stop))
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: Terminal

    @Test func terminalTicketAndWebSocketURL() async throws {
        let transport = StubTransport { _ in
            .init(status: 200, body: Data(#"{"ticket":"tk_1","expires_in":60,"url":"/api/v1/agent/ws/terminal?ticket=tk_1"}"#.utf8))
        }
        let client = ServerPlanClient(config: ServerPlanConfig(baseURL: URL(string: "https://panel.example")!, token: "t"), transport: transport)
        let url = try await client.terminalURL(serverID: 2, cols: 100, rows: 30, command: .claude)
        #expect(url.absoluteString == "wss://panel.example/api/v1/agent/ws/terminal?ticket=tk_1")
        let body = json(try #require(transport.requests.first))
        #expect(body["server_id"] as? Int == 2 && body["cols"] as? Int == 100 && body["rows"] as? Int == 30)
        #expect(body["command"] as? String == "claude")

        let plain = ServerPlanClient(config: config)
        #expect(try plain.webSocketURL(for: ServerPlanTicket(ticket: "x y", url: "/api/v1/agent/ws/terminal")).absoluteString
                == "ws://127.0.0.1:5099/api/v1/agent/ws/terminal?ticket=x%20y")
    }

    @Test func terminalControlFrames() {
        #expect(ServerPlanTerminalMessage.resize(cols: 80, rows: 24).json == #"{"cols":80,"rows":24,"type":"resize"}"#)
        #expect(ServerPlanTerminalMessage(json: #"{"type":"exit","code":130}"#) == .exit(code: 130))
        #expect(ServerPlanTerminalMessage(json: #"{"type":"error","message":"ssh: handshake failed"}"#) == .error("ssh: handshake failed"))
        #expect(ServerPlanTerminalMessage(json: "plain text") == nil)
    }

    // MARK: Server-Sent Events

    @Test func parsesSSEAcrossChunks() {
        let text = ": ping\r\n\r\nid: 5\r\nevent: log\r\ndata: {\"line\":\"a\"}\r\n\r\ndata: one\ndata: two\n\nretry: 3000\nevent: x\ndata:no-space\n\n"
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        // One byte at a time: CR LF and lines split everywhere.
        for byte in Data(text.utf8) { events += parser.feed(Data([byte])) }
        events += parser.finish()
        #expect(events.count == 3)
        #expect(events[0] == ServerSentEvent(event: "log", data: #"{"line":"a"}"#, id: "5"))
        #expect(events[1].event == "message" && events[1].data == "one\ntwo" && events[1].id == "5")
        #expect(events[2].event == "x" && events[2].data == "no-space" && events[2].retry == 3000)
        #expect(parser.lastEventID == "5")
    }

    @Test func lastEventWithoutBlankLineCountsAtTheEnd() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data("event: done\ndata: {}".utf8)).isEmpty)
        #expect(parser.finish() == [ServerSentEvent(event: "done", data: "{}")])
    }

    @Test func deployStreamEvents() async throws {
        let transport = StubTransport { _ in .init(status: 200, body: try! fixture("deploy-stream.txt")) }
        let client = ServerPlanClient(config: config, transport: transport)
        var items: [ServerPlanDeployStreamEvent] = []
        for try await event in try await client.deployStream(id: 207) {
            if let item = ServerPlanDeployStreamEvent(event) { items.append(item) }
        }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(items.count == 4)
        #expect(items[0] == .log("[git_pull] Already up to date."))
        #expect(items[1] == .status(ServerPlanDeployProgress(status: .building, step: "build")))
        guard case .done(let deployment) = items[3] else { Issue.record("no done"); return }
        #expect(deployment.status == .failed && deployment.errorSummary == "docker build failed")
    }

    @Test func eventStreamResumesWithLastEventID() async throws {
        let transport = StubTransport { _ in .init(status: 200, body: try! fixture("events.txt")) }
        let client = ServerPlanClient(config: config, transport: transport)
        var events: [ServerPlanEvent] = []
        for try await event in try await client.eventStream(lastEventID: "40") {
            if let value = ServerPlanEvent(event) { events.append(value) }
        }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Last-Event-ID") == "40")
        #expect(events.map(\.kind) == [.deployStarted, .deployFailed, .serverUnreachable])
        #expect(events[1].eventID == "42")
        #expect(events[1].data.deploymentID == 207 && events[1].data.projectName == "payments-api")
        #expect(events[1].data.errorSummary == "docker build failed")
        #expect(events[2].data.serverName == "mail-relay")
    }

    @Test func streamErrorStatusIsThrown() async {
        let client = ServerPlanClient(config: config, transport: StubTransport { _ in .init(status: 403, body: Data(#"{"error":"forbidden","message":"Yok"}"#.utf8)) })
        await #expect(throws: ServerPlanError.forbidden("Yok")) { _ = try await client.eventStream(lastEventID: nil) }
    }

    // MARK: Fix with Claude

    @Test func repairPromptAndKey() throws {
        let deployment = try ServerPlanClient.decode(ServerPlanDeployment.self, from: try fixture("deployment-207.json"))
        let prompt = DeployRepair.prompt(project: "payments-api", server: "prod-eu-1", deployment: deployment, log: deployment.log ?? "")
        #expect(prompt.hasPrefix("The ServerPlan deploy #207 of payments-api to prod-eu-1 failed (branch main, commit 4f2c9e1b7a3d)."))
        #expect(prompt.contains("Error: docker build failed"))
        #expect(prompt.contains("missing go.sum entry"))
        #expect(prompt.contains("Don't deploy"))
        #expect(DeployRepair.key(panel: URL(string: "http://127.0.0.1:5050")!, deploymentID: 207) == "127.0.0.1#deploy:207")
    }

    @Test func matchesProjectByFolder() {
        let projects = [Project(path: "/tmp/a/payments-api"), Project(path: "/tmp/a/blog")]
        #expect(DeployRepair.project(forRepoPath: "/tmp/a/blog/", in: projects)?.path == "/tmp/a/blog")
        #expect(DeployRepair.project(forRepoPath: "/tmp/a/../a/payments-api", in: projects)?.path == "/tmp/a/payments-api")
        #expect(DeployRepair.project(forRepoPath: "/elsewhere/blog", in: projects) == nil)
        #expect(DeployRepair.project(forRepoPath: nil, in: projects) == nil)
    }

    @Test func groupsServerProjectsUnderTheirDeckProject() {
        let main = Project(path: "/tmp/a/app")
        let worktree = Project(path: "/tmp/a/app/.claude/worktrees/x/")
        let blog = Project(path: "/tmp/a/blog")
        let other = Project(path: "/tmp/a/app-other")
        let server = [
            ServerPlanProject(id: 1, name: "app", repoPath: "/tmp/a/app/"),
            ServerPlanProject(id: 2, name: "api", repoPath: "/tmp/a/app/services/api"),
            ServerPlanProject(id: 3, name: "wt", repoPath: "/tmp/a/app/.claude/worktrees/x/web"),
            ServerPlanProject(id: 4, name: "elsewhere", repoPath: "/srv/blog"),
            ServerPlanProject(id: 5, name: "no path"),
            ServerPlanProject(id: 6, name: "blog", repoPath: "/tmp/a/../a/blog"),
        ]
        let map = DeployRepair.projectsByDeckProject(server, in: [main, worktree, blog, other])
        #expect(map[main.id]?.map(\.id) == [1, 2])
        #expect(map[worktree.id]?.map(\.id) == [3])
        #expect(map[blog.id]?.map(\.id) == [6])
        // "/tmp/a/app-other" doesn't hold "/tmp/a/app…": a prefix of the name isn't a subfolder.
        #expect(map[other.id] == nil)
        #expect(DeckSettings().serverPlanProjectRows)
    }

    @Test func deckKeepsRepairRequestsAndTerminalTargets() throws {
        var deck = DeckData()
        let project = deck.addProject(path: "/tmp/a/blog")
        let session = deck.addSession(to: project.id, name: "staging")
        deck.updateSession(session!.id) { $0.kind = .shell; $0.serverPlanTerminal = ServerPlanTerminalTarget(serverID: 2, serverName: "staging", runClaude: true) }
        deck.settings.serverPlanURL = "http://127.0.0.1:5050"
        deck.recordDeployRepair(DeployRepairRequest(key: "k", sessionID: session?.id))
        let data = try JSONEncoder().encode(deck)
        let decoded = try JSONDecoder().decode(DeckData.self, from: data)
        #expect(decoded.deployRepairRequest("k")?.sessionID == session?.id)
        #expect(decoded.session(session!.id)?.serverPlanTerminal?.serverName == "staging")
        #expect(decoded.settings.serverPlanURL == "http://127.0.0.1:5050")
        // A deck written before these keys existed still loads.
        let legacy = try JSONDecoder().decode(DeckData.self, from: Data(#"{"sessions":[]}"#.utf8))
        #expect(legacy.deployRepairRequests.isEmpty && legacy.settings.serverPlanURL.isEmpty)
    }
}
