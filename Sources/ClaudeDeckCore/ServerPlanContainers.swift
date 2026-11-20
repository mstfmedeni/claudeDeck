import Foundation

// Containers and server resources through ServerPlan's agent API: what a 1.4 panel gives
// (the container list, health strings, logs, domains, project env) and the 1.5 additions
// ClaudeDeck asked for (docs/serverplan-containers.md §5). Every 1.5 call is gated on its `/me`
// feature, never on the version; the shapes below read both the proposed JSON and what 1.4 sends.

extension ServerPlanContract.Feature {
    /// v1.1: project env (`GET/POST /projects/:id/env`).
    public static let env = "env"
    /// v1.3: `DELETE /projects/:id/env/:envId` (428, confirm = the key).
    public static let envDelete = "env_delete"
    /// v1.1: `GET /domains`.
    public static let domains = "domains"
    // Proposed for 1.5 (docs/serverplan-containers.md §5).
    /// `id`, `created`, `health`, `project_id`, `project_name`, `domains` on the container list.
    public static let containerDetails = "container_details"
    /// `GET /servers/:id/containers/:name`.
    public static let containerInspect = "container_inspect"
    /// `GET /servers/:id/containers/stats` and `…/containers/:name/stats`.
    public static let containerStats = "container_stats"
    /// Numbers on `/servers/:id/health` (`cpu_percent`, `mem_used_bytes`, …, net counters).
    public static let serverStats = "server_stats"
    /// `since` / `until` / `grep` / `timestamps` on container logs.
    public static let logQuery = "log_query"
    /// `POST /ws-ticket` with `command: "exec"` and `container`.
    public static let containerExec = "container_exec"
    /// `POST …/containers/:name/recreate` (428).
    public static let containerRecreate = "container_recreate"
    /// `POST …/containers/:name/pull` (428).
    public static let imageUpdate = "image_update"
    /// `DELETE …/containers/:name` (428).
    public static let containerRemove = "container_remove"
    /// `GET /servers/:id/docker/disk`, `POST /servers/:id/docker/prune` (428).
    public static let dockerPrune = "docker_prune"
}

// MARK: - What docker's status line says

/// A container's health check as docker reports it.
public enum ServerPlanContainerHealth: String, Sendable, Equatable {
    case healthy, unhealthy, starting, none

    init(raw: String?) {
        switch raw?.lowercased() {
        case "healthy": self = .healthy
        case "unhealthy": self = .unhealthy
        case "starting", "health: starting": self = .starting
        default: self = .none
        }
    }
}

extension ServerPlanContainer {
    /// The panel's `health` (1.5), else what `docker ps` puts in the status: "Up 2 hours (healthy)".
    public var health: ServerPlanContainerHealth {
        if let healthField { return ServerPlanContainerHealth(raw: healthField) }
        guard let status = status?.lowercased() else { return .none }
        if status.contains("(unhealthy)") { return .unhealthy }
        if status.contains("(healthy)") { return .healthy }
        if status.contains("health: starting") { return .starting }
        return .none
    }

    /// docker's state, lowercased (`running`, `exited`, `restarting`, `paused`, `created`, `dead`).
    public var stateName: String { (state ?? "").lowercased() }

    /// How long it has been up ("2 hours") from "Up 2 hours (healthy)"; nil when not up.
    public var uptime: String? {
        guard let status, status.hasPrefix("Up ") else { return nil }
        var text = String(status.dropFirst(3))
        if let paren = text.range(of: " (") { text = String(text[..<paren.lowerBound]) }
        return text.isEmpty ? nil : text
    }

    /// The exit code of a stopped container ("Exited (1) 29 minutes ago" → 1).
    public var exitCode: Int? {
        guard let status, let match = status.firstMatch(of: /^Exited \((-?\d+)\)/) else { return nil }
        return Int(match.1)
    }

    /// Published ports, simplified and without the IPv6 duplicates:
    /// "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp, 5432/tcp" → ["3000→3000/tcp", "5432/tcp"].
    public var portList: [String] {
        guard let ports, !ports.isEmpty else { return [] }
        var seen: [String] = []
        for raw in ports.split(separator: ",") {
            var item = raw.trimmingCharacters(in: .whitespaces)
            if let arrow = item.range(of: "->") {
                let host = item[..<arrow.lowerBound]
                let hostPort = host.split(separator: ":").last.map(String.init) ?? String(host)
                item = hostPort + "→" + item[arrow.upperBound...]
            }
            if !item.isEmpty, !seen.contains(item) { seen.append(item) }
        }
        return seen
    }

