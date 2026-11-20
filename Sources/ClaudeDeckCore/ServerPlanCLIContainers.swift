import Foundation

/// `claudedeck server container SERVER CONTAINER inspect|status|env|stats|recreate|pull|remove`,
/// `server stats SERVER`, `server disk SERVER`, `server prune SERVER`.
///
/// What a 1.4 panel can answer is built from its container list, domains, projects, health and
/// project env (`container-inspect`, `stats`, `container-env`). The rest is ServerPlan's proposed
/// 1.5 (docs/serverplan-containers.md §5), offered only once `/me` lists the feature. Everything
/// that changes a container or the server's docker goes through the owner (gate `.owner`): the
/// panel's 428 summary becomes a card in the Onaylar queue.
extension ServerPlanCLI.Runner {
    func performContainers(_ command: ServerPlanCLI.Command, form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        switch command.name {
        case "container-inspect":
            return try await containerInspect(form)
        case "container-env":
            let (server, container) = try await serverAndContainer(form)
            let domains = (try? await client.domains(serverID: server.id)) ?? []
            let projects = try await client.projects()
            guard let project = ServerPlanContainerMatch.project(for: container, serverID: server.id, projects: projects, domains: domains) else {
                throw Refusal(outcome: .error(404, "no_project", "\(container.name) isn't a ServerPlan project's container (no env to show)", exit: .unknown))
            }
            let data = try await raw("GET", "/projects/\(project.id)/env")
            let rows = ServerPlanCLI.array(data) ?? []
            let table = rows.map { row -> [String] in
                let secret = (row["is_secret"] as? Bool) == true
                return [ServerPlanCLI.value(row, "id") ?? "-", ServerPlanCLI.value(row, "key") ?? "",
                        secret ? "(secret)" : ServerPlanCLI.value(row, "value") ?? "", ServerPlanCLI.value(row, "source") ?? "-"]
            }
            let header = "project: \(project.name) (#\(project.id)); changes apply at the next deploy (server env set / env rm)"
            let json = ServerPlanCLI.data(["project_id": project.id, "project": project.name,
                                           "env": (try? JSONSerialization.jsonObject(with: ServerPlanCLI.redactedEnv(data))) ?? []])
            return ServerPlanCLI.Outcome(json: json, text: header + "\n" + (rows.isEmpty ? "(no env)" : SessionCLI.table([["ID", "KEY", "VALUE", "SOURCE"]] + table)))
        case "container-stats":
            let server = try await serverID(form["server"])
            let name = try containerName(form)
            // A list, like the all-containers route (empty for a container docker stats skipped).
            let data = try await raw("GET", "/servers/\(server)/containers/\(ServerPlanClient.pathComponent(name))/stats")
            let stats = try ServerPlanClient.decode([ServerPlanContainerStats].self, from: data)
            return ServerPlanCLI.Outcome(json: data, text: stats.isEmpty ? "\(name): no stats (not running?)" : ServerPlanCLI.statsText(stats))
        case "stats":
            return try await serverStats(form)
        case "container-recreate", "container-pull", "container-remove":
            let op: ServerPlanAction.ContainerOp = command.name == "container-recreate" ? .recreate : command.name == "container-pull" ? .pull : .remove
            let servers = try await client.servers()
            let server = try pick(form["server"], servers.map { ($0.id, $0.name) }, what: "server")
            let name = try containerName(form)
            return try await ownerAction(.containerOp(serverID: server.id, serverName: server.name, name: name, op: op),
                                         label: "container \(op.rawValue)", what: "\(op.rawValue) \(name) on \(server.name)")
        case "disk":
            let server = try await serverID(form["server"])
            let data = try await raw("GET", "/servers/\(server)/docker/disk")
            let disk = try ServerPlanClient.decode(ServerPlanDockerDisk.self, from: data)
            return ServerPlanCLI.Outcome(json: data, text: ServerPlanCLI.diskText(disk))
        case "prune":
            let servers = try await client.servers()
            let server = try pick(form["server"], servers.map { ($0.id, $0.name) }, what: "server")
            let images = ServerPlanPruneOptions.Images(rawValue: form["images"] ?? "dangling") ?? .dangling
            let options = ServerPlanPruneOptions(images: images, containers: form["containers"] != "0",
                                                 volumes: form["volumes"] == "1", buildCache: form["build_cache"] != "0")
            return try await ownerAction(.prune(serverID: server.id, serverName: server.name, options: options),
                                         label: "prune", what: "prune \(options.summary) on \(server.name)")
        default:
            return .error(404, "unknown_command", exit: .usage)
        }
    }

    // MARK: Helpers

