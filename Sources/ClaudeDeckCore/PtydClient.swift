import Darwin
import Foundation

/// The helper's handshake answer.
public struct PtydWelcome: Sendable, Equatable {
    public var protocolVersion: Int
    public var oldestCompatibleClient: Int
    public var build: String
    public var instance: String
    public var pid: Int32
    public var compatibility: PtydCompatibility
}

public enum PtydClientError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case handshake(String)
    case disconnected
    case timeout
    case refused(String, PtydSessionInfo?)

    public var description: String {
        switch self {
        case .unreachable(let why): "helper unreachable: \(why)"
        case .handshake(let why): "handshake failed: \(why)"
        case .disconnected: "helper disconnected"
        case .timeout: "helper didn't answer"
        case .refused(let code, _): "helper refused: \(code)"
        }
    }
}

/// The app's connection to `claudedeck-ptyd`. Connecting blocks (call it off the main thread);
/// after that everything is asynchronous. Replies and events arrive on `callbackQueue`, in the
/// order the helper sent them (an attach's replay always comes before that session's live output).
public final class PtydClient: @unchecked Sendable {
    public let welcome: PtydWelcome
    public var compatibility: PtydCompatibility { welcome.compatibility }
    public var isFull: Bool { welcome.compatibility != .readOnly }

    /// Live output of an attached session.
    public var onOutput: (@Sendable (String, [UInt8]) -> Void)?
    /// A session ended (sent for every session, attached or not).
    public var onExit: (@Sendable (PtydSessionInfo) -> Void)?
    /// The connection is gone (helper quit or crashed). Called once.
    public var onDisconnect: (@Sendable () -> Void)?

    private let fd: Int32
    // Above the default QoS: on a loaded Mac the helper drops a client that falls 64 MB behind.
    private let queue = DispatchQueue(label: "claudedeck.ptyd.client", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    private var reader = PtydFrameReader()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var outbox: [[UInt8]] = []
    private var outboxOffset = 0
    private var pending: [Int: @Sendable (Result<PtydFrame, PtydClientError>) -> Void] = [:]
    private var nextSeq = 1
    private var closed = false

    private init(fd: Int32, welcome: PtydWelcome, callbackQueue: DispatchQueue) {
        self.fd = fd
        self.welcome = welcome
        self.callbackQueue = callbackQueue
    }

    /// Connects and shakes hands. Blocks up to `timeout`.
    public static func connect(socket: URL, build: String, timeout: TimeInterval = 3,
                               callbackQueue: DispatchQueue = .main) throws -> PtydClient {
        let fd: Int32
        do {
            fd = try PtydSocket.connect(to: socket.path)
        } catch {
            throw PtydClientError.unreachable("\(error)")
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard PtydSocket.peerUID(fd) == getuid() else {
            Darwin.close(fd)
            throw PtydClientError.handshake("helper runs as another user")
        }
        var hello = PtydMessage(op: .hello, seq: 0)
        hello.protocolVersion = PtydProtocol.version
        hello.oldestCompatible = PtydProtocol.oldestCompatibleHelper
        hello.build = build
        guard let bytes = try? PtydFrame(hello).encoded(), PtydSocket.writeAll(fd, bytes) else {
            Darwin.close(fd)
            throw PtydClientError.handshake("couldn't send hello")
        }
        var reader = PtydFrameReader()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        var frame: PtydFrame?
        while frame == nil {
            guard Date() < deadline else { Darwin.close(fd); throw PtydClientError.timeout }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                reader.append(buffer[0..<n])
                frame = try? reader.next()
                continue
            }
            if n < 0, errno == EINTR { continue }
            Darwin.close(fd)
            throw n < 0 && errno == EAGAIN ? PtydClientError.timeout : PtydClientError.handshake("closed")
        }
        guard let message = frame?.message, message.op == .welcome,
              let version = message.protocolVersion, let instance = message.instance else {
            Darwin.close(fd)
            throw PtydClientError.handshake("unexpected answer")
        }
        let oldest = message.oldestCompatible ?? version
        let welcome = PtydWelcome(
            protocolVersion: version, oldestCompatibleClient: oldest, build: message.build ?? "?",
            instance: instance, pid: message.pid ?? 0,
            compatibility: PtydVersion.negotiate(client: (PtydProtocol.version, PtydProtocol.oldestCompatibleHelper),
                                                 helper: (version, oldest))
        )
        var none = timeval()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        PtydSocket.setNonBlocking(fd)
        let client = PtydClient(fd: fd, welcome: welcome, callbackQueue: callbackQueue)
        client.queue.sync {
            client.reader = reader
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: client.queue)
            source.setEventHandler { [weak client] in client?.readAvailable() }
            source.setCancelHandler { Darwin.close(fd) }
            source.activate()
            client.readSource = source
            // Frames that came in right behind the welcome.
            client.dispatchFrames()
        }
        return client
    }

