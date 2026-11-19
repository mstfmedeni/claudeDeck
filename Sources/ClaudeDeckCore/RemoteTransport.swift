import Foundation
import Network

// TCP transport for remote mode (see RemoteProtocol.swift). Everything runs on the queue given
// at init (the app passes `.main`); callbacks arrive there too.

/// One framed TCP connection.
public final class RemoteChannel: @unchecked Sendable {
    private let stream: RemoteByteStream
    private let queue: DispatchQueue
    private var decoder = RemoteFrameDecoder()
    private var closed = false

    public var onReady: (() -> Void)?
    public var onMessage: ((RemoteMessage) -> Void)?
    /// Frames of other kinds (reserved for terminal streaming).
    public var onFrame: ((RemoteFrame) -> Void)?
    /// Called once; `reason` is nil for a clean close by this side.
    public var onClose: ((String?) -> Void)?
    /// Last time anything arrived (keepalive).
    public private(set) var lastReceived = Date()
    /// Set once the handshake is done: from then on every frame is sealed both ways.
    private var cipher: RemoteCipher?

    public var isEncrypted: Bool { cipher != nil }

    /// Switches to sealed frames (call right after the last plaintext handshake message).
    public func startEncrypting(_ cipher: RemoteCipher) {
        self.cipher = cipher
    }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.stream = NWConnectionStream(connection)
        self.queue = queue
    }

    /// Through a RemoteDialer (the in-app Tailscale node) instead of the system's network.
    public init(dialer: RemoteDialer, host: String, port: UInt16, timeout: TimeInterval, queue: DispatchQueue) {
        self.stream = DialedStream(dialer: dialer, host: host, port: port, timeout: timeout)
        self.queue = queue
    }

    public func start() {
        stream.start(queue: queue) { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready: self.onReady?()
            case .failed(let reason): self.finish(reason)
            case .cancelled: self.finish(nil)
            }
        }
        receive()
    }

    public func send(_ message: RemoteMessage) {
        guard !closed, let frame = try? message.frame() else { return }
        send(frame)
    }

    public func send(_ frame: RemoteFrame) {
        guard !closed else { return }
        // The peer drops the connection over a frame it can't take (`RemoteFrame.maxPayload`):
        // leave one that big out instead. Checked before sealing, which uses up a nonce.
        guard Self.fits(frame, sealed: cipher != nil) else {
            droppedOversized += 1
            return
        }
        var frame = frame
        if cipher != nil {
            guard let sealed = try? cipher!.seal(frame) else { finish(String(localized: "Encryption failed")); return }
            frame = sealed
        }
        let data = frame.encoded()
        pendingBytes += data.count
        stream.send(data) { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            if let error { self.finish(error.localizedDescription) }
        }
    }

    /// Bytes handed to the connection and not yet sent (backpressure for terminal output).
    public private(set) var pendingBytes = 0
    /// Frames left out for being larger than the peer accepts (diagnostics).
    public private(set) var droppedOversized = 0

    /// Whether the peer's decoder takes this frame (sealing adds the kind byte and the tag).
    static func fits(_ frame: RemoteFrame, sealed: Bool) -> Bool {
        frame.payload.count + (sealed ? 17 : 0) <= RemoteFrame.maxPayload
    }

    /// Until the handshake is done, larger frames close the connection. Set by the host on
    /// incoming connections: `hello` and `auth` are a few hundred bytes, and nobody who hasn't
    /// proved the key gets to make it buffer megabytes. (Not on the remote side: the host's
    /// first sealed snapshot can arrive in the same read as `welcome`, before the cipher is on.)
    public var maxPayloadBeforeHandshake: Int?

    /// Sends `refused` (if given) and closes once it is out.
    public func close(refusing reason: String? = nil) {
        guard !closed else { return }
        if let reason, var frame = try? RemoteMessage.refused(reason: reason).frame() {
            if cipher != nil, let sealed = try? cipher!.seal(frame) { frame = sealed }
            stream.send(frame.encoded()) { [weak self] _ in
                self?.finish(nil)
            }
        } else {
            finish(nil)
        }
    }

    private func receive() {
        stream.receive { [weak self] data, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.decoder.maxPayload = self.cipher == nil ? (self.maxPayloadBeforeHandshake ?? RemoteFrame.maxPayload) : RemoteFrame.maxPayload
                do {
                    for wire in try self.decoder.append(data) {
                        // After the handshake only sealed frames are accepted (no injected plaintext).
                        let frame: RemoteFrame
                        if self.cipher != nil {
                            guard let opened = try? self.cipher!.open(wire) else {
                                self.finish(String(localized: "The connection to the other Mac isn't intact (decryption failed)."))
                                return
                            }
                            frame = opened
                        } else {
                            guard wire.kind != RemoteFrameKind.sealed.rawValue else { continue }
                            frame = wire
                        }
                        // A message this version doesn't know (the other side is newer): skip it.
                        if frame.kind == RemoteFrameKind.message.rawValue {
                            if let message = try? RemoteMessage.decode(frame) { self.onMessage?(message) }
                        } else {
                            self.onFrame?(frame)
                        }
                        if self.closed { return }
                    }
                } catch {
                    self.finish(String(localized: "Malformed data from the other Mac"))
                    return
                }
            }
            if let error { self.finish(error.localizedDescription); return }
            if isComplete { self.finish(String(localized: "Connection closed by the other Mac")); return }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        stream.cancel()
        let handler = onClose
        onClose = nil
        onReady = nil
        onMessage = nil
        onFrame = nil
        handler?(reason)
    }

    /// The peer's IP address, for incoming connections.
    public var remoteIP: String? {
        guard case .hostPort(let host, _) = stream.remoteEndpoint else { return nil }
        return Self.ipString(host)
    }

    /// The address the peer connected to (incoming connections; nil when unknown).
    public var localIP: String? {
        guard case .hostPort(let host, _) = stream.localEndpoint else { return nil }
        return Self.ipString(host)
    }

    /// The interface the connection arrived on (diagnostics).
    public var interfaceName: String? { stream.interfaceName }

    static func ipString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: address.rawValue) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}

// MARK: Host side