    /// The image's tag ("acme-storefront:205" → "205"; nil without one).
    public var imageTag: String? {
        guard let image, let colon = image.lastIndex(of: ":") else { return nil }
        let tag = image[image.index(after: colon)...]
        return tag.contains("/") || tag.isEmpty ? nil : String(tag)
    }

    /// The row's state for the dot: problems first.
    public var condition: ServerPlanContainerCondition {
        switch stateName {
        case "running": health == .unhealthy ? .unhealthy : health == .starting ? .starting : .running
        case "restarting": .restarting
        case "paused": .paused
        case "exited", "dead": exitCode.map { $0 == 0 } == true ? .stopped : .failed
        default: .stopped
        }
    }
}

public enum ServerPlanContainerCondition: String, Sendable, Equatable {
    case running, starting, unhealthy, restarting, paused, stopped, failed

    /// Needs the owner's eye (orange / red in the list).
    public var isProblem: Bool { [.unhealthy, .restarting, .failed].contains(self) }
}

// MARK: - Domains and the container ↔ project ↔ domain rule

/// A row of `GET /domains` (the panel's domain table; read tolerantly).
public struct ServerPlanDomain: Decodable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var serverID: Int?
    public var subdomain: String
    public var baseDomain: String
    /// go_app | static | redirect
    public var type: String
    public var target: String
    public var port: Int?
    public var projectName: String?

    public init(id: Int, serverID: Int?, subdomain: String = "", baseDomain: String, type: String = "go_app", target: String = "",
                port: Int? = nil, projectName: String? = nil) {
        self.id = id
        self.serverID = serverID
        self.subdomain = subdomain
        self.baseDomain = baseDomain
        self.type = type
        self.target = target
        self.port = port
        self.projectName = projectName
    }

    public var fqdn: String { subdomain.isEmpty || subdomain == "@" ? baseDomain : "\(subdomain).\(baseDomain)" }

    enum CodingKeys: String, CodingKey {
        case id, serverID = "server_id", subdomain, baseDomain = "base_domain", type, target, port, projectName = "project_name", fqdn
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleInt.self, forKey: .id).value
        serverID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .serverID))?.value
        subdomain = (try? c.decodeIfPresent(String.self, forKey: .subdomain)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "go_app"
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        port = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .port))?.value
        projectName = (try? c.decodeIfPresent(String.self, forKey: .projectName)).flatMap { $0?.isEmpty == false ? $0 : nil }
        if let base = try? c.decodeIfPresent(String.self, forKey: .baseDomain), !base.isEmpty {
            baseDomain = base
        } else if let fqdn = try? c.decodeIfPresent(String.self, forKey: .fqdn) {
            // Older fixtures carry only the FQDN.
            let parts = fqdn.split(separator: ".")
            baseDomain = parts.suffix(2).joined(separator: ".")
            if subdomain.isEmpty, parts.count > 2 { subdomain = parts.dropLast(2).joined(separator: ".") }
        } else {
            baseDomain = ""
        }
    }
}

