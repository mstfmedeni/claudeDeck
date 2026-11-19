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
    /// The Namecheap balance (v1.4 panels); nil until fetched, or without Namecheap in the panel.
    private(set) var registrarBalance: ServerPlanRegistrarBalance?
    /// false: the panel answered 412 not_configured (no Namecheap): nothing about it is shown.
    private(set) var registrarConfigured: Bool?
    private(set) var registrarBalanceError: String?
    private(set) var registrarBalanceLoading = false
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
    /// Failures were cleared: their delivered notifications (`ServerPlanNotice.id`s) go too.
    @ObservationIgnored var onCleared: (([String]) -> Void)?
    /// Old cleared failures are pruned once per launch, after the first full list.
    @ObservationIgnored private var pruned = false
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastEventID: String?
    @ObservationIgnored private var notified: Set<String> = []
    @ObservationIgnored private var knownStatuses: [Int: ServerPlanDeployStatus] = [:]
    @ObservationIgnored private var listPrimed = false
    /// Deploys started from ClaudeDeck: their success is a notification too.
    @ObservationIgnored private var startedHere: Set<Int> = []
    @ObservationIgnored private var healthAt: Date = .distantPast
    @ObservationIgnored private var capabilitiesAt: [Int: Date] = [:]
    @ObservationIgnored private var balanceTask: Task<Void, Never>?
    @ObservationIgnored private var registrarBalanceAt: Date = .distantPast

    static let refreshInterval: Duration = .seconds(30)
    static let healthInterval: TimeInterval = 60
    static let pollInterval: Duration = .seconds(60)
    /// The Namecheap balance: every 30 min while a window is visible (the panel caches it 5 min).
    static let balanceInterval: TimeInterval = 30 * 60
    static let balanceNoticeID = "serverplan-registrar-balance"

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
        balanceTask?.cancel()
        balanceTask = nil
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
        registrarBalance = nil
        registrarConfigured = nil
        registrarBalanceError = nil
        registrarBalanceAt = .distantPast
        if client != nil {
            watchTask = Task { [weak self] in await self?.watch() }
            balanceTask = Task { [weak self] in await self?.balanceLoop() }
        }
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
        var opened = true
        while !Task.isCancelled, isConfigured {
            await AppVisibility.shared.waitUntilVisible()
            guard !Task.isCancelled else { return }
            await refresh()
            // The section was just opened: the balance too (unless it was read a minute ago).
            if opened { opened = false; await refreshBalance(maxAge: 60) }
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// `listsOnly`: servers, projects and deploys (a connected phone's refresh), without the live
    /// health, containers and capabilities.
    func refresh(force: Bool = false, listsOnly: Bool = false) async {
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
            forgetRecovered(panel: true, servers: [])
            if !pruned { pruned = true; pruneCleared() }
        } catch {
            lastError = error.localizedDescription
            return
        }
        if listsOnly { return }
        await refreshContainers()
        if force || Date().timeIntervalSince(healthAt) >= Self.healthInterval {
            healthAt = Date()
            await refreshHealth()
        }
        await refreshCapabilities(force: force)
        if force { await refreshBalance(force: true) }
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
        // Back up: a cleared "unreachable" shows again the next time it fails.
        forgetRecovered(panel: false, servers: servers.filter { serverIssue($0) == nil && health[$0.id] != nil }.map(\.id))
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
            if event.kind == .serverRecovered { forgetRecovered(panel: false, servers: [id]) }
            if event.kind == .serverUnreachable { notifyServerDown(servers[index].name, id: id) }
        case .registrarLowBalance:
            if let available = data.availableBalance { registrarBalance?.available = available }
            registrarBalance?.low = true
            var watch = balanceWatch
            let notice = watch.lowEvent(available: data.availableBalance, currency: data.currency, threshold: data.lowThreshold,
                                        localThreshold: localBalanceThreshold)
            balanceWatch = watch
            if let notice { notifyLowBalance(notice) }
            model?.onCountsChanged?()
        case .registrarBalanceOK:
            if let available = data.availableBalance { registrarBalance?.available = available }
            registrarBalance?.low = false
            var watch = balanceWatch
            if watch.okEvent() { onCleared?([Self.balanceNoticeID]) }
            balanceWatch = watch
            model?.onCountsChanged?()
        case .unknown:
            break
        }
    }

    // MARK: Namecheap balance (v1.4)

    /// The panel serves the balance to this token.
    var offersRegistrarBalance: Bool { me?.offersRegistrarBalance == true && registrarConfigured != false }

    /// Settings › ServerPlan's "Namecheap balance alert (USD)": used when the panel has no threshold.
    var localBalanceThreshold: Double { model?.deck.settings.serverPlanBalanceAlert ?? DeckSettings().serverPlanBalanceAlert }

    /// The threshold in force (the panel's, else the local one), nil when off.
    var balanceThreshold: Double? {
        RegistrarBalanceWatch.threshold(panel: registrarBalance?.lowThreshold, local: localBalanceThreshold)
    }

    /// Under the threshold in force.
    var balanceIsLow: Bool {
        guard let balance = registrarBalance, let threshold = balanceThreshold else { return false }
        return balance.available < threshold
    }

    /// Reads the balance unless it was read within `maxAge`; `force` also asks Namecheap again
    /// (`?refresh=1`). A panel without Namecheap (412) stays quiet; other failures only show in
    /// Settings (never as the sidebar's panel error).
    func refreshBalance(force: Bool = false, maxAge: TimeInterval = ServerPlanController.balanceInterval) async {
        guard let client, me?.offersRegistrarBalance == true, !registrarBalanceLoading else { return }
        guard force || Date().timeIntervalSince(registrarBalanceAt) >= maxAge else { return }
        registrarBalanceLoading = true
        registrarBalanceAt = Date()
        defer { registrarBalanceLoading = false }
        do {
            let balance = try await client.registrarBalance(refresh: force)
            guard client.config == self.client?.config else { return }
            registrarBalance = balance
            registrarConfigured = true
            registrarBalanceError = nil
            var watch = balanceWatch
            let wasLow = watch.notifiedLow
            let notice = watch.observe(available: balance.available, currency: balance.currency, panelThreshold: balance.lowThreshold,
                                       localThreshold: localBalanceThreshold)
            balanceWatch = watch
            if let notice { notifyLowBalance(notice) } else if wasLow, !watch.notifiedLow { onCleared?([Self.balanceNoticeID]) }
        } catch ServerPlanError.http(let status, _, _) where status == 412 {
            registrarBalance = nil
            registrarConfigured = false
            registrarBalanceError = nil
        } catch {
            registrarBalanceError = error.localizedDescription
        }
        model?.onCountsChanged?()  // the phone's snapshot carries it
    }

    /// The local threshold changed in Settings: the balance on hand is checked against it.
    func balanceThresholdChanged() {
        guard let balance = registrarBalance else { return }
        var watch = balanceWatch
        let notice = watch.observe(available: balance.available, currency: balance.currency, panelThreshold: balance.lowThreshold,
                                   localThreshold: localBalanceThreshold)
        balanceWatch = watch
        if let notice { notifyLowBalance(notice) }
        model?.onCountsChanged?()
    }

    /// Every 30 min while a window is visible (Settings and the Servers section read it sooner).
    private func balanceLoop() async {
        while !Task.isCancelled, let client {
            await AppVisibility.shared.waitUntilVisible()
            guard !Task.isCancelled else { return }
            if me == nil { me = try? await client.me() }
            await refreshBalance()
            let due = registrarBalanceAt.addingTimeInterval(Self.balanceInterval).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(me == nil ? 300 : max(60, due)))
        }
    }

    /// Whether the owner was told the balance is low, per panel, kept across launches (window
    /// state: a demo keeps its own).
    private var balanceWatch: RegistrarBalanceWatch {
        get {
            guard let key = balanceWatchKey else { return RegistrarBalanceWatch() }
            return RegistrarBalanceWatch(notifiedLow: UserDefaults.windowState.bool(forKey: key))
        }
        set {
            guard let key = balanceWatchKey else { return }
            if newValue.notifiedLow { UserDefaults.windowState.set(true, forKey: key) } else { UserDefaults.windowState.removeObject(forKey: key) }
        }
    }

    private var balanceWatchKey: String? { panelURL.map { "serverPlan.registrarLowNotified.\($0.absoluteString)" } }

    private func notifyLowBalance(_ notice: RegistrarBalanceWatch.Notice) {
        let amount = ServerPlanRegistrarBalance.format(notice.available), threshold = ServerPlanRegistrarBalance.format(notice.threshold)
        let currency = notice.currency
        onNotice?(ServerPlanNotice(
            title: String(localized: "Namecheap balance low"),
            body: String(localized: "Namecheap balance is low: \(amount) \(currency) (threshold \(threshold) \(currency)). Top up for domain purchases: Namecheap › Billing › Add Funds."),
            id: Self.balanceNoticeID, deploymentID: nil, isFailure: true))
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

    /// The ServerPlan projects listed under a ClaudeDeck project in the sidebar: the same folder
    /// or a subfolder of it (`DeployRepair.projectsByDeckProject`). Empty when the setting is off.
    func serverProjects(under deckProject: UUID) -> [ServerPlanProject] {
        guard isConfigured, let model, model.deck.settings.serverPlanProjectRows, !projects.isEmpty else { return [] }
        return projectsByDeckProject(model.deck.projects)[deckProject] ?? []
    }

    /// Ids of every ServerPlan project shown under a ClaudeDeck project (the sidebar rebuilds its
    /// list when one goes away).
    var projectRowIDs: Set<String> {
        guard isConfigured, let model, model.deck.settings.serverPlanProjectRows, !projects.isEmpty else { return [] }
        return Set(projectsByDeckProject(model.deck.projects).flatMap { deck, list in list.map { "\(deck)-\($0.id)" } })
    }

    /// Matching resolves symlinks on disk: worked out once per change of either list.
    @ObservationIgnored private var matchCache: (paths: [String], projects: [ServerPlanProject], map: [UUID: [ServerPlanProject]])?

    private func projectsByDeckProject(_ deckProjects: [Project]) -> [UUID: [ServerPlanProject]] {
        let paths = deckProjects.map { "\($0.id) \($0.path)" }
        if let cache = matchCache, cache.paths == paths, cache.projects == projects { return cache.map }
        let map = DeployRepair.projectsByDeckProject(projects, in: deckProjects)
        matchCache = (paths, projects, map)
        return map
    }

    /// Terminals: the token's scope and the panel's feature flag (it only sends `terminal` when the
    /// user also has the servers.ssh permission).
    var canOpenTerminal: Bool {
        guard let me else { return false }
        return me.allows(.terminal) && me.has(feature: ServerPlanContract.Feature.terminal)
    }

    func canRunClaude(on serverID: Int) -> Bool {
        guard canOpenTerminal, me?.has(feature: ServerPlanContract.Feature.terminalClaude) == true else { return false }
        return capabilities[serverID]?.claude == true
    }

    func allows(_ scope: ServerPlanScope) -> Bool { me?.allows(scope) ?? false }

    /// For the phone (RemoteSnapshot.serverPlan): nil unless configured.
    var remoteStatus: RemoteServerPlan? {
        guard isConfigured else { return nil }
        // Cleared failures stay on the Mac's side: phones (old ones too) don't list them.
        let recent = deployments.filter { $0.status.isRunning || ($0.status == .failed && !isCleared($0)) }.prefix(10)
        var status = RemoteServerPlan(
            servers: servers.map { RemoteServerPlan.Server(id: $0.id, name: $0.name, status: $0.effectiveStatus.rawValue) },
            deploys: recent.map {
                RemoteServerPlan.Deploy(id: $0.id, project: $0.projectName ?? projectName($0.projectID) ?? "#\($0.id)", server: $0.serverName,
                                        status: $0.status.rawValue, error: $0.errorSummary, finishedAt: $0.finishedAt)
            }
        )
        status.projects = projects.map { project in
            let last = latestDeploy(of: project)
            var row = RemoteServerPlan.Project(id: project.id, name: project.name, serverID: project.defaultServerID, lastDeployID: last?.id,
                                               lastDeployStatus: last?.status.rawValue, lastDeployAt: last?.finishedAt)
            if let last, isCleared(last) { row.lastDeployCleared = true }
            return row
        }
        if let balance = registrarBalance, registrarConfigured == true {
            status.registrarBalance = RemoteServerPlan.Balance(available: balance.available, currency: balance.currency,
                                                               threshold: balanceThreshold, low: balanceIsLow)
        }
        return status
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
                    actionError = nil
                    startedHere.insert(started.deploymentID)
                    if case .deploy(_, let name, _, _) = pending.action {
                        sheet = .deploy(id: started.deploymentID, title: name)
                    }
                    absorb([ServerPlanDeployment(id: started.deploymentID, projectID: actionProjectID(pending.action), status: .pending)], fromEvent: true)
                case .done:
                    actionError = nil
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
    /// Claude session in the project's ClaudeDeck project (added if its folder exists). `done` gets
    /// the session, or why there's none (a phone's Fix with Claude).
    func fixWithClaude(_ deploymentID: Int, done: ((UUID?, String?) -> Void)? = nil) {
        guard let client, let model, let key = repairKey(deploymentID) else {
            done?(nil, String(localized: "ServerPlan isn't set up (Settings › ServerPlan)."))
            return
        }
        guard !repairing.contains(deploymentID) else {
            done?(nil, String(localized: "Fix with Claude is already starting for this deploy."))
            return
        }
        repairing.insert(deploymentID)
        Task {
            defer { repairing.remove(deploymentID) }
            let deployment: ServerPlanDeployment
            do {
                deployment = try await client.deployment(id: deploymentID)
            } catch {
                actionError = error.localizedDescription
                done?(nil, error.localizedDescription)
                return
            }
            let spProject = projects.first { $0.id == deployment.projectID }
            var deckProject = spProject.flatMap(deckProject(for:))
            if deckProject == nil, let path = spProject?.repoPath, FileManager.default.fileExists(atPath: path) {
                deckProject = model.addProject(path: path)
            }
            guard let deckProject else {
                actionError = String(localized: "No ClaudeDeck project has this project's folder; add it first.")
                done?(nil, actionError)
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
            guard let target else {
                done?(nil, String(localized: "The session couldn't be started."))
                NSSound.beep()
                return
            }
            model.mutate { $0.recordDeployRepair(DeployRepairRequest(key: key, sessionID: target)) }
            actionError = nil
            sheet = nil
            model.openMainWindow?()
            model.tabs.selectSessions()
            model.sendPrompt(DeployRepair.prompt(project: projectName, server: deployment.serverName, deployment: deployment, log: deployment.log ?? ""), to: target)
            done?(target, nil)
        }
    }

    // MARK: Clearing failures (local: nothing changes on the panel)

    private var panelURL: URL? { client?.config.baseURL }

    /// A failed deploy's issue (nil for any other status).
    func issue(for deploy: ServerPlanDeployment) -> ServerIssue? {
        guard deploy.status == .failed, let panelURL else { return nil }
        return .deploy(panel: panelURL, deploymentID: deploy.id)
    }

    /// A failed deploy the owner cleared.
    func isCleared(_ deploy: ServerPlanDeployment) -> Bool {
        guard let issue = issue(for: deploy), let model else { return false }
        return model.deck.isDismissed(issue)
    }

    /// Whether `deploy` is shown as a failure (failed and not cleared).
    func showsFailure(_ deploy: ServerPlanDeployment?) -> Bool {
        guard let deploy, deploy.status == .failed else { return false }
        return !isCleared(deploy)
    }

    /// What's wrong with a server (unreachable, offline, Docker not answering), or nil.
    func serverIssue(_ server: ServerPlanServer) -> ServerIssue? {
        guard let panelURL else { return nil }
        let health = health[server.id]
        let message: String
        if health?.reachable == false {
            message = "unreachable:" + (health?.error ?? "")
        } else if server.effectiveStatus == .offline {
            message = "offline"
        } else if health?.dockerOK == false {
            message = "docker"
        } else {
            return nil
        }
        return .server(panel: panelURL, serverID: server.id, message: message)
    }

    /// Whether the server row shows its problem (there is one and it wasn't cleared).
    func showsServerIssue(_ server: ServerPlanServer) -> Bool {
        guard let issue = serverIssue(server), let model else { return false }
        return !model.deck.isDismissed(issue)
    }

    private var panelIssue: ServerIssue? {
        guard let lastError, let panelURL else { return nil }
        return .panel(panelURL, message: lastError)
    }

    /// `lastError`, unless it was cleared (it shows again after the panel answers once more).
    var shownLastError: String? {
        guard let lastError else { return nil }
        if let issue = panelIssue, model?.deck.isDismissed(issue) == true { return nil }
        return lastError
    }

    /// The failed deploys the sidebar can show: the recent list and every project's last deploy.
    private var failedDeploys: [ServerPlanDeployment] {
        var seen: Set<Int> = []
        return (deployments + projects.compactMap { latestDeploy(of: $0) })
            .filter { $0.status == .failed && seen.insert($0.id).inserted }
    }

    /// Every failure on screen that can still be cleared.
    var visibleIssues: [ServerIssue] {
        guard let model else { return [] }
        let all = failedDeploys.compactMap(issue(for:)) + servers.compactMap(serverIssue) + [panelIssue].compactMap { $0 }
        return all.filter { !model.deck.isDismissed($0) }
    }

    /// For the Servers header's Clear All.
    var hasClearableErrors: Bool { actionError != nil || !visibleIssues.isEmpty }

    func clearDeploy(_ deploy: ServerPlanDeployment) {
        guard let issue = issue(for: deploy) else { return }
        clear([issue], notices: ["serverplan-deploy-\(deploy.id)"])
    }

    func clearServerIssue(_ server: ServerPlanServer) {
        guard let issue = serverIssue(server) else { return }
        clear([issue], notices: ["serverplan-server-\(server.id)"])
    }

    func clearPanelError() {
        guard let issue = panelIssue else { return }
        clear([issue], notices: [])
    }

    /// Clear All: every failure shown now and the last action's error.
    func clearAll() {
        actionError = nil
        let notices = failedDeploys.map { "serverplan-deploy-\($0.id)" } + servers.map { "serverplan-server-\($0.id)" }
        clear(visibleIssues, notices: notices)
    }

    /// The phone's swipe (`ids`) or its Clear All (`all`).
    func clearFromPhone(deploymentIDs ids: [Int], all: Bool) {
        if all { clearAll(); return }
        let wanted = Set(ids)
        let deploys = failedDeploys.filter { wanted.contains($0.id) }
        clear(deploys.compactMap(issue(for:)), notices: deploys.map { "serverplan-deploy-\($0.id)" })
    }

    private func clear(_ issues: [ServerIssue], notices: [String]) {
        guard let model else { return }
        if !issues.isEmpty {
            let active = activeIssueKeys
            model.mutate {
                $0.dismissServerIssues(issues)
                $0.pruneDismissedServerIssues(keeping: active)
            }
        }
        if !notices.isEmpty { onCleared?(notices) }
        model.onCountsChanged?()  // the phone's snapshot leaves them out
    }

    /// Keys of the failures still listed (their clearing must outlive the 30 days).
    private var activeIssueKeys: Set<String> {
        Set(failedDeploys.compactMap(issue(for:)).map(\.key) + servers.compactMap(serverIssue).map(\.key) + [panelIssue].compactMap { $0?.key })
    }

    private func pruneCleared() {
        guard let model else { return }
        let active = activeIssueKeys
        var deck = model.deck
        guard deck.pruneDismissedServerIssues(keeping: active) else { return }
        model.mutate(userInitiated: false) { $0.pruneDismissedServerIssues(keeping: active) }
    }

    /// The panel answered / servers are healthy again: their cleared errors are forgotten, so the
    /// next failure shows.
    private func forgetRecovered(panel: Bool, servers ids: [Int]) {
        guard let model, let panelURL else { return }
        var keys = Set(ids.map { ServerIssue.serverKey(panel: panelURL, serverID: $0) })
        if panel { keys.insert(ServerIssue.panelKey(panelURL)) }
        guard model.deck.dismissedServerIssues.contains(where: { keys.contains($0.key) }) else { return }
        model.mutate(userInitiated: false) { $0.forgetServerIssues(keys) }
    }

    /// Shows the deploy's log (from a notification).
    func showDeploy(_ id: Int) {
        let name = deployments.first { $0.id == id }?.projectName ?? "#\(id)"
        sheet = .deploy(id: id, title: name)
    }
}