    private func containerName(_ form: [String: String]) throws -> String {
        let name = form["container"] ?? ""
        guard ServerPlanClient.isValidContainerName(name) else { throw Refusal(outcome: .error(400, "bad_container", exit: .usage)) }
        return name
    }

    /// The server and its container (from the panel's list: an unknown one is exit 5).
    private func serverAndContainer(_ form: [String: String]) async throws -> (server: (id: Int, name: String), container: ServerPlanContainer) {
        let servers = try await client.servers()
        let server = try pick(form["server"], servers.map { ($0.id, $0.name) }, what: "server")
        let name = try containerName(form)
        let list = try await client.containers(serverID: server.id)
        guard let container = list.first(where: { $0.name == name }) ?? list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let known = list.map(\.name).joined(separator: ", ")
            throw Refusal(outcome: .error(404, "unknown_container", "\(name) isn't on \(server.name) (\(known.isEmpty ? "no containers" : known))", exit: .unknown))
        }
        return (server, container)
    }

    /// A destructive action: the panel's 428 summary goes to the owner; only a yes sends it.
    private func ownerAction(_ action: ServerPlanAction, label: String, what: String) async throws -> ServerPlanCLI.Outcome {
        let preview = try await client.preview(action)
        guard await approve(label, preview.expected ?? action.confirmTarget, preview.summary ?? what) else {
            log("\(what): the owner refused or didn't answer")
            return .error(403, "owner_refused", "the owner didn't approve it in ClaudeDeck", exit: .refused)
        }
        guard let confirmation = ServerPlanConfirmation(action, expected: preview.expected) else { throw ServerPlanError.confirmationMissing }
        let result = try await client.perform(confirmation)
        log("\(what): approved by the owner, done")
        var object: [String: Any] = ["done": true]
        var text = "done: \(what)"
        if case .answer(let answer) = result {
            for (key, value) in answer { object[key] = value }
            if let bytes = answer["reclaimed_bytes"].flatMap(Double.init) { text += "\nreclaimed: \(ByteSize.format(bytes))" }
            if let updated = answer["updated"] { text += "\nimage updated: \(updated == "true" ? "yes" : "no (already the newest)")" }
            if let output = answer["output"], !output.isEmpty { text += "\n" + output }
        }
        return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(object), text: text)
    }

    private func containerInspect(_ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let (server, container) = try await serverAndContainer(form)
        let domains = (try? await client.domains(serverID: server.id)) ?? []
        let projects = (try? await client.projects()) ?? []
        let project = ServerPlanContainerMatch.project(for: container, serverID: server.id, projects: projects, domains: domains)
        var object: [String: Any] = [
            "server": server.name, "server_id": server.id, "name": container.name, "state": container.stateName,
            "condition": container.condition.rawValue, "health": container.health.rawValue, "status": container.status ?? "",
            "image": container.image ?? "", "ports": container.portList,
            "domains": ServerPlanContainerMatch.domains(for: container, serverID: server.id, in: domains),
        ]
        if let uptime = container.uptime { object["uptime"] = uptime }
        if let code = container.exitCode { object["exit_code"] = code }
        if let project { object["project"] = project.name; object["project_id"] = project.id }
        var inspect: ServerPlanContainerInspect?
        if me?.has(feature: ServerPlanContract.Feature.containerInspect) == true {
            let data = try await raw("GET", "/servers/\(server.id)/containers/\(ServerPlanClient.pathComponent(container.name))")
            inspect = try? ServerPlanClient.decode(ServerPlanContainerInspect.self, from: data)
            if let full = ServerPlanCLI.object(data) { object["inspect"] = full }
        }
        return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(object),
                                     text: ServerPlanCLI.inspectText(container, server: server.name, domains: object["domains"] as? [String] ?? [],
                                                                     project: project, inspect: inspect))
    }

    private func serverStats(_ form: [String: String]) async throws -> ServerPlanCLI.Outcome {
        let server = try await serverID(form["server"])
        let healthData = try await raw("GET", "/servers/\(server)/health")
        let health = try ServerPlanClient.decode(ServerPlanHealth.self, from: healthData)
        var object: [String: Any] = ["server": ServerPlanCLI.object(healthData) ?? [:]]
        var text = ServerPlanCLI.serverStatsText(health)
        if me?.has(feature: ServerPlanContract.Feature.containerStats) == true {
            let data = try await raw("GET", "/servers/\(server)/containers/stats")
            let stats = (try? ServerPlanClient.decode([ServerPlanContainerStats].self, from: data)) ?? []
            object["containers"] = (try? JSONSerialization.jsonObject(with: data)) ?? []
            text += "\n" + ServerPlanCLI.statsText(stats)
        } else {
            text += "\ncontainers: per-container stats need ServerPlan's container_stats (not offered by this panel yet)"
        }
        return ServerPlanCLI.Outcome(json: ServerPlanCLI.data(object), text: text)
    }
}

