import Foundation

/// Where ServerPlan is and the token that opens it. The token lives in the Keychain on the Mac;
/// this value only carries it for the duration of a request.
public struct ServerPlanConfig: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// From what the user typed: trims, adds `http://` when no scheme is given, drops a trailing `/`.
    public init?(address: String, token: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !token.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        self.init(baseURL: url, token: token)
    }
}

/// Sends requests; swapped for a stub in tests.
public protocol ServerPlanTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The body as it arrives (Server-Sent Events).
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

public struct URLSessionServerPlanTransport: ServerPlanTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerPlanError.transport("not HTTP") }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerPlanError.transport("not HTTP") }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        // Hand over per line: SSE is line based and keepalives are tiny.
                        if byte == 0x0A {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

/// A destructive action. It is only sent with a `ServerPlanConfirmation`, which the UI makes
/// after the user said yes in a confirmation dialog.
public enum ServerPlanAction: Sendable, Equatable, Hashable {
    case deploy(projectID: Int, projectName: String, serverID: Int?, forceRebuild: Bool)
    case container(serverID: Int, serverName: String, name: String, verb: ContainerVerb)
    /// 1.5: recreate, update the image, remove (features `container_recreate`, `image_update`,
    /// `container_remove`).
    case containerOp(serverID: Int, serverName: String, name: String, op: ContainerOp)
    /// 1.5 `docker_prune`: confirmed with the server's name.
    case prune(serverID: Int, serverName: String, options: ServerPlanPruneOptions)
    /// v1.3 `env_delete`: one project env row, confirmed with its key.
    case envDelete(projectID: Int, projectName: String, envID: Int, key: String)

    public enum ContainerVerb: String, Sendable, Hashable, CaseIterable {
        case start, stop, restart
    }

    public enum ContainerOp: String, Sendable, Hashable, CaseIterable {
        case recreate, pull, remove

        /// The `/me` feature that offers it.
        public var feature: String {
            switch self {
            case .recreate: ServerPlanContract.Feature.containerRecreate
            case .pull: ServerPlanContract.Feature.imageUpdate
            case .remove: ServerPlanContract.Feature.containerRemove
            }
        }
    }

    /// The exact name the server expects in `"confirm"`: the project's display name / the container.
    public var confirmTarget: String {
        switch self {
        case .deploy(_, let projectName, _, _): projectName
        case .container(_, _, let name, _), .containerOp(_, _, let name, _): name
        case .prune(_, let serverName, _): serverName
        case .envDelete(_, _, _, let key): key
        }
    }

    var method: String {
        switch self {
        case .containerOp(_, _, _, .remove), .envDelete: "DELETE"
        default: "POST"
        }
    }

    /// The container a request names (checked before its URL is built).
    public var containerName: String? {
        switch self {
        case .container(_, _, let name, _), .containerOp(_, _, let name, _): name
        default: nil
        }
    }

    var path: String {
        switch self {
        case .deploy(let id, _, _, _): "/projects/\(id)/deploy"
        case .container(let serverID, _, let name, let verb): "/servers/\(serverID)/containers/\(ServerPlanClient.pathComponent(name))/\(verb.rawValue)"
        case .containerOp(let serverID, _, let name, .remove): "/servers/\(serverID)/containers/\(ServerPlanClient.pathComponent(name))"
        case .containerOp(let serverID, _, let name, let op): "/servers/\(serverID)/containers/\(ServerPlanClient.pathComponent(name))/\(op.rawValue)"
        case .prune(let serverID, _, _): "/servers/\(serverID)/docker/prune"
        case .envDelete(let projectID, _, let envID, _): "/projects/\(projectID)/env/\(envID)"
        }
    }

    /// The request body; without `confirm` the server only answers 428 with what it would do.
    func body(confirm: String?) -> [String: Any] {
        var body: [String: Any] = [:]
        switch self {
        case .deploy(_, _, let serverID, let force):
            if let serverID { body["server_id"] = serverID }
            if force { body["force_rebuild"] = true }
        case .prune(_, _, let options):
            body = options.body
        default:
            break
        }
        if let confirm { body["confirm"] = confirm }
        return body
    }
}

/// Proof that the user confirmed one action. Made by the confirmation dialog only.
public struct ServerPlanConfirmation: Sendable, Equatable {
    public let action: ServerPlanAction
    public let target: String

    /// `name` is what the user confirmed: the action's target, or the name the server asked for
    /// in its 428 (`expected`). Anything else isn't a confirmation.
    public init?(_ action: ServerPlanAction, name: String? = nil, expected: String? = nil) {
        let name = name ?? expected ?? action.confirmTarget
        guard !name.isEmpty, name == (expected ?? action.confirmTarget) else { return nil }
        self.action = action
        self.target = name
    }
}

public enum ServerPlanActionResult: Sendable, Equatable {
    case deployStarted(ServerPlanDeployStarted)
    case done
    /// Done, with what the panel said (`{"reclaimed_bytes"}` of a prune, `{"updated"}` of a pull, …).
    case answer([String: String])
}

/// What the server says a destructive action would do (its 428 answer to an unconfirmed request).
public struct ServerPlanActionPreview: Sendable, Equatable {
    public var summary: String?
    /// The exact name to confirm with.
    public var expected: String?

    public init(summary: String?, expected: String?) {
        self.summary = summary
        self.expected = expected
    }
}

/// The ServerPlan agent API (`/api/v1/agent/…`). Stateless and Sendable: ClaudeDeck's controller
/// uses it on the Mac, and `claudedeck server …` can use it as is.
public struct ServerPlanClient: Sendable {
    public let config: ServerPlanConfig
    public let transport: ServerPlanTransport

    public init(config: ServerPlanConfig, transport: ServerPlanTransport = URLSessionServerPlanTransport()) {
        self.config = config
        self.transport = transport
    }

    public static let decoder = JSONDecoder()

    // MARK: Requests

    /// The URL of an API path (`/servers` → `<base>/api/v1/agent/servers`).
    public func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let full = path.hasPrefix(ServerPlanContract.basePath) ? path : ServerPlanContract.basePath + path
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { throw ServerPlanError.badURL }
        // The panel's address, whatever was pasted: "…:5050/api" or a page URL would put the agent API under the
        // panel's session-auth routes (401 "Oturum acmaniz gerekli"), so anything from "/api" on is dropped.
        var prefix = components.percentEncodedPath
        if let api = prefix.range(of: "/api") { prefix = String(prefix[..<api.lowerBound]) }
        if prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + full
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ServerPlanError.badURL }
        return url
    }

    /// A request with the bearer token.
    public func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil,
                        accept: String = "application/json", timeout: TimeInterval = 20) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.data(for: request)
        } catch let error as ServerPlanError {
            throw error
        } catch {
            throw ServerPlanError.transport(error.localizedDescription)
        }
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { out, pair in
                if let key = pair.key as? String { out[key] = "\(pair.value)" }
            }
            throw ServerPlanError.from(status: response.statusCode, body: data, headers: headers)
        }
        return (data, response)
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send(try request(path, query: query))
        return try Self.decode(type, from: data)
    }

    /// Decodes `T`; a list wrapped in a one-key object (`{"servers":[…]}`) is read too, though v1
    /// sends bare arrays.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.count == 1,
               let inner = object.values.first, JSONSerialization.isValidJSONObject(inner) || inner is [Any],
               let innerData = try? JSONSerialization.data(withJSONObject: inner),
               let value = try? decoder.decode(T.self, from: innerData) {
                return value
            }
            throw ServerPlanError.decoding(String(describing: error))
        }
    }

    // MARK: Reads

    public func me() async throws -> ServerPlanMe { try await get(ServerPlanMe.self, "/me") }
    /// Servers with the panel's cached reachability.
    public func servers() async throws -> [ServerPlanServer] { try await get([ServerPlanServer].self, "/servers") }
    /// Live CPU, memory, disk, uptime (the panel runs SSH commands: call only while it's on screen).
    public func health(serverID: Int) async throws -> ServerPlanHealth { try await get(ServerPlanHealth.self, "/servers/\(serverID)/health") }
    /// Whether `claude` runs on the server (cached 10 min by the panel; `refresh` forces a check).
    public func capabilities(serverID: Int, refresh: Bool = false) async throws -> ServerPlanCapabilities {
        try await get(ServerPlanCapabilities.self, "/servers/\(serverID)/capabilities", query: refresh ? [URLQueryItem(name: "refresh", value: "1")] : [])
    }
    public func projects() async throws -> [ServerPlanProject] { try await get([ServerPlanProject].self, "/projects") }
    public func containers(serverID: Int) async throws -> [ServerPlanContainer] {
        try await get([ServerPlanContainer].self, "/servers/\(serverID)/containers")
    }
    /// Newest first, without logs (limit up to 100).
    public func deployments(projectID: Int? = nil, limit: Int = 20) async throws -> [ServerPlanDeployment] {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let projectID { query.append(URLQueryItem(name: "project_id", value: String(projectID))) }
        return try await get([ServerPlanDeployment].self, "/deployments", query: query)
    }
    /// One deployment with its log.
    public func deployment(id: Int) async throws -> ServerPlanDeployment { try await get(ServerPlanDeployment.self, "/deployments/\(id)") }

    static func logsPath(serverID: Int, container: String) -> String {
        "/servers/\(serverID)/containers/\(pathComponent(container))/logs"
    }

    /// Docker container names the panel accepts (anything else is a 400 there): checked before a
    /// container URL is built.
    public static func isValidContainerName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}/) != nil
    }

    static func checkContainer(_ name: String) throws {
        guard isValidContainerName(name) else {
            throw ServerPlanError.http(status: 400, code: "bad_request", message: String(localized: "Not a valid container name: \(name)"))
        }
    }

    /// The last `tail` lines of a container's log (text/plain).
    public func containerLogs(serverID: Int, container: String, tail: Int = 200) async throws -> String {
        try Self.checkContainer(container)
        let request = try request(Self.logsPath(serverID: serverID, container: container),
                                  query: [URLQueryItem(name: "tail", value: String(tail))], accept: "text/plain")
        let (data, _) = try await send(request)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Destructive actions

    /// Asks what a destructive action would do, without doing it: the request carries no
    /// `confirm`, so the server checks auth and permission and answers 428 with a summary.
    public func preview(_ action: ServerPlanAction) async throws -> ServerPlanActionPreview {
        if let name = action.containerName { try Self.checkContainer(name) }
        do {
            _ = try await send(try request(action.path, method: action.method, json: action.body(confirm: nil)))
        } catch ServerPlanError.confirmRequired(let summary, let expected) {
            return ServerPlanActionPreview(summary: summary, expected: expected)
        }
        // A server that acted without a confirmation breaks the contract; say so instead of pretending.
        throw ServerPlanError.http(status: 200, code: "confirm_ignored", message: String(localized: "ServerPlan didn't ask for a confirmation."))
    }

    /// Sends a confirmed destructive action. The only way to send `confirm`: a
    /// `ServerPlanConfirmation`, which the confirmation dialog makes.
    public func perform(_ confirmation: ServerPlanConfirmation) async throws -> ServerPlanActionResult {
        let action = confirmation.action
        if let name = action.containerName { try Self.checkContainer(name) }
        // Recreating, pulling and pruning run docker on the server: give them time.
        let timeout: TimeInterval = switch action {
        case .containerOp, .prune: 180
        default: 20
        }
        let (data, _) = try await send(try request(action.path, method: action.method, json: action.body(confirm: confirmation.target), timeout: timeout))
        switch action {
        case .deploy: return .deployStarted(try Self.decode(ServerPlanDeployStarted.self, from: data))
        case .containerOp, .prune, .envDelete:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            var answer: [String: String] = [:]
            for (key, value) in object where key != "success" {
                switch value {
                case let text as String: answer[key] = text
                case let number as NSNumber:
                    answer[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                default: break
                }
            }
            return answer.isEmpty ? .done : .answer(answer)
        case .container: return .done
        }
    }

    // MARK: Terminal

    /// A single-use, 60 s ticket for a terminal on `serverID`; `claude` only where its capabilities say so.
    /// `container` (with `.exec`, 1.5 `container_exec`): a shell inside that container.
    public func terminalTicket(serverID: Int, cols: Int, rows: Int, command: ServerPlanTerminalCommand = .shell,
                               container: String? = nil) async throws -> ServerPlanTicket {
        var body: [String: Any] = ["server_id": serverID, "cols": cols, "rows": rows, "command": command.rawValue]
        if command == .exec {
            guard let container else { throw ServerPlanError.http(status: 400, code: "bad_request", message: "exec needs a container") }
            try Self.checkContainer(container)
            body["container"] = container
        }
        let (data, _) = try await send(try request(ServerPlanContract.ticketPath, method: "POST", json: body))
        return try Self.decode(ServerPlanTicket.self, from: data)
    }

    /// The ticket's WebSocket URL on this panel (`ws(s)://host/api/v1/agent/ws/terminal?ticket=…`).
    public func webSocketURL(for ticket: ServerPlanTicket) throws -> URL {
        let given = ticket.url
        var components: URLComponents
        if given.contains("://"), let absolute = URLComponents(string: given) {
            components = absolute
        } else {
            guard var base = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
                  let relative = URLComponents(string: given.hasPrefix("/") ? given : "/" + given) else { throw ServerPlanError.badURL }
            let prefix = base.percentEncodedPath.hasSuffix("/") ? String(base.percentEncodedPath.dropLast()) : base.percentEncodedPath
            base.percentEncodedPath = prefix + relative.percentEncodedPath
            base.percentEncodedQuery = relative.percentEncodedQuery
            components = base
        }
        components.scheme = components.scheme == "https" || components.scheme == "wss" ? "wss" : "ws"
        if !(components.queryItems ?? []).contains(where: { $0.name == "ticket" }) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ticket", value: ticket.ticket)]
        }
        guard let url = components.url else { throw ServerPlanError.badURL }
        return url
    }

    /// Ticket + URL for a terminal on `serverID`.
    public func terminalURL(serverID: Int, cols: Int = 120, rows: Int = 40, command: ServerPlanTerminalCommand = .shell,
                            container: String? = nil) async throws -> URL {
        try webSocketURL(for: try await terminalTicket(serverID: serverID, cols: cols, rows: rows, command: command, container: container))
    }

    // MARK: Server-Sent Events

    /// Opens an SSE stream; events arrive until the server closes it or the task is cancelled.
    public func events(_ path: String, query: [URLQueryItem] = [], lastEventID: String? = nil) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        var request = try request(path, query: query, accept: "text/event-stream")
        request.timeoutInterval = 24 * 3600
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let (response, chunks): (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
        do {
            (response, chunks) = try await transport.lines(for: request)
        } catch {
            throw ServerPlanError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            do {
                for try await chunk in chunks {
                    body.append(chunk)
                    if body.count > 4096 { break }
                }
            } catch {}
            throw ServerPlanError.from(status: response.statusCode, body: body)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ServerSentEventParser()
                do {
                    for try await chunk in chunks {
                        for event in parser.feed(chunk) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `/deployments/:id/stream`: the log so far, then live status and lines, then `done`.
    public func deployStream(id: Int) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        try await events("/deployments/\(id)/stream")
    }

    /// Follows a container's log (`event: log`), starting with the last `tail` lines.
    /// `since` only for a panel with `log_query` (the caller checks).
    public func containerLogStream(serverID: Int, container: String, tail: Int = 100, since: String? = nil) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        try Self.checkContainer(container)
        var query = [URLQueryItem(name: "tail", value: String(tail))]
        if let since, !since.isEmpty { query.append(URLQueryItem(name: "since", value: since)) }
        return try await events(Self.logsPath(serverID: serverID, container: container) + "/stream", query: query)
    }

    /// `/events`, resuming after `lastEventID`.
    public func eventStream(lastEventID: String?) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        try await events("/events", lastEventID: lastEventID)
    }

    static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? text
    }
}

