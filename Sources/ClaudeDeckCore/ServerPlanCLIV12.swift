import Foundation

/// The v1.2 agent API behind `claudedeck server …`: SQL on a project's database, local runs with
/// local-only env, dev copies of a database, git / build / diagnose wrappers, domain edits,
/// Cloudflare cache and SSL, Postgres admin and server env. Plus `env rescan` (v1.1).
///
/// Panel errors are the agent API's `{"error","message"}`; a 428 goes through `gated` (all of
/// these are the owner's dialog, see `ServerPlanCLI.commands`).
extension ServerPlanCLI.Runner {
    func performV12(_ command: ServerPlanCLI.Command, form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        switch command.name {
        case "env-rescan":
            let project = try await projectID(form["project"])
            let dryRun = form["dry_run"] == "1"
            let data = try await raw("POST", "/projects/\(project)/env/rescan", json: ["dry_run": dryRun])
            let added = (ServerPlanCLI.object(data)?["added"] as? [[String: Any]]) ?? []
            let keys = added.map { row in
                (ServerPlanCLI.value(row, "key") ?? "?") + ((row["is_secret"] as? Bool) == true ? " (secret)" : "")
            }
            let text = keys.isEmpty ? "nothing new in .env.example"
                : (dryRun ? "would add: " : "added: ") + keys.joined(separator: ", ")
            // Keys only, whatever else the panel sends.
            let rows = added.map { ["key": $0["key"] ?? NSNull(), "is_secret": $0["is_secret"] ?? false] }
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(["dry_run": dryRun, "added": rows]), text: text)

        case "sql":
            return try await sql(command, form)

        // MARK: Local runs
        case "local-run":
            let project = try await projectID(form["project"])
            var body: [String: Any] = [:]
            if let server = form["server"], !server.isEmpty { body["server_id"] = try await serverID(server) }
            if let port = form["port"], !port.isEmpty {
                guard let number = Int(port), (1...65535).contains(number) else { throw Refusal(outcome: .error(400, "bad_port", exit: .usage)) }
                body["port"] = number
            }
            if form["no_cache"] == "1" { body["no_cache"] = true }
            let data = try await raw("POST", "/projects/\(project)/local-run", json: body, timeout: 120)
            log("local run project #\(project)")
            let object = ServerPlanCLI.object(data) ?? [:]
            var text = "local run started"
            if let url = ServerPlanCLI.value(object, "local_url") { text += ": \(url)" }
            if let name = ServerPlanCLI.value(object, "container_name") { text += " (\(name))" }
            if let db = ServerPlanCLI.value(object, "db_host") { text += "\ndb: \(db)" + (ServerPlanCLI.value(object, "db_source").map { " (\($0))" } ?? "") }
            return ServerPlanCLI.Outcome(json: data, text: text)
        case "local-status":
            return try await localStatus(form)
        case "local-logs":
            let project = try await projectID(form["project"])
            let tail = min(max(Int(form["tail"] ?? "") ?? 200, 1), 5000)
            let data = try await raw("GET", "/projects/\(project)/local-logs", query: [URLQueryItem(name: "tail", value: String(tail))],
                                     accept: "text/plain")
            let text = String(decoding: data, as: UTF8.self)
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(["lines": text.split(separator: "\n").map(String.init)]), text: text.trimmingCharacters(in: .newlines))
        case "local-stop":
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/projects/\(project)/local-stop", timeout: 60)
            log("local stop project #\(project)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "stopped"))
        case "local-env-get":
            let project = try await projectID(form["project"])
            let data = try await raw("GET", "/projects/\(project)/local-env")
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.redactedEnv(data), text: Self.envTable(data, empty: "(no local overrides)"))
        case "local-env-set":
            let project = try await projectID(form["project"])
            let vars = ServerPlanCLI.envAssignments(form["vars"] ?? "")
            guard !vars.isEmpty else { throw Refusal(outcome: .error(400, "no_variables", "KEY=value lines", exit: .usage)) }
            _ = try await raw("PUT", "/projects/\(project)/local-env", json: ["vars": vars])
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(["written": vars.keys.sorted()]), text: "written (local only): " + vars.keys.sorted().joined(separator: ", "))
        case "local-env-unset":
            let project = try await projectID(form["project"])
            let keys = Self.keys(form["keys"])
            guard !keys.isEmpty else { throw Refusal(outcome: .error(400, "no_keys", "which keys?", exit: .usage)) }
            var removed: [String] = [], missing: [String] = []
            for key in keys {
                do {
                    _ = try await raw("DELETE", "/projects/\(project)/local-env/\(ServerPlanClient.pathComponent(key))")
                    removed.append(key)
                } catch ServerPlanError.notFound {
                    missing.append(key)
                }
            }
            guard !removed.isEmpty else {
                return .error(404, "no_local_override", "no local override: " + missing.joined(separator: ", "), exit: .unknown)
            }
            var lines = ["removed: " + removed.joined(separator: ", ")]
            if !missing.isEmpty { lines.append("no local override: " + missing.joined(separator: ", ")) }
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(["removed": removed, "missing": missing]), text: lines.joined(separator: "\n"))

        // MARK: Database copies
        case "db-clone-local":
            let project = try await projectID(form["project"])
            let server: Int
            if let given = form["server"], !given.isEmpty {
                server = try await serverID(given)
            } else {
                let settings = ServerPlanCLI.object(try await raw("GET", "/projects/\(project)/settings")) ?? [:]
                guard let id = ServerPlanCLI.int(settings["default_server_id"]) else {
                    throw Refusal(outcome: .error(400, "no_server", "--server, or set the project's server first", exit: .usage))
                }
                server = id
            }
            var source = (form["database"] ?? "").trimmingCharacters(in: .whitespaces)
            if source.isEmpty {
                // The project's DB_NAME (never a secret) is the database it deploys with.
                let env = ServerPlanCLI.array(try await raw("GET", "/projects/\(project)/env")) ?? []
                source = env.first { ServerPlanCLI.value($0, "key") == "DB_NAME" }.flatMap { ServerPlanCLI.value($0, "value") } ?? ""
                guard !source.isEmpty else { throw Refusal(outcome: .error(400, "no_database", "--database DB (the project has no DB_NAME)", exit: .usage)) }
            }
            var body: [String: Any] = ["project_id": project]
            if let target = form["target"], !target.isEmpty { body["target_name"] = target }
            let data = try await raw("POST", "/servers/\(server)/pg/databases/\(ServerPlanClient.pathComponent(source))/clone-for-local", json: body, timeout: 60)
            let object = ServerPlanCLI.object(data) ?? [:]
            let target = ServerPlanCLI.value(object, "target|local_env.DB_NAME") ?? form["target"] ?? "\(source)_dev"
            log("db clone-for-local \(source) → \(target) (project #\(project))")
            let job = ServerPlanCLI.value(object, "job_id") ?? "?"
            // `next`: the job, for `--wait`.
            return ServerPlanCLI.Outcome(json: data, text: "clone job \(job): \(source) → \(target)\nthe project's local env DB_NAME is now \(target) (the deploy env is unchanged)",
                           next: job)
        case "clone-status":
            return try await cloneStatus(form)

        // MARK: Projects: git, build, diagnose
        case "branches":
            let project = try await projectID(form["project"])
            let data = try await raw("GET", "/projects/\(project)/branches", timeout: 60)
            let object = ServerPlanCLI.object(data) ?? [:]
            let current = ServerPlanCLI.value(object, "current_branch") ?? ""
            let branches = (object["branches"] as? [Any] ?? []).compactMap { ($0 as? String) ?? ($0 as? [String: Any]).flatMap { ServerPlanCLI.value($0, "name") } }
            let text = branches.map { ($0 == current ? "* " : "  ") + $0 }.joined(separator: "\n")
            return ServerPlanCLI.Outcome(json: data, text: text.isEmpty ? "(no branches)" : text)
        case "refresh":
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/projects/\(project)/refresh", timeout: 60)
            let object = ServerPlanCLI.object(data) ?? [:]
            let name = ServerPlanCLI.value(object, "display_name|name") ?? "#\(project)"
            let branch = ServerPlanCLI.value(object, "git_branch|branch").map { " (\($0))" } ?? ""
            return ServerPlanCLI.Outcome(json: data, text: "refreshed: \(name)\(branch)")
        case "git-pull":
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/projects/\(project)/git-pull", timeout: 120)
            log("git pull project #\(project)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "pulled", key: "log|message"))
        case "git-push":
            let project = try await projectNamed(form["project"])
            let data = try await gated(command, "POST", "/projects/\(project.id)/git-push", target: project.name, timeout: 120)
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "pushed", key: "log|message"))
        case "switch-branch":
            let project = try await projectNamed(form["project"])
            let branch = (form["branch"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !branch.isEmpty, !branch.hasPrefix("-") else { throw Refusal(outcome: .error(400, "no_branch", "which branch?", exit: .usage)) }
            let data = try await gated(command, "POST", "/projects/\(project.id)/switch-branch", body: ["branch": branch], target: project.name, timeout: 120)
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "switched to \(branch)"))
        case "build":
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/projects/\(project)/build", json: form["no_cache"] == "1" ? ["no_cache": true] : [:], timeout: 1200)
            log("build project #\(project)")
            let object = ServerPlanCLI.object(data) ?? [:]
            var lines = (ServerPlanCLI.value(object, "output") ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if lines.count > 40 { lines = ["…"] + lines.suffix(40) }
            if let image = ServerPlanCLI.value(object, "image") { lines.append("image: \(image)") }
            if let binary = ServerPlanCLI.value(object, "binary") { lines.append("binary: \(binary)") }
            return ServerPlanCLI.Outcome(json: data, text: lines.isEmpty ? "built" : lines.joined(separator: "\n"))
        case "pull-deploy":
            let project = try await projectNamed(form["project"])
            var body: [String: Any] = [:]
            if let server = form["server"], !server.isEmpty {
                body["server_id"] = try await serverID(server)
            } else {
                let settings = ServerPlanCLI.object(try await raw("GET", "/projects/\(project.id)/settings")) ?? [:]
                guard let id = ServerPlanCLI.int(settings["default_server_id"]) else {
                    throw Refusal(outcome: .error(400, "no_server", "--server, or set the project's server first", exit: .usage))
                }
                body["server_id"] = id
            }
            if form["force"] == "1" { body["force_rebuild"] = true }
            let data = try await raw("POST", "/projects/\(project.id)/pull-deploy", json: body, timeout: 60)
            guard let id = ServerPlanCLI.object(data).flatMap({ ServerPlanCLI.value($0, "deployment_id") }) else {
                throw ServerPlanError.decoding("no deployment_id")
            }
            log("pull-deploy \(project.name): deployment #\(id)")
            return ServerPlanCLI.Outcome(json: data, text: id)
        case "diagnose":
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/projects/\(project)/diagnose", timeout: 120)
            return ServerPlanCLI.Outcome(json: data, text: Self.diagnoseText(data))
        case "diagnose-fix":
            let project = try await projectNamed(form["project"])
            let action = (form["action"] ?? "").trimmingCharacters(in: .whitespaces)
            guard action.wholeMatch(of: /[a-z][a-z_]{0,40}/) != nil else {
                throw Refusal(outcome: .error(400, "bad_action", "a fix_action from server diagnose (e.g. fix_restart)", exit: .usage))
            }
            let data = try await gated(command, "POST", "/projects/\(project.id)/diagnose/fix", body: ["action": action], target: project.name, timeout: 120)
            let failed = (ServerPlanCLI.object(data)?["success"] as? Bool) == false
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "done: \(action)"), exit: failed ? .failed : .ok)
        case "deploy-cancel":
            guard let id = Int(form["id"] ?? "") else { throw Refusal(outcome: .error(400, "bad_id", exit: .usage)) }
            let data = try await gated(command, "POST", "/deployments/\(id)/cancel", target: "deployment #\(id)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "cancelled: deployment #\(id)"))

        // MARK: Domains, Cloudflare
        case "domain-set":
            return try await domainSet(command, form)
        case "domain-apply", "domain-nginx", "domain-purge":
            let domain = try await domainID(form["domain"])
            let path = ["domain-apply": "apply", "domain-nginx": "deploy-nginx", "domain-purge": "purge-cache"][command.name]!
            let data = try await raw("POST", "/domains/\(domain.id)/\(path)", timeout: 120)
            log("\(command.name) \(domain.fqdn)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "done: \(domain.fqdn)"))
        case "zone-purge", "ssl-full":
            let base = try ServerPlanCLI.baseDomain(form["base"])
            let path = command.name == "zone-purge" ? "/cloudflare/purge-zone" : "/cloudflare/ssl-full"
            let data = try await raw("POST", path, json: ["base_domain": base], timeout: 60)
            log("\(command.name) \(base)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "done: \(base)"))
        case "ssl":
            let base = try ServerPlanCLI.baseDomain(form["base"])
            let data = try await raw("GET", "/cloudflare/ssl", query: [URLQueryItem(name: "domain", value: base)])
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.objectText(data))

        // MARK: Postgres
        case "pg-databases":
            let server = try await serverID(form["server"])
            let data = try await raw("GET", "/servers/\(server)/pg/databases", timeout: 60)
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.listText(data, [("NAME", "name"), ("OWNER", "owner"), ("SIZE", "size")]))
        case "pg-users":
            let server = try await serverID(form["server"])
            let data = try await raw("GET", "/servers/\(server)/pg/users", timeout: 60)
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.listText(data, [("NAME", "name"), ("SUPERUSER", "is_superuser"), ("DATABASES", "databases")]))
        case "pg-user-add":
            let server = try await serverID(form["server"])
            let username = try Self.identifier(form["username"], what: "user name")
            let project = try await projectID(form["project"])
            let data = try await raw("POST", "/servers/\(server)/pg/users", json: ["username": username, "project_id": project], timeout: 60)
            log("pg user add \(username) (project #\(project))")
            // The password goes to the project's env; never shown, even if a panel sent it.
            var object = ServerPlanCLI.object(data) ?? [:]
            object.removeValue(forKey: "password")
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(object),
                           text: "created \(username); DB_USER and DB_PASSWORD (secret) are in the project's env")
        case "pg-grant":
            let server = try await serverID(form["server"])
            let user = try Self.identifier(form["username"], what: "user name")
            let database = try Self.identifier(form["database"], what: "database")
            var body: [String: Any] = ["database": database]
            if form["revoke"] == "1" { body["revoke"] = true }
            let data = try await raw("POST", "/servers/\(server)/pg/users/\(ServerPlanClient.pathComponent(user))/grant", json: body, timeout: 60)
            log("pg \(form["revoke"] == "1" ? "revoke" : "grant") \(user) on \(database)")
            return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "done"))
        case "pg-clone":
            let server = try await serverID(form["server"])
            let source = try Self.identifier(form["database"], what: "database")
            let target = try Self.identifier(form["target"], what: "new database name")
            var body: [String: Any] = ["target_name": target]
            var warning: String?
            if let given = form["project"], !given.isEmpty {
                let project = try await projectNamed(given)
                body["project_id"] = project.id
                warning = "warning: \(project.name)'s deploy env DB_NAME now points at \(target): its next deploy uses the copy"
            }
            let data = try await raw("POST", "/servers/\(server)/pg/databases/\(ServerPlanClient.pathComponent(source))/clone", json: body, timeout: 60)
            log("pg clone \(source) → \(target)" + (warning == nil ? "" : " (switches the deploy DB_NAME)"))
            let job = ServerPlanCLI.object(data).flatMap { ServerPlanCLI.value($0, "job_id") } ?? "?"
            return ServerPlanCLI.Outcome(json: data, text: "clone job \(job): \(source) → \(target)" + (warning.map { "\n" + $0 } ?? ""), next: job)

        // MARK: Server env
        case "server-env-get":
            let server = try await serverID(form["server"])
            let data = try await raw("GET", "/servers/\(server)/env")
            // The panel sends null for secret-looking keys.
            let rows = (ServerPlanCLI.array(data) ?? []).map { row -> [String] in
                [ServerPlanCLI.value(row, "key") ?? "", row["value"] is NSNull || row["value"] == nil ? "(secret)" : ServerPlanCLI.value(row, "value") ?? "",
                 ServerPlanCLI.value(row, "description") ?? "-"]
            }
            return ServerPlanCLI.Outcome(json: data, text: rows.isEmpty ? "(none)" : SessionCLI.table([["KEY", "VALUE", "DESCRIPTION"]] + rows))
        case "server-env-set":
            let server = try await serverID(form["server"])
            let vars = ServerPlanCLI.envAssignments(form["vars"] ?? "")
            guard !vars.isEmpty else { throw Refusal(outcome: .error(400, "no_variables", "KEY=value lines", exit: .usage)) }
            for key in vars.keys.sorted() {
                _ = try await raw("POST", "/servers/\(server)/env", json: ["key": key, "value": vars[key]!])
            }
            log("server-env set \(vars.keys.sorted().joined(separator: ",")) on server #\(server)")
            return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(["written": vars.keys.sorted()]), text: "written: " + vars.keys.sorted().joined(separator: ", "))
        default:
            return .error(404, "unknown_command", exit: .usage)
        }
    }

    // MARK: SQL

    /// One statement on the project's database (`--local`: the local env's DB_NAME). Reads run
    /// read-only on the panel; a write is a 428 whose confirmation (the database name) only the
    /// owner gives.
    private func sql(_ command: ServerPlanCLI.Command, _ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let project = try await projectNamed(form["project"])
        let query = (form["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw Refusal(outcome: .error(400, "no_query", "a SQL statement", exit: .usage)) }
        let write = form["write"] == "1"
        var body: [String: Any] = ["query": query, "target": form["local"] == "1" ? "local" : "deploy"]
        if write { body["write"] = true }
        let data = try await gated(command, "POST", "/projects/\(project.id)/sql", body: body, target: project.name, timeout: write ? 90 : 60)
        return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.sqlText(data))
    }

    // MARK: Long polls

    /// `local-status`; with `wait=N`, polls (every 2 s) until the run is no longer building or N
    /// seconds passed. `since`: the status already shown (only a change is printed). Exit 0
    /// running (or no wait), 1 failed / stopped / not running, 124 still building.
    private func localStatus(_ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let project = try await projectID(form["project"])
        let window = min(SessionCLI.maxWaitWindow, max(0, Int(form["wait"] ?? "") ?? 0))
        let deadline = Date().addingTimeInterval(TimeInterval(window))
        func status(_ data: Data) -> String {
            let object = ServerPlanCLI.object(data) ?? [:]
            return ServerPlanCLI.value(object, "status").map { $0.replacingOccurrences(of: " ", with: "_") } ?? ((object["running"] as? Bool) == true ? "running" : "not_running")
        }
        var data = try await raw("GET", "/projects/\(project)/local-status")
        while window > 0, status(data) == "building", Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            data = try await raw("GET", "/projects/\(project)/local-status")
        }
        let now = status(data)
        let object = ServerPlanCLI.object(data) ?? [:]
        var lines: [String] = []
        if window == 0 || form["since"] != now || now != "building" {
            var line = "local: \(now)"
            if let url = ServerPlanCLI.value(object, "local_url"), now == "running" || now == "building" { line += " \(url)" }
            lines.append(line)
            if let error = ServerPlanCLI.value(object, "error") { lines.append("error: \(error)") }
        }
        let exit: SessionCLI.Exit = window == 0 || now == "running" ? .ok : now == "building" ? .timeout : .failed
        return ServerPlanCLI.Outcome(json: data, text: lines.joined(separator: "\n"), exit: exit, next: now)
    }

    /// A clone job (`/pg/clone-jobs/:id`); with `wait=N` a long poll like `localStatus`.
    /// `since`: events already shown. Exit 0 success (or no wait), 1 error, 124 still running.
    private func cloneStatus(_ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let job = (form["id"] ?? "").trimmingCharacters(in: .whitespaces)
        guard job.wholeMatch(of: /[A-Za-z0-9_-]{1,80}/) != nil else { throw Refusal(outcome: .error(400, "bad_id", "a clone job id", exit: .usage)) }
        let since = max(0, Int(form["since"] ?? "") ?? 0)
        let window = min(SessionCLI.maxWaitWindow, max(0, Int(form["wait"] ?? "") ?? 0))
        let deadline = Date().addingTimeInterval(TimeInterval(window))
        func read() async throws -> (status: String, events: [[String: Any]], data: Data) {
            let data = try await raw("GET", "/pg/clone-jobs/\(job)")
            let object = ServerPlanCLI.object(data) ?? [:]
            return (ServerPlanCLI.value(object, "status") ?? "unknown", object["events"] as? [[String: Any]] ?? [], data)
        }
        var state = try await read()
        while window > 0, state.status == "running", state.events.count <= since, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            state = try await read()
        }
        let shown = window == 0 ? state.events : Array(state.events.dropFirst(min(since, state.events.count)))
        var lines = shown.map { event -> String in
            let progress = ServerPlanCLI.value(event, "progress").map { "[\($0)%] " } ?? ""
            let text = ServerPlanCLI.value(event, "message") ?? ServerPlanCLI.value(event, "step") ?? ""
            return progress + text + (ServerPlanCLI.value(event, "error").map { " (\($0))" } ?? "")
        }
        if window == 0 || state.status != "running" { lines.append("clone \(job): \(state.status)") }
        let exit: SessionCLI.Exit = state.status == "success" ? .ok : state.status == "running" ? (window > 0 ? .timeout : .ok) : .failed
        return ServerPlanCLI.Outcome(json: state.data, text: lines.joined(separator: "\n"), exit: exit, next: String(state.events.count))
    }

    // MARK: Domain edit

    /// `PUT /domains/:id` replaces every field: the current row, with what's given changed.
    private func domainSet(_ command: ServerPlanCLI.Command, _ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let domain = try await domainID(form["domain"])
        let rows = ServerPlanCLI.array(try await raw("GET", "/domains")) ?? []
        guard let row = rows.first(where: { ServerPlanCLI.value($0, "id") == String(domain.id) }) else { throw ServerPlanError.notFound }
        func flag(_ key: String, _ current: Any?) -> Bool {
            switch form[key] { case "1": true; case "0": false; default: (current as? Bool) ?? false }
        }
        var body: [String: Any] = [
            "server_id": ServerPlanCLI.int(row["server_id"]) ?? 0,
            "subdomain": ServerPlanCLI.value(row, "subdomain") ?? "",
            "base_domain": ServerPlanCLI.value(row, "base_domain") ?? domain.base,
            "type": ServerPlanCLI.value(row, "type") ?? "go_app",
            "target": ServerPlanCLI.value(row, "target") ?? "",
            "port": ServerPlanCLI.int(row["port"]) ?? 0,
            "ssl_enabled": flag("ssl", row["ssl_enabled"] ?? true),
            "clean_urls": flag("clean_urls", row["clean_urls"]),
            "websocket_enabled": flag("websocket", row["websocket_enabled"]),
            "project_name": ServerPlanCLI.value(row, "project_name") ?? "",
        ]
        var changed = ["ssl", "clean_urls", "websocket"].contains { form[$0] == "1" || form[$0] == "0" }
        if let server = form["server"], !server.isEmpty { body["server_id"] = try await serverID(server); changed = true }
        if let port = form["port"], !port.isEmpty {
            guard let number = Int(port), (1...65535).contains(number) else { throw Refusal(outcome: .error(400, "bad_port", exit: .usage)) }
            body["port"] = number
            changed = true
        }
        if let target = form["target"], !target.isEmpty { body["target"] = target; changed = true }
        if let project = form["project"], !project.isEmpty { body["project_name"] = try await projectNamed(project).name; changed = true }
        guard changed else {
            throw Refusal(outcome: .error(400, "nothing_to_set", "--server, --port, --target, --project, --[no-]websocket, --[no-]clean-urls or --[no-]ssl", exit: .usage))
        }
        let data = try await gated(command, "PUT", "/domains/\(domain.id)", body: body, target: domain.fqdn, timeout: 60)
        log("domain set \(domain.fqdn)")
        return ServerPlanCLI.Outcome(json: data, text: Self.message(data, "updated: \(domain.fqdn)"))
    }

    // MARK: Helpers

    /// A project by id or name, with the name the panel confirms with.
    func projectNamed(_ ref: String?) async throws -> (id: Int, name: String) {
        try pick(ref, try await client.projects().map { ($0.id, $0.name) }, what: "project")
    }

    /// A Postgres name (user, database): letters, digits, `_`.
    static func identifier(_ value: String?, what: String) throws -> String {
        let name = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]{0,62}/) != nil else {
            throw Refusal(outcome: .error(400, "bad_name", "not a valid \(what): \(name)", exit: .usage))
        }
        return name
    }

    /// Keys separated by commas, spaces or newlines.
    static func keys(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init).filter { !$0.isEmpty }
    }

    /// The panel's `message` (or `key`), else `fallback`.
    static func message(_ data: Data, _ fallback: String, key: String = "message") -> String {
        guard let object = ServerPlanCLI.object(data) else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : text
        }
        return ServerPlanCLI.value(object, key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }

    /// KEY VALUE rows; a secret's value never shown.
    static func envTable(_ data: Data, empty: String) -> String {
        let rows = (ServerPlanCLI.array(data) ?? []).map { row -> [String] in
            let secret = (row["is_secret"] as? Bool) == true
            return [ServerPlanCLI.value(row, "key") ?? "", secret ? "(secret)" : ServerPlanCLI.value(row, "value") ?? ""]
        }
        return rows.isEmpty ? empty : SessionCLI.table([["KEY", "VALUE"]] + rows)
    }

    static func diagnoseText(_ data: Data) -> String {
        guard let object = ServerPlanCLI.object(data) else { return String(decoding: data, as: UTF8.self) }
        var lines: [String] = []
        let head = [ServerPlanCLI.value(object, "project"), ServerPlanCLI.value(object, "server").map { "on \($0)" },
                    ServerPlanCLI.value(object, "container_name").map { "(container \($0))" }].compactMap { $0 }
        if !head.isEmpty { lines.append(head.joined(separator: " ")) }
        let checks = object["checks"] as? [[String: Any]] ?? []
        if !checks.isEmpty {
            lines.append(SessionCLI.table([["CHECK", "STATUS", "MESSAGE", "FIX"]] + checks.map { check in
                [ServerPlanCLI.value(check, "label|name") ?? "", ServerPlanCLI.value(check, "status") ?? "", ServerPlanCLI.value(check, "message") ?? "",
                 (check["fix_available"] as? Bool) == true ? ServerPlanCLI.value(check, "fix_action") ?? "yes" : "-"]
            }))
        }
        return lines.joined(separator: "\n")
    }
}

extension ServerPlanCLI {
    /// `/projects/:id/sql`: a read's columns and rows as a table, a write's psql output.
    public static func sqlText(_ data: Data) -> String {
        guard let object = object(data) else { return String(decoding: data, as: UTF8.self) }
        let database = value(object, "database").map { " (\($0))" } ?? ""
        guard let columns = object["columns"] as? [Any], !columns.isEmpty else {
            let output = (object["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "done\(database)" : output
        }
        let rows = (object["rows"] as? [[Any]] ?? []).map { $0.map { string($0) ?? "NULL" } }
        let header = columns.map { string($0) ?? "" }
        var text = SessionCLI.table([header] + rows)
        let count = int(object["row_count"]) ?? rows.count
        text += "\n(\(count) row\(count == 1 ? "" : "s")\((object["truncated"] as? Bool) == true ? ", truncated" : "")\(database))"
        return text
    }
}