/// Listens for remotes, authenticates them and keeps them up to date.
public final class RemoteServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    private let port: UInt16
    private let queue: DispatchQueue
    private let key: () -> Data?
    private let acceptsPeer: (String) -> Bool
    private var listener: NWListener?
    private var pending: [ObjectIdentifier: PendingPeer] = [:]
    private var peers: [ObjectIdentifier: Peer] = [:]

    private struct Peer {
        var channel: RemoteChannel
        var name: String
        /// Sessions whose terminal this remote shows.
        var watching: Set<UUID> = []
        /// Watched sessions whose output was dropped (remote too slow): they get a fresh start.
        var resync: Set<UUID> = []
        /// A phone that registered for pushes (it gets in-app alerts while connected).
        var pushToken: Data?
        /// Sessions whose conversation this remote shows (`conversationOpen`): told when they change.
        var conversations: Set<UUID> = []
    }

    /// Output stops being queued for a remote with this much unsent data.
    static let maxPendingBytes = 2 << 20
    private var keepalive: DispatchSourceTimer?
    private var failures: [String: [Date]] = [:]
    static let maxFailures = 10
    static let failureWindow: TimeInterval = 600
    /// Connections from one address that haven't proved the key yet, at once (a device races a
    /// few addresses, not dozens). Per address, so one peer can't crowd the others out.
    public var maxPendingPerAddress = 16
    /// Largest frame accepted before the handshake (`RemoteChannel.maxPayloadBeforeHandshake`).
    static let maxPayloadBeforeHandshake = 64 << 10
    /// APNs device tokens are 32 bytes, topics a bundle id: anything far larger isn't a phone's.
    static let maxPushToken = 256
    static let maxPushTopic = 256
    /// Live output goes out in frames of at most this many bytes (a burst held up behind a busy
    /// main thread can't become one frame larger than the peer accepts).
    static let maxOutputChunk = 1 << 20

    /// Forgets addresses whose wrong passwords are all older than `failureWindow` (the map
    /// would otherwise keep every address that ever failed).
    func pruneFailures(now: Date = Date()) {
        failures = failures.compactMapValues { times in
            let recent = times.filter { now.timeIntervalSince($0) < Self.failureWindow }
            return recent.isEmpty ? nil : recent
        }
    }

    func noteFailure(_ ip: String, at date: Date = Date()) {
        failures[ip, default: []].append(date)
    }

    /// Addresses with recent wrong passwords (tests).
    var failingAddresses: Int { failures.count }

    public private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    /// Names of the connected (authenticated) remotes.
    public var onPeersChanged: (([String]) -> Void)?
    /// A remote answered a prompt; return whether the keystroke was sent.
    public var onPermission: ((_ sessionID: UUID, _ stamp: Double, _ approve: Bool) -> Bool)?
    /// A remote answered a question; reply whether the keys are being typed.
    public var onAnswerQuestion: ((_ sessionID: UUID, _ toolUseID: String, _ answers: [QuestionAnswer], _ reply: @escaping @Sendable (Bool) -> Void) -> Void)?
    /// The latest snapshot; setting a different one sends it to every remote.
    public var snapshot: RemoteSnapshot? {
        didSet {
            guard let snapshot, snapshot != oldValue else { return }
            for peer in peers.values { peer.channel.send(.snapshot(snapshot)) }
        }
    }

    private struct PendingPeer {
        var channel: RemoteChannel
        var remoteNonce: Data?
        var hostNonce: Data?
        var name: String?
        var startedAt: Date
        var ip: String
    }

    /// `acceptsPeer` filters by the peer's IP before any byte is read (Tailscale addresses only).
    public init(port: UInt16, queue: DispatchQueue = .main, key: @escaping () -> Data?, acceptsPeer: @escaping (String) -> Bool) {
        self.port = port
        self.queue = queue
        self.key = key
        self.acceptsPeer = acceptsPeer
    }

    /// After `acceptsPeer`: the peer's address and the local one it connected to (nil when the
    /// path doesn't say); false drops the connection. nil: not checked.
    public var acceptsPath: ((_ remoteIP: String, _ localIP: String?) -> Bool)?

    public var peerNames: [String] { peers.values.map(\.name).sorted() }
    /// Advertise on the local network (Bonjour) under this name, with the host id in the TXT record.
    /// Set before `start()`.
    public var bonjour: (name: String, hostID: UUID)?
    /// Push tokens of the phones connected right now.
    public var connectedPushTokens: Set<Data> { Set(peers.values.compactMap(\.pushToken)) }

    /// Push tokens of the connected phones heard from in the last `seconds`. A phone pings every
    /// 20 s while it's in front; one that went away without closing (out of range, suspended)
    /// stays connected here until the keepalive drops it (75 s), and should get pushes meanwhile.
    public func pushTokensHeard(within seconds: TimeInterval, now: Date = Date()) -> Set<Data> {
        Set(peers.values.filter { now.timeIntervalSince($0.channel.lastReceived) <= seconds }.compactMap(\.pushToken))
    }

    /// How long a phone may be silent and still count as there for pushes: its ping interval
    /// (20 s, a timer with leeway) plus room for a slow network.
    public static let pushSilence: TimeInterval = 30

    public struct TerminalStart: Sendable {
        public var cols: Int
        public var rows: Int
        public var screen: Data
        public init(cols: Int, rows: Int, screen: Data) {
            self.cols = cols
            self.rows = rows
            self.screen = screen
        }
    }

    /// A remote opened a session's terminal: its size and screen, or nil if it isn't running.
    public var onTerminalOpen: ((UUID) -> TerminalStart?)?
    /// Keystrokes from a remote.
    public var onTerminalInput: ((UUID, Data) -> Void)?
    /// A remote asked for a page of a conversation; answer through the reply (any queue hop is fine,
    /// it is sent on the server's queue).
    public var onHistoryRequest: ((_ sessionID: UUID, _ before: String?, _ after: String?, _ limit: Int, _ reply: @escaping @Sendable (ChatPage?) -> Void) -> Void)?
    /// A remote asked for a page of a session's edits / a file's net diff; answer through the reply.
    public var onEditsRequest: ((_ sessionID: UUID, _ after: String?, _ reply: @escaping @Sendable (RemoteEditsPage?) -> Void) -> Void)?
    public var onNetDiffRequest: ((_ sessionID: UUID, _ path: String, _ reply: @escaping @Sendable (RemoteNetDiff?) -> Void) -> Void)?
    public var onMarkSeen: ((UUID) -> Void)?
    /// Start a session in a project; return its id (sent back to the remote that asked).
    public var onStartSession: ((_ projectID: UUID, _ prompt: String?) -> UUID?)?
    public var onStopSession: ((UUID) -> Void)?
    public var onStartShell: ((_ projectID: UUID, _ command: String?) -> UUID?)?
    public var onPastConversations: ((_ projectID: UUID, _ reply: @escaping @Sendable ([RemotePastConversation]) -> Void) -> Void)?
    public var onResumeConversation: ((_ projectID: UUID, _ conversationID: String) -> UUID?)?
    public var onInterrupt: ((UUID) -> Void)?
    /// `.listDirectory` / `.readFile` / `.downloadFile` / `.uploadFile`: answer with `.directory` /
    /// `.file` / `.fileChunk` / `.uploadAck` through the reply.
    public var onFileRequest: ((_ request: RemoteMessage, _ reply: @escaping @Sendable (RemoteMessage) -> Void) -> Void)?
    public var onResumeSession: ((UUID) -> Void)?
    /// A watching remote wants the terminal at this grid (0 cols = release).
    public var onTerminalFit: ((UUID, Int, Int) -> Void)?
    public var onSendPrompt: ((UUID, String) -> Void)?
    /// `.queuePrompt` / `.queueAction` (the next snapshot carries the queue).
    public var onQueuePrompt: ((UUID, String) -> Void)?
    public var onQueueAction: ((_ sessionID: UUID, _ promptID: UUID, _ action: QueueAction) -> Void)?
    /// `.askAgents` / `.agentNoteAction` (notes go out with the conversation pages).
    public var onAskAgents: ((_ sessionID: UUID, _ agentIDs: [UUID], _ request: String) -> Void)?
    public var onAgentNoteAction: ((_ sessionID: UUID, _ noteID: UUID, _ action: AgentNoteAction) -> Void)?
    public var onAgentRegistration: ((_ agentID: UUID, _ approve: Bool, _ url: String?, _ authHeader: String?) -> Void)?
    public var onAgentDetails: ((_ reply: @escaping @Sendable (RemoteAgentDetails) -> Void) -> Void)?
    /// A message with files; reply nil once it's going in, else why not.
    public var onSendPromptWithFiles: ((_ sessionID: UUID, _ text: String, _ files: [RemoteUpload], _ reply: @escaping @Sendable (String?) -> Void) -> Void)?
    /// The session's permission mode (after Shift+Tab when cycling); reply with what the screen shows.
    public var onPermissionMode: ((_ sessionID: UUID, _ cycle: Bool, _ reply: @escaping @Sendable (String?) -> Void) -> Void)?
    /// A folder's subfolders for the project picker; reply with `.folder`.
    public var onBrowseFolder: ((_ path: String, _ reply: @escaping @Sendable (RemoteMessage) -> Void) -> Void)?
    public var onAddProject: ((_ path: String) -> Void)?
    /// The session menu's actions.
    public var onSessionAction: ((_ sessionID: UUID, _ action: RemoteSessionAction) -> Void)?
    /// Fix with Claude for a failed ServerPlan deploy; reply with the session it went to, or why not.
    public var onServerPlanRepair: ((_ deploymentID: Int, _ reply: @escaping @Sendable (UUID?, String?) -> Void) -> Void)?
    /// Pin / rename one of the host's projects.
    /// `reply` answers a `renameFolder` (nil: done, else why not).
    public var onProjectAction: ((_ projectID: UUID, _ action: RemoteProjectAction, _ reply: @escaping (String?) -> Void) -> Void)?
    /// Files to paste into a watched terminal; reply nil once they're going in, else why not.
    public var onPasteFiles: ((_ sessionID: UUID, _ files: [RemoteUpload], _ reply: @escaping @Sendable (String?) -> Void) -> Void)?
    /// A phone registered for push notifications.
    public var onRegisterPush: ((PushDevice) -> Void)?
    /// `answerDecision` (the answer cut to `Decisions.maxAnswer`).
    public var onAnswerDecision: ((_ id: String, _ answer: String) -> Void)?
    /// `dismissDecision`.
    public var onDismissDecision: ((_ id: String) -> Void)?
    /// `dismissServerIssues` (ids capped at 200).
    public var onDismissServerIssues: ((_ deploymentIDs: [Int], _ all: Bool) -> Void)?
    /// `changeDecisionAnswer` (the answer cut to `Decisions.maxAnswer`).
    public var onChangeDecisionAnswer: ((_ id: String, _ answer: String) -> Void)?
    /// The set of sessions any remote watches changed (the host taps only those).
    public var onWatchedChanged: ((Set<UUID>) -> Void)?

    public var watchedSessions: Set<UUID> { peers.values.reduce(into: Set()) { $0.formUnion($1.watching) } }

    /// Sessions whose conversation some remote has open.
    public var openConversations: Set<UUID> { peers.values.reduce(into: Set()) { $0.formUnion($1.conversations) } }

    /// The session's transcript changed: remotes with its conversation open ask for what's new.
    public func conversationChanged(sessionID: UUID) {
        for peer in peers.values where peer.conversations.contains(sessionID) {
            peer.channel.send(.conversationChanged(sessionID: sessionID))
        }
    }

    /// New output of a session, for every remote watching it.
    public func sendOutput(sessionID: UUID, bytes: Data) {
        let frames = RemoteTerminalOutput.frames(sessionID: sessionID, bytes: bytes, maxChunk: Self.maxOutputChunk)
        for (id, peer) in peers where peer.watching.contains(sessionID) {
            for frame in frames {
                if peers[id]?.resync.contains(sessionID) != false { break }
                if peer.channel.pendingBytes > Self.maxPendingBytes {
                    peers[id]?.resync.insert(sessionID)
                    break
                }
                peer.channel.send(frame)
            }
        }
        resyncDrained()
    }

    /// The terminal was resized (or must be redrawn): every watcher gets a fresh start.
    public func restartTerminal(sessionID: UUID) {
        for (id, peer) in peers where peer.watching.contains(sessionID) { sendStart(sessionID, to: id, channel: peer.channel) }
    }

    /// The session stopped: tell its watchers and forget them.
    public func terminalEnded(sessionID: UUID) {
        var changed = false
        for (id, peer) in peers where peer.watching.contains(sessionID) {
            peer.channel.send(.terminalEnded(sessionID: sessionID))
            peers[id]?.watching.remove(sessionID)
            peers[id]?.resync.remove(sessionID)
            changed = true
        }
        if changed { onWatchedChanged?(watchedSessions) }
    }

    private func sendStart(_ sessionID: UUID, to id: ObjectIdentifier, channel: RemoteChannel) {
        peers[id]?.resync.remove(sessionID)
        guard let start = onTerminalOpen?(sessionID) else {
            channel.send(.terminalEnded(sessionID: sessionID))
            peers[id]?.watching.remove(sessionID)
            return
        }
        channel.send(.terminalStart(sessionID: sessionID, cols: start.cols, rows: start.rows, screen: start.screen))
    }

    /// Remotes that caught up get a fresh screen instead of the output they missed.
    private func resyncDrained() {
        for (id, peer) in peers where !peer.resync.isEmpty && peer.channel.pendingBytes < Self.maxPendingBytes / 4 {
            for sessionID in peer.resync { sendStart(sessionID, to: id, channel: peer.channel) }
        }
    }
    /// Last connection dropped for not coming from an allowed address (diagnostics).
    public private(set) var lastRejectedPeer: String?

    public func start() {
        guard listener == nil else { return }
        // Port 0: the system picks one (tests); `state` reports it.
        guard let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) else { state = .failed("Invalid port \(port)"); return }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready: self.state = .listening(port: self.listener?.port?.rawValue ?? self.port)
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
                self.stop(keepState: true)
            default: break
            }
        }
        if let bonjour {
            var txt = NWTXTRecord()
            txt["id"] = bonjour.hostID.uuidString
            listener.service = NWListener.Service(name: bonjour.name, type: RemoteBonjour.serviceType, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        startKeepalive()
    }

    public func stop() { stop(keepState: false) }

    private func stop(keepState: Bool) {
        listener?.cancel()
        listener = nil
        keepalive?.cancel()
        keepalive = nil
        for peer in pending.values { peer.channel.close() }
        for peer in peers.values { peer.channel.close() }
        pending = [:]
        peers = [:]
        onPeersChanged?([])
        if !keepState { state = .stopped }
    }

    /// Drops every remote (after a key change), keeps listening.
    public func disconnectAll(reason: String) {
        for peer in pending.values { peer.channel.close(refusing: reason) }
        for peer in peers.values { peer.channel.close(refusing: reason) }
    }

    private func accept(_ connection: NWConnection) {
        let channel = RemoteChannel(connection: connection, queue: queue)
        guard let ip = channel.remoteIP, acceptsPeer(ip) else {
            lastRejectedPeer = "\(connection.endpoint)"
            connection.cancel()
            return
        }
        // Then where it arrived (the source address alone can be spoofed by the network's range).
        if let acceptsPath, !acceptsPath(ip, channel.localIP) {
            lastRejectedPeer = "\(connection.endpoint) → \(channel.localIP ?? "?") on \(channel.interfaceName ?? "?")"
            connection.cancel()
            return
        }
        // Wrong passwords: at most `maxFailures` per address in `failureWindow`.
        let now = Date()
        pruneFailures(now: now)
        if (failures[ip]?.count ?? 0) >= Self.maxFailures {
            connection.cancel()
            return
        }
        // Unfinished handshakes are dropped after 10 s; until then only so many per address.
        guard pending.values.filter({ $0.ip == ip }).count < maxPendingPerAddress else {
            connection.cancel()
            return
        }
        channel.maxPayloadBeforeHandshake = Self.maxPayloadBeforeHandshake
        let id = ObjectIdentifier(channel)
        pending[id] = PendingPeer(channel: channel, startedAt: Date(), ip: ip)
        channel.onMessage = { [weak self] message in self?.received(message, from: id) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.pending[id] = nil
            if let peer = self.peers.removeValue(forKey: id) {
                self.onPeersChanged?(self.peerNames)
                if !peer.watching.isEmpty { self.onWatchedChanged?(self.watchedSessions) }
            }
        }
        channel.start()
    }

    private func received(_ message: RemoteMessage, from id: ObjectIdentifier) {
        if let peer = peers[id] {
            switch message {
            case .ping:
                peer.channel.send(.pong)
            case .permission(let sessionID, let stamp, let approve):
                let applied = onPermission?(sessionID, stamp, approve) ?? false
                peer.channel.send(.permissionResult(sessionID: sessionID, approve: approve, applied: applied))
            case .answerQuestion(let sessionID, let toolUseID, let answers):
                let channel = peer.channel
                onAnswerQuestion?(sessionID, toolUseID, answers) { [queue] applied in
                    queue.async { channel.send(.permissionResult(sessionID: sessionID, approve: true, applied: applied)) }
                }
            case .terminalOpen(let sessionID):
                let wasWatched = watchedSessions
                peers[id]?.watching.insert(sessionID)
                sendStart(sessionID, to: id, channel: peer.channel)
                if watchedSessions != wasWatched { onWatchedChanged?(watchedSessions) }
            case .terminalClose(let sessionID):
                let wasWatched = watchedSessions
                peers[id]?.watching.remove(sessionID)
                peers[id]?.resync.remove(sessionID)
                if watchedSessions != wasWatched { onWatchedChanged?(watchedSessions) }
            case .terminalInput(let sessionID, let data) where peer.watching.contains(sessionID):
                onTerminalInput?(sessionID, data)
            case .historyRequest(let sessionID, let before, let after, let limit):
                let channel = peer.channel
                onHistoryRequest?(sessionID, before, after, limit) { [queue] page in
                    queue.async {
                        channel.send(.history(sessionID: sessionID, page: page ?? ChatPage(entries: [], hasMoreBefore: false, reset: true)))
                    }
                }
            case .conversationOpen(let sessionID):
                peers[id]?.conversations.insert(sessionID)
            case .conversationClose(let sessionID):
                peers[id]?.conversations.remove(sessionID)
            case .editsRequest(let sessionID, let after):
                let channel = peer.channel
                onEditsRequest?(sessionID, after) { [queue] page in
                    queue.async {
                        channel.send(.edits(sessionID: sessionID, page: page ?? RemoteEditsPage(changes: [], reset: true)))
                    }
                }
            case .netDiffRequest(let sessionID, let path):
                let channel = peer.channel
                onNetDiffRequest?(sessionID, path) { [queue] diff in
                    queue.async {
                        channel.send(.netDiff(sessionID: sessionID, path: path, diff: diff ?? RemoteNetDiff(hunks: nil, changes: 0)))
                    }
                }
            case .terminalFit(let sessionID, let cols, let rows) where peer.watching.contains(sessionID):
                onTerminalFit?(sessionID, cols == 0 ? 0 : min(max(cols, 20), 500), min(max(rows, 5), 300))
            case .startSession(let projectID, let prompt):
                if let id = onStartSession?(projectID, prompt.map { String($0.prefix(20_000)) }) {
                    peer.channel.send(.sessionStarted(sessionID: id))
                }
            case .startShell(let projectID, let command):
                if let id = onStartShell?(projectID, command.map { String($0.prefix(2_000)) }) {
                    peer.channel.send(.sessionStarted(sessionID: id))
                }
            case .pastConversationsRequest(let projectID):
                let channel = peer.channel
                onPastConversations?(projectID) { [queue] items in
                    queue.async { channel.send(.pastConversations(projectID: projectID, items: items)) }
                }
            case .resumeConversation(let projectID, let conversationID):
                if let id = onResumeConversation?(projectID, conversationID) {
                    peer.channel.send(.sessionStarted(sessionID: id))
                }
            case .interrupt(let sessionID):
                onInterrupt?(sessionID)
            case .listDirectory, .readFile, .downloadFile, .uploadFile:
                let channel = peer.channel
                onFileRequest?(message) { [queue] answer in queue.async { channel.send(answer) } }
            case .stopSession(let sessionID):
                onStopSession?(sessionID)
            case .resumeSession(let sessionID):
                onResumeSession?(sessionID)
            case .markSeen(let sessionID):
                onMarkSeen?(sessionID)
            case .sendPrompt(let sessionID, let text) where !text.isEmpty:
                onSendPrompt?(sessionID, String(text.prefix(20_000)))
            case .queuePrompt(let sessionID, let text) where !text.isEmpty:
                onQueuePrompt?(sessionID, String(text.prefix(20_000)))
            case .queueAction(let sessionID, let promptID, let action):
                onQueueAction?(sessionID, promptID, action)
            case .askAgents(let sessionID, let agentIDs, let request):
                onAskAgents?(sessionID, agentIDs, String(request.prefix(4000)))
            case .agentNoteAction(let sessionID, let noteID, let action):
                onAgentNoteAction?(sessionID, noteID, action)
            case .agentRegistration(let agentID, let approve, let url, let authHeader):
                onAgentRegistration?(agentID, approve, url.map { String($0.prefix(4096)) }, authHeader.map { String($0.prefix(AgentCompletion.maxAuthHeader + 1)) })
            case .agentDetails:
                let channel = peer.channel
                onAgentDetails? { [queue] details in queue.async { channel.send(.agentDetailsAre(details)) } }
            case .sendPromptWithFiles(let sessionID, let text, let files)
                where !files.isEmpty && files.reduce(0, { $0 + $1.data.count }) <= RemoteUpload.maxTotalBytes:
                let channel = peer.channel
                onSendPromptWithFiles?(sessionID, String(text.prefix(20_000)), files) { [queue] error in
                    queue.async { channel.send(.promptResult(sessionID: sessionID, error: error)) }
                }
            case .permissionMode(let sessionID, let cycle):
                let channel = peer.channel
                onPermissionMode?(sessionID, cycle) { [queue] mode in
                    queue.async { channel.send(.permissionModeIs(sessionID: sessionID, mode: mode)) }
                }
            case .projectAction(let projectID, let action):
                let channel = peer.channel
                onProjectAction?(projectID, action) { [queue] error in
                    queue.async { channel.send(.projectActionResult(projectID: projectID, error: error)) }
                }
            case .sessionAction(let sessionID, let action):
                onSessionAction?(sessionID, action)
            case .serverPlanRepair(let deploymentID):
                let channel = peer.channel
                onServerPlanRepair?(deploymentID) { [queue] sessionID, error in
                    queue.async { channel.send(.serverPlanRepairResult(deploymentID: deploymentID, sessionID: sessionID, error: error)) }
                }
            case .answerDecision(let decisionID, let answer) where Decisions.isValidID(decisionID):
                onAnswerDecision?(decisionID, String(answer.prefix(Decisions.maxAnswer)))
            case .dismissDecision(let decisionID) where Decisions.isValidID(decisionID):
                onDismissDecision?(decisionID)
            case .dismissServerIssues(let ids, let all):
                onDismissServerIssues?(Array(ids.prefix(200)), all)
            case .changeDecisionAnswer(let decisionID, let answer) where Decisions.isValidID(decisionID):
                onChangeDecisionAnswer?(decisionID, String(answer.prefix(Decisions.maxAnswer)))
            case .browseFolder(let path):
                let channel = peer.channel
                onBrowseFolder?(path) { [queue] answer in queue.async { channel.send(answer) } }
            case .addProject(let path):
                onAddProject?(path)
            case .pasteFiles(let sessionID, let files)
                where !files.isEmpty && files.reduce(0, { $0 + $1.data.count }) <= RemoteUpload.maxTotalBytes:
                let channel = peer.channel
                onPasteFiles?(sessionID, files) { [queue] error in
                    queue.async { channel.send(.promptResult(sessionID: sessionID, error: error)) }
                }
            case .registerPush(let token, let topic, let environment, let deviceName)
                where !token.isEmpty && !topic.isEmpty && token.count <= Self.maxPushToken && topic.utf8.count <= Self.maxPushTopic:
                peers[id]?.pushToken = token
                onRegisterPush?(PushDevice(token: token, topic: topic, environment: environment == "production" ? "production" : "development", name: String(deviceName.prefix(80)), addedAt: Date()))
            default:
                break
            }
            return
        }
        guard var peer = pending[id] else { return }
        switch message {
        case .hello(let version, let nonce, let deviceName) where peer.remoteNonce == nil:
            guard version == RemoteMessage.protocolVersion else {
                peer.channel.close(refusing: String(localized: "The other Mac runs a different ClaudeDeck version. Update both Macs."))
                return
            }
            guard let key = key(), nonce.count >= 16 else {
                peer.channel.close(refusing: String(localized: "Remote access is off on this Mac."))
                return
            }
            let hostNonce = RemoteHandshake.makeNonce()
            peer.remoteNonce = nonce
            peer.hostNonce = hostNonce
            peer.name = String(deviceName.prefix(80))
            pending[id] = peer
            peer.channel.send(.challenge(nonce: hostNonce))
        case .auth(let proof):
            guard let key = key(), let remoteNonce = peer.remoteNonce, let hostNonce = peer.hostNonce,
                  RemoteHandshake.matches(proof, RemoteHandshake.remoteProof(key: key, remoteNonce: remoteNonce, hostNonce: hostNonce))
            else {
                noteFailure(peer.ip)
                peer.channel.close(refusing: String(localized: "The password or pairing key doesn't match."))
                return
            }
            pending[id] = nil
            peers[id] = Peer(channel: peer.channel, name: peer.name ?? "Mac")
            peer.channel.send(.welcome(proof: RemoteHandshake.hostProof(key: key, remoteNonce: remoteNonce, hostNonce: hostNonce)))
            peer.channel.startEncrypting(RemoteCipher(pairingKey: key, remoteNonce: remoteNonce, hostNonce: hostNonce, role: .host))
            if let snapshot { peer.channel.send(.snapshot(snapshot)) }
            onPeersChanged?(peerNames)
        default:
            peer.channel.close(refusing: String(localized: "Unexpected message during pairing."))
        }
    }

    /// Unfinished handshakes get 10 s; authenticated remotes ping every 20 s.
    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for peer in self.pending.values where now.timeIntervalSince(peer.startedAt) > 10 { peer.channel.close() }
            for peer in self.peers.values where now.timeIntervalSince(peer.channel.lastReceived) > 75 { peer.channel.close() }
            self.resyncDrained()
        }
        timer.resume()
        keepalive = timer
    }
}

