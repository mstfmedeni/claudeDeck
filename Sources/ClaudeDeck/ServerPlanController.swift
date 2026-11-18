import AppKit
import ClaudeDeckCore
import Foundation
import Observation

/// A notification about ServerPlan (AttentionCenter shows it on the Mac, RemoteController pushes
/// it to paired phones).
struct ServerPlanNotice {
    var title: String
    var body: String
    /// Replaces an older notice with the same id.
    var id: String
    var deploymentID: Int?
    var isFailure: Bool
}

/// What a sidebar sheet shows.
enum ServerPlanSheet: Identifiable, Equatable {
    case deploy(id: Int, title: String)
    case logs(serverID: Int, server: String, container: String)

    var id: String {
        switch self {
        case .deploy(let id, _): "deploy-\(id)"
        case .logs(let serverID, _, let container): "logs-\(serverID)-\(container)"
        }
    }
}

/// A destructive action waiting for the user's yes (with the server's summary of what it does).
struct ServerPlanPendingConfirm: Identifiable {
    let action: ServerPlanAction
    let preview: ServerPlanActionPreview
    var id: ServerPlanAction { action }
}

/// ServerPlan (the server panel) on the Mac: the Servers section's data, the deploy-failure
/// watch and the actions. Off — no task, no request — unless an address and a token are set.
///
/// The lists, health and capabilities are only fetched while the Servers section is on screen
/// (`refreshLoop`, which waits for a visible window). The one exception is the events stream
/// (`/events`, one long-lived SSE connection that costs nothing while quiet) for deploy-failure
/// notifications; with a panel without events it is a poll of the deploy list every 60 s.
@MainActor
@Observable
final class ServerPlanController {
    static let shared = ServerPlanController()