/// ServerPlan's own rule for which container serves a domain (`servers.go ListContainers`,
/// `deploy/deployer.go`): an app's container is `lower(target)` or `lower(project_name)`; a static
/// site's is `nginx-<sub>-<base with dashes>` (`nginx-<base with dashes>` for the root).
public enum ServerPlanContainerMatch {
    public static func containerNames(of domain: ServerPlanDomain) -> [String] {
        switch domain.type {
        case "static":
            let base = domain.baseDomain.replacingOccurrences(of: ".", with: "-")
            let sub = domain.subdomain
            return [sub.isEmpty || sub == "@" ? "nginx-\(base)" : "nginx-\(sub)-\(base)"]
        case "go_app":
            return [domain.target.lowercased(), domain.projectName?.lowercased()].compactMap { $0 }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    /// The domains that route to `container` on `serverID` (the panel's list when it sends one).
    public static func domains(for container: ServerPlanContainer, serverID: Int, in domains: [ServerPlanDomain]) -> [String] {
        if let given = container.domains { return given }
        let name = container.name.lowercased()
        return domains.filter { ($0.serverID == nil || $0.serverID == serverID) && containerNames(of: $0).contains(name) }
            .map(\.fqdn).sorted()
    }

    /// The ServerPlan project the container belongs to: the panel's `project_id`, else its domain's
    /// project, else the project named like it (preferring one deployed to this server).
    public static func project(for container: ServerPlanContainer, serverID: Int, projects: [ServerPlanProject],
                               domains: [ServerPlanDomain]) -> ServerPlanProject? {
        if let id = container.projectID, let project = projects.first(where: { $0.id == id }) { return project }
        func named(_ name: String) -> ServerPlanProject? {
            let candidates = projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return candidates.first { $0.defaultServerID == serverID } ?? candidates.first
        }
        if let name = container.projectName, let project = named(name) { return project }
        let lower = container.name.lowercased()
        for domain in domains where (domain.serverID == nil || domain.serverID == serverID) && domain.type == "go_app" {
            if containerNames(of: domain).contains(lower), let name = domain.projectName, let project = named(name) { return project }
        }
        return named(container.name)
    }
}

// MARK: - Sizes and numbers from shell tools

public enum ByteSize {
    /// "150MiB", "3.84GiB", "12.6MB", "4.1kB", "0B", "1.2G" (df/free -h: 1024-based), "2Gi".
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /([0-9]+(?:[.,][0-9]+)?)\s*([A-Za-z]*)/) else { return nil }
        guard let number = Double(match.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
        switch String(match.2).lowercased() {
        case "", "b": return number
        case "k", "ki", "kib": return number * 1024
        case "m", "mi", "mib": return number * 1_048_576
        case "g", "gi", "gib": return number * 1_073_741_824
        case "t", "ti", "tib": return number * 1_099_511_627_776
        case "kb": return number * 1_000
        case "mb": return number * 1_000_000
        case "gb": return number * 1_000_000_000
        case "tb": return number * 1_000_000_000_000
        default: return nil
        }
    }

    /// "1.2 GB" style (binary units shown as the panel does, rounded).
    public static func format(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .memory)
    }

    /// "used / total" pairs as docker and `free -h` print them ("150MiB / 3.84GiB", "1.2G/3.8G").
    public static func pair(_ text: String?) -> (used: Double, total: Double)? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        // df's "(22%)" suffix.
        let second = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
        guard let used = parse(parts[0]), let total = parse(second) else { return nil }
        return (used, total)
    }
}

/// The server's numbers for the sparklines: the 1.5 numbers, else parsed from 1.4's strings.
public struct ServerPlanServerSample: Sendable, Equatable {
    public var cpuPercent: Double?
    /// 0…100
    public var memPercent: Double?
    public var diskPercent: Double?
    public var load1: Double?
    public var netRxBytes: Double?
    public var netTxBytes: Double?
    public var memUsedBytes: Double?
    public var memTotalBytes: Double?

    public init(_ health: ServerPlanHealth) {
        cpuPercent = health.cpuPercentValue ?? health.cpu.flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        if let used = health.memUsedBytes, let total = health.memTotalBytes, total > 0 {
            memPercent = used / total * 100
            memUsedBytes = used
            memTotalBytes = total
        } else if let pair = ByteSize.pair(health.memory), pair.total > 0 {
            memPercent = pair.used / pair.total * 100
            memUsedBytes = pair.used
            memTotalBytes = pair.total
        }
        if let used = health.diskUsedBytes, let total = health.diskTotalBytes, total > 0 {
            diskPercent = used / total * 100
        } else if let disk = health.disk, let match = disk.firstMatch(of: /\((\d+(?:\.\d+)?)%\)/) {
            diskPercent = Double(match.1)
        } else if let pair = ByteSize.pair(health.disk), pair.total > 0 {
            diskPercent = pair.used / pair.total * 100
        }
        load1 = health.load1 ?? health.loadAverage.flatMap { $0.split(separator: " ").first.flatMap { Double($0) } }
        netRxBytes = health.netRxBytes
        netTxBytes = health.netTxBytes
    }
}

// MARK: - 1.5 shapes

