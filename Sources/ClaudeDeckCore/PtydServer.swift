import Darwin
import Foundation

/// The session helper (`claudedeck-ptyd`): owns ptys and their child processes so they outlive
/// the app. Apps attach and detach over a Unix socket (PtydProtocol). Everything runs on one
/// serial queue, driven by dispatch sources (no timers while idle), so an idle helper uses no CPU.
///
/// If the helper dies, the ptys' master sides close and the children get SIGHUP: nothing it ran
/// can outlive it unnoticed (the app then falls back to resuming, see PtydLaunchPlan).
public final class PtydServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var paths: PtydPaths
        public var build: String
        public var ringBytes: Int
        /// Exit after this long with no sessions and no clients (child mode); nil = never.
        public var idleExit: TimeInterval?
        /// The protocol this helper speaks and the oldest app it accepts (tests pretend to be
        /// another version with these).
        public var protocolVersion = PtydProtocol.version
        public var oldestCompatibleClient = PtydProtocol.oldestCompatibleClient

        public init(paths: PtydPaths, build: String, ringBytes: Int = PtydProtocol.defaultRingBytes, idleExit: TimeInterval? = nil) {
            self.paths = paths
            self.build = build
            self.ringBytes = ringBytes
            self.idleExit = idleExit
        }
    }

    public enum StartError: Error {
        /// Another helper holds the lock (it serves this socket already).
        case alreadyRunning
        case failed(String)
    }

    public let options: Options
    public let instance = UUID().uuidString
    private let queue = DispatchQueue(label: "claudedeck.ptyd")
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int: Client] = [:]
    private var nextClientID = 1
    private var sessions: [String: Session] = [:]
    private var draining = false
    private var shuttingDown = false
    private var idleTimer: DispatchSourceTimer?
    private let log: @Sendable (String) -> Void

    public init(options: Options, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.options = options
        self.log = log
    }

    /// Takes the lock and starts listening. Throws `.alreadyRunning` if another helper has it.
    public func start() throws {
        let dir = options.paths.directory.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(options.paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StartError.failed("open lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw StartError.alreadyRunning
        }
        lockFD = fd
        ftruncate(fd, 0)
        let pidText = Array("\(getpid())\n".utf8)
        _ = pidText.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        do {
            listenFD = try PtydSocket.listen(at: options.paths.socket.path)
        } catch {
            throw StartError.failed("\(error)")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.activate()
        acceptSource = source
        queue.async { self.updateIdleTimer() }
        log("listening on \(options.paths.socket.path) (instance \(instance), build \(options.build))")
    }

    /// Exits the process (socket removed first, the lock goes with the process).
    private func exitProcess(_ code: Int32) -> Never {
        log("exiting (\(code))")
        unlink(options.paths.socket.path)
        exit(code)
    }

    // MARK: Clients

    private final class Client: @unchecked Sendable {
        let id: Int
        let fd: Int32
        var reader = PtydFrameReader()
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var outbox: [[UInt8]] = []
        var outboxOffset = 0
        var outboxBytes = 0
        var greeted = false
        var full = false
        var closed = false

        init(id: Int, fd: Int32) {
            self.id = id
            self.fd = fd
        }
    }

    /// A client that stops reading is dropped before its backlog eats the helper's memory;
    /// it reattaches (replaying the scrollback) when it comes back.
    private static let maxOutbox = 64 << 20

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            PtydSocket.setCloseOnExec(fd)
            PtydSocket.setNoSigPipe(fd)
            guard PtydSocket.peerUID(fd) == getuid() else {
                log("refused a connection from another user")
                close(fd)
                continue
            }
            PtydSocket.setNonBlocking(fd)
            let client = Client(id: nextClientID, fd: fd)
            nextClientID += 1
            clients[client.id] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.readClient(client)
            }
            source.activate()
            client.readSource = source
            updateIdleTimer()
        }
    }

    private func readClient(_ client: Client) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !client.closed {
            let n = buffer.withUnsafeMutableBytes { read(client.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                client.reader.append(buffer[0..<n])
                do {
                    while !client.closed, let frame = try client.reader.next() { handle(frame, from: client) }
                } catch {
                    log("client \(client.id): bad frame (\(error))")
                    drop(client)
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            drop(client)
            return
        }
    }

    private func drop(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        client.readSource?.cancel()
        client.writeSource?.cancel()
        client.outbox = []
        close(client.fd)
        clients[client.id] = nil
        for session in sessions.values { session.attached.remove(client.id) }
        updateIdleTimer()
    }

    private func send(_ message: PtydMessage, payload: [UInt8] = [], to client: Client) {
        guard !client.closed, let bytes = try? PtydFrame(message, payload: payload).encoded() else { return }
        client.outbox.append(bytes)
        client.outboxBytes += bytes.count
        if client.outboxBytes > Self.maxOutbox {
            log("client \(client.id) fell behind; dropping it")
            drop(client)
            return
        }
        flush(client)
    }

    private func flush(_ client: Client) {
        while !client.closed, let first = client.outbox.first {
            let remaining = first.count - client.outboxOffset
            let n = first.withUnsafeBytes { write(client.fd, $0.baseAddress! + client.outboxOffset, remaining) }
            if n > 0 {
                client.outboxOffset += n
                client.outboxBytes -= n
                if client.outboxOffset == first.count {
                    client.outbox.removeFirst()
                    client.outboxOffset = 0
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if client.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
                    source.setEventHandler { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.flush(client)
                    }
                    source.activate()
                    client.writeSource = source
                }
                return
            }
            drop(client)
            return
        }
        // Drained: stop watching for writability (it would fire continuously).
        client.writeSource?.cancel()
        client.writeSource = nil
    }

    private func reply(_ request: PtydMessage, _ op: PtydOp, to client: Client, configure: (inout PtydMessage) -> Void = { _ in }) {
        var message = PtydMessage(op: op, seq: request.seq, session: request.session)
        configure(&message)
        send(message, to: client)
    }

    private func fail(_ request: PtydMessage, _ code: String, to client: Client, info: PtydSessionInfo? = nil) {
        reply(request, .error, to: client) {
            $0.error = code
            $0.info = info
        }
    }

    // MARK: Requests

    private func handle(_ frame: PtydFrame, from client: Client) {
        let message = frame.message
        guard client.greeted || message.op == .hello else {
            fail(message, PtydErrorCode.badRequest, to: client)
            drop(client)
            return
        }
        switch message.op {
        case .hello:
            let compatibility = PtydVersion.negotiate(
                client: (message.protocolVersion ?? 0, message.oldestCompatible ?? 0),
                helper: (options.protocolVersion, options.oldestCompatibleClient)
            )
            client.greeted = true
            client.full = compatibility != .readOnly
            reply(message, .welcome, to: client) {
                $0.protocolVersion = options.protocolVersion
                $0.oldestCompatible = options.oldestCompatibleClient
                $0.build = options.build
                $0.instance = instance
                $0.pid = getpid()
                $0.full = client.full
            }
        case .list:
            reply(message, .sessions, to: client) {
                $0.sessions = sessions.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
            }
        case .attach:
            guard let id = message.session, let session = sessions[id] else {
                return fail(message, PtydErrorCode.unknownSession, to: client)
            }
            guard session.alive else { return fail(message, PtydErrorCode.notAlive, to: client, info: session.info) }
            // Replay and live output are handed over in one step on this queue: nothing is lost
            // or repeated between the snapshot and the first live chunk.
            session.attached.insert(client.id)
            var attached = PtydMessage(op: .attached, seq: message.seq, session: id)
            attached.info = session.info
            send(attached, payload: session.ring.snapshot(), to: client)
        case .detach:
            if let id = message.session { sessions[id]?.attached.remove(client.id) }
            reply(message, .ok, to: client)
        default:
            guard client.full else { return fail(message, PtydErrorCode.readOnly, to: client) }
            handleFull(frame, from: client)
        }
    }

    private func handleFull(_ frame: PtydFrame, from client: Client) {
        let message = frame.message
        switch message.op {
        case .spawn:
            guard let spawn = message.spawn, !spawn.argv.isEmpty, UUID(uuidString: spawn.id) != nil || !spawn.id.isEmpty else {
                return fail(message, PtydErrorCode.badRequest, to: client)
            }
            if let existing = sessions[spawn.id], existing.alive {
                // Never a second process for one session: the app attaches instead.
                return fail(message, PtydErrorCode.exists, to: client, info: existing.info)
            }
            guard !draining, !shuttingDown else { return fail(message, PtydErrorCode.spawnFailed, to: client) }
            guard let session = startSession(spawn) else { return fail(message, PtydErrorCode.spawnFailed, to: client) }
            session.attached.insert(client.id)
            reply(message, .spawned, to: client) { $0.info = session.info; $0.session = spawn.id }
            updateIdleTimer()
        case .write:
            guard let id = message.session, let session = sessions[id], session.alive else {
                return fail(message, PtydErrorCode.notAlive, to: client)
            }
            session.input.append(contentsOf: frame.payload)
            flushInput(session)
        case .resize:
            guard let id = message.session, let session = sessions[id], session.alive,
                  let cols = message.cols, let rows = message.rows, cols > 0, rows > 0 else { return }
            session.cols = cols
            session.rows = rows
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(session.master, TIOCSWINSZ, &size)
        case .signal:
            guard let id = message.session, let session = sessions[id], session.alive, let signal = message.signal else {
                return fail(message, PtydErrorCode.notAlive, to: client)
            }
            kill(session.pid, signal)
            if let after = message.killAfter { scheduleKill(session, after: after) }
            reply(message, .ok, to: client)
        case .forget:
            if let id = message.session, let session = sessions[id], !session.alive { sessions[id] = nil }
            reply(message, .ok, to: client)
        case .drain:
            // Exit once the last session has ended (Settings: turned off, keep sessions until they end).
            draining = true
            reply(message, .ok, to: client)
            exitIfDrained()
        case .shutdown:
            reply(message, .ok, to: client)
            shutdown()
        default:
            fail(message, PtydErrorCode.badRequest, to: client)
        }
    }

    // MARK: Sessions

    private final class Session: @unchecked Sendable {
        let spawn: PtydSpawn
        let pid: pid_t
        let master: Int32
        let startedAt: Double
        var cols: Int
        var rows: Int
        var ring: PtydRingBuffer
        var alive = true
        var exitCode: Int32?
        var exitSignal: Int32?
        var attached: Set<Int> = []
        var input: [UInt8] = []
        var readSuspended = false
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var exitSource: DispatchSourceProcess?
        var killTimer: DispatchSourceTimer?

        init(spawn: PtydSpawn, pid: pid_t, master: Int32, startedAt: Double, ringBytes: Int) {
            self.spawn = spawn
            self.pid = pid
            self.master = master
            self.startedAt = startedAt
            self.cols = spawn.cols
            self.rows = spawn.rows
            self.ring = PtydRingBuffer(capacity: ringBytes)
        }

        var info: PtydSessionInfo {
            PtydSessionInfo(id: spawn.id, pid: pid, startedAt: startedAt, cols: cols, rows: rows, alive: alive,
                            exitCode: exitCode, exitSignal: exitSignal, meta: spawn.meta)
        }
    }

    private func startSession(_ spawn: PtydSpawn) -> Session? {
        guard let (pid, master) = Self.forkExec(spawn) else {
            log("spawn \(spawn.id) failed: \(String(cString: strerror(errno)))")
            return nil
        }
        PtydSocket.setCloseOnExec(master)
        PtydSocket.setNonBlocking(master)
        let startedAt = PtydLaunchPlan.processStartTime(pid) ?? Date().timeIntervalSince1970
        let session = Session(spawn: spawn, pid: pid, master: master, startedAt: startedAt, ringBytes: options.ringBytes)
        sessions[spawn.id] = session

        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.readMaster(session)
        }
        read.setCancelHandler { close(master) }
        read.activate()
        session.readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        exit.activate()
        session.exitSource = exit
        // An exit before the source was armed wouldn't be reported: check once.
        queue.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.reap(session)
        }
        log("spawned \(spawn.id) pid \(pid)")
        return session
    }

    private func readMaster(_ session: Session) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<16 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(session.master, $0.baseAddress, $0.count) }
            if n > 0 {
                deliver(buffer[0..<n], from: session)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            // EOF / EIO: the slave side is closed (the child is exiting). Stop reading; the
            // exit source finishes the session.
            session.readSource?.suspend()
            session.readSuspended = true
            return
        }
    }

    private func deliver(_ chunk: ArraySlice<UInt8>, from session: Session) {
        session.ring.append(chunk)
        guard !session.attached.isEmpty else { return }
        let message = PtydMessage(op: .output, session: session.spawn.id)
        let bytes = Array(chunk)
        for id in session.attached {
            if let client = clients[id] { send(message, payload: bytes, to: client) }
        }
    }

    private func flushInput(_ session: Session) {
        while !session.input.isEmpty {
            let n = session.input.withUnsafeBytes { Darwin.write(session.master, $0.baseAddress, $0.count) }
            if n > 0 {
                session.input.removeFirst(n)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN {
                if session.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: session.master, queue: queue)
                    source.setEventHandler { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.flushInput(session)
                    }
                    source.activate()
                    session.writeSource = source
                }
                return
            }
            session.input = []
            break
        }
        session.writeSource?.cancel()
        session.writeSource = nil
    }

    private func scheduleKill(_ session: Session, after seconds: Double) {
        session.killTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak session] in
            guard let session, session.alive else { return }
            kill(session.pid, SIGKILL)
        }
        timer.activate()
        session.killTimer = timer
    }

    private func reap(_ session: Session) {
        guard session.alive else { return }
        var status: Int32 = 0
        let result = waitpid(session.pid, &status, WNOHANG)
        guard result == session.pid || (result < 0 && errno == ECHILD) else { return }
        // Whatever the child printed last is still in the pty: keep it for the scrollback.
        if session.readSuspended { session.readSource?.resume(); session.readSuspended = false }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(session.master, $0.baseAddress, $0.count) }
            if n > 0 { deliver(buffer[0..<n], from: session); continue }
            if n < 0, errno == EINTR { continue }
            break
        }
        session.alive = false
        if result == session.pid {
            let low = status & 0x7f
            if low == 0 {
                session.exitCode = (status >> 8) & 0xff
            } else if low != 0x7f {
                session.exitSignal = low
            }
        }
        session.exitSource?.cancel()
        session.killTimer?.cancel()
        session.writeSource?.cancel()
        session.readSource?.cancel()   // closes the master
        session.exitSource = nil
        session.killTimer = nil
        session.writeSource = nil
        session.readSource = nil
        session.input = []
        // The scrollback isn't needed once nobody can attach any more.
        session.ring = PtydRingBuffer(capacity: 1)
        session.attached = []
        log("session \(session.spawn.id) ended (code \(session.exitCode.map(String.init) ?? "-"), signal \(session.exitSignal.map(String.init) ?? "-"))")
        // Every app hears about it, attached or not.
        var message = PtydMessage(op: .exited, session: session.spawn.id)
        message.info = session.info
        for client in clients.values where client.greeted { send(message, to: client) }
        pruneTombstones()
        exitIfDrained()
        updateIdleTimer()
    }

    /// Ended sessions stay listed until an app forgets them; keep at most a few hundred.
    private func pruneTombstones() {
        let dead = sessions.values.filter { !$0.alive }.sorted { $0.startedAt < $1.startedAt }
        for session in dead.dropLast(200) { sessions[session.spawn.id] = nil }
    }

    private var aliveCount: Int { sessions.values.filter(\.alive).count }

    private func exitIfDrained() {
        if draining, aliveCount == 0 { exitProcess(0) }
    }

    /// Ends every session (SIGHUP, then SIGKILL after 3 s) and exits.
    private func shutdown() {
        shuttingDown = true
        let alive = sessions.values.filter(\.alive)
        for session in alive {
            kill(session.pid, SIGHUP)
            kill(session.pid, SIGTERM)
            scheduleKill(session, after: 3)
        }
        draining = true
        exitIfDrained()
        // Belt and braces: never hang around longer than that.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in self?.exitProcess(0) }
    }

    private func updateIdleTimer() {
        guard let idle = options.idleExit else { return }
        let isIdle = aliveCount == 0 && clients.isEmpty
        if !isIdle {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idle)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.aliveCount == 0, self.clients.isEmpty { self.exitProcess(0) }
            self.idleTimer = nil
        }
        timer.activate()
        idleTimer = timer
    }

    // MARK: fork + exec

    /// forkpty + chdir + execve, like SwiftTerm's `PseudoTerminalHelpers.fork` (the app's own
    /// terminals), so a session gets exactly the process it would get in the app. Only
    /// async-signal-safe calls run in the child; everything is prepared before the fork.
    static func forkExec(_ spawn: PtydSpawn) -> (pid_t, Int32)? {
        let argv = spawn.argv.map { strdup($0) } + [nil]
        let envp = spawn.env.map { strdup($0) } + [nil]
        let path = strdup(spawn.executable)
        let dir = strdup(spawn.cwd)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path)
            free(dir)
        }
        var size = winsize(ws_row: UInt16(clamping: max(spawn.rows, 1)), ws_col: UInt16(clamping: max(spawn.cols, 1)),
                           ws_xpixel: 0, ws_ypixel: 0)
        var empty = sigset_t()
        sigemptyset(&empty)
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { argvPtr in
            envp.withUnsafeBufferPointer { envPtr -> pid_t in
                let pid = forkpty(&master, nil, nil, &size)
                if pid == 0 {
                    // Dispatch threads may block signals; the child starts with none blocked.
                    sigprocmask(SIG_SETMASK, &empty, nil)
                    if let dir { _ = chdir(dir) }
                    execve(path, UnsafeMutablePointer(mutating: argvPtr.baseAddress!),
                           UnsafeMutablePointer(mutating: envPtr.baseAddress!))
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { return nil }
        return (pid, master)
    }
}
