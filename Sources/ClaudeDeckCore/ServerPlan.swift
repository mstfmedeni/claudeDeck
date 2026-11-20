import Foundation

// ServerPlan (the owner's Go server-management panel) as seen through its agent API: models,
// errors and the wire details that may still move. The client is ServerPlanClient.swift; the app
// side is ServerPlanController (ClaudeDeck) and, later, `claudedeck server …` (CLI).
//
// Written against the frozen agent API contract v1. The wire details live in ServerPlanContract.

/// The wire details of the agent API (contract v1), in one place.
public enum ServerPlanContract {
    public static let defaultURL = "http://127.0.0.1:5050"
    /// Namespace of every endpoint.
    public static let basePath = "/api/v1/agent"
    /// "Destructive action without (the right) confirmation".
    public static let confirmRequiredStatus = 428
    public static let confirmRequiredCode = "confirm_required"
    /// Where WebSocket tickets come from.
    public static let ticketPath = "/ws-ticket"
    /// Feature flags in `/me`.
    public enum Feature {
        public static let deployStream = "deploy_stream"
        public static let logStream = "log_stream"
        public static let terminal = "terminal"
        public static let terminalClaude = "terminal_claude"
        public static let events = "events"
        /// v1.4: `GET /registrar/balance`, the `registrar.*` events.
        public static let registrarBalance = "registrar_balance"
    }
}

/// What a token may do (`/me` → `scopes`).
public enum ServerPlanScope: String, Sendable, CaseIterable {
    case read, logs, deploy, containers, terminal
}

public struct ServerPlanMe: Decodable, Sendable, Equatable {
    public var user: String
    public var role: String?
    public var scopes: [String]
    public var serverVersion: String?
    public var features: [String]

    public init(user: String, role: String? = nil, scopes: [String], serverVersion: String? = nil, features: [String] = []) {
        self.user = user
        self.role = role
        self.scopes = scopes
        self.serverVersion = serverVersion
        self.features = features
    }

    public func allows(_ scope: ServerPlanScope) -> Bool { scopes.contains(scope.rawValue) }
    public func has(feature: String) -> Bool { features.contains(feature) }

    enum CodingKeys: String, CodingKey { case user, role, scopes, serverVersion = "server_version", features }
    enum UserKeys: String, CodingKey { case username }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `{"id","username"}`; a bare name is read too.
        if let nested = try? c.nestedContainer(keyedBy: UserKeys.self, forKey: .user) {
            user = (try? nested.decodeIfPresent(String.self, forKey: .username)) ?? ""
        } else {
            user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? ""
        }
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? []
        serverVersion = try? c.decodeIfPresent(String.self, forKey: .serverVersion)
        features = (try? c.decodeIfPresent([String].self, forKey: .features)) ?? []
    }
}

/// A server's reachability as the dot shows it.
public enum ServerPlanServerStatus: String, Sendable, Equatable {
    case online, offline, unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "online", "up", "reachable", "ok": self = .online
        case "offline", "down", "unreachable", "error": self = .offline
        default: self = .unknown
        }
    }
}

public struct ServerPlanServer: Decodable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var host: String?
    public var status: ServerPlanServerStatus
    public var lastSeen: Date?
    /// The panel's cached reachability (`health.reachable`) and when it was checked.
    public var reachable: Bool?
    public var checkedAt: Date?

    public init(id: Int, name: String, host: String? = nil, status: ServerPlanServerStatus = .unknown, lastSeen: Date? = nil,
                reachable: Bool? = nil, checkedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.status = status
        self.lastSeen = lastSeen
        self.reachable = reachable
        self.checkedAt = checkedAt
    }

    /// The dot: the status field, else what the cached health says.
    public var effectiveStatus: ServerPlanServerStatus {
        if status != .unknown { return status }
        if let reachable { return reachable ? .online : .offline }
        return .unknown
    }

    enum CodingKeys: String, CodingKey { case id, name, host, status, lastSeen = "last_seen", health }
    enum HealthKeys: String, CodingKey { case reachable, checkedAt = "checked_at" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleInt.self, forKey: .id).value
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "#\(id)"
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        status = ServerPlanServerStatus(raw: try? c.decodeIfPresent(String.self, forKey: .status))
        lastSeen = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .lastSeen))?.value
        if let health = try? c.nestedContainer(keyedBy: HealthKeys.self, forKey: .health) {
            reachable = try? health.decodeIfPresent(Bool.self, forKey: .reachable)
            checkedAt = (try? health.decodeIfPresent(FlexibleDate.self, forKey: .checkedAt))?.value
        }
    }
}

