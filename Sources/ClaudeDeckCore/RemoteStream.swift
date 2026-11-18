import Foundation
import Network

// The byte stream under a RemoteChannel: the system's TCP (NWConnection, everywhere), or a
// connected socket from somewhere else (the iPhone/iPad app's in-app Tailscale node).

/// What happens to a stream, on the channel's queue.
enum RemoteStreamEvent {
    case ready
    /// Failed or gave up (unreachable); the reason is shown.
    case failed(String)
    case cancelled
}

/// A two-way byte stream a RemoteChannel frames messages over.
protocol RemoteByteStream: AnyObject {
    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteStreamEvent) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// One read of up to 64 KB; `isComplete` at the end of the stream.
    func receive(completion: @escaping @Sendable (_ data: Data?, _ isComplete: Bool, _ error: Error?) -> Void)
    /// Stops: no more events or callbacks.
    func cancel()
    /// The peer's address (incoming connections).
    var remoteEndpoint: NWEndpoint? { get }
    /// This side's address and the interface the connection uses (incoming connections; nil
    /// when unknown).
    var localEndpoint: NWEndpoint? { get }
    var interfaceName: String? { get }
}

/// The system's network: an NWConnection, used exactly as before the abstraction.
final class NWConnectionStream: RemoteByteStream, @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteStreamEvent) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: onEvent(.ready)
            case .failed(let error): onEvent(.failed(error.localizedDescription))
            // A client connection waits (retries) when the host is unreachable; give up instead:
            // the caller tries the next address or reconnects later.
            case .waiting(let error): onEvent(.failed(error.localizedDescription))
            case .cancelled: onEvent(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func receive(completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    var remoteEndpoint: NWEndpoint? { connection.endpoint }
    // An accepted connection has its path before it starts.
    var localEndpoint: NWEndpoint? { connection.currentPath?.localEndpoint }
    var interfaceName: String? { connection.currentPath?.availableInterfaces.first?.name }
}

/// Opens connections some other way than the system's network: the iPhone/iPad app's in-app
/// Tailscale node (userspace; it works next to any VPN). The Mac never sets one.
public protocol RemoteDialer: AnyObject, Sendable {
    /// Connects to `host` (an IP or a MagicDNS name) on `port`. `completion` gets a connected
    /// stream socket (the caller owns and closes it) or why it couldn't; it may run on any queue.
    func dial(host: String, port: UInt16, completion: @escaping @Sendable (Result<Int32, Error>) -> Void)
}

/// A connected socket from a RemoteDialer, read and written with DispatchIO.
final class DialedStream: RemoteByteStream, @unchecked Sendable {
    private let dialer: RemoteDialer
    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private var queue: DispatchQueue?
    private var onEvent: (@Sendable (RemoteStreamEvent) -> Void)?
    private var io: DispatchIO?
    /// The channel's receive, waiting for bytes.
    private var pendingReceive: (@Sendable (Data?, Bool, Error?) -> Void)?
    private var buffer = Data()
    private var ended = false
    private var readError: Error?
    private var cancelled = false

    struct DialError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(dialer: RemoteDialer, host: String, port: UInt16, timeout: TimeInterval) {
        self.dialer = dialer
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteStreamEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.cancelled, self.io == nil else { return }
            self.fail(String(localized: "Couldn't reach the Mac"))
        }
        dialer.dial(host: host, port: port) { [weak self] result in
            queue.async { [weak self] in
                guard let self,!self.cancelled, self.io == nil, self.onEvent != nil else {
                    // Too late (cancelled or timed out): the socket isn't wanted.
                    if case .success(let fd) = result { Darwin.close(fd) }
                    return
                }
                switch result {
                case .success(let fd):
                    self.connected(fd, queue: queue)
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func connected(_ fd: Int32, queue: DispatchQueue) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
        io.setLimit(lowWater: 1)
        self.io = io
        startReading(io, queue: queue)
        onEvent?(.ready)
    }

    private func fail(_ reason: String) {
        let handler = onEvent
        onEvent = nil
        handler?(.failed(reason))
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard let io, let queue, !cancelled else { completion(DialError(message: String(localized: "Connection closed"))); return }
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { done, _, error in
            guard done else { return }
            completion(error == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        }
    }

    func receive(completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        guard !cancelled else { return }
        pendingReceive = completion
        deliver()
    }

    /// Hands what has arrived to the waiting receive (one read runs for the stream's lifetime).
    private func deliver() {
        guard let pending = pendingReceive else { return }
        if !buffer.isEmpty {
            let bytes = buffer
            buffer = Data()
            pendingReceive = nil
            pending(bytes, false, nil)
        } else if let readError {
            pendingReceive = nil
            pending(nil, false, readError)
        } else if ended {
            pendingReceive = nil
            pending(nil, true, nil)
        }
    }

    private func startReading(_ io: DispatchIO, queue: DispatchQueue) {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, chunk, error in
            guard let self, !self.cancelled else { return }
            if let chunk, !chunk.isEmpty { self.buffer.append(contentsOf: chunk) }
            if error != 0 && error != ECANCELED {
                self.readError = POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            } else if done {
                self.ended = true
            }
            self.deliver()
        }
    }

    func cancel() {
        cancelled = true
        onEvent = nil
        pendingReceive = nil
        io?.close(flags: .stop)
        io = nil
    }

    var remoteEndpoint: NWEndpoint? { nil }
    var localEndpoint: NWEndpoint? { nil }
    var interfaceName: String? { nil }
}