    private(set) var client: ServerPlanClient?
    var isConfigured: Bool { client != nil }
    private(set) var me: ServerPlanMe?
    private(set) var servers: [ServerPlanServer] = []
    private(set) var projects: [ServerPlanProject] = []
    /// Recent deploys (no logs), newest first.
    private(set) var deployments: [ServerPlanDeployment] = []
    private(set) var containers: [Int: [ServerPlanContainer]] = [:]
    private(set) var health: [Int: ServerPlanHealth] = [:]
    private(set) var capabilities: [Int: ServerPlanCapabilities] = [:]
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    private(set) var refreshing = false
    /// Deploys whose "Fix with Claude" is fetching the log.
    private(set) var repairing: Set<Int> = []
    var sheet: ServerPlanSheet?
    var pendingConfirm: ServerPlanPendingConfirm?
    var actionError: String?
    /// Servers expanded in the sidebar (kept across launches): their containers are fetched.
    var expandedServers: Set<Int> = Set(UserDefaults.windowState.array(forKey: "sidebar.serversExpandedIDs") as? [Int] ?? []) {
        didSet {
            guard expandedServers != oldValue else { return }
            UserDefaults.windowState.set(expandedServers.sorted(), forKey: "sidebar.serversExpandedIDs")
            if !expandedServers.subtracting(oldValue).isEmpty { Task { await refreshContainers() } }
        }
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var onNotice: ((ServerPlanNotice) -> Void)?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastEventID: String?
    @ObservationIgnored private var notified: Set<String> = []
    @ObservationIgnored private var knownStatuses: [Int: ServerPlanDeployStatus] = [:]
    @ObservationIgnored private var listPrimed = false
    /// Deploys started from ClaudeDeck: their success is a notification too.
    @ObservationIgnored private var startedHere: Set<Int> = []
    @ObservationIgnored private var healthAt: Date = .distantPast
    @ObservationIgnored private var capabilitiesAt: [Int: Date] = [:]

    static let refreshInterval: Duration = .seconds(30)
    static let healthInterval: TimeInterval = 60
    static let pollInterval: Duration = .seconds(60)

    private init() {}

    func start(model: AppModel) {
        self.model = model
        reconfigure()
    }

    // MARK: Configuration

    /// The token, in the login keychain (never in deck.json).
    static var token: String? { AgentKeychain.read("serverplan-token") }
    static func setToken(_ token: String?) { AgentKeychain.write(token, "serverplan-token") }

    /// Demo copies (tools/demo.sh) point at a local mock through the environment.
    private static var demoOverride: ServerPlanConfig? {
        let env = ProcessInfo.processInfo.environment
        guard AppModel.isDemo, let url = env["CLAUDEDECK_SERVERPLAN_URL"], let token = env["CLAUDEDECK_SERVERPLAN_TOKEN"] else { return nil }
        return ServerPlanConfig(address: url, token: token)
    }

    var address: String {
        if let demo = Self.demoOverride { return demo.baseURL.absoluteString }
        return model?.deck.settings.serverPlanURL ?? ""
    }

    /// Re-reads the address and token; a change drops everything and starts over.
    func reconfigure() {
        let config = Self.demoOverride ?? model.flatMap { model in
            Self.token.flatMap { ServerPlanConfig(address: model.deck.settings.serverPlanURL, token: $0) }
        }
        guard config != client?.config else { return }
        watchTask?.cancel()
        watchTask = nil
        client = config.map { ServerPlanClient(config: $0) }
        me = nil
        servers = []
        projects = []
        deployments = []
        containers = [:]
        health = [:]
        capabilities = [:]
        lastError = nil
        lastRefresh = nil
        lastEventID = nil
        knownStatuses = [:]
        listPrimed = false
        capabilitiesAt = [:]
        healthAt = .distantPast
        sheet = nil
        pendingConfirm = nil
        if client != nil { watchTask = Task { [weak self] in await self?.watch() } }
        model?.onCountsChanged?()
    }

    /// Settings › ServerPlan: saves both and checks them with `/me`.
    func connect(address: String, token: String?) async -> Result<ServerPlanMe, ServerPlanError> {
        model?.mutate(userInitiated: false) { $0.settings.serverPlanURL = address.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let token, !token.trimmingCharacters(in: .whitespaces).isEmpty { Self.setToken(token) }
        reconfigure()
        guard let client else { return .failure(address.isEmpty ? .notConfigured : .badURL) }
        do {
            let me = try await client.me()
            self.me = me
            lastError = nil
            return .success(me)
        } catch {
            let error = error as? ServerPlanError ?? .transport(error.localizedDescription)
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    func disconnect() {
        Self.setToken(nil)
        model?.mutate(userInitiated: false) { $0.settings.serverPlanURL = "" }
        reconfigure()
    }

    // MARK: Visible refresh (Servers section on screen)

    /// Runs while the Servers section is on screen: a refresh now and every 30 s, paused (no
    /// timer, no request) while no window can be seen.
    func refreshLoop() async {
        while !Task.isCancelled, isConfigured {
            await AppVisibility.shared.waitUntilVisible()
            guard !Task.isCancelled else { return }
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(force: Bool = false) async {
        guard let client, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if me == nil || force { me = try await client.me() }
            async let servers = client.servers()
            async let projects = client.projects()
            async let deployments = client.deployments(limit: 30)
            let (s, p, d) = try await (servers, projects, deployments)
            self.servers = s
            self.projects = p
            absorb(d)
            lastError = nil
            lastRefresh = Date()
        } catch {
            lastError = error.localizedDescription
            return
        }
        await refreshContainers()
        if force || Date().timeIntervalSince(healthAt) >= Self.healthInterval {
            healthAt = Date()
            await refreshHealth()
        }
        await refreshCapabilities(force: force)
    }

    private func refreshContainers() async {
        guard let client, me?.allows(.read) != false else { return }
        for id in expandedServers where servers.contains(where: { $0.id == id && $0.effectiveStatus != .offline }) {
            if let list = try? await client.containers(serverID: id) { containers[id] = list }
        }
    }

    /// Live health (the panel runs commands over SSH): only from the visible loop.
    private func refreshHealth() async {
        guard let client else { return }
        await withTaskGroup(of: (Int, ServerPlanHealth?).self) { group in
            for server in servers where server.effectiveStatus != .offline {
                group.addTask { (server.id, try? await client.health(serverID: server.id)) }
            }
            for await (id, value) in group { health[id] = value ?? health[id] }
        }
    }

    /// Whether `claude` runs on each server (the panel caches it 10 min; so do we).
    private func refreshCapabilities(force: Bool) async {
        guard let client, let me, me.allows(.terminal), me.has(feature: ServerPlanContract.Feature.terminalClaude) else { return }
        for server in servers where server.effectiveStatus != .offline {
            if !force, let at = capabilitiesAt[server.id], Date().timeIntervalSince(at) < 600 { continue }
            capabilitiesAt[server.id] = Date()
            if let value = try? await client.capabilities(serverID: server.id) { capabilities[server.id] = value }
        }
    }

    // MARK: Background watch (deploy failures)

    /// One `/events` connection while configured, reconnecting with backoff; without the events
    /// feature, a 60 s poll of the deploy list instead.
    private func watch() async {
        var backoff: Duration = .seconds(5)
        while !Task.isCancelled, let client {
            if me == nil { me = try? await client.me() }
            guard let me else {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
                continue
            }
            if me.has(feature: ServerPlanContract.Feature.events) {
                do {
                    let stream = try await client.eventStream(lastEventID: lastEventID)
                    backoff = .seconds(5)
                    for try await item in stream {
                        if let id = item.id { lastEventID = id }
                        if let event = ServerPlanEvent(item) { handle(event) }
                    }
                } catch {
                    if case ServerPlanError.unauthorized = error { lastError = error.localizedDescription }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
            } else {
                if let list = try? await client.deployments(limit: 20) { absorb(list) }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func handle(_ event: ServerPlanEvent) {
        let data = event.data
        switch event.kind {
        case .deployStarted, .deploySucceeded, .deployFailed, .deployCancelled:
            let status: ServerPlanDeployStatus = switch event.kind {
            case .deployStarted: .pending
            case .deploySucceeded: .success
            case .deployFailed: .failed
            default: .cancelled
            }
            guard let id = data.deploymentID else { return }
            var deployment = deployments.first { $0.id == id } ?? ServerPlanDeployment(id: id, status: status)
            deployment.status = status
            deployment.projectID = data.projectID ?? deployment.projectID
            deployment.projectName = data.projectName ?? deployment.projectName
            deployment.serverID = data.serverID ?? deployment.serverID
            deployment.serverName = data.serverName ?? deployment.serverName
            deployment.errorSummary = data.errorSummary ?? deployment.errorSummary
            if status.isFinished { deployment.finishedAt = event.at ?? Date() }
            absorb([deployment], fromEvent: true)
        case .serverUnreachable, .serverRecovered:
            guard let id = data.serverID, let index = servers.firstIndex(where: { $0.id == id }) else {
                if event.kind == .serverUnreachable, let name = data.serverName { notifyServerDown(name, id: data.serverID ?? 0) }
                return
            }
            servers[index].status = event.kind == .serverRecovered ? .online : .offline
            servers[index].reachable = event.kind == .serverRecovered
            if event.kind == .serverUnreachable { notifyServerDown(servers[index].name, id: id) }
        case .unknown:
            break
        }
    }

    /// Merges deploys (newest first) and notices the ones that just failed. An event always
    /// counts; from a list, the first list only records what is there (failures from before
    /// launch don't notify), later lists notify what changed to failed or is new and failed.
    private func absorb(_ list: [ServerPlanDeployment], fromEvent: Bool = false) {
        let priming = !fromEvent && !listPrimed
        if !fromEvent { listPrimed = true }
        var byID = Dictionary(deployments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for deployment in list {
            let before = knownStatuses[deployment.id]
            knownStatuses[deployment.id] = deployment.status
            var merged = deployment
            if let old = byID[deployment.id] {
                merged.projectName = merged.projectName ?? old.projectName
                merged.serverName = merged.serverName ?? old.serverName
                merged.errorSummary = merged.errorSummary ?? old.errorSummary
                merged.step = merged.step ?? old.step
            }
            byID[deployment.id] = merged
            if deployment.status == .failed, before != .failed, !priming {
                notifyFailure(merged)
            } else if deployment.status == .success, startedHere.remove(deployment.id) != nil {
                notifySuccess(merged)
            }
            // Keep the project's last deploy current without waiting for the next list.
            if let projectID = deployment.projectID, let index = projects.firstIndex(where: { $0.id == projectID }),
               (projects[index].lastDeploy?.id ?? 0) <= deployment.id {
                projects[index].lastDeploy = ServerPlanDeploySummary(id: deployment.id, status: deployment.status, finishedAt: deployment.finishedAt)
            }
        }
        deployments = byID.values.sorted { $0.id > $1.id }.prefix(50).map { $0 }
        model?.onCountsChanged?()  // the phone's snapshot carries running and failed deploys
    }

    private func notifyFailure(_ deployment: ServerPlanDeployment) {
        let key = "deploy-\(deployment.id)"
        guard notified.insert(key).inserted else { return }
        let project = deployment.projectName ?? projectName(deployment.projectID) ?? "#\(deployment.id)"
        let title = deployment.serverName.map { String(localized: "Deploy failed: \(project) → \($0)") } ?? String(localized: "Deploy failed: \(project)")
        let body = deployment.errorSummary ?? String(localized: "Open the deploy log in ClaudeDeck.")
        onNotice?(ServerPlanNotice(title: title, body: body, id: "serverplan-\(key)", deploymentID: deployment.id, isFailure: true))
    }

    /// A deploy started from ClaudeDeck finished (others only notify when they fail).
    private func notifySuccess(_ deployment: ServerPlanDeployment) {
        let project = deployment.projectName ?? projectName(deployment.projectID) ?? "#\(deployment.id)"
        onNotice?(ServerPlanNotice(title: String(localized: "Deployed: \(project)"),
                                   body: deployment.serverName.map { String(localized: "Running on \($0).") } ?? String(localized: "The deploy finished."),
                                   id: "serverplan-deploy-\(deployment.id)", deploymentID: deployment.id, isFailure: false))
    }

    private func notifyServerDown(_ name: String, id: Int) {
        let key = "server-\(id)-\(Int(Date().timeIntervalSince1970 / 600))"
        guard notified.insert(key).inserted else { return }
        onNotice?(ServerPlanNotice(title: String(localized: "Server unreachable: \(name)"), body: String(localized: "ServerPlan can't reach this server."),
                                   id: "serverplan-server-\(id)", deploymentID: nil, isFailure: true))
    }

    // MARK: Lookups

    func projectName(_ id: Int?) -> String? { id.flatMap { id in projects.first { $0.id == id }?.name } }
    func server(_ id: Int?) -> ServerPlanServer? { id.flatMap { id in servers.first { $0.id == id } } }
    func projects(on serverID: Int?) -> [ServerPlanProject] { projects.filter { $0.defaultServerID == serverID } }
    func latestDeploy(of project: ServerPlanProject) -> ServerPlanDeployment? {
        deployments.first { $0.projectID == project.id } ?? project.lastDeploy.map {
            ServerPlanDeployment(id: $0.id, projectID: project.id, projectName: project.name, status: $0.status, finishedAt: $0.finishedAt)
        }
    }

    /// The ClaudeDeck project for a ServerPlan project (same folder).
    func deckProject(for project: ServerPlanProject) -> Project? {
        guard let model else { return nil }
        return DeployRepair.project(forRepoPath: project.repoPath, in: model.deck.projects)
    }

    func canRunClaude(on serverID: Int) -> Bool {
        guard let me, me.allows(.terminal), me.has(feature: ServerPlanContract.Feature.terminalClaude) else { return false }
        return capabilities[serverID]?.claude == true
    }

    func allows(_ scope: ServerPlanScope) -> Bool { me?.allows(scope) ?? false }

    /// For the phone (RemoteSnapshot.serverPlan): nil unless configured.
    var remoteStatus: RemoteServerPlan? {
        guard isConfigured else { return nil }
        let recent = deployments.filter { $0.status.isRunning || $0.status == .failed }.prefix(10)
        return RemoteServerPlan(
            servers: servers.map { RemoteServerPlan.Server(id: $0.id, name: $0.name, status: $0.effectiveStatus.rawValue) },
            deploys: recent.map {
                RemoteServerPlan.Deploy(id: $0.id, project: $0.projectName ?? projectName($0.projectID) ?? "#\($0.id)", server: $0.serverName,
                                        status: $0.status.rawValue, error: $0.errorSummary, finishedAt: $0.finishedAt)
            }
        )
    }

    // MARK: Destructive actions

    /// Step one: asks the panel what the action would do (it answers without doing anything),
    /// then shows the confirmation dialog with that.
    func request(_ action: ServerPlanAction) {
        guard let client else { return }
        actionError = nil
        Task {
            do {
                let preview = try await client.preview(action)
                pendingConfirm = ServerPlanPendingConfirm(action: action, preview: preview)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Step two, from the dialog's confirm button only.
    func confirm(_ pending: ServerPlanPendingConfirm) {
        pendingConfirm = nil
        guard let client, let confirmation = ServerPlanConfirmation(pending.action, expected: pending.preview.expected) else {
            actionError = String(localized: "This needs a confirmation first.")
            return
        }
        Task {
            do {
                switch try await client.perform(confirmation) {
                case .deployStarted(let started):
                    startedHere.insert(started.deploymentID)
                    if case .deploy(_, let name, _, _) = pending.action {
                        sheet = .deploy(id: started.deploymentID, title: name)
                    }
                    absorb([ServerPlanDeployment(id: started.deploymentID, projectID: actionProjectID(pending.action), status: .pending)], fromEvent: true)
                case .done:
                    if case .container(let serverID, _, _, _) = pending.action,
                       let list = try? await client.containers(serverID: serverID) { containers[serverID] = list }
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func actionProjectID(_ action: ServerPlanAction) -> Int? {
        if case .deploy(let id, _, _, _) = action { return id }
        return nil
    }

    // MARK: Fix with Claude

    func repairKey(_ deploymentID: Int) -> String? {
        client.map { DeployRepair.key(panel: $0.config.baseURL, deploymentID: deploymentID) }
    }

    /// "Fix with Claude" for a failed deploy: fetches its log and sends it with an instruction to a
    /// Claude session in the project's ClaudeDeck project (added if its folder exists).
    func fixWithClaude(_ deploymentID: Int) {
        guard let client, let model, let key = repairKey(deploymentID), !repairing.contains(deploymentID) else { return }
        repairing.insert(deploymentID)
        Task {
            defer { repairing.remove(deploymentID) }
            let deployment: ServerPlanDeployment
            do {
                deployment = try await client.deployment(id: deploymentID)
            } catch {
                actionError = error.localizedDescription
                return
            }
            let spProject = projects.first { $0.id == deployment.projectID }
            var deckProject = spProject.flatMap(deckProject(for:))
            if deckProject == nil, let path = spProject?.repoPath, FileManager.default.fileExists(atPath: path) {
                deckProject = model.addProject(path: path)
            }
            guard let deckProject else {
                actionError = String(localized: "No ClaudeDeck project has this project's folder; add it first.")
                NSSound.beep()
                return
            }
            let projectName = deployment.projectName ?? spProject?.name ?? deckProject.name
            var target = model.deck.deployRepairRequest(key)?.sessionID.flatMap { model.deck.session($0) }?.id
            if target == nil {
                var created: DeckSession?
                model.mutate { created = $0.addSession(to: deckProject.id, name: "\(deckProject.name) · deploy #\(deploymentID)") }
                target = created?.id
            }
            guard let target else { NSSound.beep(); return }
            model.mutate { $0.recordDeployRepair(DeployRepairRequest(key: key, sessionID: target)) }
            sheet = nil
            model.openMainWindow?()
            model.tabs.selectSessions()
            model.sendPrompt(DeployRepair.prompt(project: projectName, server: deployment.serverName, deployment: deployment, log: deployment.log ?? ""), to: target)
        }
    }

    /// Shows the deploy's log (from a notification).
    func showDeploy(_ id: Int) {
        let name = deployments.first { $0.id == id }?.projectName ?? "#\(id)"
        sheet = .deploy(id: id, title: name)
    }
}
