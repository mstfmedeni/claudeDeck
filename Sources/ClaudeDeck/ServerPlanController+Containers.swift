import AppKit
import ClaudeDeckCore
import Foundation

/// Containers and server resources on the Mac: the container ↔ project ↔ domain matching, the
/// sparkline sampling (only while a detail sheet shows it), what a finished action said, and
/// "Claude ile düzelt" from log lines. The panel's 1.5 additions are used only when `/me`
/// names them (docs/serverplan-containers.md).
extension ServerPlanController {
    /// Whether the panel offers a `/me` feature.
    func has(_ feature: String) -> Bool { me?.has(feature: feature) == true }

    /// The panel's domains (v1.1); a panel without them (or a token without `read`) just has none.
    func refreshDomains() async {
        guard let client else { return }
        if let list = try? await client.domains() { domains = list }
    }

    func container(_ serverID: Int, _ name: String) -> ServerPlanContainer? {
        containers[serverID]?.first { $0.name == name }
    }

    func project(for container: ServerPlanContainer, serverID: Int) -> ServerPlanProject? {
        ServerPlanContainerMatch.project(for: container, serverID: serverID, projects: projects, domains: domains)
    }

    func domains(for container: ServerPlanContainer, serverID: Int) -> [String] {
        ServerPlanContainerMatch.domains(for: container, serverID: serverID, in: domains)
    }

    static func key(_ serverID: Int, _ container: String) -> String { "\(serverID)/\(container)" }

    // MARK: Container events (1.6 `container_events`)

    /// Shows a `container.*` event on the row at once, reads the server's list again for docker's
    /// own status, and notifies a crash, OOM, unhealthy or restart loop (Settings › ServerPlan).
    func containerEvent(_ event: ServerPlanEvent) {
        let data = event.data
        guard let serverID = data.serverID, let name = data.containerName else { return }
        if var list = containers[serverID], let index = list.firstIndex(where: { $0.name == name }) {
            var row = list[index]
            switch event.kind {
            case .containerDied:
                row.state = "exited"
                row.status = "Exited (\(data.exitCode ?? 0)) just now"
                row.healthField = nil
            case .containerUnhealthy:
                row.state = "running"
                row.healthField = "unhealthy"
                if let status = row.status {
                    row.status = status.contains("(healthy)") ? status.replacingOccurrences(of: "(healthy)", with: "(unhealthy)")
                        : status.contains("(unhealthy)") ? status : status + " (unhealthy)"
                }
            case .containerRestarted, .containerRecreated:
                row.state = "running"
                row.status = "Up Less than a second"
                row.healthField = nil
                if let id = data.containerID { row.containerID = id }
            default:
                break
            }
            list[index] = row
            containers[serverID] = list
        }
        Task { await refreshContainers(serverID: serverID) }
        guard model?.deck.settings.serverPlanContainerAlerts ?? true else { return }
        var watch = containerWatch
        let alert = watch.alert(for: event)
        containerWatch = watch
        if let alert { notifyContainer(alert) }
    }

    /// One server's containers again (after an event).
    func refreshContainers(serverID: Int) async {
        guard let client, me?.allows(.read) != false else { return }
        if let list = try? await client.containers(serverID: serverID) { containers[serverID] = list }
    }

    private func notifyContainer(_ alert: ServerPlanContainerAlert) {
        let name = alert.container
        let server = alert.serverName.isEmpty ? (self.server(alert.serverID)?.name ?? "") : alert.serverName
        let title: String = switch alert.reason {
        case .crashed(let code): String(localized: "\(name) crashed (exit \(code))")
        case .outOfMemory: String(localized: "\(name) ran out of memory")
        case .unhealthy: String(localized: "\(name) is unhealthy")
        case .restartLoop(let count): String(localized: "\(name) keeps restarting (\(count)× in 10 min)")
        }
        let body: String = switch alert.reason {
        case .crashed: String(localized: "The container stopped on \(server). Open its logs to see why.")
        case .outOfMemory: String(localized: "The kernel killed it on \(server) for memory (OOM).")
        case .unhealthy: String(localized: "Its health check fails on \(server).")
        case .restartLoop: String(localized: "Docker keeps restarting it on \(server); it probably crashes at start.")
        }
        var canFix = false
        if let serverID = alert.serverID, let model {
            let row = container(serverID, name) ?? ServerPlanContainer(name: name)
            canFix = project(for: row, serverID: serverID).flatMap { repairProject(for: $0, model: model) } != nil
        }
        onNotice?(ServerPlanNotice(title: title, body: body, id: alert.noticeID, deploymentID: nil, isFailure: true,
                                   container: alert.serverID.map { ServerPlanNotice.ContainerRef(serverID: $0, server: server, name: name, canFix: canFix) }))
    }

