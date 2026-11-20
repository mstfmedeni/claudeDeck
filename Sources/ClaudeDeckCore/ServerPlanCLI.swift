import Foundation

/// `claudedeck server …`: ServerPlan for sessions, through the app. The command never sees the
/// ServerPlan token; the app runs these with its client (token from the Keychain) when ServerPlan
/// is set up and Settings › Agents › "Sessions may use ServerPlan" is on.
///
/// `commands` is the table: each CLI command, the method the script uses, what it needs from the
/// panel, and what happens on a 428 (confirm_required). Panel answers are passed through as JSON
/// (`--json`) and read tolerantly for text, so a shape change only touches the text columns.
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
        /// Part of the v1.1 agent API or later (v1.2 too): an older panel answers "not available".
        public var v11: Bool
        /// A v1.1 token scope; a panel whose `/me` lacks it doesn't offer the command (yet).
        public var scope: String?
        public var gate: Gate
        /// v1.3 and later: offered only when `/me` names this feature or says it's at least
        /// 1.`minMinor` (never on an unknown version: these spend money).
        public var feature: String?
        public var minMinor: Int
        /// Offered only when `/me` lists `feature` (ServerPlan's proposed 1.5 additions:
        /// whatever version ships them, the feature is what says they're there).
        public var featureOnly: Bool

        init(_ name: String, _ method: String, v11: Bool = false, scope: String? = nil, gate: Gate = .none,
             feature: String? = nil, minMinor: Int = 1, featureOnly: Bool = false) {
            self.name = name
            self.method = method
            self.v11 = v11 || featureOnly
            self.scope = scope
            self.gate = gate
            self.feature = feature
            self.minMinor = minMinor
            self.featureOnly = featureOnly
        }
    }

    public static let commands: [String: Command] = {
        let list: [Command] = [
            // v1
            Command("list", "GET"),
            Command("health", "GET"),
            Command("projects", "GET"),
            Command("containers", "GET"),
            Command("logs", "GET"),
            Command("deploy", "POST", gate: .auto),
            Command("deploy-status", "GET"),
            Command("deployments", "GET"),
            Command("container", "POST", gate: .owner),
            Command("features", "GET"),
            // v1.1
            Command("ports", "GET", v11: true),
            Command("dirs", "GET", v11: true),
            Command("scan", "POST", v11: true, scope: "projects_write"),
            Command("project-show", "GET", v11: true),
            Command("project-set", "POST", v11: true, scope: "projects_write"),
            Command("env-get", "GET", v11: true),
            Command("env-set", "POST", v11: true, scope: "projects_write"),
            Command("dockerfile-template", "GET", v11: true),
            Command("dockerfile-write", "POST", v11: true, scope: "projects_write"),
            Command("db-create", "POST", v11: true, scope: "databases"),
            Command("domain-list", "GET", v11: true),
            Command("domain-add", "POST", v11: true, scope: "domains", gate: .owner),
            Command("dns-sync", "POST", v11: true, scope: "dns", gate: .owner),
            Command("cloudflare", "GET", v11: true),
            Command("zone-add", "POST", v11: true, scope: "dns"),
            Command("ns-set", "POST", v11: true, scope: "dns", gate: .owner),
            // Static sites: autonomous (no gate). A panel without them answers 404: "not available".
            Command("static-add", "POST", v11: true, scope: "domains"),
            Command("sync", "POST", v11: true, scope: "deploy"),
            Command("env-rescan", "POST", v11: true, scope: "projects_write"),
            Command("env-rm", "POST", v11: true, scope: "projects_write", gate: .owner),
            // v1.2 (ServerPlanCLIV12.swift). `method` is how the script calls the app, not the panel's verb.
            Command("sql", "POST", v11: true, scope: "sql", gate: .owner),
            Command("local-run", "POST", v11: true, scope: "local"),
            Command("local-status", "GET", v11: true),
            Command("local-logs", "GET", v11: true, scope: "local"),
            Command("local-stop", "POST", v11: true, scope: "local"),
            Command("local-env-get", "GET", v11: true),
            Command("local-env-set", "POST", v11: true, scope: "local"),
            Command("local-env-unset", "POST", v11: true, scope: "local"),
            Command("db-clone-local", "POST", v11: true, scope: "databases"),
            Command("clone-status", "GET", v11: true, scope: "databases"),
            Command("branches", "GET", v11: true),
            Command("refresh", "POST", v11: true, scope: "projects_write"),
            Command("git-pull", "POST", v11: true, scope: "projects_write"),
            Command("git-push", "POST", v11: true, scope: "projects_write", gate: .owner),
            Command("switch-branch", "POST", v11: true, scope: "projects_write", gate: .owner),
            Command("build", "POST", v11: true, scope: "deploy"),
            Command("pull-deploy", "POST", v11: true, scope: "deploy"),
            Command("diagnose", "GET", v11: true),
            Command("diagnose-fix", "POST", v11: true, scope: "projects_write", gate: .owner),
            Command("deploy-cancel", "POST", v11: true, scope: "deploy", gate: .owner),
            Command("domain-set", "POST", v11: true, scope: "domains", gate: .owner),
            Command("domain-apply", "POST", v11: true, scope: "domains"),
            Command("domain-nginx", "POST", v11: true, scope: "domains"),
            Command("domain-purge", "POST", v11: true, scope: "dns"),
            Command("zone-purge", "POST", v11: true, scope: "dns"),
            Command("ssl", "GET", v11: true),
            Command("ssl-full", "POST", v11: true, scope: "dns"),
            Command("pg-databases", "GET", v11: true, scope: "databases"),
            Command("pg-users", "GET", v11: true, scope: "databases"),
            Command("pg-user-add", "POST", v11: true, scope: "databases"),
            Command("pg-grant", "POST", v11: true, scope: "databases"),
            Command("pg-clone", "POST", v11: true, scope: "databases"),
            Command("server-env-get", "GET", v11: true),
            Command("server-env-set", "POST", v11: true, scope: "projects_write"),
            // v1.3 (ServerPlanCLIV13.swift). A purchase spends money: always the owner's dialog.
            Command("domain-check", "GET", v11: true, scope: "read", feature: "domain_check", minMinor: 3),
            Command("domain-buy", "POST", v11: true, scope: "domains_buy", gate: .owner, feature: "domain_purchase", minMinor: 3),
            // v1.4: the Namecheap balance (read only).
            Command("balance", "GET", v11: true, scope: "read", feature: ServerPlanContract.Feature.registrarBalance, minMinor: 4),
            // v1.5: Cloudflare rate limiting (ServerPlanCLIRateLimit.swift). Replacing a zone's rule
            // and clearing it: the owner.
            Command("ratelimit-show", "GET", v11: true, scope: "read", feature: "ratelimit", minMinor: 5),
            Command("ratelimit-set", "POST", v11: true, scope: "dns", gate: .owner, feature: "ratelimit", minMinor: 5),
            Command("ratelimit-clear", "POST", v11: true, scope: "dns", gate: .owner, feature: "ratelimit", minMinor: 5),
            // Containers (ServerPlanCLIContainers.swift). Status and server stats work on any panel
            // (the container list, health); env needs v1.1. The rest is ServerPlan's proposed
            // 1.5 (docs/serverplan-containers.md §5): offered once `/me` lists the feature.
            Command("container-inspect", "GET"),
            Command("stats", "GET"),
            Command("container-env", "GET", v11: true),
            Command("container-stats", "GET", scope: "read", feature: ServerPlanContract.Feature.containerStats, featureOnly: true),
            Command("container-recreate", "POST", scope: "containers", gate: .owner,
                    feature: ServerPlanContract.Feature.containerRecreate, featureOnly: true),
            Command("container-pull", "POST", scope: "containers", gate: .owner, feature: ServerPlanContract.Feature.imageUpdate, featureOnly: true),
            Command("container-remove", "POST", scope: "containers", gate: .owner,
                    feature: ServerPlanContract.Feature.containerRemove, featureOnly: true),
            Command("disk", "GET", scope: "read", feature: ServerPlanContract.Feature.dockerPrune, featureOnly: true),
            Command("prune", "POST", scope: "containers", gate: .owner, feature: ServerPlanContract.Feature.dockerPrune, featureOnly: true),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    /// Whether the panel behind `me` offers a v1.1 command (its scope is granted; v1 ones always).
    /// It also needs a panel that says it's 1.1 or later (an unknown version is tried): `deploy`
    /// is a v1 scope, so a scope alone doesn't tell.
    public static func offers(_ command: Command, me: ServerPlanMe?) -> Bool {
        guard command.v11 else { return true }
        guard let me else { return command.feature == nil }
        if let scope = command.scope, !me.scopes.contains(scope) { return false }
        if let feature = command.feature, me.features.contains(feature) { return true }
        if command.featureOnly { return false }
        guard let version = me.serverVersion, let major = Int(version.split(separator: ".").first ?? "") else { return command.feature == nil }
        let minor = version.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
        return major > 1 || major == 1 && minor >= command.minMinor
    }

    static let notAvailable = "not available: ServerPlan doesn't offer this yet"

    /// Commands whose 404 can only mean an older panel without the route: what they name was
    /// resolved (or isn't looked up) first. Not `local-logs` (not running locally), `local-env-unset`
    /// (no override), `clone-status` (unknown job) or `deploy-cancel` (unknown deployment).
    static let missingWhen404: Set<String> = [
        "ports", "dirs", "domain-list", "cloudflare", "static-add", "sync",
        "env-rescan", "sql", "local-run", "local-status", "local-stop", "local-env-get", "local-env-set", "db-clone-local",
        "branches", "refresh", "git-pull", "git-push", "switch-branch", "build", "pull-deploy", "diagnose", "diagnose-fix",
        "domain-set", "domain-apply", "domain-nginx", "domain-purge", "zone-purge", "ssl", "ssl-full",
        "pg-databases", "pg-users", "pg-user-add", "pg-clone", "server-env-get", "server-env-set",
        "domain-check", "domain-buy", "balance",
    ]

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
        /// An owner decision by id (ClaudeDeck's decisions book): `domain buy --approval`.
        public let decision: @Sendable (String) async -> OwnerDecision?
        /// Between looks at the domain list after a lost `domain add` answer (tests: zero).
        var retryDelay: Duration = .seconds(5)

        public init(client: ServerPlanClient, me: ServerPlanMe?, approve: @escaping Approve, log: @escaping @Sendable (String) -> Void = { _ in },
                    decision: @escaping @Sendable (String) async -> OwnerDecision? = { _ in nil }) {
            self.client = client
            self.me = me
            self.approve = approve
            self.log = log
            self.decision = decision
        }

        public func run(_ name: String, method: String, form: [String: String]) async -> Outcome {
            guard let command = ServerPlanCLI.commands[name] else { return .error(404, "unknown_command", exit: .usage) }
            guard command.method == method else { return .error(405, "method_not_allowed", exit: .usage) }
            guard ServerPlanCLI.offers(command, me: me) else {
                return .error(501, "not_available", ServerPlanCLI.notAvailable + " (or the token lacks the \(command.scope ?? "") scope)", exit: .refused)
            }
            do {
                return try await perform(command, form: form)
            } catch let refusal as Refusal {
                return refusal.outcome
            } catch ServerPlanError.notFound where command.v11 && ServerPlanCLI.missingWhen404.contains(command.name) {
                return .error(501, "not_available", ServerPlanCLI.notAvailable, exit: .refused)
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
                let planned = ServerPlanCLI.commands.values.filter(\.v11).sorted { $0.name < $1.name }
                let lines = planned.map { "\($0.name): " + (ServerPlanCLI.offers($0, me: me) ? "available" : "not available (ServerPlan doesn't offer this yet)") }
                let object: [String: Any] = ["features": me.features, "scopes": me.scopes,
                                             "commands": Dictionary(uniqueKeysWithValues: planned.map { ($0.name, ServerPlanCLI.offers($0, me: me)) })]
                return Outcome(json: ServerPlanCLI.data(object), text: (["scopes: " + me.scopes.joined(separator: ", ")] + lines).joined(separator: "\n"))
            // v1.1
            case "ports":
                let server = try await serverID(form["server"])
                let data = try await raw("GET", "/servers/\(server)/ports")
                return Outcome(json: data, text: ServerPlanCLI.portsText(data))
            case "dirs":
                let data = try await raw("GET", "/project-dirs")
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("REMOTE", "is_remote"), ("PATH", "path")]))
            case "scan":
                // A dir id, or a path in (or of) a registered dir: the project at that path is the answer.
                let ref = (form["dir"] ?? "").trimmingCharacters(in: .whitespaces)
                let dirs = ServerPlanCLI.array(try await raw("GET", "/project-dirs")) ?? []
                let dir: [String: Any]?
                if let id = Int(ref) {
                    dir = dirs.first { ServerPlanCLI.value($0, "id") == String(id) }
                } else {
                    guard ref.hasPrefix("/") else { throw Refusal(outcome: .error(400, "bad_path", "a dir id or an absolute path", exit: .usage)) }
                    dir = ServerPlanCLI.dir(containing: ref, dirs)
                }
                guard let dir, let dirID = ServerPlanCLI.value(dir, "id") else {
                    let known = dirs.compactMap { ServerPlanCLI.value($0, "path") }.joined(separator: ", ")
                    throw Refusal(outcome: .error(404, "unknown_dir", "not in a registered project dir (\(known))", exit: .unknown))
                }
                let data = try await raw("POST", "/project-dirs/\(dirID)/scan")
                let projects = ServerPlanCLI.array(data) ?? []
                if ref.hasPrefix("/"), (ServerPlanCLI.value(dir, "path") ?? "") != ref {
                    guard let found = projects.first(where: { ServerPlanCLI.samePath(ServerPlanCLI.value($0, "repo_path|path"), ref) }) else {
                        throw Refusal(outcome: .error(404, "not_found_by_scan", "the scan found no project at \(ref)", exit: .unknown))
                    }
                    return Outcome(json: ServerPlanCLI.data(found), text: "project #\(ServerPlanCLI.value(found, "id") ?? "?") \(ServerPlanCLI.value(found, "display_name|name") ?? "")")
                }
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("NAME", "display_name|name"), ("PATH", "repo_path|path")]))
            case "project-show":
                let project = try await projectID(form["project"])
                let data = try await raw("GET", "/projects/\(project)/settings")
                return Outcome(json: ServerPlanCLI.redactedSettings(data), text: ServerPlanCLI.settingsText(data))
            case "project-set":
                // The panel replaces all four: what isn't given is sent as it is now.
                let project = try await projectID(form["project"])
                let current = ServerPlanCLI.object(try await raw("GET", "/projects/\(project)/settings")) ?? [:]
                var body: [String: Any] = [:]
                body["default_server_id"] = current["default_server_id"] ?? NSNull()
                body["default_port"] = current["default_port"] ?? 0
                body["volume_path"] = current["volume_path"] ?? ""
                body["dockerfile_path"] = current["dockerfile_path"] ?? ""
                var changed = false
                if let server = form["server"], !server.isEmpty { body["default_server_id"] = try await serverID(server); changed = true }
                if let port = form["port"], !port.isEmpty {
                    guard let number = Int(port), (1...65535).contains(number) else { throw Refusal(outcome: .error(400, "bad_port", exit: .usage)) }
                    body["default_port"] = number
                    changed = true
                }
                if let volume = form["volume"], !volume.isEmpty { body["volume_path"] = volume; changed = true }
                if let dockerfile = form["dockerfile"], !dockerfile.isEmpty { body["dockerfile_path"] = dockerfile; changed = true }
                guard changed else { throw Refusal(outcome: .error(400, "nothing_to_set", "--server, --port, --volume or --dockerfile", exit: .usage)) }
                let data = try await raw("PUT", "/projects/\(project)/settings", json: body)
                let shown = ServerPlanCLI.object(data) == nil ? ServerPlanCLI.data(body) : data
                return Outcome(json: ServerPlanCLI.redactedSettings(shown), text: ServerPlanCLI.settingsText(shown))
            case "env-get":
                let project = try await projectID(form["project"])
                let data = try await raw("GET", "/projects/\(project)/env")
                // Secrets never come back; a value the panel sends for one is still not shown.
                // The row id (for `env rm`) when the panel sends one.
                let list = ServerPlanCLI.array(data) ?? []
                let ids = list.contains { $0["id"] != nil }
                let rows = list.map { row -> [String] in
                    let secret = (row["is_secret"] as? Bool) == true
                    let cells = [ServerPlanCLI.value(row, "key") ?? "", secret ? "(secret)" : ServerPlanCLI.value(row, "value") ?? "", ServerPlanCLI.value(row, "source") ?? "-"]
                    return ids ? [ServerPlanCLI.value(row, "id") ?? "-"] + cells : cells
                }
                let header = ids ? ["ID", "KEY", "VALUE", "SOURCE"] : ["KEY", "VALUE", "SOURCE"]
                return Outcome(json: ServerPlanCLI.redactedEnv(data), text: SessionCLI.table([header] + rows))
            case "env-set":
                let project = try await projectID(form["project"])
                let vars = ServerPlanCLI.envAssignments(form["vars"] ?? "")
                guard !vars.isEmpty else { throw Refusal(outcome: .error(400, "no_variables", "KEY=value lines", exit: .usage)) }
                let secrets = Set((form["secret"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                let list = vars.keys.sorted().map { key -> [String: Any] in ["key": key, "value": vars[key]!, "is_secret": secrets.contains(key)] }
                _ = try await raw("POST", "/projects/\(project)/env/bulk", json: ["env_vars": list])
                // Only the keys: what the panel echoes may hold the values.
                return Outcome(json: ServerPlanCLI.data(["written": vars.keys.sorted(), "secret": secrets.sorted()]),
                               text: "written: " + vars.keys.sorted().map { secrets.contains($0) ? "\($0) (secret)" : $0 }.joined(separator: ", "))
            case "dockerfile-template":
                let project = try await projectID(form["project"])
                let data = try await raw("GET", "/projects/\(project)/dockerfile/template")
                let object = ServerPlanCLI.object(data)
                let text = object.flatMap { ServerPlanCLI.value($0, "content|template|dockerfile") } ?? String(decoding: data, as: UTF8.self)
                return Outcome(json: object == nil ? ServerPlanCLI.data(["content": text]) : data, text: text)
            case "dockerfile-write":
                let project = try await projectID(form["project"])
                let content = form["content"] ?? ""
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal(outcome: .error(400, "no_content", exit: .usage)) }
                var body: [String: Any] = ["content": content]
                if let port = form["port"], let number = Int(port), number > 0 { body["port"] = number }
                let data = try await raw("POST", "/projects/\(project)/dockerfile", json: body)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data).ifEmpty("written"))
            case "db-create":
                let project = try await projectID(form["project"])
                let data = try await raw("POST", "/projects/\(project)/auto-create-db")
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "domain-list":
                var query: [URLQueryItem] = []
                if let server = form["server"], !server.isEmpty { query.append(URLQueryItem(name: "server_id", value: String(try await serverID(server)))) }
                // The panel sends subdomain + base_domain ("@" or "" for the root): the FQDN is added here.
                let data = ServerPlanCLI.withFQDN(try await raw("GET", "/domains", query: query))
                return Outcome(json: data, text: ServerPlanCLI.listText(data, [("ID", "id"), ("SERVER", "server_id"), ("TYPE", "type"), ("PORT", "port"),
                                                                              ("PROJECT", "project_name"), ("FQDN", "fqdn")]))
            case "domain-add" where form["static"] == "1":
                // A static site: no project, no port, no owner's dialog (nothing is replaced).
                let server = try await serverID(form["server"])
                let sub = (form["subdomain"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let base = try ServerPlanCLI.baseDomain(form["base"])
                let given = (form["target"] ?? "").trimmingCharacters(in: .whitespaces)
                let target = given.isEmpty ? ServerPlanCLI.staticTarget(subdomain: sub, base: base) : given
                let body: [String: Any] = ["type": "static", "server_id": server, "subdomain": sub, "base_domain": base, "target": target,
                                           "ssl_enabled": true, "clean_urls": form["clean_urls"] != "0"]
                let fqdn = sub.isEmpty || sub == "@" ? base : "\(sub).\(base)"
                let added = try await createDomain(fqdn: fqdn, server: server) { try await raw("POST", "/domains", json: body) }
                log("domain add --static \(fqdn) → \(target)" + (added.slow ? " (the panel answered slowly)" : ""))
                if added.slow { return ServerPlanCLI.slowCreateOutcome(fqdn, row: added.data) }
                return Outcome(json: added.data, text: ServerPlanCLI.objectText(added.data).ifEmpty("added: \(fqdn) (\(target))"))
            case "static-add":
                let server = try await serverID(form["server"])
                let base = try ServerPlanCLI.baseDomain(form["base"])
                let data = try await raw("POST", "/domains/quick-static", json: ["server_id": server, "base_domain": base])
                log("static add \(base)")
                return Outcome(json: data, text: ServerPlanCLI.objectText(data)
                    .ifEmpty("added: \(base) (\(ServerPlanCLI.staticTarget(subdomain: "", base: base)))"))
            case "sync":
                // The command resolved the folder; here it must exist. The panel checks it's in a registered dir.
                let path = (form["path"] ?? "").trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") else { throw Refusal(outcome: .error(400, "bad_path", "an absolute folder path", exit: .usage)) }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw Refusal(outcome: .error(400, "bad_path", "not a folder: \(path)", exit: .usage))
                }
                let domain = try await domainID(form["domain"])
                let data: Data
                do {
                    data = try await raw("POST", "/domains/\(domain.id)/sync", json: ["local_path": path])
                } catch ServerPlanError.forbidden(let message) {
                    let hint = "the folder must be inside a registered project dir (claudedeck server dirs)"
                    throw Refusal(outcome: .error(403, "not_in_project_dir", message.map { "\($0); \(hint)" } ?? hint, exit: .refused))
                }
                log("sync \(domain.fqdn) ← \(path)")
                let message = ServerPlanCLI.object(data).flatMap { ServerPlanCLI.value($0, "message") }
                return Outcome(json: data, text: message ?? ServerPlanCLI.objectText(data).ifEmpty("synced: \(domain.fqdn)"))
            case "domain-add":
                // Server and port: given, or the project's settings.
                let projects = try await client.projects()
                let project = try pick(form["project"], projects.map { ($0.id, $0.name) }, what: "project")
                let sub = (form["subdomain"] ?? "").trimmingCharacters(in: .whitespaces)
                let base = (form["base"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard !base.isEmpty, base.contains(".") else { throw Refusal(outcome: .error(400, "bad_domain", "SUBDOMAIN BASE (e.g. api example.com)", exit: .usage)) }
                let settings = ServerPlanCLI.object(try await raw("GET", "/projects/\(project.id)/settings")) ?? [:]
                let server: Int? = if let given = form["server"], !given.isEmpty { try await serverID(given) } else { ServerPlanCLI.int(settings["default_server_id"]) }
                guard let server else { throw Refusal(outcome: .error(400, "no_server", "--server, or set the project's server first", exit: .usage)) }
                let port = Int(form["port"] ?? "") ?? ServerPlanCLI.int(settings["default_port"]) ?? 0
                guard port > 0 else { throw Refusal(outcome: .error(400, "no_port", "--port, or set the project's port first", exit: .usage)) }
                var body: [String: Any] = ["server_id": server, "subdomain": sub, "base_domain": base, "type": "go_app", "port": port,
                                           "ssl_enabled": true, "clean_urls": false, "websocket_enabled": form["websocket"] == "1",
                                           "project_name": project.name]
                if let target = form["target"], !target.isEmpty { body["target"] = target }
                let fqdn = sub.isEmpty || sub == "@" ? base : "\(sub).\(base)"
                let added = try await createDomain(fqdn: fqdn, server: server) { try await gated(command, "POST", "/domains", body: body, target: fqdn) }
                if added.slow {
                    log("domain add \(fqdn): created; the panel answered slowly")
                    return ServerPlanCLI.slowCreateOutcome(fqdn, row: added.data)
                }
                return Outcome(json: added.data, text: ServerPlanCLI.objectText(added.data).ifEmpty("added: \(fqdn)"))
            case "dns-sync":
                let domain = try await domainID(form["domain"])
                let data = try await gated(command, "POST", "/domains/\(domain.id)/dns-sync", target: domain.fqdn)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data).ifEmpty("synced: \(domain.fqdn)"))
            case "cloudflare":
                let data = try await raw("GET", "/cloudflare/status")
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "zone-add":
                let name = (form["name"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard name.contains(".") else { throw Refusal(outcome: .error(400, "bad_zone", "a domain like example.com", exit: .usage)) }
                let data = try await raw("POST", "/cloudflare/zones", json: ["name": name])
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "ns-set":
                let domain = try await domainID(form["domain"])
                let data = try await gated(command, "POST", "/domains/\(domain.id)/namecheap/nameservers", target: domain.base)
                return Outcome(json: data, text: ServerPlanCLI.objectText(data))
            case "domain-check", "domain-buy", "balance":
                return try await performV13(command, form: form)
            case "container-inspect", "stats", "container-env", "container-stats", "container-recreate", "container-pull",
                 "container-remove", "disk", "prune":
                return try await performContainers(command, form: form)
            case "ratelimit-show", "ratelimit-set", "ratelimit-clear":
                return try await performRateLimit(command, form: form)
            default:
                return try await performV12(command, form: form)
            }
        }

        // MARK: Requests

        func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                 accept: String = "application/json", timeout: TimeInterval = 20) async throws -> Data {
            let wait = max(timeout, ServerPlanCLI.slowCallTimeout(method: method, path: path) ?? 0)
            return try await client.raw(method, path, query: query, json: json, accept: accept, timeout: wait)
        }

        /// Creates a domain. The panel applies Traefik / nginx / Cloudflare before it answers, so
        /// the answer can be lost to a timeout after the row exists: then the domain list is asked
        /// (a few times, the panel may still be writing) and a new row with that FQDN on that
        /// server counts as created (`slow`). One that was already there before doesn't.
        func createDomain(fqdn: String, server: Int, _ post: () async throws -> Data) async throws -> (data: Data, slow: Bool) {
            func find() async -> [String: Any]? {
                guard let rows = try? ServerPlanCLI.array(await raw("GET", "/domains", query: [URLQueryItem(name: "server_id", value: String(server))])) else { return nil }
                return rows.first { ServerPlanCLI.fqdn($0)?.caseInsensitiveCompare(fqdn) == .orderedSame }
            }
            let existed = await find() != nil
            do {
                return (try await post(), false)
            } catch let error as ServerPlanError {
                guard case .transport = error, !existed else { throw error }
                for attempt in 0..<3 {
                    if attempt > 0 { try? await Task.sleep(for: retryDelay) }
                    if let row = await find() { return (ServerPlanCLI.data(row), true) }
                }
                throw error
            }
        }

        /// A request that may answer 428: sent again with the panel's `confirm` once the gate
        /// allows it (deploys automatically; the rest only with the owner's yes).
        func gated(_ command: Command, _ method: String, _ path: String, body: [String: Any] = [:], target: String,
                   timeout: TimeInterval = 20) async throws -> Data {
            do {
                return try await raw(method, path, json: body, timeout: timeout)
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
                return try await raw(method, path, json: confirmed, timeout: timeout)
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
            // `--since` / `--until` / `--timestamps` need the panel (its log lines carry no time);
            // `--grep` is the panel's with `log_query`, else applied here to the fetched tail. The
            // live stream takes only since / timestamps (ServerPlan answers 400 to until or grep),
            // so a followed log is always filtered here.
            let since = (form["since"] ?? "").trimmingCharacters(in: .whitespaces)
            let until = (form["until"] ?? "").trimmingCharacters(in: .whitespaces)
            let grep = (form["grep"] ?? "").trimmingCharacters(in: .whitespaces)
            let timestamps = form["timestamps"] == "1"
            let panelQuery = me?.has(feature: ServerPlanContract.Feature.logQuery) == true
            for (flag, value) in [("--since", since), ("--until", until)] where !value.isEmpty {
                guard panelQuery else {
                    throw Refusal(outcome: .error(501, "not_available", ServerPlanCLI.notAvailable + " (\(flag) needs ServerPlan's log_query)", exit: .refused))
                }
                guard ServerPlanCLI.isValidSince(value) else {
                    throw Refusal(outcome: .error(400, "bad_since", "\(flag): an RFC 3339 time (no spaces) or a duration like 10m, 2h", exit: .usage))
                }
            }
            if timestamps, !panelQuery {
                throw Refusal(outcome: .error(501, "not_available", ServerPlanCLI.notAvailable + " (--timestamps needs ServerPlan's log_query)", exit: .refused))
            }
            if !until.isEmpty, window > 0 {
                throw Refusal(outcome: .error(400, "bad_until", "--until doesn't go with --follow (the live log has no end time)", exit: .usage))
            }
            if panelQuery, window == 0, !ServerPlanLogQuery.isValidGrep(grep) {
                throw Refusal(outcome: .error(400, "bad_grep", "--grep: one line of at most \(ServerPlanLogQuery.grepMax) characters", exit: .usage))
            }
            guard window > 0 else {
                let query = panelQuery && (!since.isEmpty || !until.isEmpty || !grep.isEmpty || timestamps)
                let text: String
                do {
                    text = query
                        ? try await client.containerLogs(serverID: server, container: name, tail: tail, since: since, until: until, grep: grep,
                                                         timestamps: timestamps)
                        : try await client.containerLogs(serverID: server, container: name, tail: tail)
                } catch ServerPlanError.http(let status, _, _) where status == 502 {
                    // ServerPlan answers 502 for docker's "No such container" on logs: say which.
                    try await unknownContainer(server: server, name: name)
                    throw ServerPlanError.http(status: 502, code: "server_unreachable", message: "docker logs failed on the server")
                }
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                while lines.last?.isEmpty == true { lines.removeLast() }
                if !panelQuery { lines = ServerPlanLogFilter.grep(lines, grep) }
                // With grep the panel's pipe hides docker's error: an empty answer may be an unknown container.
                if lines.isEmpty, query, !grep.isEmpty { try await unknownContainer(server: server, name: name) }
                return Outcome(json: ServerPlanCLI.data(["lines": lines]), text: lines.joined(separator: "\n"))
            }
            let stream = try await client.containerLogStream(serverID: server, container: name, tail: tail, since: panelQuery ? since : nil,
                                                             timestamps: timestamps)
            let collector = Task { () -> ([String], Bool) in
                var lines: [String] = []
                do {
                    for try await event in stream {
                        if event.event == "end" { return (lines, true) }
                        if event.event == "log" {
                            let line = (try? JSONDecoder().decode(ServerPlanLogLine.self, from: Data(event.data.utf8)))?.line ?? event.data
                            if ServerPlanLogFilter.grep([line], grep).isEmpty { continue }
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

        /// Throws the CLI's unknown-container refusal (exit 5) when `name` isn't on the server.
        private func unknownContainer(server: Int, name: String) async throws {
            guard let list = try? await client.containers(serverID: server), !list.contains(where: { $0.name == name }) else { return }
            let known = list.map(\.name).joined(separator: ", ")
            throw Refusal(outcome: .error(404, "unknown_container", "\(name) isn't on the server (\(known.isEmpty ? "no containers" : known))",
                                          exit: .unknown))
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

        /// A domain by id or FQDN, with its base domain (Namecheap's confirmation).
        func domainID(_ ref: String?) async throws -> (id: Int, fqdn: String, base: String) {
            let rows = ServerPlanCLI.array(try await raw("GET", "/domains")) ?? []
            let items = rows.compactMap { row -> (Int, String)? in
                guard let id = ServerPlanCLI.value(row, "id").flatMap(Int.init) else { return nil }
                return (id, ServerPlanCLI.fqdn(row) ?? "")
            }
            let found = try pick(ref, items, what: "domain")
            let row = rows.first { ServerPlanCLI.value($0, "id") == String(found.id) } ?? [:]
            let base = ServerPlanCLI.value(row, "base_domain") ?? found.name.split(separator: ".").suffix(2).joined(separator: ".")
            return (found.id, found.name, base)
        }
    }

    // MARK: Domains

    /// A domain row's FQDN: the panel's `fqdn` if it sends one, else `subdomain.base_domain`, and
    /// just `base_domain` for the root (subdomain "@", which quick-static always uses, or "").
    public static func fqdn(_ row: [String: Any]) -> String? {
        if let given = value(row, "fqdn") { return given }
        guard let base = value(row, "base_domain") else { return value(row, "domain|name") }
        let sub = (row["subdomain"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return sub.isEmpty || sub == "@" ? base : "\(sub).\(base)"
    }

    /// The domain list with each row's `fqdn` filled in (`domain list` prints and passes it).
    static func withFQDN(_ data: Data) -> Data {
        guard let rows = array(data) else { return data }
        return ServerPlanCLI.data(rows.map { row in
            var row = row
            if let fqdn = fqdn(row) { row["fqdn"] = fqdn }
            return row
        })
    }

    /// `domain add` whose answer was lost to a timeout but whose row is there.
    static func slowCreateOutcome(_ fqdn: String, row: Data) -> Outcome {
        var object = ServerPlanCLI.object(row) ?? [:]
        object["slow_answer"] = true
        return Outcome(json: ServerPlanCLI.data(object),
                       text: "added: \(fqdn) (created; the panel answered slowly, check it with: claudedeck server domain list)")
    }

    /// Calls the panel does synchronously over SSH, nginx and Cloudflare (domains, databases,
    /// scans): they get 3 minutes instead of the default 20 s. The script's curl waits longer.
    public static func slowCallTimeout(method: String, path: String) -> TimeInterval? {
        let slow = method == "POST" && (
            path == "/domains" || path == "/domains/quick-static" || path == "/domains/purchase"
                || path.wholeMatch(of: /\/domains\/\d+\/(sync|apply|deploy-nginx)/) != nil
                || path.wholeMatch(of: /\/projects\/\d+\/auto-create-db/) != nil
                || path.wholeMatch(of: /\/servers\/\d+\/pg\/databases\/[^\/]+\/clone(-for-local)?/) != nil
                || path.wholeMatch(of: /\/project-dirs\/\d+\/scan/) != nil
        ) || method == "PUT" && path.wholeMatch(of: /\/domains\/\d+/) != nil
        return slow ? 180 : nil
    }

    // MARK: Static sites

    /// A base domain (`example.com`), lowercased.
    static func baseDomain(_ value: String?) throws -> String {
        let base = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard base.contains("."), !base.hasPrefix("."), !base.hasSuffix("."), !base.contains("/") else {
            throw Runner.Refusal(outcome: .error(400, "bad_domain", "a base domain like example.com", exit: .usage))
        }
        return base
    }

    /// The panel's convention: `/opt/static/<base with dashes>` for the root site (quick-static),
    /// `/opt/static/<sub>-<base with dashes>` for a subdomain.
    public static func staticTarget(subdomain: String, base: String) -> String {
        "/opt/static/" + (subdomain.isEmpty ? base : "\(subdomain).\(base)").lowercased().replacingOccurrences(of: ".", with: "-")
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

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    static func samePath(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        func trimmed(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        return trimmed(a) == trimmed(b)
    }

    /// The registered dir a path is in (the longest match), or is.
    static func dir(containing path: String, _ dirs: [[String: Any]]) -> [String: Any]? {
        dirs.filter { dir in
            guard let root = value(dir, "path") else { return false }
            return samePath(root, path) || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }.max { (value($0, "path") ?? "").count < (value($1, "path") ?? "").count }
    }

    /// `/servers/:id/ports`: the suggested port, the used ones (with their domain and project) and
    /// some free ones.
    public static func portsText(_ data: Data) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let used = object["used_ports"] as? [String: Any] ?? [:]
        let projects = object["port_projects"] as? [String: Any] ?? [:]
        var lines: [String] = []
        if let suggested = object["suggested_port"].flatMap(string) { lines.append("suggested: \(suggested)") }
        let ports = Set(used.keys).union(projects.keys).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        if !ports.isEmpty {
            lines.append(SessionCLI.table([["PORT", "DOMAIN", "PROJECT"]] + ports.map { [$0, used[$0].flatMap(string) ?? "-", projects[$0].flatMap(string) ?? "-"] }))
        }
        if let free = object["free_ports"] as? [Any], !free.isEmpty {
            lines.append("free: " + free.prefix(10).compactMap(string).joined(separator: ", ") + (free.count > 10 ? ", …" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// `/projects/:id/settings` as text: env vars by key only (secrets are null anyway).
    public static func settingsText(_ data: Data) -> String {
        guard var object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let env = object.removeValue(forKey: "env_vars") as? [[String: Any]]
        var text = objectText(ServerPlanCLI.data(object))
        if let env { text += "\nenv_vars: " + env.compactMap { value($0, "key") }.joined(separator: ", ") }
        return text
    }

    static func redactedSettings(_ data: Data) -> Data {
        guard var object = object(data) else { return data }
        if let env = object["env_vars"] { object["env_vars"] = (try? JSONSerialization.jsonObject(with: redactedEnv(ServerPlanCLI.data(env)))) ?? env }
        return ServerPlanCLI.data(object)
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
    /// `timeout`: longer for what the panel does over SSH or docker (SQL, builds, git).
    public func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                    accept: String = "application/json", timeout: TimeInterval = 20) async throws -> Data {
        try await send(try request(path, method: method, query: query, json: json, accept: accept, timeout: timeout)).0
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
