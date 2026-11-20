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
        /// Where the running binary was loaded from, captured at launch (an update may move the
        /// old file away; the new one lands at this path). Nil: no self-update.
        public var executablePath: String?
        /// The arguments to exec the next image with, argv[0] included (`--resume-fd` is added).
        public var arguments: [String] = []
        /// How often the binary at `executablePath` is looked at (0: never; `upgrade` still works).
        public var watchInterval: TimeInterval = 5
        /// The running image's designated requirement, captured at launch
        /// (`PtydUpgradeCheck.ownDesignatedRequirement`): a candidate must satisfy it. Nil: none
        /// is ever accepted.
        public var designatedRequirement: String?
        /// Tests only: accept a candidate of the same build (the signature is still checked).
        public var allowSameBuildUpgrade = false

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
    /// A fresh id per helper process; an exec into an updated binary keeps it (same process).
    public private(set) var instance = UUID().uuidString
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
    /// Self-update (PtydHandover): the binary watch, and an upgrade being checked or under way.
    private var binaryWatch: PtydBinaryWatch
    private var watchTimer: DispatchSourceTimer?
    private var upgrading = false
    private let log: @Sendable (String) -> Void

    public init(options: Options, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.options = options
        self.log = log
        binaryWatch = PtydBinaryWatch(baseline: options.executablePath.flatMap(PtydFileIdentity.init(path:)))
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
        serve()
        log("listening on \(options.paths.socket.path) (instance \(instance), build \(options.build))")
    }

    /// The previous image of this process exec'd into this one (PtydHandover): takes over its
    /// socket, lock and sessions instead of starting afresh. The lock is already held through
    /// the inherited descriptor (flock again would conflict with it), and the socket already
    /// listens (connections made during the exec wait in its backlog).
    public func resume(_ handover: PtydHandover) throws {
        for fd in [handover.listenFD, handover.lockFD] where fcntl(fd, F_GETFD) < 0 {
            throw StartError.failed("inherited descriptor \(fd) is not open")
        }
        // Children must never inherit these (nor the masters: restoreSession).
        PtydSocket.setCloseOnExec(handover.listenFD)
        PtydSocket.setCloseOnExec(handover.lockFD)
        PtydSocket.setNonBlocking(handover.listenFD)
        listenFD = handover.listenFD
        lockFD = handover.lockFD
        instance = handover.instance
        queue.sync {
            draining = handover.draining
            for saved in handover.sessions { restoreSession(saved) }
        }
        serve()
        let alive = handover.sessions.filter(\.alive).count
        log("resumed from build \(handover.fromBuild) as build \(options.build): \(alive) live sessions, "
            + "\(handover.sessions.count - alive) ended (instance \(instance))")
        queue.async { self.exitIfDrained() }
    }

    /// Accepts connections and watches the binary.
    private func serve() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.activate()
        acceptSource = source
        queue.async {
            self.updateIdleTimer()
            self.startBinaryWatch()
        }
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
        case .probeAccess:
            // Informational and harmless: read-only clients may ask too. A helper pretending to
            // be older (tests) answers like one that doesn't know the request.
            guard options.protocolVersion >= PtydProtocol.accessProbeVersion else {
                return fail(message, PtydErrorCode.badRequest, to: client)
            }
            // Off the helper's queue: a slow file system mustn't hold up the sessions' output.
            DispatchQueue.global(qos: .utility).async { [weak self, weak client] in
                let report = PtydAccessProbe.run()
                self?.queue.async {
                    guard let self, let client else { return }
                    self.reply(message, .access, to: client) { $0.access = report }
                }
            }
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
        case .upgrade:
            // A helper pretending to be older (tests) answers like one that doesn't know it.
            guard options.protocolVersion >= PtydProtocol.upgradeVersion else {
                return fail(message, PtydErrorCode.badRequest, to: client)
            }
            upgrade(reason: "asked by client \(client.id)") { [self] verdict in
                guard !client.closed else { return }
                switch verdict {
                case .go(let build):
                    self.reply(message, .ok, to: client) { $0.build = build }
                case .notNewer:
                    self.fail(message, PtydErrorCode.notNewer, to: client)
                case .invalid:
                    self.fail(message, PtydErrorCode.invalidCandidate, to: client)
                }
            }
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
        /// When `killTimer` fires (handed over to the next image).
        var killDeadline: DispatchTime?

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
        watch(session)
        log("spawned \(spawn.id) pid \(pid)")
        return session
    }

    /// A session as the previous image left it (same child, same pty master).
    private func restoreSession(_ saved: PtydHandover.Session) {
        let hasPty = saved.alive && saved.master >= 0 && fcntl(saved.master, F_GETFD) >= 0
        if saved.alive, !hasPty { log("session \(saved.spawn.id): its pty didn't come through the exec") }
        let session = Session(spawn: saved.spawn, pid: saved.pid, master: hasPty ? saved.master : -1,
                              startedAt: saved.startedAt, ringBytes: saved.alive ? options.ringBytes : 1)
        session.cols = saved.cols
        session.rows = saved.rows
        session.exitCode = saved.exitCode
        session.exitSignal = saved.exitSignal
        sessions[saved.spawn.id] = session
        guard saved.alive else {
            session.alive = false
            return
        }
        if !saved.scrollback.isEmpty { session.ring.append(saved.scrollback) }
        guard hasPty else {
            // Without its pty nobody can attach; it is still reaped and its exit reported.
            watchExit(session)
            return
        }
        PtydSocket.setCloseOnExec(saved.master)
        PtydSocket.setNonBlocking(saved.master)
        session.input = saved.pendingInput
        watch(session)
        if saved.readStopped {
            // As before the exec: EOF seen, the exit source finishes it.
            session.readSource?.suspend()
            session.readSuspended = true
        }
        if !session.input.isEmpty { flushInput(session) }
        if let killIn = saved.killIn { scheduleKill(session, after: max(0, killIn)) }
        log("restored \(saved.spawn.id) pid \(saved.pid) (\(saved.scrollback.count) bytes of scrollback)")
    }

    /// Reads the session's pty and reaps its child when it exits.
    private func watch(_ session: Session) {
        let master = session.master
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.readMaster(session)
        }
        read.setCancelHandler { close(master) }
        read.activate()
        session.readSource = read
        watchExit(session)
    }

    private func watchExit(_ session: Session) {
        let exit = DispatchSource.makeProcessSource(identifier: session.pid, eventMask: .exit, queue: queue)
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
        session.killDeadline = .now() + seconds
    }

    private func reap(_ session: Session) {
        guard session.alive else { return }
        var status: Int32 = 0
        let result = waitpid(session.pid, &status, WNOHANG)
        guard result == session.pid || (result < 0 && errno == ECHILD) else { return }
        // Whatever the child printed last is still in the pty: keep it for the scrollback.
        if session.readSuspended { session.readSource?.resume(); session.readSuspended = false }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while session.master >= 0 {
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

    // MARK: Self-update (exec into the updated binary)

    /// Looks at the binary every `watchInterval` seconds (a stat; with a large leeway, so an
    /// idle helper still costs next to nothing). A replaced file is checked once it has stayed
    /// the same for a few seconds.
    private func startBinaryWatch() {
        guard watchTimer == nil, let path = options.executablePath, options.watchInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = options.watchInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 300)))
        timer.setEventHandler { [weak self] in
            guard let self, !self.upgrading, !self.shuttingDown else { return }
            let current = PtydFileIdentity(path: path)
            if self.binaryWatch.observe(current, now: Date().timeIntervalSince1970) {
                self.upgrade(reason: "the binary on disk was replaced", identity: current) { _ in }
            }
        }
        timer.activate()
        watchTimer = timer
    }

    /// Checks the binary at `executablePath` (off the queue: it reads the file) and, if it's a
    /// validly signed newer build, re-execs into it a moment after `completion` (which may
    /// answer the client that asked). Anything wrong: logged, and this image keeps running.
    private func upgrade(reason: String, identity: PtydFileIdentity? = nil,
                         completion: @escaping @Sendable (PtydUpgradeCheck.Verdict) -> Void) {
        guard let path = options.executablePath else {
            log("upgrade (\(reason)): no executable path; not upgrading")
            return completion(.invalid("no executable path"))
        }
        guard !shuttingDown else { return completion(.invalid("shutting down")) }
        // One at a time; a second request rides along with the one under way.
        guard !upgrading else { return completion(.go(build: nil)) }
        upgrading = true
        let checked = identity ?? PtydFileIdentity(path: path)
        let build = options.build
        let allowSame = options.allowSameBuildUpgrade
        let requirement = options.designatedRequirement
        log("upgrade (\(reason)): checking \(path)")
        DispatchQueue.global(qos: .utility).async { [self] in
            let verdict = PtydUpgradeCheck.check(path: path, requirement: requirement, currentBuild: build,
                                                 allowSameBuild: allowSame)
            self.queue.async {
                guard case .go(let newBuild) = verdict else {
                    self.log("upgrade refused: \(verdict); this image keeps running")
                    self.upgrading = false
                    self.binaryWatch.reject(checked)
                    return completion(verdict)
                }
                if allowSame { self.log("upgrade: same build allowed (test mode)") }
                completion(verdict)
                // A moment for the answer to reach the client before the connection drops.
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    if let problem = self.reexec(path: path, expected: checked, build: newBuild) {
                        self.log("upgrade failed: \(problem); this image keeps running")
                        self.binaryWatch.reject(checked)
                    }
                    self.upgrading = false
                }
            }
        }
    }

    /// The state the next image needs (read-only: nothing here changes a session).
    private func handover() -> PtydHandover {
        let now = DispatchTime.now()
        let ordered = sessions.values.sorted { $0.startedAt < $1.startedAt }
        let scrollbacks = PtydHandover.bounded(ordered.map { $0.alive ? $0.ring.snapshot() : [] })
        let saved = zip(ordered, scrollbacks).map { session, scrollback in
            let killIn = session.killDeadline.map { deadline -> Double in
                deadline > now ? Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9 : 0
            }
            return PtydHandover.Session(
                spawn: session.spawn, pid: session.pid, master: session.alive ? session.master : -1,
                startedAt: session.startedAt, cols: session.cols, rows: session.rows, alive: session.alive,
                exitCode: session.exitCode, exitSignal: session.exitSignal, pendingInput: session.input,
                killIn: session.alive ? killIn : nil, readStopped: session.readSuspended, scrollback: scrollback)
        }
        return PtydHandover(instance: instance, fromBuild: options.build, listenFD: listenFD, lockFD: lockFD,
                            draining: draining, sessions: saved)
    }

    /// Hands the state over and execs the binary at `path` in this process. Runs on the queue,
    /// start to finish, so no session is read or changed in between: output arriving meanwhile
    /// waits in the ptys for the next image. Returns only on failure (why), with everything as
    /// it was: the clients are still connected and no session was touched.
    private func reexec(path: String, expected: PtydFileIdentity?, build: String?) -> String? {
        guard !shuttingDown else { return "shutting down" }
        // The file must still be the one that was checked.
        guard PtydFileIdentity(path: path) == expected else { return "the binary changed again since it was checked" }
        let state = handover()
        let stateFD: Int32
        do {
            stateFD = try state.writeUnlinked(in: options.paths.directory)
            // The next image can't come back to this one: make sure it can read what it gets.
            guard try PtydHandover.read(fd: stateFD) == state else {
                close(stateFD)
                return "the handover didn't read back the same"
            }
        } catch {
            return "\(error)"
        }
        let keep = state.descriptors + [stateFD]
        for fd in keep where fcntl(fd, F_GETFD) < 0 {
            close(stateFD)
            return "descriptor \(fd) is not open"
        }
        var args = options.arguments
        if let index = args.firstIndex(of: "--resume-fd") { args.removeSubrange(index..<min(index + 2, args.count)) }
        args += ["--resume-fd", String(stateFD)]
        if args.count == 2 { args.insert(path, at: 0) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // SETEXEC: replace this process (same pid) like execve; CLOEXEC_DEFAULT: every descriptor
        // not inherited below is closed, so none leaks into the next image (the clients' sockets
        // close, and their apps reconnect).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        // This runs on a dispatch thread, which may block signals: the next image starts with none blocked.
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // stdin/out/err (the log) as they are, when open.
        for fd in Int32(0)...2 where fcntl(fd, F_GETFD) >= 0 { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        for fd in keep { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        log("upgrade: handing \(state.sessions.filter(\.alive).count) live sessions to build \(build ?? "?") "
            + "(\(state.sessions.reduce(0) { $0 + $1.scrollback.count }) bytes of scrollback), exec \(path)")
        // The inherit actions alone don't keep a close-on-exec descriptor open: clear the flag
        // just for the exec. Only this queue forks (forkExec), so no child can catch them meanwhile.
        for fd in keep { _ = fcntl(fd, F_SETFD, 0) }
        let result = posix_spawn(nil, path, &actions, &attributes, argv, environ)
        // Only on failure: the new image didn't start, this one carries on.
        for fd in keep { PtydSocket.setCloseOnExec(fd) }
        close(stateFD)
        return "exec: \(String(cString: strerror(result))) (descriptors \(keep))"
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
        // Ignored signals survive exec: a helper started with SIGHUP ignored (nohup, a shell's
        // background job, launchd) would hand that on, and a session would outlive the helper.
        var byDefault = sigaction()
        byDefault.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&byDefault.sa_mask)
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { argvPtr in
            envp.withUnsafeBufferPointer { envPtr -> pid_t in
                let pid = forkpty(&master, nil, nil, &size)
                if pid == 0 {
                    // Dispatch threads may block signals; the child starts with none blocked.
                    sigprocmask(SIG_SETMASK, &empty, nil)
                    for signal in 1..<NSIG { _ = sigaction(signal, &byDefault, nil) }
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