/// A container's resource use (`container_stats`). Reads the proposed numbers and docker's own
/// display strings (`{"cpu":"1.85%","mem":"150MiB / 3.84GiB","net":"…","block":"…"}`).
public struct ServerPlanContainerStats: Decodable, Sendable, Equatable {
    public var name: String
    public var cpuPercent: Double?
    public var memUsedBytes: Double?
    public var memLimitBytes: Double?
    public var memPercent: Double?
    public var netRxBytes: Double?
    public var netTxBytes: Double?
    public var blockReadBytes: Double?
    public var blockWriteBytes: Double?
    public var pids: Int?

    public init(name: String, cpuPercent: Double? = nil, memUsedBytes: Double? = nil, memLimitBytes: Double? = nil, memPercent: Double? = nil,
                netRxBytes: Double? = nil, netTxBytes: Double? = nil, blockReadBytes: Double? = nil, blockWriteBytes: Double? = nil, pids: Int? = nil) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memUsedBytes = memUsedBytes
        self.memLimitBytes = memLimitBytes
        self.memPercent = memPercent
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.pids = pids
    }

    enum CodingKeys: String, CodingKey {
        case name, container, cpuPercent = "cpu_percent", memUsed = "mem_used_bytes", memLimit = "mem_limit_bytes", memPercent = "mem_percent"
        case netRx = "net_rx_bytes", netTx = "net_tx_bytes", blockRead = "block_read_bytes", blockWrite = "block_write_bytes", pids
        case cpu, mem, net, block
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double? { (try? c.decodeIfPresent(FlexibleDouble.self, forKey: key))?.value }
        func text(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        name = text(.name) ?? text(.container) ?? ""
        cpuPercent = number(.cpuPercent) ?? number(.cpu)
        let mem = ByteSize.pair(text(.mem))
        memUsedBytes = number(.memUsed) ?? mem?.used
        memLimitBytes = number(.memLimit) ?? mem?.total
        memPercent = number(.memPercent) ?? {
            guard let used = memUsedBytes, let limit = memLimitBytes, limit > 0 else { return nil }
            return used / limit * 100
        }()
        let net = ByteSize.pair(text(.net)), block = ByteSize.pair(text(.block))
        netRxBytes = number(.netRx) ?? net?.used
        netTxBytes = number(.netTx) ?? net?.total
        blockReadBytes = number(.blockRead) ?? block?.used
        blockWriteBytes = number(.blockWrite) ?? block?.total
        pids = number(.pids).map { Int($0) }
    }
}

/// One container in detail (`container_inspect`; env values never, only the keys).
public struct ServerPlanContainerInspect: Decodable, Sendable, Equatable {
    public struct Mount: Decodable, Sendable, Equatable {
        public var source: String
        public var destination: String
        public var rw: Bool
        enum CodingKeys: String, CodingKey { case source, destination, rw }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
            destination = (try? c.decodeIfPresent(String.self, forKey: .destination)) ?? ""
            rw = (try? c.decodeIfPresent(Bool.self, forKey: .rw)) ?? true
        }
    }

    public var name: String
    public var imageID: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var createdAt: Date?
    public var restartCount: Int?
    public var restartPolicy: String?
    public var oomKilled: Bool?
    public var exitCode: Int?
    public var networks: [String]
    public var mounts: [Mount]
    public var envKeys: [String]
    public var domains: [String]?
    public var projectID: Int?
    public var projectName: String?
    public var health: String?

    enum CodingKeys: String, CodingKey {
        case name, imageID = "image_id", startedAt = "started_at", finishedAt = "finished_at", createdAt = "created_at"
        case restartCount = "restart_count", restartPolicy = "restart_policy", oomKilled = "oom_killed", exitCode = "exit_code"
        case networks, mounts, envKeys = "env_keys", domains, projectID = "project_id", projectName = "project_name", health
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) -> Date? {
            guard let value = (try? c.decodeIfPresent(FlexibleDate.self, forKey: key))?.value else { return nil }
            // docker's "0001-01-01T00:00:00Z" is "never".
            return value.timeIntervalSince1970 < 0 ? nil : value
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        imageID = try? c.decodeIfPresent(String.self, forKey: .imageID)
        startedAt = date(.startedAt)
        finishedAt = date(.finishedAt)
        createdAt = date(.createdAt)
        restartCount = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .restartCount))?.value
        restartPolicy = try? c.decodeIfPresent(String.self, forKey: .restartPolicy)
        oomKilled = try? c.decodeIfPresent(Bool.self, forKey: .oomKilled)
        exitCode = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .exitCode))?.value
        networks = (try? c.decodeIfPresent([String].self, forKey: .networks)) ?? []
        mounts = (try? c.decodeIfPresent([Mount].self, forKey: .mounts)) ?? []
        envKeys = (try? c.decodeIfPresent([String].self, forKey: .envKeys)) ?? []
        domains = try? c.decodeIfPresent([String].self, forKey: .domains)
        projectID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .projectID))?.value
        projectName = try? c.decodeIfPresent(String.self, forKey: .projectName)
        health = try? c.decodeIfPresent(String.self, forKey: .health)
    }
}