/// `GET /servers/:id/capabilities` (cached 10 min by the panel).
public struct ServerPlanCapabilities: Decodable, Sendable, Equatable {
    public var claude: Bool
    public var claudePath: String?

    public init(claude: Bool, claudePath: String? = nil) {
        self.claude = claude
        self.claudePath = claudePath
    }

    enum CodingKeys: String, CodingKey { case claude, claudePath = "claude_path" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decodeIfPresent(Bool.self, forKey: .claude)) ?? false
        claudePath = try? c.decodeIfPresent(String.self, forKey: .claudePath)
    }
}

/// `GET /servers/:id/health`. The panel measures with shell tools, so the numbers may come as
/// strings ("12%", "1.2G/4G") or numbers; both are kept as display text.
public struct ServerPlanHealth: Decodable, Sendable, Equatable {
    public var cpu: String?
    public var memory: String?
    public var disk: String?
    public var uptime: String?
    public var loadAverage: String?
    public var reachable: Bool?
    public var dockerOK: Bool?
    /// Why the server couldn't be measured (with `reachable: false`).
    public var error: String?
    public var checkedAt: Date?
    /// 1.5 `server_stats`: the same as numbers (nil from 1.4 panels; `ServerPlanStats` reads
    /// the strings above then). Net counters are cumulative since boot.
    public var cpuPercentValue: Double?
    public var cores: Int?
    public var memUsedBytes: Double?
    public var memTotalBytes: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var load1: Double?
    public var netRxBytes: Double?
    public var netTxBytes: Double?

    public init(cpu: String? = nil, memory: String? = nil, disk: String? = nil, uptime: String? = nil, loadAverage: String? = nil,
                reachable: Bool? = nil, dockerOK: Bool? = nil, error: String? = nil, checkedAt: Date? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.uptime = uptime
        self.loadAverage = loadAverage
        self.reachable = reachable
        self.dockerOK = dockerOK
        self.error = error
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case cpu, cpuUsage = "cpu_usage", mem, memory, memoryUsage = "memory_usage", disk, diskUsage = "disk_usage", uptime
        case loadAvg = "load_avg", reachable, dockerOK = "docker_ok", error, checkedAt = "checked_at"
        case cpuPercent = "cpu_percent", cores, memUsed = "mem_used_bytes", memTotal = "mem_total_bytes"
        case diskUsed = "disk_used_bytes", diskTotal = "disk_total_bytes", load1, netRx = "net_rx_bytes", netTx = "net_tx_bytes"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ keys: CodingKeys...) -> String? {
            for key in keys { if let v = try? c.decodeIfPresent(FlexibleString.self, forKey: key) { return v.value } }
            return nil
        }
        cpu = text(.cpu, .cpuUsage)
        memory = text(.mem, .memory, .memoryUsage)
        disk = text(.disk, .diskUsage)
        uptime = text(.uptime)
        loadAverage = text(.loadAvg)
        reachable = try? c.decodeIfPresent(Bool.self, forKey: .reachable)
        dockerOK = try? c.decodeIfPresent(Bool.self, forKey: .dockerOK)
        error = text(.error)
        checkedAt = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .checkedAt))?.value
        func number(_ key: CodingKeys) -> Double? { (try? c.decodeIfPresent(FlexibleDouble.self, forKey: key))?.value }
        cpuPercentValue = number(.cpuPercent)
        cores = number(.cores).map { Int($0) }
        memUsedBytes = number(.memUsed)
        memTotalBytes = number(.memTotal)
        diskUsedBytes = number(.diskUsed)
        diskTotalBytes = number(.diskTotal)
        load1 = number(.load1)
        netRxBytes = number(.netRx)
        netTxBytes = number(.netTx)
    }
}

public enum ServerPlanDeployStatus: String, Sendable, Equatable {
    case pending, building, transferring, deploying, success, failed, cancelled, unknown

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "succeeded", "ok", "done": self = .success
        case "error", "failure": self = .failed
        case "canceled": self = .cancelled
        case let value?: self = ServerPlanDeployStatus(rawValue: value) ?? .unknown
        case nil: self = .unknown
        }
    }

    public var isRunning: Bool { [.pending, .building, .transferring, .deploying].contains(self) }
    public var isFinished: Bool { [.success, .failed, .cancelled].contains(self) }
}