// MARK: - Server-Sent Events parsing

public struct ServerSentEvent: Sendable, Equatable {
    /// `event:` (default "message").
    public var event: String
    public var data: String
    public var id: String?
    public var retry: Int?

    public init(event: String = "message", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// The text/event-stream format, fed in chunks of any size (a line may span chunks).
/// Comments (`:` keepalives) are skipped; a blank line ends an event; an event with no data
/// lines is dropped. `lastEventID` keeps the latest `id:` (for `Last-Event-ID`).
public struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?
    public private(set) var lastEventID: String?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [ServerSentEvent] {
        buffer.append(chunk)
        var events: [ServerSentEvent] = []
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            var lineEnd = newline
            var next = buffer.index(after: newline)
            if buffer[newline] == 0x0D {
                // CR LF counts once; a CR at the very end waits for the next chunk.
                if next == buffer.endIndex { break }
                if buffer[next] == 0x0A { next = buffer.index(after: next) }
            }
            if lineEnd > buffer.startIndex, buffer[buffer.index(before: lineEnd)] == 0x0D { lineEnd = buffer.index(before: lineEnd) }
            let line = String(decoding: buffer[buffer.startIndex..<lineEnd], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<next)
            if let event = handle(line) { events.append(event) }
        }
        return events
    }

    /// At the end of the stream: a last event without its blank line still counts.
    public mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = handle(line) { events.append(event) }
        }
        if let event = handle("") { events.append(event) }
        return events
    }

    private mutating func handle(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { event = nil; dataLines = []; retry = nil }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(event: event ?? "message", data: dataLines.joined(separator: "\n"), id: id ?? lastEventID, retry: retry)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        case "id":
            if !value.contains("\0") {
                id = String(value)
                lastEventID = String(value)
            }
        case "retry": retry = Int(value)
        default: break
        }
        return nil
    }
}