/// `GET /servers/:id/docker/disk` (`docker_prune`): `docker system df` in bytes.
public struct ServerPlanDockerDisk: Decodable, Sendable, Equatable {
    public struct Usage: Decodable, Sendable, Equatable {
        public var count: Int
        public var active: Int
        public var sizeBytes: Double
        public var reclaimableBytes: Double

        public init(count: Int = 0, active: Int = 0, sizeBytes: Double = 0, reclaimableBytes: Double = 0) {
            self.count = count
            self.active = active
            self.sizeBytes = sizeBytes
            self.reclaimableBytes = reclaimableBytes
        }

        enum CodingKeys: String, CodingKey { case count, active, sizeBytes = "size_bytes", reclaimableBytes = "reclaimable_bytes" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .count))?.value ?? 0
            active = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .active))?.value ?? 0
            sizeBytes = (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .sizeBytes))?.value ?? 0
            reclaimableBytes = (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .reclaimableBytes))?.value ?? 0
        }
    }

    public var images: Usage
    public var containers: Usage
    public var volumes: Usage
    public var buildCache: Usage

    enum CodingKeys: String, CodingKey { case images, containers, volumes, buildCache = "build_cache" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = (try? c.decodeIfPresent(Usage.self, forKey: .images)) ?? Usage()
        containers = (try? c.decodeIfPresent(Usage.self, forKey: .containers)) ?? Usage()
        volumes = (try? c.decodeIfPresent(Usage.self, forKey: .volumes)) ?? Usage()
        buildCache = (try? c.decodeIfPresent(Usage.self, forKey: .buildCache)) ?? Usage()
    }

    /// What a prune with `options` could free at most.
    public func reclaimable(_ options: ServerPlanPruneOptions) -> Double {
        var total = 0.0
        if options.images != .none { total += images.reclaimableBytes }
        if options.containers { total += containers.reclaimableBytes }
        if options.volumes { total += volumes.reclaimableBytes }
        if options.buildCache { total += buildCache.reclaimableBytes }
        return total
    }
}

/// What `POST /servers/:id/docker/prune` removes.
public struct ServerPlanPruneOptions: Sendable, Hashable {
    public enum Images: String, Sendable, Hashable, CaseIterable {
        /// Untagged layers only (what ServerPlan already does after every deploy).
        case dangling
        /// Every image no container uses.
        case unused
        case none
    }

    public var images: Images
    public var containers: Bool
    /// Unused named volumes and their data.
    public var volumes: Bool
    public var buildCache: Bool