    deinit {
        readSource?.cancel()
    }

    // MARK: Requests

    /// Sends a request; `completion` gets the reply (an `error` reply becomes `.refused`).
    public func request(_ message: PtydMessage, payload: [UInt8] = [],
                        completion: @escaping @Sendable (Result<PtydFrame, PtydClientError>) -> Void) {
        queue.async {
            guard !self.closed else {
                self.callbackQueue.async { completion(.failure(.disconnected)) }
                return
            }
            var message = message
            message.seq = self.nextSeq
            self.nextSeq += 1
            self.pending[message.seq!] = completion
            self.enqueue(message, payload: payload)
        }
    }

    /// Sends without waiting for an answer (input, resize).
    public func post(_ message: PtydMessage, payload: [UInt8] = []) {
        queue.async {
            guard !self.closed else { return }
            self.enqueue(message, payload: payload)
        }
    }

    public func list(_ completion: @escaping @Sendable (Result<[PtydSessionInfo], PtydClientError>) -> Void) {
        request(PtydMessage(op: .list)) { result in completion(result.map { $0.message.sessions ?? [] }) }
    }

    /// Starts a session and attaches to it. `.refused("exists", info)` if it already runs.
    public func spawn(_ spawn: PtydSpawn, _ completion: @escaping @Sendable (Result<PtydSessionInfo, PtydClientError>) -> Void) {
        var message = PtydMessage(op: .spawn, session: spawn.id)
        message.spawn = spawn
        request(message) { result in
            completion(result.flatMap { frame in
                frame.message.info.map { .success($0) } ?? .failure(.refused(PtydErrorCode.badRequest, nil))
            })
        }
    }

    /// Attaches: the reply carries the scrollback; live output follows through `onOutput`.
    public func attach(_ id: String, _ completion: @escaping @Sendable (Result<(PtydSessionInfo, [UInt8]), PtydClientError>) -> Void) {
        request(PtydMessage(op: .attach, session: id)) { result in
            completion(result.flatMap { frame in
                frame.message.info.map { .success(($0, frame.payload)) } ?? .failure(.refused(PtydErrorCode.badRequest, nil))
            })
        }
    }

    public func detach(_ id: String) { post(PtydMessage(op: .detach, session: id)) }

    public func write(_ id: String, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        activityLock.withLock { lastInput = Date() }
        post(PtydMessage(op: .write, session: id), payload: bytes)
    }

    /// When input was last sent to any session over this connection (nil: never).
    public var lastInputAt: Date? { activityLock.withLock { lastInput } }
    private let activityLock = NSLock()
    private var lastInput: Date?

    public func resize(_ id: String, cols: Int, rows: Int) {
        var message = PtydMessage(op: .resize, session: id)
        message.cols = cols
        message.rows = rows
        post(message)
    }

    public func signal(_ id: String, _ signal: Int32, killAfter: Double? = nil) {
        var message = PtydMessage(op: .signal, session: id)
        message.signal = signal
        message.killAfter = killAfter
        post(message)
    }

    /// Drops an ended session from the helper's list.
    public func forget(_ id: String) { post(PtydMessage(op: .forget, session: id)) }

    /// The helper exits once its last session has ended.
    public func drain(_ completion: (@Sendable (Result<PtydFrame, PtydClientError>) -> Void)? = nil) {
        request(PtydMessage(op: .drain)) { completion?($0) }
    }

    /// The helper ends every session and exits.
    public func shutdown(_ completion: (@Sendable (Result<PtydFrame, PtydClientError>) -> Void)? = nil) {
        request(PtydMessage(op: .shutdown)) { completion?($0) }
    }

    /// The helper answers `probeAccess` (protocol 2 and later).
    public var supportsAccessProbe: Bool { welcome.protocolVersion >= PtydProtocol.accessProbeVersion }

