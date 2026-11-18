import Foundation

/// Wire protocol between ClaudeDeck and `claudedeck-ptyd`, the helper that owns the session ptys
/// when "Keep sessions running when ClaudeDeck quits" is on (Settings › Sessions).
///
/// A frame is `[u32 header length][u32 payload length][header JSON][payload bytes]`, big endian.
/// The header is a `PtydMessage`; the payload carries raw terminal bytes (input, output, replay).
///
/// Frozen forever (any helper and any app understand them, whatever their versions): the frame
/// layout, `hello`/`welcome`, `list`/`sessions`, `attach`/`attached`, `detach`, `output`, `exited`
/// and `error`. That subset lets an app read sessions held by an incompatible helper (read-only)
/// and tell which ones are still alive, so it never starts them a second time.
public enum PtydProtocol {
    /// This build's protocol version. Bump it when a message changes meaning; add the old
    /// behaviour behind `dialect` checks while older peers are still supported.
    public static let version = 1
    /// Oldest helper this app can drive fully (spawn, write, resize, signal).
    public static let oldestCompatibleHelper = 1
    /// Oldest app this helper accepts as a full client; older apps get read-only access.
    public static let oldestCompatibleClient = 1

    public static let maxHeaderBytes = 1 << 20
    public static let maxPayloadBytes = 16 << 20
    /// Scrollback the helper keeps per pty and replays on attach.
    public static let defaultRingBytes = 4 << 20
}

public enum PtydOp: String, Codable, Sendable {
    // Frozen.
    case hello, welcome, list, sessions, attach, attached, detach, output, exited, error
    // Version 1.
    case spawn, spawned, write, resize, signal, forget, drain, shutdown, ok
}

/// One pty session as the helper reports it.
public struct PtydSessionInfo: Codable, Sendable, Equatable {
    public var id: String
    public var pid: Int32
    /// When the child was started (seconds since 1970).
    public var startedAt: Double
    public var cols: Int
    public var rows: Int
    public var alive: Bool
    /// Exit code if the child exited normally, else nil.
    public var exitCode: Int32?
    /// Signal that ended the child, if any.
    public var exitSignal: Int32?
    /// Whatever the app attached at spawn (opaque to the helper).
    public var meta: [String: String]

    public init(id: String, pid: Int32, startedAt: Double, cols: Int, rows: Int, alive: Bool,
                exitCode: Int32? = nil, exitSignal: Int32? = nil, meta: [String: String] = [:]) {
        self.id = id
        self.pid = pid
        self.startedAt = startedAt
        self.cols = cols
        self.rows = rows
        self.alive = alive
        self.exitCode = exitCode
        self.exitSignal = exitSignal
        self.meta = meta
    }
}

/// What to run: exactly what the app would hand to its own pty (executable, argv with argv[0],
/// the full environment, working directory, grid).
public struct PtydSpawn: Codable, Sendable, Equatable {
    public var id: String
    public var executable: String
    /// Full argv, argv[0] included (e.g. "-zsh").
    public var argv: [String]
    /// "KEY=value" entries, the complete environment of the child.
    public var env: [String]
    public var cwd: String
    public var cols: Int
    public var rows: Int
    public var meta: [String: String]

    public init(id: String, executable: String, argv: [String], env: [String], cwd: String,
                cols: Int, rows: Int, meta: [String: String] = [:]) {
        self.id = id
        self.executable = executable
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.meta = meta
    }
}

/// A frame header. Fields are optional; which ones are set depends on `op`.
public struct PtydMessage: Codable, Sendable, Equatable {
    public var op: PtydOp
    /// Request number; a reply carries the request's.
    public var seq: Int?
    public var session: String?

    // hello / welcome
    public var protocolVersion: Int?
    /// hello: oldest helper the app supports; welcome: oldest app the helper supports.
    public var oldestCompatible: Int?
    public var build: String?
    /// welcome: a fresh id per helper process (tells a relaunched helper from the old one).
    public var instance: String?
    public var pid: Int32?
    /// welcome: whether this connection may change sessions (false = read-only).
    public var full: Bool?

    public var sessions: [PtydSessionInfo]?
    public var info: PtydSessionInfo?
    public var spawn: PtydSpawn?
    public var cols: Int?
    public var rows: Int?
    public var signal: Int32?
    /// signal: SIGKILL after this many seconds if the child is still alive.
    public var killAfter: Double?
    public var error: String?

    public init(op: PtydOp, seq: Int? = nil, session: String? = nil) {
        self.op = op
        self.seq = seq
        self.session = session
    }
}

/// Error codes in `PtydMessage.error`.
public enum PtydErrorCode {
    public static let exists = "exists"
    public static let unknownSession = "unknown_session"
    public static let readOnly = "read_only"
    public static let badRequest = "bad_request"
    public static let spawnFailed = "spawn_failed"
    public static let notAlive = "not_alive"
}