extension ServerPlanCLI {
    /// `--since` / `--until`: what ServerPlan's `log_query` takes, an RFC 3339 time without spaces
    /// or a duration (`10m`, `2h`, `30s`).
    public static func isValidSince(_ value: String) -> Bool { ServerPlanLogQuery.isValidTime(value) }

    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "-" }

    static func inspectText(_ container: ServerPlanContainer, server: String, domains: [String], project: ServerPlanProject?,
                            inspect: ServerPlanContainerInspect?) -> String {
        var lines = ["name: \(container.name) on \(server)"]
        var state = container.stateName.isEmpty ? "unknown" : container.stateName
        if container.health != .none { state += " (\(container.health.rawValue))" }
        if let code = container.exitCode { state += ", exit code \(code)" }
        lines.append("state: \(state)")
        if let status = container.status { lines.append("status: \(status)") }
        if let uptime = container.uptime { lines.append("up: \(uptime)") }
        lines.append("image: \(container.image ?? "-")")
        lines.append("ports: " + (container.portList.isEmpty ? "-" : container.portList.joined(separator: ", ")))
        lines.append("domains: " + (domains.isEmpty ? "-" : domains.joined(separator: ", ")))
        lines.append("project: " + (project.map { "\($0.name) (#\($0.id))" } ?? "-"))
        if let inspect {
            if let count = inspect.restartCount { lines.append("restarts: \(count)" + (inspect.restartPolicy.map { " (policy \($0))" } ?? "")) }
            if let started = inspect.startedAt { lines.append("started: \(started.formatted(.iso8601))") }
            if let finished = inspect.finishedAt, container.isRunning == false { lines.append("finished: \(finished.formatted(.iso8601))") }
            if !inspect.ports.isEmpty { lines.append("published: " + inspect.ports.map(\.label).joined(separator: ", ")) }
            if inspect.oomKilled == true { lines.append("oom killed: yes") }
            if !inspect.networks.isEmpty { lines.append("networks: " + inspect.networks.joined(separator: ", ")) }
            for mount in inspect.mounts { lines.append("mount: \(mount.source) → \(mount.destination)" + (mount.rw ? "" : " (ro)")) }
            if !inspect.envKeys.isEmpty { lines.append("env keys: " + inspect.envKeys.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }

    static func serverStatsText(_ health: ServerPlanHealth) -> String {
        if health.reachable == false { return "server: unreachable" + (health.error.map { " (\($0))" } ?? "") }
        let sample = ServerPlanServerSample(health)
        var parts = ["cpu: " + percent(sample.cpuPercent)]
        var memory = "mem: " + percent(sample.memPercent)
        if let used = sample.memUsedBytes, let total = sample.memTotalBytes { memory += " (\(ByteSize.format(used)) / \(ByteSize.format(total)))" }
        parts.append(memory)
        parts.append("disk: " + percent(sample.diskPercent))
        if let load = health.loadAverage { parts.append("load: \(load)") }
        if let uptime = health.uptime { parts.append(uptime) }
        if health.dockerOK == false { parts.append("docker: NOT ANSWERING") }
        return "server: " + parts.joined(separator: "  ")
    }

    static func statsText(_ stats: [ServerPlanContainerStats]) -> String {
        guard !stats.isEmpty else { return "(no running containers)" }
        func bytes(_ value: Double?) -> String { value.map(ByteSize.format) ?? "-" }
        let rows = stats.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.map { s -> [String] in
            [s.name, percent(s.cpuPercent), bytes(s.memUsedBytes) + (s.memLimitBytes.map { " / " + ByteSize.format($0) } ?? ""),
             percent(s.memPercent), "\(bytes(s.netRxBytes)) / \(bytes(s.netTxBytes))", "\(bytes(s.blockReadBytes)) / \(bytes(s.blockWriteBytes))",
             s.pids.map(String.init) ?? "-"]
        }
        return SessionCLI.table([["NAME", "CPU", "MEM", "MEM%", "NET RX/TX", "BLOCK R/W", "PIDS"]] + rows)
    }

    static func diskText(_ disk: ServerPlanDockerDisk) -> String {
        let rows = [("images", disk.images), ("containers", disk.containers), ("volumes", disk.volumes), ("build cache", disk.buildCache)].map {
            [$0.0, String($0.1.count), String($0.1.active), ByteSize.format($0.1.sizeBytes), ByteSize.format($0.1.reclaimableBytes)]
        }
        return SessionCLI.table([["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"]] + rows)
    }
}