    public init(images: Images = .dangling, containers: Bool = true, volumes: Bool = false, buildCache: Bool = true) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.buildCache = buildCache
    }

    var body: [String: Any] {
        ["images": images.rawValue, "containers": containers, "volumes": volumes, "build_cache": buildCache]
    }

    /// For the CLI and the confirmation text: "images (unused), stopped containers, build cache".
    public var summary: String {
        var parts: [String] = []
        if images != .none { parts.append("images (\(images.rawValue))") }
        if containers { parts.append("stopped containers") }
        if buildCache { parts.append("build cache") }
        if volumes { parts.append("unused volumes WITH THEIR DATA") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

/// A project env row (`GET /projects/:id/env`); a secret's value never comes back.
public struct ServerPlanEnvVar: Decodable, Sendable, Equatable, Identifiable {
    public var envID: Int?
    public var key: String
    public var value: String?
    public var isSecret: Bool
    public var source: String?
    public var id: String { envID.map(String.init) ?? key }

    public init(envID: Int?, key: String, value: String?, isSecret: Bool, source: String? = nil) {
        self.envID = envID
        self.key = key
        self.value = value
        self.isSecret = isSecret
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, key, value, isSecret = "is_secret", source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        envID = (try? c.decodeIfPresent(FlexibleInt.self, forKey: .id))?.value
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        isSecret = (try? c.decodeIfPresent(Bool.self, forKey: .isSecret)) ?? false
        // Never keep a secret's value, even if a panel sent one.
        value = isSecret ? nil : (try? c.decodeIfPresent(String.self, forKey: .value)) ?? nil
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }
}

// MARK: - Logs: search, severity

/// How a log line reads: errors and warnings are highlighted, "errors only" keeps the errors.
public enum ServerPlanLogSeverity: Sendable, Equatable {
    case error, warning, normal

    /// Words loggers use (`level=error`, `"level":"error"`, `ERROR`, `panic:`, `Traceback`, …).
    public static func of(_ line: String) -> ServerPlanLogSeverity {
        let lower = line.lowercased()
        if lower.contains(/\b(error|err|fatal|panic|exception|traceback|critical|crit|emerg|failed|failure|unhandled|segfault|oomkilled)\b/) {
            // "0 errors", "error=nil", "errors: 0" are noise.
            if lower.contains(/\b0 errors?\b|error=nil|error: none|errors: 0|"error":null/) { return .normal }
            return .error
        }
        if lower.contains(/\b(warn|warning|deprecated)\b/) { return .warning }
        return .normal
    }
}

/// The logs view's filter: text (case-insensitive substring, or a regex after `re:`) and
/// "errors only".
public struct ServerPlanLogFilter: Sendable, Equatable {
    public var query: String
    public var errorsOnly: Bool

    public init(query: String = "", errorsOnly: Bool = false) {
        self.query = query
        self.errorsOnly = errorsOnly
    }

    public var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || errorsOnly }

    /// A `re:` query that doesn't compile matches nothing (the view says so).
    public var invalidRegex: Bool {
        guard let pattern = regexPattern else { return false }
        return (try? Regex(pattern).ignoresCase()) == nil
    }

    private var regexPattern: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("re:") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    public func matches(_ line: String) -> Bool {
        if errorsOnly, ServerPlanLogSeverity.of(line) != .error { return false }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if let pattern = regexPattern {
            guard !pattern.isEmpty else { return true }
            guard let regex = try? Regex(pattern).ignoresCase() else { return false }
            return line.contains(regex)
        }
        return line.localizedCaseInsensitiveContains(trimmed)
    }

    /// The CLI's `--grep` (like `grep -i -F`).
    public static func grep(_ lines: [String], _ text: String) -> [String] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
}

// MARK: - Sparkline series

/// The last `capacity` samples of one metric (oldest first).
public struct MetricSeries: Sendable, Equatable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 60) { self.capacity = max(2, capacity) }

    public mutating func append(_ value: Double?) {
        guard let value, value.isFinite else { return }
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var last: Double? { values.last }
    public var peak: Double? { values.max() }
}

/// Turns cumulative counters (bytes received so far) into per-second rates between samples.
public struct CounterRate: Sendable, Equatable {
    private var previous: (value: Double, at: Date)?

    public init() {}

    /// The rate since the previous sample; nil for the first one and after a counter reset.
    public mutating func rate(_ value: Double?, at date: Date) -> Double? {
        guard let value else { return nil }
        defer { previous = (value, date) }
        guard let previous, value >= previous.value else { return nil }
        let seconds = date.timeIntervalSince(previous.at)
        guard seconds > 0.5 else { return nil }
        return (value - previous.value) / seconds
    }

    public static func == (lhs: CounterRate, rhs: CounterRate) -> Bool {
        lhs.previous?.value == rhs.previous?.value && lhs.previous?.at == rhs.previous?.at
    }
}

/// The sparklines of one server or container: CPU %, memory %, disk %, load, and network
/// rates (bytes/s, from cumulative counters).
public struct ServerPlanSeries: Sendable, Equatable {
    public var cpu = MetricSeries()
    public var memory = MetricSeries()
    public var disk = MetricSeries()
    public var load = MetricSeries()
    public var netIn = MetricSeries()
    public var netOut = MetricSeries()
    private var rx = CounterRate()
    private var tx = CounterRate()

    public init() {}

    public mutating func add(_ sample: ServerPlanServerSample, at date: Date) {
        cpu.append(sample.cpuPercent)
        memory.append(sample.memPercent)
        disk.append(sample.diskPercent)
        load.append(sample.load1)
        netIn.append(rx.rate(sample.netRxBytes, at: date))
        netOut.append(tx.rate(sample.netTxBytes, at: date))
    }