public struct PtydFrame: Sendable, Equatable {
    public var message: PtydMessage
    public var payload: [UInt8]

    public init(_ message: PtydMessage, payload: [UInt8] = []) {
        self.message = message
        self.payload = payload
    }

    public func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(message)
        guard header.count <= PtydProtocol.maxHeaderBytes, payload.count <= PtydProtocol.maxPayloadBytes else {
            throw PtydFrameError.tooLarge
        }
        var out: [UInt8] = []
        out.reserveCapacity(8 + header.count + payload.count)
        Self.appendU32(UInt32(header.count), to: &out)
        Self.appendU32(UInt32(payload.count), to: &out)
        out.append(contentsOf: header)
        out.append(contentsOf: payload)
        return out
    }

    static func appendU32(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }
}

public enum PtydFrameError: Error, Equatable {
    case tooLarge
    case badHeader
}

/// Splits a byte stream into frames; feed it whatever `read` returned.
public struct PtydFrameReader: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, nil if more bytes are needed. Throws on a malformed stream
    /// (the connection should then be dropped).
    public mutating func next() throws -> PtydFrame? {
        let available = buffer.count - start
        guard available >= 8 else { compact(); return nil }
        let headerLength = Int(readU32(at: start))
        let payloadLength = Int(readU32(at: start + 4))
        guard headerLength <= PtydProtocol.maxHeaderBytes, payloadLength <= PtydProtocol.maxPayloadBytes else {
            throw PtydFrameError.tooLarge
        }
        guard available >= 8 + headerLength + payloadLength else { compact(); return nil }
        let headerStart = start + 8
        let header = Data(buffer[headerStart..<(headerStart + headerLength)])
        let payloadStart = headerStart + headerLength
        let payload = Array(buffer[payloadStart..<(payloadStart + payloadLength)])
        start = payloadStart + payloadLength
        guard let message = try? JSONDecoder().decode(PtydMessage.self, from: header) else {
            throw PtydFrameError.badHeader
        }
        return PtydFrame(message, payload: payload)
    }

    /// Bytes received but not yet part of a returned frame.
    public var pendingBytes: Int { buffer.count - start }

    private mutating func compact() {
        guard start > 0 else { return }
        if start >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if start > 64 * 1024 || start > buffer.count / 2 {
            buffer.removeSubrange(0..<start)
        } else {
            return
        }
        start = 0
    }

    private func readU32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16 | UInt32(buffer[index + 2]) << 8 | UInt32(buffer[index + 3])
    }
}

/// Outcome of the version handshake.
public enum PtydCompatibility: Sendable, Equatable {
    /// Every operation, in the older side's dialect.
    case full(dialect: Int)
    /// Only the frozen subset: list sessions, watch them (no input, no spawning).
    case readOnly
}

public enum PtydVersion {
    /// Both sides run this with the same numbers and reach the same answer.
    /// - Parameters:
    ///   - client: the app's protocol version and the oldest helper it can drive.
    ///   - helper: the helper's protocol version and the oldest app it accepts.
    public static func negotiate(client: (version: Int, oldestHelper: Int),
                                 helper: (version: Int, oldestClient: Int)) -> PtydCompatibility {
        guard helper.version >= client.oldestHelper, client.version >= helper.oldestClient else { return .readOnly }
        return .full(dialect: min(client.version, helper.version))
    }
}

/// Fixed-size scrollback: keeps the newest `capacity` bytes of a pty's output.
public struct PtydRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [UInt8]
    private var head = 0     // index of the oldest byte
    public private(set) var count = 0
    /// Every byte ever appended (not only those still kept).
    public private(set) var totalWritten: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = []
    }

    public mutating func append(_ bytes: some Collection<UInt8>) {
        totalWritten += UInt64(bytes.count)
        var slice = ArraySlice(bytes)
        // Only the newest `capacity` bytes can survive.
        if slice.count > capacity { slice = slice.suffix(capacity) }
        if storage.count < capacity {
            // Still growing: no wraparound until the storage is full.
            let room = capacity - storage.count
            let direct = slice.prefix(room)
            storage.append(contentsOf: direct)
            count = storage.count
            slice = slice.dropFirst(direct.count)
            if slice.isEmpty { return }
        }
        // Full: overwrite the oldest bytes, in at most two runs (up to the end, then from 0).
        while !slice.isEmpty {
            let run = min(slice.count, capacity - head)
            storage.replaceSubrange(head..<(head + run), with: slice.prefix(run))
            slice = slice.dropFirst(run)
            head = (head + run) % capacity
        }
        count = capacity
    }

    /// The kept bytes, oldest first.
    public func snapshot() -> [UInt8] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }
}