public struct ServerPlanDeploySummary: Decodable, Sendable, Equatable {
    public var id: Int
    public var status: ServerPlanDeployStatus
    public var finishedAt: Date?

    public init(id: Int, status: ServerPlanDeployStatus, finishedAt: Date? = nil) {
        self.id = id
        self.status = status
        self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey { case id, status, finishedAt = "finished_at" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleInt.self, forKey: .id).value
        status = ServerPlanDeployStatus(raw: try? c.decodeIfPresent(String.self, forKey: .status))
        finishedAt = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .finishedAt))?.value
    }
}

public struct ServerPlanProject: Decodable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var branch: String?
    public var defaultServerID: Int?
    public var domain: String?
    public var lastDeploy: ServerPlanDeploySummary?
    /// The project's folder on this Mac (`path`): matched to a ClaudeDeck project for Fix with Claude.
    public var repoPath: String?
    public var gitRemote: String?

    public init(id: Int, name: String, branch: String? = nil, defaultServerID: Int? = nil, domain: String? = nil,
                lastDeploy: ServerPlanDeploySummary? = nil, repoPath: String? = nil, gitRemote: String? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.defaultServerID = defaultServerID
        self.domain = domain
        self.lastDeploy = lastDeploy
        self.repoPath = repoPath
        self.gitRemote = gitRemote
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", name, branch, gitBranch = "git_branch", defaultServerID = "default_server_id"
        case domain, lastDeploy = "last_deploy", repoPath = "repo_path", path, gitRemote = "git_remote"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleInt.self, forKey: .id).value
        let display = try? c.decodeIfPresent(String.self, forKey: .displayName)
        let plain = try? c.decodeIfPresent(String.self, forKey: .name)
        name = [display, plain].compactMap { $0 }.first { !$0.isEmpty } ?? "#\(id)"
        branch = [try? c.decodeIfPresent(String.self, forKey: .branch), try? c.decodeIfPresent(String.self, forKey: .gitBranch)]
            .compactMap { $0 }.compactMap { $0 }.first { !$0.isEmpty }
        defaultServerID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .defaultServerID))?.value
        domain = try? c.decodeIfPresent(String.self, forKey: .domain)
        lastDeploy = try? c.decodeIfPresent(ServerPlanDeploySummary.self, forKey: .lastDeploy)
        repoPath = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? (try? c.decodeIfPresent(String.self, forKey: .repoPath))
        gitRemote = try? c.decodeIfPresent(String.self, forKey: .gitRemote)
    }
}

public struct ServerPlanContainer: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var image: String?
    public var state: String?
    public var status: String?
    public var ports: String?
    /// 1.5 `container_details` (nil from 1.4 panels): docker's short id, its creation time as
    /// docker prints it, `healthy|unhealthy|starting|none`, the project and the domains.
    public var containerID: String?
    public var created: String?
    public var healthField: String?
    public var projectID: Int?
    public var projectName: String?
    public var domains: [String]?
    public var id: String { name }

    public init(name: String, image: String? = nil, state: String? = nil, status: String? = nil, ports: String? = nil,
                containerID: String? = nil, created: String? = nil, health: String? = nil, projectID: Int? = nil,
                projectName: String? = nil, domains: [String]? = nil) {
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.containerID = containerID
        self.created = created
        self.healthField = health
        self.projectID = projectID
        self.projectName = projectName
        self.domains = domains
    }

    public var isRunning: Bool { state?.lowercased() == "running" }

    enum CodingKeys: String, CodingKey {
        case name, image, state, status, ports, id, created, health, projectID = "project_id", projectName = "project_name", domains
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        name = text(.name) ?? ""
        image = text(.image)
        state = text(.state)
        status = text(.status)
        ports = (try? c.decodeIfPresent(FlexibleString.self, forKey: .ports))?.value
        containerID = text(.id)
        created = text(.created)
        healthField = text(.health)
        projectID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .projectID))?.value
        projectName = text(.projectName)
        domains = try? c.decodeIfPresent([String].self, forKey: .domains)
    }
}

