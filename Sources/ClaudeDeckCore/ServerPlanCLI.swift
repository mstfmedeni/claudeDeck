import Foundation

/// `claudedeck server …`: ServerPlan for sessions, through the app. The command never sees the
/// ServerPlan token; the app runs these with its client (token from the Keychain) when ServerPlan
/// is set up and Settings › Agents › "Sessions may use ServerPlan" is on.
///
/// `commands` is the table: each CLI command, the method the script uses, the `/me` feature and
/// scope it needs, and what happens on a 428 (confirm_required). Panel answers are passed through
/// as JSON (`--json`) and read tolerantly for text, so shape changes only touch the text columns.
public enum ServerPlanCLI {
    /// What a 428 (confirm_required) leads to.
    public enum Gate: Sendable, Equatable {
        /// Not expected; a 428 is an error.
        case none
        /// The owner wants deploys to be autonomous: confirmed automatically, and logged.
        case auto
        /// The owner's dialog in the app; refused or unanswered in 2 minutes: exit 4.
        case owner
    }

    public struct Command: Sendable, Equatable {
        public var name: String
        public var method: String
        /// A `/me` feature the panel must list (nil: part of v1, always there).
        public var feature: String?
        /// The token scope it needs (nil: any).
        public var scope: String?
        public var gate: Gate
    }

    /// `/me` features of the v1.1 API (draft; the names may still change).
    public enum Feature {
        public static let ports = "ports"
        public static let projectsWrite = "projects_write"
        public static let env = "env"
        public static let databases = "databases"
        public static let domains = "domains"
        public static let dns = "dns"
        public static let namecheap = "namecheap"
    }