    /// A container notification's click: the container sheet on its logs.
    func showContainerLogs(serverID: Int, server: String, name: String) {
        model?.openMainWindow?()
        NSApp.activate()
        sheet = .container(serverID: serverID, server: server, container: name, tab: .logs)
    }

    /// A container notification's "Fix with Claude": its last log lines (the errors and the tail)
    /// go to a new session in the container's project.
    func fixContainerFromNotice(serverID: Int, server: String, name: String) async {
        guard let client else { return }
        model?.openMainWindow?()
        NSApp.activate()
        let text = (try? await client.containerLogs(serverID: serverID, container: name, tail: 300)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        if containers[serverID] == nil { await refreshContainers(serverID: serverID) }
        let row = container(serverID, name) ?? ServerPlanContainer(name: name)
        fixLogsWithClaude(serverID: serverID, server: server, container: row, lines: ContainerLogRepair.pick(lines))
    }

    // MARK: Sampling (while a sheet is open)

    /// One health sample of a server (the panel runs a few commands over SSH).
    func sampleServer(_ serverID: Int) async {
        guard let client else { return }
        guard let value = try? await client.health(serverID: serverID) else { return }
        health[serverID] = value
        serverSeries[serverID, default: ServerPlanSeries()].add(ServerPlanServerSample(value), at: Date())
    }

    /// Every running container's use, on panels with `container_stats` (one `docker stats`).
    func sampleContainers(_ serverID: Int) async {
        guard let client, has(ServerPlanContract.Feature.containerStats) else { return }
        guard let list = try? await client.containerStats(serverID: serverID) else { return }
        let now = Date()
        var byName: [String: ServerPlanContainerStats] = [:]
        for stats in list {
            byName[stats.name] = stats
            containerSeries[Self.key(serverID, stats.name), default: ServerPlanSeries()].add(stats, at: now)
        }
        containerStats[serverID] = byName
    }

    /// Samples every `interval` while the calling view is up and a window can be seen.
    func sampleLoop(_ serverID: Int, containers: Bool, interval: Duration = .seconds(10)) async {
        while !Task.isCancelled {
            await AppVisibility.shared.waitUntilVisible()
            guard !Task.isCancelled else { return }
            await sampleServer(serverID)
            if containers { await sampleContainers(serverID) }
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: Actions

    func isRunning(_ action: ServerPlanAction) -> Bool { actionRunning.contains(action) }

    /// After a confirmed action: the container list again, and what the panel said.
    func actionDone(_ action: ServerPlanAction, result: ServerPlanActionResult) {
        var notice: String?
        switch action {
        case .container(_, _, let name, let verb):
            notice = switch verb {
            case .start: String(localized: "\(name) started.")
            case .stop: String(localized: "\(name) stopped.")
            case .restart: String(localized: "\(name) restarted.")
            }
        case .containerOp(_, _, let name, .recreate): notice = String(localized: "\(name) recreated.")
        case .containerOp(_, _, let name, .remove): notice = String(localized: "\(name) removed.")
        case .containerOp(_, _, let name, .pull):
            if case .answer(let answer) = result, answer["updated"] == "false" {
                notice = String(localized: "\(name) already runs the newest image.")
            } else {
                notice = String(localized: "\(name) runs the updated image.")
            }
        case .prune:
            if case .answer(let answer) = result, let bytes = answer["reclaimed_bytes"].flatMap(Double.init) {
                notice = String(localized: "Docker cleaned up: \(ByteSize.format(bytes)) freed.")
            } else {
                notice = String(localized: "Docker cleaned up.")
            }
        case .envDelete(_, _, _, let key): notice = String(localized: "\(key) deleted; it's gone at the next deploy.")
        case .deploy: break
        }
        actionNotice = notice
        let serverID: Int? = switch action {
        case .container(let id, _, _, _), .containerOp(let id, _, _, _), .prune(let id, _, _): id
        default: nil
        }
        if let serverID, let client {
            Task {
                if let list = try? await client.containers(serverID: serverID) { containers[serverID] = list }
            }
        }
    }

    // MARK: The phone

    /// A server's containers for a phone (`Feature.serverPlanContainers`), with their use on
    /// panels that send it, and the last 100 log lines of `logsOf`.
    func phoneContainers(serverID: Int, logsOf: String?) async -> RemoteMessage {
        guard let client else {
            return .serverPlanContainers(serverID: serverID, containers: [], logsOf: logsOf, logs: nil,
                                         error: String(localized: "ServerPlan isn't set up (Settings › ServerPlan)."))
        }
        do {
            let list = try await client.containers(serverID: serverID)
            containers[serverID] = list
            if domains.isEmpty { await refreshDomains() }
            await sampleContainers(serverID)
            let stats = containerStats[serverID] ?? [:]
            let rows = list.map { container in
                RemoteServerPlan.Container(name: container.name, condition: container.condition.rawValue, status: container.status,
                                           image: container.image, domains: domains(for: container, serverID: serverID),
                                           cpuPercent: stats[container.name]?.cpuPercent, memPercent: stats[container.name]?.memPercent,
                                           memBytes: stats[container.name]?.memUsedBytes)
            }
            var logs: [String]?
            if let logsOf, allows(.logs) {
                let text = try await client.containerLogs(serverID: serverID, container: logsOf, tail: 100)
                logs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                while logs?.last?.isEmpty == true { logs?.removeLast() }
            }
            return .serverPlanContainers(serverID: serverID, containers: rows, logsOf: logsOf, logs: logs, error: nil)
        } catch {
            return .serverPlanContainers(serverID: serverID, containers: [], logsOf: logsOf, logs: nil, error: error.localizedDescription)
        }
    }

    /// Start, stop or restart from a phone: the panel's summary becomes a card in the Onaylar
    /// queue (approved on the Mac only); nil once done, else why not.
    func phoneContainerAction(serverID: Int, container: String, verb: String) async -> String? {
        guard let client, let model else { return String(localized: "ServerPlan isn't set up (Settings › ServerPlan).") }
        guard let verb = ServerPlanAction.ContainerVerb(rawValue: verb) else { return "bad action" }
        guard allows(.containers) else { return String(localized: "The token isn't allowed to do this.") }
        let serverName = server(serverID)?.name ?? "#\(serverID)"
        let action = ServerPlanAction.container(serverID: serverID, serverName: serverName, name: container, verb: verb)
        do {
            let preview = try await client.preview(action)
            let title = switch verb {
            case .start: String(localized: "The phone asks to start \(container) on \(serverName)")
            case .stop: String(localized: "The phone asks to stop \(container) on \(serverName)")
            case .restart: String(localized: "The phone asks to restart \(container) on \(serverName)")
            }
            var approval = model.makeApproval(UUID(), kind: .serverPlan, command: "container \(verb.rawValue)", target: preview.expected ?? container,
                                              summary: preview.summary, title: title)
            approval.session = String(localized: "Phone")
            guard await model.awaitApproval(approval) else { return String(localized: "Not approved on the Mac.") }
            guard let confirmation = ServerPlanConfirmation(action, expected: preview.expected) else { return String(localized: "This needs a confirmation first.") }
            let result = try await client.perform(confirmation)
            actionDone(action, result: result)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Claude ile düzelt from log lines

    /// Sends the picked log lines (or the last errors) of a container to a Claude session in the
    /// ClaudeDeck project of its ServerPlan project, like a failed deploy's Fix with Claude.
    func fixLogsWithClaude(serverID: Int, server: String, container: ServerPlanContainer, lines: [String]) {
        guard let model else { return }
        let key = Self.key(serverID, container.name)
        guard !repairingLogs.contains(key) else { return }
        guard let spProject = project(for: container, serverID: serverID),
              let deckProject = repairProject(for: spProject, model: model) else {
            actionError = String(localized: "No ClaudeDeck project has this container's project folder; add it first.")
            NSSound.beep()
            return
        }
        repairingLogs.insert(key)
        defer { repairingLogs.remove(key) }
        var created: DeckSession?
        model.mutate { created = $0.addSession(to: deckProject.id, name: "\(deckProject.name) · \(container.name) logs") }
        guard let target = created?.id else {
            actionError = String(localized: "The session couldn't be started.")
            NSSound.beep()
            return
        }
        actionError = nil
        sheet = nil
        model.openMainWindow?()
        model.tabs.selectSessions()
        model.sendPrompt(ContainerLogRepair.prompt(container: container.name, server: server, image: container.image,
                                                   project: spProject.name, status: container.status, lines: lines), to: target)
    }
}