public struct ServerPlanDeployment: Decodable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var projectID: Int?
    public var projectName: String?
    public var serverID: Int?
    public var serverName: String?
    public var status: ServerPlanDeployStatus
    /// git_pull, sync, build, connect, transfer, deploy.
    public var step: String?
    /// A short reason (`error`).
    public var errorSummary: String?
    public var log: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var commit: String?
    public var branch: String?

    public init(id: Int, projectID: Int? = nil, projectName: String? = nil, serverID: Int? = nil, serverName: String? = nil,
                status: ServerPlanDeployStatus, step: String? = nil, errorSummary: String? = nil, log: String? = nil, startedAt: Date? = nil,
                finishedAt: Date? = nil, commit: String? = nil, branch: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.serverID = serverID
        self.serverName = serverName
        self.status = status
        self.step = step
        self.errorSummary = errorSummary
        self.log = log
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.commit = commit
        self.branch = branch
    }

    enum CodingKeys: String, CodingKey {
        case id, projectID = "project_id", projectName = "project_name", project, serverID = "server_id", serverName = "server_name", server
        case status, step, errorSummary = "error_summary", error, log, startedAt = "started_at", finishedAt = "finished_at", commit, branch
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleInt.self, forKey: .id).value
        projectID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .projectID))?.value
        projectName = (try? c.decodeIfPresent(String.self, forKey: .projectName)) ?? (try? c.decodeIfPresent(String.self, forKey: .project))
        serverID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .serverID))?.value
        serverName = (try? c.decodeIfPresent(String.self, forKey: .serverName)) ?? (try? c.decodeIfPresent(String.self, forKey: .server))
        status = ServerPlanDeployStatus(raw: try? c.decodeIfPresent(String.self, forKey: .status))
        step = try? c.decodeIfPresent(String.self, forKey: .step)
        errorSummary = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? (try? c.decodeIfPresent(String.self, forKey: .errorSummary))
        log = try? c.decodeIfPresent(String.self, forKey: .log)
        startedAt = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .startedAt))?.value
        finishedAt = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .finishedAt))?.value
        // "" means unknown.
        commit = (try? c.decodeIfPresent(String.self, forKey: .commit)).flatMap { $0?.isEmpty == false ? $0 : nil }
        branch = (try? c.decodeIfPresent(String.self, forKey: .branch)).flatMap { $0?.isEmpty == false ? $0 : nil }
    }
}

/// `event: status` on `/deployments/:id/stream`: `{"status","step"}`.
public struct ServerPlanDeployProgress: Decodable, Sendable, Equatable {
    public var status: ServerPlanDeployStatus
    /// git_pull, sync, build, connect, transfer, deploy.
    public var step: String?

    public init(status: ServerPlanDeployStatus, step: String? = nil) {
        self.status = status
        self.step = step
    }

    enum CodingKeys: String, CodingKey { case status, step }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = ServerPlanDeployStatus(raw: try? c.decodeIfPresent(String.self, forKey: .status))
        step = try? c.decodeIfPresent(String.self, forKey: .step)
    }
}

/// A `{"line", "stream"?}` log line (deploy and container log streams).
public struct ServerPlanLogLine: Decodable, Sendable, Equatable {
    public var line: String
    /// stdout | stderr (container logs).
    public var stream: String?

    public init(line: String, stream: String? = nil) {
        self.line = line
        self.stream = stream
    }

    /// From an SSE `event: log`; a body that isn't JSON is the line itself.
    public init?(_ event: ServerSentEvent) {
        guard event.event == "log" else { return nil }
        self = (try? ServerPlanClient.decoder.decode(ServerPlanLogLine.self, from: Data(event.data.utf8))) ?? ServerPlanLogLine(line: event.data)
    }

    /// `event: end` (`{"reason"}`): the container's log ended (docker logs exited); don't reconnect.
    public static func endReason(_ event: ServerSentEvent) -> String? {
        guard event.event == "end" else { return nil }
        struct End: Decodable { var reason: String? }
        return (try? ServerPlanClient.decoder.decode(End.self, from: Data(event.data.utf8)).reason) ?? ""
    }
}

/// An item of `/deployments/:id/stream`: the log so far is replayed first, then it goes live;
/// after `done` (the full deployment) the server closes the stream.
public enum ServerPlanDeployStreamEvent: Sendable, Equatable {
    case log(String)
    case status(ServerPlanDeployProgress)
    case done(ServerPlanDeployment)