    public static let commands: [String: Command] = {
        let list: [Command] = [
            // v1
            Command(name: "list", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "health", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "projects", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "containers", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "logs", method: "GET", feature: nil, scope: "logs", gate: .none),
            Command(name: "deploy", method: "POST", feature: nil, scope: "deploy", gate: .auto),
            Command(name: "deploy-status", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "deployments", method: "GET", feature: nil, scope: "read", gate: .none),
            Command(name: "container", method: "POST", feature: nil, scope: "containers", gate: .owner),
            Command(name: "features", method: "GET", feature: nil, scope: nil, gate: .none),
            // v1.1 (draft)
            Command(name: "ports", method: "GET", feature: Feature.ports, scope: "read", gate: .none),
            Command(name: "dirs", method: "GET", feature: Feature.projectsWrite, scope: "read", gate: .none),
            Command(name: "scan", method: "POST", feature: Feature.projectsWrite, scope: "projects_write", gate: .none),
            Command(name: "project-set", method: "POST", feature: Feature.projectsWrite, scope: "projects_write", gate: .none),
            Command(name: "env-get", method: "GET", feature: Feature.env, scope: "projects_write", gate: .none),
            Command(name: "env-set", method: "POST", feature: Feature.env, scope: "projects_write", gate: .none),
            Command(name: "db-create", method: "POST", feature: Feature.databases, scope: "databases", gate: .none),
            Command(name: "domain-list", method: "GET", feature: Feature.domains, scope: "domains", gate: .none),
            Command(name: "domain-add", method: "POST", feature: Feature.domains, scope: "domains", gate: .none),
            Command(name: "dns-status", method: "GET", feature: Feature.dns, scope: "dns", gate: .none),
            Command(name: "dns-sync", method: "POST", feature: Feature.dns, scope: "dns", gate: .owner),
            Command(name: "ns-set", method: "POST", feature: Feature.namecheap, scope: "dns", gate: .owner),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    /// What the app sends back for one command.
    public struct Outcome: Sendable {
        public var status: Int
        public var json: Data
        public var text: String
        public var exit: SessionCLI.Exit
        /// `X-ClaudeDeck-Next`: where a `--wait` / `--follow` loop goes on from.
        public var next: String?

        public init(status: Int = 200, json: Data, text: String, exit: SessionCLI.Exit = .ok, next: String? = nil) {
            self.status = status
            self.json = json
            self.text = text
            self.exit = exit
            self.next = next
        }

        public static func error(_ status: Int, _ code: String, _ message: String? = nil, exit: SessionCLI.Exit) -> Outcome {
            var object: [String: Any] = ["error": code]
            if let message { object["message"] = message }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return Outcome(status: status, json: data, text: message.map { "\(code): \($0)" } ?? code, exit: exit)
        }

        public func response(json wantsJSON: Bool) -> AgentHTTPResponse {
            var response = wantsJSON || status >= 300
                ? AgentHTTPResponse(status: status, body: json, contentType: "application/json")
                : AgentHTTPResponse(status: status, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
            response.headers[SessionCLI.exitHeader] = String(exit.rawValue)
            if let next { response.headers["X-ClaudeDeck-Next"] = next }
            return response
        }
    }

    /// A ServerPlan error as the command's answer.
    public static func outcome(for error: Error) -> Outcome {
        guard let error = error as? ServerPlanError else { return .error(502, "serverplan", error.localizedDescription, exit: .failed) }
        let message = error.errorDescription
        switch error {
        case .notConfigured, .badURL: return .error(403, "serverplan_off", message, exit: .refused)
        case .unauthorized: return .error(403, "serverplan_unauthorized", message, exit: .refused)
        case .forbidden: return .error(403, "serverplan_forbidden", message, exit: .refused)
        case .notFound: return .error(404, "unknown", message, exit: .unknown)
        case .confirmRequired, .confirmationMissing: return .error(403, "confirm_required", message, exit: .refused)
        case .rateLimited: return .error(429, "serverplan_rate_limited", message, exit: .refused)
        case .http(let status, let code, _):
            return .error(status == 409 ? 409 : status == 400 ? 400 : 502, code ?? (status == 409 ? "conflict" : "serverplan_error"), message, exit: .failed)
        case .transport, .decoding: return .error(502, "serverplan_unreachable", message, exit: .failed)
        }
    }

    /// The owner's answer to a gated action: what the panel said it would do, and the exact
    /// confirmation it wants.
    public typealias Approve = @Sendable (_ command: String, _ target: String, _ summary: String?) async -> Bool

    /// Runs one command. `approve` asks the owner (gate `.owner`); `log` records what was
    /// confirmed automatically (deploys) and what the owner decided.
    public struct Runner: Sendable {
        public let client: ServerPlanClient
        public let me: ServerPlanMe?
        public let approve: Approve
        public let log: @Sendable (String) -> Void

        public init(client: ServerPlanClient, me: ServerPlanMe?, approve: @escaping Approve, log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.client = client
            self.me = me
            self.approve = approve
            self.log = log
        }

        public func run(_ name: String, method: String, form: [String: String]) async -> Outcome {
            guard let command = ServerPlanCLI.commands[name] else { return .error(404, "unknown_command", exit: .usage) }
            guard command.method == method else { return .error(405, "method_not_allowed", exit: .usage) }
            if let feature = command.feature, me?.has(feature: feature) != true {
                return .error(501, "not_available", "not available: ServerPlan doesn't offer this yet", exit: .refused)
            }
            if let scope = command.scope, let me, !me.scopes.isEmpty, !me.scopes.contains(scope) {
                return .error(403, "serverplan_scope", "the ServerPlan token lacks the \(scope) scope", exit: .refused)
            }
            do {
                return try await perform(command, form: form)
            } catch let refusal as Refusal {
                return refusal.outcome
            } catch {
                return ServerPlanCLI.outcome(for: error)
            }
        }

        struct Refusal: Error { var outcome: Outcome }

        // MARK: The table's calls

        private func perform(_ command: Command, form: [String: String]) async throws -> Outcome {
            switch command.name {
            case "list":
                let data = try await raw("GET", "/servers")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("STATUS", "status"), ("NAME", "name"), ("HOST", "host")]))
            case "health":
                let server = try await serverID(form["server"])
                let data = try await raw("GET", "/servers/\(server)/health")
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "projects":
                let data = try await raw("GET", "/projects")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("SERVER", "default_server_id"), ("LAST DEPLOY", "last_deploy.status"),
                                                                              ("NAME", "display_name|name"), ("PATH", "repo_path|path")]))
            case "containers":
                let server = try await serverID(form["server"])
                let data = try await raw("GET", "/servers/\(server)/containers")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("NAME", "name"), ("STATE", "state"), ("STATUS", "status"), ("IMAGE", "image"), ("PORTS", "ports")]))
            case "logs":
                return try await logs(form)
            case "deploy":
                return try await deploy(form)
            case "deploy-status":
                return try await deployStatus(form)
            case "deployments":
                var query = [URLQueryItem(name: "limit", value: String(min(max(Int(form["limit"] ?? "") ?? 20, 1), 100)))]
                if let project = form["project"], !project.isEmpty { query.append(URLQueryItem(name: "project_id", value: String(try await projectID(project)))) }
                let data = try await raw("GET", "/deployments", query: query)
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("STATUS", "status"), ("PROJECT", "project_name|project"),
                                                                              ("SERVER", "server_name|server"), ("FINISHED", "finished_at"), ("ERROR", "error_summary|error")]))
            case "container":
                return try await container(form)
            case "features":
                let me = try await client.me()
                let planned = ServerPlanCLI.commands.values.filter { $0.feature != nil }.sorted { $0.name < $1.name }
                let lines = planned.map { "\($0.name): " + (me.has(feature: $0.feature!) ? "available" : "not available (ServerPlan doesn't offer this yet)") }
                let object: [String: Any] = ["features": me.features, "scopes": me.scopes,
                                             "commands": Dictionary(uniqueKeysWithValues: planned.map { ($0.name, me.has(feature: $0.feature!)) })]
                return Outcome(json: ServerPlanCLI.data(object), text: (["features: " + me.features.joined(separator: ", "),
                                                                          "scopes: " + me.scopes.joined(separator: ", ")] + lines).joined(separator: "\n"))
            // v1.1 (draft)
            case "ports":
                let server = try await serverID(form["server"])
                var query: [URLQueryItem] = []
                if form["suggest"] == "1" { query.append(URLQueryItem(name: "suggest", value: "1")) }
                for key in ["from", "to"] { if let value = form[key], Int(value) != nil { query.append(URLQueryItem(name: key, value: value)) } }
                let data = try await raw("GET", "/servers/\(server)/ports", query: query)
                let object = ServerPlanCLI.object(data)
                var text = ServerPlanCLI.listText(ServerPlanCLI.data(object?["used"] ?? []), [("PORT", "port"), ("BY", "by.type"), ("NAME", "by.name")])
                if let suggested = object?["suggested"].flatMap(ServerPlanCLI.string) { text += "\nsuggested: \(suggested)" }
                return Outcome(json: data, text: text)
            case "dirs":
                let data = try await raw("GET", "/project-dirs")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("REMOTE", "is_remote"), ("PATH", "path")]))
            case "scan":
                guard let path = form["path"], path.hasPrefix("/") else { throw Refusal(outcome: .error(400, "bad_path", "an absolute path", exit: .usage)) }
                let data = try await raw("POST", "/projects/scan", json: ["path": path])
                let object = ServerPlanCLI.object(data) ?? [:]
                let lines = ["created", "updated", "found"].flatMap { key in
                    ((object[key] as? [[String: Any]]) ?? []).map { "\(key): #\(ServerPlanCLI.value($0, "id") ?? "?") \(ServerPlanCLI.value($0, "display_name|name") ?? "")" }
                }
                return Outcome(json: data, text: lines.isEmpty ? "no projects found" : lines.joined(separator: "\n"))
            case "project-set":
                let project = try await projectID(form["project"])
                var body: [String: Any] = [:]
                if let server = form["server"], !server.isEmpty { body["default_server_id"] = try await serverID(server) }
                if let port = form["port"], !port.isEmpty {
                    guard let number = Int(port), (1...65535).contains(number) else { throw Refusal(outcome: .error(400, "bad_port", exit: .usage)) }
                    body["default_port"] = number
                }
                if let volume = form["volume"], !volume.isEmpty { body["volume_path"] = volume }
                if let dockerfile = form["dockerfile"], !dockerfile.isEmpty { body["dockerfile_path"] = dockerfile }
                guard !body.isEmpty else { throw Refusal(outcome: .error(400, "nothing_to_set", exit: .usage)) }
                let data = try await raw("PATCH", "/projects/\(project)", json: body)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "env-get":
                let project = try await projectID(form["project"])
                let data = try await raw("GET", "/projects/\(project)/env")
                // Secrets never come back; a value the panel sends for one is still not shown.
                let rows = (ServerPlanCLI.array(data) ?? []).map { row -> [String] in
                    let secret = (row["is_secret"] as? Bool) == true
                    return [ServerPlanCLI.value(row, "key") ?? "", secret ? "(secret)" : ServerPlanCLI.value(row, "value") ?? "", ServerPlanCLI.value(row, "source") ?? "-"]
                }
                return Outcome(json: ServerPlanCLI.redactedEnv(data), text: SessionCLI.table([["KEY", "VALUE", "SOURCE"]] + rows))
            case "env-set":
                let project = try await projectID(form["project"])
                let vars = ServerPlanCLI.envAssignments(form["vars"] ?? "")
                guard !vars.isEmpty else { throw Refusal(outcome: .error(400, "no_variables", "KEY=value lines", exit: .usage)) }
                let secrets = (form["secret"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let data = try await raw("PUT", "/projects/\(project)/env", json: ["vars": vars, "secret_keys": secrets])
                let written = (ServerPlanCLI.object(data)?["written"] as? [Any])?.compactMap(ServerPlanCLI.string) ?? vars.keys.sorted()
                return Outcome(json: data, text: "written: " + written.joined(separator: ", "))
            case "db-create":
                let project = try await projectID(form["project"])
                var body: [String: Any] = [:]
                if let name = form["name"], !name.isEmpty { body["name"] = name }
                let data = try await raw("POST", "/projects/\(project)/database", json: body)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "domain-list":
                let data = try await raw("GET", "/domains")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("PORT", "port"), ("DNS", "dns.synced"), ("PROJECT", "project_name"), ("FQDN", "fqdn")]))
            case "domain-add":
                let project = try await projectID(form["project"])
                guard let sub = form["subdomain"], let base = form["base"], !base.isEmpty else { throw Refusal(outcome: .error(400, "bad_domain", exit: .usage)) }
                var body: [String: Any] = ["project_id": project, "subdomain": sub, "base_domain": base]
                if let server = form["server"], !server.isEmpty { body["server_id"] = try await serverID(server) }
                if let port = form["port"], let number = Int(port) { body["port"] = number }
                if form["websocket"] == "1" { body["websocket"] = true }
                let data = try await raw("POST", "/domains", json: body)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "dns-status":
                let domain = try await domainID(form["domain"])
                let data = try await raw("GET", "/domains/\(domain.id)/dns")
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "dns-sync":
                let domain = try await domainID(form["domain"])
                let data = try await gated(command, "POST", "/domains/\(domain.id)/dns", target: domain.fqdn)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data).ifEmpty("synced: \(domain.fqdn)"))
            case "ns-set":
                let domain = try await domainID(form["domain"])
                let data = try await gated(command, "POST", "/domains/\(domain.id)/namecheap/nameservers", target: domain.fqdn)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            default:
                return .error(404, "unknown_command", exit: .usage)
            }
        }

        // MARK: Requests

        func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> Data {
            try await client.raw(method, path, query: query, json: json)
        }

        /// A request that may answer 428: sent again with the panel's `confirm` once the gate
        /// allows it (deploys automatically; the rest only with the owner's yes).
        func gated(_ command: Command, _ method: String, _ path: String, body: [String: Any] = [:], target: String) async throws -> Data {
            do {
                return try await raw(method, path, json: body)
            } catch ServerPlanError.confirmRequired(let summary, let expected) {
                let confirm = expected ?? target
                switch command.gate {
                case .none:
                    throw ServerPlanError.confirmRequired(summary: summary, expected: expected)
                case .auto:
                    log("\(command.name) \(target): confirmed automatically")
                case .owner:
                    guard await approve(command.name, confirm, summary) else {
                        log("\(command.name) \(target): the owner refused or didn't answer")
                        throw Refusal(outcome: .error(403, "owner_refused", "the owner didn't approve it in ClaudeDeck", exit: .refused))
                    }
                    log("\(command.name) \(target): approved by the owner")
                }
                var confirmed = body
                confirmed["confirm"] = confirm
                return try await raw(method, path, json: confirmed)
            }
        }

        private func deploy(_ form: [String: String]) async throws -> Outcome {
            let projects = try await client.projects()
            let project = try pick(form["project"], projects.map { ($0.id, $0.name) }, what: "project")
            var body: [String: Any] = [:]
            if let server = form["server"], !server.isEmpty { body["server_id"] = try await serverID(server) }
            if form["force"] == "1" { body["force_rebuild"] = true }
            let data = try await gated(ServerPlanCLI.commands["deploy"]!, "POST", "/projects/\(project.id)/deploy", body: body, target: project.name)
            let started = try ServerPlanClient.decode(ServerPlanDeployStarted.self, from: data)
            log("deploy \(project.name): deployment #\(started.deploymentID)")
            return Outcome(json: data, text: String(started.deploymentID))
        }

        /// One deployment; with `wait=N`, a long poll (every 2 s, only while asked) that answers
        /// once it has finished, new log lines came, or N seconds passed. `since`: log lines
        /// already shown. Exit 0 success, 1 failed or cancelled, 124 still running.
        private func deployStatus(_ form: [String: String]) async throws -> Outcome {
            guard let id = Int(form["id"] ?? "") else { throw Refusal(outcome: .error(400, "bad_id", exit: .usage)) }
            let since = max(0, Int(form["since"] ?? "") ?? 0)
            let window = min(SessionCLI.maxWaitWindow, max(0, Int(form["wait"] ?? "") ?? 0))
            let deadline = Date().addingTimeInterval(TimeInterval(window))
            var deployment = try await client.deployment(id: id)
            func lines(_ d: ServerPlanDeployment) -> [String] { (d.log ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
            while window > 0, deployment.status.isRunning || deployment.status == .unknown, lines(deployment).count <= since, Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                deployment = try await client.deployment(id: id)
            }
            let all = lines(deployment)
            var shown = Array(all.dropFirst(min(since, all.count)))
            let finished = deployment.status.isFinished
            if window == 0, shown.count > 40 { shown = ["…"] + shown.suffix(40) }
            var text = shown
            let step = deployment.step.map { " (\($0))" } ?? ""
            if finished || window == 0 || form["status"] != deployment.status.rawValue {
                text.append("deploy #\(id): \(deployment.status.rawValue)\(step)")
            }
            if let error = deployment.errorSummary, deployment.status == .failed { text.append("error: \(error)") }
            let exit: SessionCLI.Exit = deployment.status == .success ? .ok : finished ? .failed : window > 0 ? .timeout : .ok
            let object: [String: Any] = ["id": id, "status": deployment.status.rawValue, "step": deployment.step as Any,
                                         "error": deployment.errorSummary as Any, "lines": shown, "finished": finished]
            return Outcome(json: ServerPlanCLI.data(object), text: text.joined(separator: "\n"), exit: exit,
                           next: "\(all.count):\(deployment.status.rawValue)")
        }

        /// The last `tail` lines; with `follow=N`, what the live log adds in N seconds (exit 124:
        /// ask again; 0: the log ended).
        private func logs(_ form: [String: String]) async throws -> Outcome {
            let server = try await serverID(form["server"])
            let name = form["container"] ?? ""
            guard ServerPlanClient.isValidContainerName(name) else { throw Refusal(outcome: .error(400, "bad_container", exit: .usage)) }
            let tail = min(max(Int(form["tail"] ?? "") ?? 200, 0), 5000)
            let window = min(SessionCLI.maxWaitWindow, max(0, Int(form["follow"] ?? "") ?? 0))
            guard window > 0 else {
                let text = try await client.containerLogs(serverID: server, container: name, tail: tail)
                return Outcome(json: ServerPlanCLI.data(["lines": text.split(separator: "\n").map(String.init)]), text: text.trimmingCharacters(in: .newlines))
            }
            let stream = try await client.containerLogStream(serverID: server, container: name, tail: tail)
            let collector = Task { () -> ([String], Bool) in
                var lines: [String] = []
                do {
                    for try await event in stream {
                        if event.event == "end" { return (lines, true) }
                        if event.event == "log" {
                            let line = (try? JSONDecoder().decode(ServerPlanLogLine.self, from: Data(event.data.utf8)))?.line ?? event.data
                            lines.append(line)
                        }
                        if Task.isCancelled || lines.count >= 2000 { break }
                    }
                } catch {}
                return (lines, !Task.isCancelled)
            }
            let timer = Task { try? await Task.sleep(for: .seconds(window)); collector.cancel() }
            let (lines, ended) = await collector.value
            timer.cancel()
            return Outcome(json: ServerPlanCLI.data(["lines": lines, "ended": ended]), text: lines.joined(separator: "\n"),
                           exit: ended ? .ok : .timeout)
        }

        private func container(_ form: [String: String]) async throws -> Outcome {
            let servers = try await client.servers()
            let server = try pick(form["server"], servers.map { ($0.id, $0.name) }, what: "server")
            let name = form["container"] ?? ""
            guard ServerPlanClient.isValidContainerName(name) else { throw Refusal(outcome: .error(400, "bad_container", exit: .usage)) }
            guard let verb = ServerPlanAction.ContainerVerb(rawValue: form["action"] ?? "") else { throw Refusal(outcome: .error(400, "bad_action", exit: .usage)) }
            let action = ServerPlanAction.container(serverID: server.id, serverName: server.name, name: name, verb: verb)
            let preview = try await client.preview(action)
            guard await approve("container \(verb.rawValue)", preview.expected ?? name, preview.summary ?? "\(verb.rawValue) \(name) on \(server.name)") else {
                log("container \(verb.rawValue) \(name) on \(server.name): the owner refused or didn't answer")
                return .error(403, "owner_refused", "the owner didn't approve it in ClaudeDeck", exit: .refused)
            }
            guard let confirmation = ServerPlanConfirmation(action, expected: preview.expected) else { throw ServerPlanError.confirmationMissing }
            _ = try await client.perform(confirmation)
            log("container \(verb.rawValue) \(name) on \(server.name): approved by the owner, done")
            return Outcome(json: ServerPlanCLI.data(["done": true]), text: "\(verb.rawValue): \(name) on \(server.name)")
        }

        // MARK: Names and ids

        /// A server, project or domain by id or name (any case).
        func pick(_ ref: String?, _ items: [(id: Int, name: String)], what: String) throws -> (id: Int, name: String) {
            let ref = (ref ?? "").trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { throw Refusal(outcome: .error(400, "no_\(what)", "which \(what)?", exit: .usage)) }
            if let id = Int(ref), let item = items.first(where: { $0.id == id }) { return item }
            let named = items.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
            if named.count == 1 { return named[0] }
            throw Refusal(outcome: named.isEmpty ? .error(404, "unknown_\(what)", ref, exit: .unknown) : .error(400, "ambiguous", ref, exit: .usage))
        }

        func serverID(_ ref: String?) async throws -> Int {
            if let id = Int(ref ?? "") { return id }
            return try pick(ref, try await client.servers().map { ($0.id, $0.name) }, what: "server").id
        }

        func projectID(_ ref: String?) async throws -> Int {
            if let id = Int(ref ?? "") { return id }
            return try pick(ref, try await client.projects().map { ($0.id, $0.name) }, what: "project").id
        }

        func domainID(_ ref: String?) async throws -> (id: Int, fqdn: String) {
            let rows = ServerPlanCLI.array(try await raw("GET", "/domains")) ?? []
            let items = rows.compactMap { row -> (Int, String)? in
                guard let id = ServerPlanCLI.value(row, "id").flatMap(Int.init) else { return nil }
                return (id, ServerPlanCLI.value(row, "fqdn") ?? "")
            }
            let found = try pick(ref, items, what: "domain")
            return (found.id, found.name)
        }
    }

    // MARK: Text

    static func data(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    /// A list, bare or wrapped in a one-key object.
    static func array(_ data: Data) -> [[String: Any]]? {
        let value = try? JSONSerialization.jsonObject(with: data)
        if let list = value as? [[String: Any]] { return list }
        if let object = value as? [String: Any], object.count == 1, let list = object.values.first as? [[String: Any]] { return list }
        return nil
    }

    static func string(_ value: Any) -> String? {
        switch value {
        case is NSNull: nil
        case let text as String: text
        case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "yes" : "no") : number.stringValue
        case let list as [Any]: list.compactMap(string).joined(separator: ",")
        default: nil
        }
    }

    /// `key` is a dotted path; `a|b` takes the first that's there.
    static func value(_ object: [String: Any], _ key: String) -> String? {
        for alternative in key.split(separator: "|") {
            var current: Any? = object
            for part in alternative.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
            if let current, let text = string(current), !text.isEmpty { return text }
        }
        return nil
    }

    public static func listText(_ data: Data, _ columns: [(header: String, key: String)]) -> String {
        guard let rows = array(data) else { return String(decoding: data, as: UTF8.self) }
        if rows.isEmpty { return "(none)" }
        return SessionCLI.table([columns.map(\.header)] + rows.map { row in columns.map { value(row, $0.key) ?? "-" } })
    }

    /// `key: value` lines (nested objects as `parent.key`); never a value of a key that looks secret.
    public static func objectText(_ data: Data) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        var lines: [String] = []
        func walk(_ object: [String: Any], _ prefix: String) {
            for key in object.keys.sorted() {
                let name = prefix + key
                if let nested = object[key] as? [String: Any] { walk(nested, name + "."); continue }
                let secret = ["password", "secret", "token"].contains { key.lowercased().contains($0) }
                lines.append("\(name): " + (secret ? "(hidden)" : string(object[key]!) ?? "-"))
            }
        }
        walk(object, "")
        return lines.joined(separator: "\n")
    }

    /// `KEY=value` lines (from stdin or a file); blank lines and `#` comments skipped, `export ` allowed.
    public static func envAssignments(_ text: String) -> [String: String] {
        var vars: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else { continue }
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
            vars[key] = value
        }
        return vars
    }

    /// `env get --json`: a secret's value is dropped even if the panel sent one.
    static func redactedEnv(_ data: Data) -> Data {
        guard let rows = array(data) else { return data }
        return ServerPlanCLI.data(rows.map { row in
            var row = row
            if (row["is_secret"] as? Bool) == true { row["value"] = NSNull() }
            return row
        })
    }
}

extension ServerPlanClient {
    /// Any method and path under the agent API, the body as it came (tolerant of shape changes).
    public func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> Data {
        try await send(try request(path, method: method, query: query, json: json)).0
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