    public mutating func add(_ stats: ServerPlanContainerStats, at date: Date) {
        cpu.append(stats.cpuPercent)
        memory.append(stats.memPercent)
        netIn.append(rx.rate(stats.netRxBytes, at: date))
        netOut.append(tx.rate(stats.netTxBytes, at: date))
    }
}

// MARK: - Claude ile düzelt from log lines

public enum ContainerLogRepair {
    /// At most this many lines go into the prompt (the last ones).
    public static let maxLines = 200

    /// The message typed into the session: what runs where, and the log lines the owner picked.
    public static func prompt(container: String, server: String, image: String?, project: String?, status: String?,
                              lines: [String]) -> String {
        var text = "The container \(container) on the server \(server)"
        if let project { text += " (ServerPlan project \(project))" }
        text += " logs the lines below"
        if let status, !status.isEmpty { text += "; docker says: \(status)" }
        text += ".\n"
        if let image { text += "Image: \(image). ServerPlan builds it from this project's Dockerfile and runs it with the project's env.\n" }
        text += "Find the cause in this project, fix it, and commit the fix. "
        text += "Don't deploy and don't touch the server; I'll redeploy from ServerPlan.\n"
        let picked = lines.suffix(maxLines).joined(separator: "\n")
        text += "Log lines:\n```\n\(picked.isEmpty ? "(no lines)" : picked)\n```"
        return text
    }
}

// MARK: - Client calls

extension ServerPlanClient {
    /// The panel's domains (v1.1), optionally of one server.
    public func domains(serverID: Int? = nil) async throws -> [ServerPlanDomain] {
        try await get([ServerPlanDomain].self, "/domains", query: serverID.map { [URLQueryItem(name: "server_id", value: String($0))] } ?? [])
    }

    /// `container_inspect`.
    public func containerInspect(serverID: Int, container: String) async throws -> ServerPlanContainerInspect {
        try Self.checkContainer(container)
        return try await get(ServerPlanContainerInspect.self, "/servers/\(serverID)/containers/\(Self.pathComponent(container))")
    }

    /// `container_stats`: every running container of the server.
    public func containerStats(serverID: Int) async throws -> [ServerPlanContainerStats] {
        try await get([ServerPlanContainerStats].self, "/servers/\(serverID)/containers/stats")
    }

    /// `container_stats`: one container.
    public func containerStats(serverID: Int, container: String) async throws -> ServerPlanContainerStats {
        try Self.checkContainer(container)
        return try await get(ServerPlanContainerStats.self, "/servers/\(serverID)/containers/\(Self.pathComponent(container))/stats")
    }

    /// `docker_prune`: what docker's images, containers, volumes and build cache take.
    public func dockerDisk(serverID: Int) async throws -> ServerPlanDockerDisk {
        try await get(ServerPlanDockerDisk.self, "/servers/\(serverID)/docker/disk")
    }

    /// The last `tail` lines; `since` / `grep` only go to a panel with `log_query` (the caller
    /// checks; an older panel would ignore them silently).
    public func containerLogs(serverID: Int, container: String, tail: Int, since: String?, grep: String?) async throws -> String {
        try Self.checkContainer(container)
        var query = [URLQueryItem(name: "tail", value: String(tail))]
        if let since, !since.isEmpty { query.append(URLQueryItem(name: "since", value: since)) }
        if let grep, !grep.isEmpty { query.append(URLQueryItem(name: "grep", value: grep)) }
        let request = try request(Self.logsPath(serverID: serverID, container: container), query: query, accept: "text/plain")
        let (data, _) = try await send(request)
        return String(decoding: data, as: UTF8.self)
    }

    /// A project's deploy env (v1.1 `env`); secret values never come back.
    public func projectEnv(projectID: Int) async throws -> [ServerPlanEnvVar] {
        try await get([ServerPlanEnvVar].self, "/projects/\(projectID)/env")
    }

    /// Adds or replaces one key of a project's deploy env (takes effect at the next deploy).
    public func setProjectEnv(projectID: Int, key: String, value: String, secret: Bool) async throws {
        _ = try await send(try request("/projects/\(projectID)/env", method: "POST", json: ["key": key, "value": value, "is_secret": secret]))
    }
}