    public init?(_ event: ServerSentEvent) {
        let data = Data(event.data.utf8)
        switch event.event {
        case "log":
            guard let line = ServerPlanLogLine(event) else { return nil }
            self = .log(line.line)
        case "status":
            guard let value = try? ServerPlanClient.decoder.decode(ServerPlanDeployProgress.self, from: data) else { return nil }
            self = .status(value)
        case "done":
            guard let value = try? ServerPlanClient.decoder.decode(ServerPlanDeployment.self, from: data) else { return nil }
            self = .done(value)
        default:
            return nil
        }
    }
}

/// An item of `/events`: `{type, at, data}`.
public struct ServerPlanEvent: Decodable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case deployStarted = "deploy.started"
        case deploySucceeded = "deploy.succeeded"
        case deployFailed = "deploy.failed"
        case deployCancelled = "deploy.cancelled"
        case serverUnreachable = "server.unreachable"
        case serverRecovered = "server.recovered"
        /// v1.4, edge-triggered on the panel: the Namecheap balance fell under its threshold / recovered.
        case registrarLowBalance = "registrar.low_balance"
        case registrarBalanceOK = "registrar.balance_ok"
        /// 1.6 `container_events` (a 2-minute poller on the panel; the first tick is silent):
        /// `{server_id,server_name,name,id,exit_code,oom_killed}`. A deliberate stop fires it too
        /// (exit 0, 137 or 143).
        case containerDied = "container.died"
        /// `{server_id,server_name,name,id}`
        case containerUnhealthy = "container.unhealthy"
        /// `{server_id,server_name,name,id,restart_count}`
        case containerRestarted = "container.restarted"
        /// `{server_id,server_name,name,id,reason:"recreate"|"image_update"}` (after an agent's
        /// recreate or image update).
        case containerRecreated = "container.recreated"
        case unknown

        public var isContainer: Bool { [.containerDied, .containerUnhealthy, .containerRestarted, .containerRecreated].contains(self) }
    }

    public struct Payload: Decodable, Sendable, Equatable {
        public var deploymentID: Int?
        public var projectID: Int?
        public var projectName: String?
        public var serverID: Int?
        public var serverName: String?
        public var errorSummary: String?
        /// `registrar.*` events: `{"available_balance","currency","low_threshold"}`.
        public var availableBalance: Double?
        public var currency: String?
        public var lowThreshold: Double?
        /// `container.*` events: the container, docker's short id and what happened.
        public var containerName: String?
        public var containerID: String?
        public var exitCode: Int?
        public var oomKilled: Bool?
        public var restartCount: Int?
        public var reason: String?

        public init(deploymentID: Int? = nil, projectID: Int? = nil, projectName: String? = nil, serverID: Int? = nil,
                    serverName: String? = nil, errorSummary: String? = nil,
                    availableBalance: Double? = nil, currency: String? = nil, lowThreshold: Double? = nil) {
            self.deploymentID = deploymentID
            self.projectID = projectID
            self.projectName = projectName
            self.serverID = serverID
            self.serverName = serverName
            self.errorSummary = errorSummary
            self.availableBalance = availableBalance
            self.currency = currency
            self.lowThreshold = lowThreshold
        }

        // v1 leaves `data` open: the likely names are read, as well as the deployment's own shape.
        enum CodingKeys: String, CodingKey {
            case deploymentID = "deployment_id", id, projectID = "project_id", projectName = "project_name", project
            case serverID = "server_id", serverName = "server_name", server, errorSummary = "error_summary", error
            case availableBalance = "available_balance", currency, lowThreshold = "low_threshold"
            case name, exitCode = "exit_code", oomKilled = "oom_killed", restartCount = "restart_count", reason
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deploymentID = ((try? c.decodeIfPresent(FlexibleInt.self, forKey: .deploymentID)) ?? (try? c.decodeIfPresent(FlexibleInt.self, forKey: .id)))?.value
            projectID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .projectID))?.value
            projectName = (try? c.decodeIfPresent(String.self, forKey: .projectName)) ?? (try? c.decodeIfPresent(String.self, forKey: .project))
            serverID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .serverID))?.value
            serverName = (try? c.decodeIfPresent(String.self, forKey: .serverName)) ?? (try? c.decodeIfPresent(String.self, forKey: .server))
            errorSummary = (try? c.decodeIfPresent(String.self, forKey: .errorSummary)) ?? (try? c.decodeIfPresent(String.self, forKey: .error))
            availableBalance = try? c.decodeIfPresent(Double.self, forKey: .availableBalance)
            currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            lowThreshold = try? c.decodeIfPresent(Double.self, forKey: .lowThreshold)
            containerName = try? c.decodeIfPresent(String.self, forKey: .name)
            // A container event's `id` is docker's hex id (a deploy event's is a number).
            containerID = try? c.decodeIfPresent(String.self, forKey: .id)
            exitCode = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .exitCode))?.value
            oomKilled = try? c.decodeIfPresent(Bool.self, forKey: .oomKilled)
            restartCount = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .restartCount))?.value
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    public var kind: Kind
    public var type: String
    public var at: Date?
    public var data: Payload
    /// The SSE `id:` it came with (for `Last-Event-ID`).
    public var eventID: String?

    public init(type: String, at: Date? = nil, data: Payload = Payload(), eventID: String? = nil) {
        self.type = type
        self.kind = Kind(rawValue: type) ?? .unknown
        self.at = at
        self.data = data
        self.eventID = eventID
    }

    enum CodingKeys: String, CodingKey { case type, at, data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        kind = Kind(rawValue: type) ?? .unknown
        at = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .at))?.value
        data = (try? c.decodeIfPresent(Payload.self, forKey: .data)) ?? Payload()
        eventID = nil
    }

    /// From an SSE item: the JSON body; the SSE event name stands in for a missing `type`.
    public init?(_ event: ServerSentEvent) {
        guard var value = try? ServerPlanClient.decoder.decode(ServerPlanEvent.self, from: Data(event.data.utf8)) else { return nil }
        if value.type.isEmpty, event.event != "message" {
            value.type = event.event
            value.kind = Kind(rawValue: event.event) ?? .unknown
        }
        value.eventID = event.id
        self = value
    }
}