// MARK: Remote side

/// The remote's connection to one host. Races every way to it (each address, and for a tailnet
/// address each route): the remembered one starts at once, the others a moment apart, all of
/// them say hello as soon as they connect, and the first to prove the pairing keeps the
/// connection while the rest are called off. One attempt; the caller reconnects.
public final class RemoteHostConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case connected(hostName: String?)
        /// Unreachable or dropped; worth retrying.
        case disconnected(String)
        /// The host said no (wrong key, old version); retrying won't help until something changes.
        case refused(String)
    }

    private let pairing: RemotePairing
    private let deviceName: String
    private let queue: DispatchQueue
    private var channel: RemoteChannel?
    /// In flight, in launch order.
    private var attempts: [Attempt] = []
    /// Ways not started yet, in launch order.
    private var pending: [RemoteCandidate] = []
    /// The attempt whose `auth` is out. One at a time: a wrong proof counts against the Mac's
    /// limit, and the others that got a challenge wait their turn.
    private var authenticating: Attempt?
    private var winner: Attempt?
    private var launchItem: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var ping: DispatchSourceTimer?
    private var finished = false
    private var lastError: String?
    /// A ClaudeDeck answered but the keys didn't match (reported if no way works).
    private var refusal: String?
    /// The address that authenticated.
    public private(set) var connectedAddress: String?
    /// How it was reached.
    public private(set) var connectedRoute: RemoteRoute?

    /// The iPhone/iPad app's in-app Tailscale node, when it's on: tailnet addresses are raced
    /// through it as well as through the system. nil (the setting off, and on the Mac): the system only.
    public var inAppDialer: RemoteDialer?
    /// Dials the system-route candidates instead of NWConnection (tests).
    var systemDialer: RemoteDialer?
    /// Per address, the route to list first among its own.
    public var rememberedRoutes: [String: RemoteRoute] = [:]
    /// The way that worked last for this Mac: started first, without waiting for the stagger.
    public var preferred: RemoteCandidate?
    /// This device's interfaces, to skip ways that can't work from here (a private address on
    /// another subnet, the system's Tailscale with its VPN off). nil: everything is tried.
    public var interfaces: [NetworkInterface]?
    /// Bonjour names advertised on this network now (the others are skipped); nil: not filtered.
    public var advertised: Set<String>?
    /// The in-app node may still be starting: it gets longer than a TCP connect.
    public var inAppTimeout: TimeInterval = 15
    /// TCP connect limits: a local-network address, and any other one through the system (a
    /// tailnet address with the in-app node behind it gets `InAppTailscale.systemTryTimeout`).
    public var lanConnectTimeout: TimeInterval = 3
    public var systemConnectTimeout: TimeInterval = 8
    /// The whole race: nothing in by then, it's over (the caller retries).
    public var overallTimeout: TimeInterval = 30

    public private(set) var state: State = .connecting { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    public var onSnapshot: ((RemoteSnapshot) -> Void)?
    public var onPermissionResult: ((_ sessionID: UUID, _ approve: Bool, _ applied: Bool) -> Void)?
    public var onTerminalStart: ((_ sessionID: UUID, _ cols: Int, _ rows: Int, _ screen: Data) -> Void)?
    public var onTerminalOutput: ((_ sessionID: UUID, _ bytes: Data) -> Void)?
    public var onTerminalEnded: ((_ sessionID: UUID) -> Void)?
    public var onHistory: ((_ sessionID: UUID, _ page: ChatPage) -> Void)?
    /// The host says an open conversation changed (hosts with `Feature.conversationPush`).
    public var onConversationChanged: ((_ sessionID: UUID) -> Void)?
    public var onEdits: ((_ sessionID: UUID, _ page: RemoteEditsPage) -> Void)?
    public var onNetDiff: ((_ sessionID: UUID, _ path: String, _ diff: RemoteNetDiff) -> Void)?
    public var onSessionStarted: ((UUID) -> Void)?
    public var onPromptResult: ((_ sessionID: UUID, _ error: String?) -> Void)?
    public var onProjectActionResult: ((_ projectID: UUID, _ error: String?) -> Void)?
    public var onPermissionMode: ((_ sessionID: UUID, _ mode: String?) -> Void)?
    public var onAgentDetails: ((RemoteAgentDetails) -> Void)?
    /// `.folder` answers (project picker).
    public var onFolder: ((RemoteMessage) -> Void)?
    public var onPastConversations: ((UUID, [RemotePastConversation]) -> Void)?
    /// `.directory` / `.file` / `.fileChunk` / `.uploadAck` answers.
    public var onFileReply: ((RemoteMessage) -> Void)?
    public var onServerPlanRepairResult: ((_ deploymentID: Int, _ sessionID: UUID?, _ error: String?) -> Void)?
    /// Each way tried (or skipped), once it's decided (the phone's Connection Log), with the time
    /// it started. Doesn't change what happens.
    public var onAttemptEnded: ((_ address: String, _ route: RemoteRoute, _ startedAt: Date, _ outcome: RemoteConnectionLog.Outcome) -> Void)?

    /// Per way: pairing must finish within this once it has connected.
    public var handshakeTimeout: TimeInterval = 10
    /// Ways start this far apart (a failed one brings the next forward).
    public var raceStagger: TimeInterval = 0.25
    /// The addresses' order is the user's (Settings › Mac › Addresses): no re-sorting.
    public var keepsOrder = false

    public init(pairing: RemotePairing, deviceName: String, queue: DispatchQueue = .main) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.queue = queue
    }

    /// The ways this race tries, in launch order, and the ones it skips (and why).
    public func plan() -> RemoteRoutePlan.Plan {
        let ordered = keepsOrder ? pairing.addresses : Self.raceOrder(pairing.addresses)
        return RemoteRoutePlan.plan(addresses: ordered, inAppEnabled: inAppDialer != nil, remembered: preferred,
                                    rememberedRoutes: rememberedRoutes, interfaces: interfaces, advertised: advertised)
    }

    public func start() {
        refusal = nil
        attempts = []
        winner = nil
        authenticating = nil
        let plan = plan()
        pending = plan.candidates
        guard !pending.isEmpty, NWEndpoint.Port(rawValue: pairing.port) != nil else {
            end(.disconnected(String(localized: "Couldn't reach the Mac")))
            return
        }
        let now = Date()
        for skipped in plan.skipped {
            onAttemptEnded?(skipped.candidate.address, skipped.candidate.route, now, .skipped(Self.describe(skipped.reason)))
        }
        let item = DispatchWorkItem { [weak self] in self?.timedOut() }
        deadline = item
        queue.asyncAfter(deadline: .now() + overallTimeout, execute: item)
        launchNext()
    }

    /// More ways while the race is on (the in-app node came up, the Mac showed up on this
    /// network): they start now. Ways already in flight or waiting are left as they are.
    public func add(_ candidates: [RemoteCandidate]) {
        guard !finished, winner == nil else { return }
        let fresh = candidates.filter { candidate in
            !pending.contains(candidate) && !attempts.contains { $0.candidate == candidate }
        }
        guard !fresh.isEmpty else { return }
        var unique: [RemoteCandidate] = []
        for candidate in fresh where !unique.contains(candidate) { unique.append(candidate) }
        pending.insert(contentsOf: unique, at: 0)
        launchNext()
    }

    /// Whether a way through `route` is in flight or waiting to start.
    public func isTrying(_ route: RemoteRoute) -> Bool {
        attempts.contains { $0.candidate.route == route } || pending.contains { $0.route == route }
    }

    public func close() {
        finished = true
        launchItem?.cancel()
        launchItem = nil
        deadline?.cancel()
        deadline = nil
        ping?.cancel()
        ping = nil
        for attempt in attempts {
            attempt.timer?.cancel()
            if !attempt.authenticated { report(attempt, .cancelled) }
        }
        for attempt in attempts { attempt.channel.close() }
        attempts = []
        pending = []
        winner = nil
        authenticating = nil
        channel?.close()
        channel = nil
    }

    /// Whether the connection still carries traffic (after the app was in the background): a
    /// ping, and anything back from the Mac within `timeout`. On the connection's queue.
    public func probe(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard case .connected = state, let channel else { completion(false); return }
        let sent = Date()
        channel.send(.ping)
        let deadline = sent.addingTimeInterval(timeout)
        func check() {
            guard !finished, self.channel === channel else { completion(false); return }
            if channel.lastReceived >= sent { completion(true); return }
            guard Date() < deadline else { completion(false); return }
            queue.asyncAfter(deadline: .now() + 0.05) { check() }
        }
        queue.asyncAfter(deadline: .now() + 0.05) { check() }
    }

    @discardableResult
    public func openTerminal(_ sessionID: UUID) -> Bool { sendIfConnected(.terminalOpen(sessionID: sessionID)) }

    @discardableResult
    public func closeTerminal(_ sessionID: UUID) -> Bool { sendIfConnected(.terminalClose(sessionID: sessionID)) }

    @discardableResult
    public func sendInput(_ sessionID: UUID, data: Data) -> Bool { sendIfConnected(.terminalInput(sessionID: sessionID, data: data)) }

    /// Any message, while connected.
    @discardableResult
    public func send(_ message: RemoteMessage) -> Bool { sendIfConnected(message) }

    private func sendIfConnected(_ message: RemoteMessage) -> Bool {
        guard case .connected = state, let channel else { return false }
        channel.send(message)
        return true
    }

    public func sendPermission(sessionID: UUID, stamp: Double, approve: Bool) -> Bool {
        guard case .connected = state, let channel else { return false }
        channel.send(.permission(sessionID: sessionID, stamp: stamp, approve: approve))
        return true
    }

    /// One way being tried: connects, says hello, and (when its turn comes) proves the pairing.
    private final class Attempt {
        let candidate: RemoteCandidate
        let channel: RemoteChannel
        var ready = false
        var nonce = Data()
        var hostNonce: Data?
        var authSent = false
        var authenticated = false
        /// A ClaudeDeck answered and said no: another way to the same address won't help.
        var refused = false
        /// Why it's being closed (a timeout, a refusal), for the log.
        var failure: String?
        /// The connect, then the handshake limit.
        var timer: DispatchWorkItem?
        let startedAt = Date()
        /// Already in the connection log.
        var reported = false
        init(candidate: RemoteCandidate, channel: RemoteChannel) {
            self.candidate = candidate
            self.channel = channel
        }
    }

    /// The Mac's published addresses: its own order (Settings › Remote › Addresses) first, then
    /// the found ones it doesn't list.
    public static func publishedOrder(custom: [String], found: [String]) -> [String] {
        let custom = custom.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return custom + found.filter { !custom.contains($0) }
    }

    /// This network first (Bonjour names, private IPs), Tailscale last: a 100.x address with
    /// Tailscale off only times out.
    public static func raceOrder(_ addresses: [String]) -> [String] {
        func rank(_ address: String) -> Int {
            if RemoteBonjour.serviceName(of: address) != nil { return 0 }
            let lower = address.lowercased()
            if lower.hasSuffix(".ts.net") || lower.hasPrefix("fd7a:115c:a1e0") { return 2 }
            let octets = address.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4 {
                if octets[0] == 100, (64...127).contains(octets[1]) { return 2 }
                if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) { return 0 }
            }
            if lower.hasSuffix(".local") { return 0 }
            return 1
        }
        return addresses.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// How long a way gets to connect.
    func connectTimeout(for candidate: RemoteCandidate) -> TimeInterval {
        if candidate.route == .inApp { return inAppTimeout }
        if InAppTailscale.isTailnetAddress(candidate.address) {
            return inAppDialer != nil ? InAppTailscale.systemTryTimeout : systemConnectTimeout
        }
        if RemoteConnectionLog.Route.isLocal(candidate.address) { return lanConnectTimeout }
        return systemConnectTimeout
    }

    static func describe(_ reason: RemoteRoutePlan.SkipReason) -> String {
        switch reason {
        case .otherNetwork: String(localized: "Not on this network")
        case .noTailscaleVPN: String(localized: "The Tailscale VPN is off")
        case .notAdvertising: String(localized: "The Mac isn't on this network")
        }
    }

    /// Starts the next way; another follows `raceStagger` later unless one is in.
    private func launchNext() {
        launchItem?.cancel()
        launchItem = nil
        guard !finished, winner == nil, !pending.isEmpty else { return }
        startAttempt(pending.removeFirst())
        guard !pending.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in self?.launchNext() }
        launchItem = item
        queue.asyncAfter(deadline: .now() + raceStagger, execute: item)
    }

    private func startAttempt(_ candidate: RemoteCandidate) {
        guard let port = NWEndpoint.Port(rawValue: pairing.port) else { return }
        let timeout = connectTimeout(for: candidate)
        let channel: RemoteChannel
        if candidate.route == .inApp, let inAppDialer {
            channel = RemoteChannel(dialer: inAppDialer, host: candidate.address, port: pairing.port, timeout: timeout, queue: queue)
        } else if let systemDialer {
            channel = RemoteChannel(dialer: systemDialer, host: candidate.address, port: pairing.port, timeout: timeout, queue: queue)
        } else {
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            let endpoint: NWEndpoint = RemoteBonjour.serviceName(of: candidate.address).map(RemoteBonjour.endpoint(serviceName:))
                ?? .hostPort(host: NWEndpoint.Host(candidate.address), port: port)
            channel = RemoteChannel(connection: NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp)), queue: queue)
        }
        let attempt = Attempt(candidate: candidate, channel: channel)
        attempts.append(attempt)
        // Our own limit as well: a Bonjour name that never resolves never fails by itself.
        arm(attempt, after: timeout + 0.5, reason: String(localized: "Couldn't reach the Mac"))
        attempt.channel.onReady = { [weak self, weak attempt] in
            guard let self, let attempt, !self.finished, self.winner == nil else { return }
            attempt.ready = true
            self.sayHello(attempt)
        }
        attempt.channel.onMessage = { [weak self, weak attempt] message in
            guard let self, let attempt, !self.finished, self.winner == nil || attempt === self.winner else { return }
            self.handle(message, from: attempt)
        }
        attempt.channel.onFrame = { [weak self, weak attempt] frame in
            guard let self, let attempt, attempt === self.winner, attempt.authenticated,
                  let output = RemoteTerminalOutput.decode(frame) else { return }
            self.onTerminalOutput?(output.sessionID, output.bytes)
        }
        attempt.channel.onClose = { [weak self, weak attempt] reason in
            guard let self, let attempt, !self.finished, self.attempts.contains(where: { $0 === attempt }) else { return }
            self.attempts.removeAll { $0 === attempt }
            attempt.timer?.cancel()
            if attempt.authenticated {
                self.end(.disconnected(reason ?? String(localized: "Connection closed")))
                return
            }
            // Its own reason: a timeout or refusal set before closing, else what the network said.
            let why = attempt.failure ?? reason ?? String(localized: "Couldn't reach the Mac")
            self.lastError = why
            self.report(attempt, attempt.refused ? .refused(why) : .failed(why))
            // That address answered and said no: its other route won't do better.
            if attempt.refused { self.pending.removeAll { $0.address == attempt.candidate.address } }
            if attempt === self.authenticating {
                self.authenticating = nil
                self.authenticateNext()
            }
            self.continueRace()
        }
        attempt.channel.start()
    }

    /// Closes the attempt after `delay` unless something cancels the timer first.
    private func arm(_ attempt: Attempt, after delay: TimeInterval, reason: String) {
        attempt.timer?.cancel()
        let item = DispatchWorkItem { [weak self, weak attempt] in
            guard let self, let attempt, !self.finished, !attempt.authenticated,
                  self.attempts.contains(where: { $0 === attempt }) else { return }
            attempt.failure = reason
            attempt.channel.close()
        }
        attempt.timer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Connected: hello at once (every way, in parallel), and the handshake must finish in
    /// `handshakeTimeout`. An address can accept TCP and never answer (a stale route, another
    /// device on the same subnet, a listener that never reads): that only costs this way.
    private func sayHello(_ attempt: Attempt) {
        attempt.nonce = RemoteHandshake.makeNonce()
        attempt.channel.send(.hello(version: RemoteMessage.protocolVersion, nonce: attempt.nonce, deviceName: deviceName))
        arm(attempt, after: handshakeTimeout, reason: String(localized: "The other Mac didn't answer"))
    }

    /// The first way to get a challenge proves the pairing; the next one only if it fails.
    private func authenticateNext() {
        guard !finished, winner == nil, authenticating == nil,
              let next = attempts.first(where: { $0.hostNonce != nil && !$0.authSent }), let hostNonce = next.hostNonce else { return }
        authenticating = next
        next.authSent = true
        next.channel.send(.auth(proof: RemoteHandshake.remoteProof(key: pairing.key, remoteNonce: next.nonce, hostNonce: hostNonce)))
    }

    /// A way failed: the next one starts now; nothing left in flight or waiting: give up.
    private func continueRace() {
        guard !finished, winner == nil else { return }
        if !pending.isEmpty {
            launchNext()
        } else if attempts.isEmpty {
            end(refusal.map { .refused($0) } ?? .disconnected(lastError ?? String(localized: "Couldn't reach the Mac")))
        }
    }

    /// Nothing got in within `overallTimeout`: every way still trying failed.
    private func timedOut() {
        guard !finished, winner == nil else { return }
        let reason = String(localized: "Couldn't reach the Mac")
        for attempt in attempts { report(attempt, .failed(attempt.ready ? String(localized: "The other Mac didn't answer") : reason)) }
        end(refusal.map { .refused($0) } ?? .disconnected(lastError ?? reason))
    }

    /// In: this way keeps the connection, the others close (logged as not needed, now).
    private func won(_ attempt: Attempt) {
        attempt.authenticated = true
        attempt.timer?.cancel()
        winner = attempt
        authenticating = nil
        launchItem?.cancel()
        launchItem = nil
        deadline?.cancel()
        deadline = nil
        report(attempt, .connected)
        channel = attempt.channel
        let others = attempts.filter { $0 !== attempt }
        attempts = [attempt]
        pending = []
        for other in others {
            other.timer?.cancel()
            report(other, .cancelled)
            other.channel.close()
        }
    }

    private func report(_ attempt: Attempt, _ outcome: RemoteConnectionLog.Outcome) {
        guard !attempt.reported else { return }
        attempt.reported = true
        onAttemptEnded?(attempt.candidate.address, attempt.candidate.route, attempt.startedAt, outcome)
    }

    private func handle(_ message: RemoteMessage, from attempt: Attempt) {
        let channel = attempt.channel
        let authenticated = attempt.authenticated
        switch message {
        case .challenge(let hostNonce) where !authenticated && attempt.hostNonce == nil && !attempt.nonce.isEmpty:
            attempt.hostNonce = hostNonce
            authenticateNext()
        case .welcome(let proof) where !authenticated && attempt === authenticating:
            guard let hostNonce = attempt.hostNonce,
                  RemoteHandshake.matches(proof, RemoteHandshake.hostProof(key: self.pairing.key, remoteNonce: attempt.nonce, hostNonce: hostNonce))
            else {
                // Not the Mac it claims to be: the other ways go on.
                let reason = String(localized: "The other Mac has a different password or pairing key.")
                self.refusal = reason
                attempt.refused = true
                attempt.failure = reason
                channel.close()
                return
            }
            self.won(attempt)
            channel.startEncrypting(RemoteCipher(pairingKey: self.pairing.key, remoteNonce: attempt.nonce, hostNonce: hostNonce, role: .remote))
            self.connectedAddress = attempt.candidate.address
            self.connectedRoute = attempt.candidate.route
            self.state = .connected(hostName: nil)
            self.startPing()
        case .snapshot(let snapshot) where authenticated:
            self.state = .connected(hostName: snapshot.hostName)
            self.onSnapshot?(snapshot)
        case .permissionResult(let id, let approve, let applied) where authenticated:
            self.onPermissionResult?(id, approve, applied)
        case .terminalStart(let id, let cols, let rows, let screen) where authenticated:
            self.onTerminalStart?(id, cols, rows, screen)
        case .terminalEnded(let id) where authenticated:
            self.onTerminalEnded?(id)
        case .history(let id, let page) where authenticated:
            self.onHistory?(id, page)
        case .conversationChanged(let id) where authenticated:
            self.onConversationChanged?(id)
        case .edits(let id, let page) where authenticated:
            self.onEdits?(id, page)
        case .netDiff(let id, let path, let diff) where authenticated:
            self.onNetDiff?(id, path, diff)
        case .sessionStarted(let id) where authenticated:
            self.onSessionStarted?(id)
        case .projectActionResult(let id, let error) where authenticated:
            self.onProjectActionResult?(id, error)
        case .promptResult(let id, let error) where authenticated:
            self.onPromptResult?(id, error)
        case .permissionModeIs(let id, let mode) where authenticated:
            self.onPermissionMode?(id, mode)
        case .agentDetailsAre(let details) where authenticated:
            self.onAgentDetails?(details)
        case .folder where authenticated:
            self.onFolder?(message)
        case .pastConversations(let projectID, let items) where authenticated:
            self.onPastConversations?(projectID, items)
        case .directory, .file, .fileChunk, .uploadAck:
            if authenticated { self.onFileReply?(message) }
        case .serverPlanRepairResult(let id, let sessionID, let error) where authenticated:
            self.onServerPlanRepairResult?(id, sessionID, error)
        case .refused(let reason):
            if authenticated {
                self.end(.refused(reason))
            } else {
                self.refusal = reason
                attempt.refused = true
                attempt.failure = reason
                channel.close()
            }
        default:
            break
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.channel else { return }
            if Date().timeIntervalSince(channel.lastReceived) > 50 {
                self.end(.disconnected(String(localized: "The other Mac stopped answering")))
                return
            }
            channel.send(.ping)
        }
        timer.resume()
        ping = timer
    }

    private func end(_ final: State) {
        guard !finished else { return }
        state = final
        close()
    }
}