    /// What privacy (TCC) lets the helper open. `.unknown` without asking from a helper older
    /// than protocol 2 (it would drop the connection over an op it doesn't know), and on an
    /// error, a lost connection or no answer within `timeout`.
    public func probeAccess(timeout: TimeInterval = 3, _ completion: @escaping @Sendable (PtydAccessReport) -> Void) {
        guard supportsAccessProbe else {
            callbackQueue.async { completion(.unknown) }
            return
        }
        let once = PtydOnce()
        request(PtydMessage(op: .probeAccess)) { result in
            let report = (try? result.get())?.message.access ?? .unknown
            if once.claim() { completion(report) }
        }
        callbackQueue.asyncAfter(deadline: .now() + timeout) {
            if once.claim() { completion(.unknown) }
        }
    }

    /// The helper can replace its own code without ending its sessions (protocol 3 and later).
    public var supportsUpgrade: Bool { welcome.protocolVersion >= PtydProtocol.upgradeVersion && isFull }

    /// Asks the helper to exec into the binary now at its path (an update replaced it). `.ok`
    /// (with the new build) means it is about to: the connection drops in a moment and the same
    /// helper, same pid and instance, answers again with every session. `.refused("not_newer")`
    /// or `("invalid_candidate")`: it keeps running as it is. Never sent to an older helper.
    public func upgrade(_ completion: @escaping @Sendable (Result<PtydFrame, PtydClientError>) -> Void) {
        guard supportsUpgrade else {
            callbackQueue.async { completion(.failure(.refused(PtydErrorCode.badRequest, nil))) }
            return
        }
        request(PtydMessage(op: .upgrade), completion: completion)
    }

    /// Closes the connection (the helper keeps every session running).
    public func close() {
        queue.async { self.disconnect(notify: false) }
    }

    // MARK: Plumbing

    private func enqueue(_ message: PtydMessage, payload: [UInt8]) {
        guard let bytes = try? PtydFrame(message, payload: payload).encoded() else { return }
        outbox.append(bytes)
        flush()
    }

    private func flush() {
        while !closed, let first = outbox.first {
            let remaining = first.count - outboxOffset
            let n = first.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + outboxOffset, remaining) }
            if n > 0 {
                outboxOffset += n
                if outboxOffset == first.count {
                    outbox.removeFirst()
                    outboxOffset = 0
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.activate()
                    writeSource = source
                }
                return
            }
            disconnect(notify: true)
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !closed {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                reader.append(buffer[0..<n])
                dispatchFrames()
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            disconnect(notify: true)
            return
        }
    }

    private func dispatchFrames() {
        do {
            while !closed, let frame = try reader.next() { route(frame) }
        } catch {
            disconnect(notify: true)
        }
    }

    private func route(_ frame: PtydFrame) {
        let message = frame.message
        switch message.op {
        case .output:
            guard let id = message.session else { return }
            let bytes = frame.payload
            callbackQueue.async { self.onOutput?(id, bytes) }
        case .exited:
            guard let info = message.info else { return }
            callbackQueue.async { self.onExit?(info) }
        default:
            guard let seq = message.seq, let completion = pending.removeValue(forKey: seq) else { return }
            let result: Result<PtydFrame, PtydClientError> = message.op == .error
                ? .failure(.refused(message.error ?? "error", message.info))
                : .success(frame)
            callbackQueue.async { completion(result) }
        }
    }

    private func disconnect(notify: Bool) {
        guard !closed else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()   // closes the socket
        readSource = nil
        outbox = []
        let waiting = pending.values
        pending = [:]
        callbackQueue.async {
            for completion in waiting { completion(.failure(.disconnected)) }
            if notify { self.onDisconnect?() }
        }
    }
}

extension PtydClient {
    public func list() async throws -> [PtydSessionInfo] {
        try await withCheckedThrowingContinuation { cont in list { cont.resume(with: $0) } }
    }

    /// `list`, or `.timeout` when the helper doesn't answer within `timeout` (a hung or starved
    /// helper must never look like one with no sessions).
    public func list(timeout: TimeInterval) async throws -> [PtydSessionInfo] {
        try await withCheckedThrowingContinuation { cont in
            let once = PtydOnce()
            list { result in if once.claim() { cont.resume(with: result) } }
            callbackQueue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(throwing: PtydClientError.timeout) }
            }
        }
    }

    public func spawn(_ spawn: PtydSpawn) async throws -> PtydSessionInfo {
        try await withCheckedThrowingContinuation { cont in self.spawn(spawn) { cont.resume(with: $0) } }
    }

    public func probeAccess(timeout: TimeInterval = 3) async -> PtydAccessReport {
        await withCheckedContinuation { cont in probeAccess(timeout: timeout) { cont.resume(returning: $0) } }
    }
}

/// True for the first caller only (a reply racing its timeout).
final class PtydOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