/// A terminal WebSocket ticket (`POST /ws-ticket`): single use, 60 s.
public struct ServerPlanTicket: Decodable, Sendable, Equatable {
    public var ticket: String
    public var expiresIn: Int?
    /// `/api/v1/agent/ws/terminal?ticket=…` (relative to the panel).
    public var url: String

    public init(ticket: String, expiresIn: Int? = nil, url: String) {
        self.ticket = ticket
        self.expiresIn = expiresIn
        self.url = url
    }

    enum CodingKeys: String, CodingKey { case ticket, expiresIn = "expires_in", url }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try c.decode(String.self, forKey: .ticket)
        expiresIn = try? c.decodeIfPresent(Int.self, forKey: .expiresIn)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? "\(ServerPlanContract.basePath)/ws/terminal"
    }
}

/// What the remote terminal starts with.
public enum ServerPlanTerminalCommand: String, Sendable, Codable {
    case shell, claude
    /// 1.6 `container_exec`: a shell inside a running container (`docker exec`, bash else sh).
    case exec
}

/// `POST /projects/:id/deploy` → 202.
public struct ServerPlanDeployStarted: Decodable, Sendable, Equatable {
    public var deploymentID: Int
    public var streamURL: String?

    public init(deploymentID: Int, streamURL: String? = nil) {
        self.deploymentID = deploymentID
        self.streamURL = streamURL
    }

    enum CodingKeys: String, CodingKey { case deploymentID = "deployment_id", streamURL = "stream_url" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deploymentID = try c.decode(FlexibleInt.self, forKey: .deploymentID).value
        streamURL = try? c.decodeIfPresent(String.self, forKey: .streamURL)
    }
}

/// Everything that can go wrong talking to the panel.
public enum ServerPlanError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case badURL
    /// 401: bad or revoked token.
    case unauthorized(String?)
    /// 403: the token's user lacks the permission or the token the scope.
    case forbidden(String?)
    case notFound
    /// 428: a destructive action without (the right) confirmation. `summary` says what it would
    /// do; `expected` is the exact name to send back as `confirm`.
    case confirmRequired(summary: String?, expected: String?)
    /// A destructive action was attempted without the user's confirmation (never sent).
    case confirmationMissing
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, code: String?, message: String?)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "ServerPlan isn't set up.")
        case .badURL: String(localized: "The ServerPlan address isn't valid.")
        case .unauthorized(let message): message ?? String(localized: "ServerPlan rejected the token.")
        case .forbidden(let message): message ?? String(localized: "The token isn't allowed to do this.")
        case .notFound: String(localized: "ServerPlan doesn't know this item.")
        case .confirmRequired(let summary, _): summary ?? String(localized: "ServerPlan wants a confirmation for this.")
        case .confirmationMissing: String(localized: "This needs a confirmation first.")
        case .rateLimited: String(localized: "Too many requests to ServerPlan; try again shortly.")
        case .http(let status, _, let message): message ?? "HTTP \(status)"
        case .transport(let message): message
        case .decoding(let message): String(localized: "Unexpected answer from ServerPlan: \(message)")
        }
    }

    /// Maps a non-2xx answer.
    public static func from(status: Int, body: Data, headers: [String: String] = [:]) -> ServerPlanError {
        let parsed = ErrorBody.parse(body)
        if status == ServerPlanContract.confirmRequiredStatus || parsed.code == ServerPlanContract.confirmRequiredCode {
            return .confirmRequired(summary: parsed.summary ?? parsed.message, expected: parsed.confirm)
        }
        switch status {
        case 401: return .unauthorized(parsed.message)
        case 403: return .forbidden(parsed.message)
        case 404: return .notFound
        case 429:
            let retry = headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) }
            return .rateLimited(retryAfter: retry)
        default: return .http(status: status, code: parsed.code, message: parsed.message)
        }
    }

    /// `{"error":"<snake_code>","message":"<text>"}`, plus `summary` / `confirm` on a 428.
    struct ErrorBody {
        var code: String?
        var message: String?
        var summary: String?
        var confirm: String?

        static func parse(_ data: Data) -> ErrorBody {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let text = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ErrorBody(message: text?.isEmpty == false ? text : nil)
            }
            let error = object["error"] as? String
            var message = object["message"] as? String ?? error
            // 1.6 `action_failed` (recreate, image update, prune): docker's last lines and, for a
            // partial prune, what was freed anyway.
            if let bytes = (object["reclaimed_bytes"] as? NSNumber)?.doubleValue, bytes > 0 {
                message = (message ?? "") + "\n" + String(localized: "Reclaimed anyway: \(ByteSize.format(bytes))")
            }
            if let output = (object["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                message = (message ?? "") + "\n" + output.split(separator: "\n").suffix(20).joined(separator: "\n")
            }
            return ErrorBody(code: error, message: message, summary: object["summary"] as? String, confirm: object["confirm"] as? String)
        }
    }
}

// MARK: - Tolerant decoding helpers

/// An integer that may come as a number or a numeric string.
struct FlexibleInt: Decodable {
    var value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { value = v; return }
        if let s = try? c.decode(String.self), let v = Int(s) { value = v; return }
        throw DecodingError.typeMismatch(Int.self, .init(codingPath: decoder.codingPath, debugDescription: "not an integer"))
    }
}

/// A number that may come as a number or a numeric string ("12.5", "12.5%").
struct FlexibleDouble: Decodable {
    var value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { value = v; return }
        if let s = try? c.decode(String.self),
           let v = Double(s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
            value = v
            return
        }
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "not a number"))
    }
}

/// Text that may come as a string, a number or a bool.
struct FlexibleString: Decodable {
    var value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = String(v); return }
        if let v = try? c.decode(Double.self) { value = String(format: "%.1f", v); return }
        if let v = try? c.decode(Bool.self) { value = v ? "true" : "false"; return }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "not text"))
    }
}

/// RFC 3339 with or without fractional seconds (Go's time.Time writes nanoseconds), or Unix seconds.
struct FlexibleDate: Decodable {
    var value: Date
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let seconds = try? c.decode(Double.self) { value = Date(timeIntervalSince1970: seconds); return }
        let text = try c.decode(String.self)
        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a date: \(text)")
        }
        value = date
    }

    static func parse(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: .iso8601) { return d }
        // Fractional seconds of any length: keep milliseconds for the parser.
        if let m = text.firstMatch(of: /^(.+T\d\d:\d\d:\d\d)\.(\d+)(.*)$/) {
            let ms = String(m.2.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            let normalized = "\(m.1).\(ms)\(m.3)"
            if let d = try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        }
        return nil
    }
}
