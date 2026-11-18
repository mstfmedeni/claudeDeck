import Foundation
import Network
import Observation
import UIKit
import UserNotifications

/// The phone's side of remote mode: one paired Mac, connected while the app is in front.
/// iOS closes sockets in the background; notifications then come from the Mac through APNs.
@MainActor
@Observable
final class RemoteStore {
    enum Connection: Equatable {
        case unpaired
        /// The app isn't in front.
        case paused
        case connecting
        case connected
        case retrying(String, at: Date)
        case refused(String)
    }

    private(set) var pairing: RemotePairing?
    private(set) var connection: Connection
    private(set) var snapshot: RemoteSnapshot?
    /// Prompts answered from here, waiting for the Mac's result.
    private(set) var answering: Set<UUID> = []
    var answerError: String?

    // Conversations (ConversationView).
    struct Conversation: Equatable {
        var entries: [ChatEntry] = []
        var hasMoreBefore = false
        var loaded = false
        /// Tokens in Claude's context (the Mac reads it with the transcript).
        var contextTokens: Int?
        var loadingOlder = false
        /// Agents' notes on the session (the Mac sends the whole list with each page).
        var agentNotes: [AgentNote] = []
    }
    private(set) var conversations: [UUID: Conversation] = [:]
    /// Conversations on screen: kept current and marked seen.
    /// Counted: the same session can be open in two windows.
    @ObservationIgnored private var openConversations: [UUID: Int] = [:]
    /// Polls the open conversations (a Task, not a run-loop timer: it keeps going while a finger
    /// is on the screen).
    @ObservationIgnored private var conversationPoll: Task<Void, Never>?
    /// Conversation requests waiting for the Mac's page, by session: one at a time, the ones asked
    /// for meanwhile (`historyAgain`) go once it's in. One unanswered for long was lost.
    @ObservationIgnored private var historyAsked: [UUID: Date] = [:]
    @ObservationIgnored private var historyAgain: Set<UUID> = []
    /// Open conversations the Mac was told about (`conversationOpen`), on this connection.
    @ObservationIgnored private var announcedConversations: Set<UUID> = []

    // Claude's edits (EditsView, and the diffs in ConversationView); hosts with `Feature.edits`.
    private(set) var edits: [UUID: RemoteEditsState] = [:]
    /// Sessions whose edits are on screen (counted like `openConversations`): only these are asked for.
    @ObservationIgnored private var openEdits: [UUID: Int] = [:]
    @ObservationIgnored private var editsPoll: Task<Void, Never>?
    /// Requests waiting for the Mac's page, by session (one at a time).
    @ObservationIgnored private var editsAsked: [UUID: Date] = [:]

    // Live terminals (RemoteTerminalView).
    enum TerminalState: Equatable { case waiting, live, ended }
    private(set) var terminalStates: [UUID: TerminalState] = [:]
    /// Several per session when it's open in more than one window.
    @ObservationIgnored private var sinks: [UUID: [RemoteTerminalSink]] = [:]

    @ObservationIgnored private var hostConnection: RemoteHostConnection?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: TimeInterval = 2
    @ObservationIgnored private var isActive = false
    /// The app is on screen (scene phase), unlike `isActive`, which a notification action also sets.
    @ObservationIgnored private var inForeground = false
    /// Waiting `answerAndWait` calls (notification actions), by session.
    @ObservationIgnored private var answerWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Called after connecting (push registration, see PushRegistration).
    @ObservationIgnored var onConnected: (() -> Void)?
    /// Claude Code's permission mode per session, as the Mac's screen last showed it.
    private(set) var permissionModes: [UUID: String] = [:]
    /// The Mac's agents and their activity (Agents screen; hosts with `Feature.agentDetails`).
    private(set) var agentDetails: RemoteAgentDetails?
    /// Messages with files on their way, by session (sending a few MB takes a moment).
    private(set) var sendingFiles: Set<UUID> = []
    /// Why the last message with files didn't go in.
    var promptError: String?
    /// The last connection attempts and waits (Settings › Connection Log), in memory only.
    private(set) var connectionLog = RemoteConnectionLog()
    /// Failed deploys whose Fix with Claude the Mac is starting (hosts with `Feature.serverPlanRepair`).
    private(set) var repairingDeploys: Set<Int> = []
    /// Why the Mac couldn't start Fix with Claude (shown, then cleared).
    var serverPlanError: String?

    // Windows (iPad): each keeps its own selection; the store only routes "show this session".
    struct OpenRequest: Equatable {
        let session: UUID
        /// The window that should show it; nil: whichever window takes it first.
        let scene: UUID?
        let token = UUID()
    }
    var openRequest: OpenRequest?
    /// Addresses to try in this order (Settings › Mac › Addresses); empty: automatic (this
    /// network first, Tailscale last). Changing it reconnects.
    var addressOrder: [String] = UserDefaults.standard.stringArray(forKey: RemoteStore.addressOrderKey) ?? [] {
        didSet {
            guard addressOrder != oldValue else { return }
            UserDefaults.standard.set(addressOrder, forKey: Self.addressOrderKey)
            if isActive, pairing != nil, !isRefused { reconnect() }
        }
    }
    static let addressOrderKey = "remote.addressOrder"

    /// The Mac set the order of its addresses (Settings › Remote › Addresses on the Mac): tried as
    /// listed, unless this device has its own order. Kept for launches before the first snapshot.
    var macOrdered: Bool = UserDefaults.standard.bool(forKey: RemoteStore.macOrderedKey) {
        didSet { UserDefaults.standard.set(macOrdered, forKey: Self.macOrderedKey) }
    }
    static let macOrderedKey = "remote.macOrdered"

    /// The order addresses are tried in now (the user's, or the automatic one).
    var addressesInOrder: [String] {
        guard let pairing else { return [] }
        let effective = effectivePairing(pairing).addresses
        return addressOrder.isEmpty && !macOrdered ? RemoteHostConnection.raceOrder(effective) : effective
    }

    /// A project for file requests, or the Mac's home folder (`RemoteFiles.homeID`) as one.
    func fileProject(_ id: UUID) -> RemoteProject? {
        if id == RemoteFiles.homeID, let home = snapshot?.homePath {
            return RemoteProject(id: id, name: (home as NSString).lastPathComponent, path: home)
        }
        return projects.first { $0.id == id }
    }

    /// Simulator testing: a screen for the session list to open (DebugHooks' show.txt).
    var debugScreen: String?

    /// Why the Mac couldn't rename a project's folder (shown, then cleared).
    var projectError: String?

    /// Show the Mac's screen (a `claudedeck://screen` or `vnc://` link).
    var screenRequest: ScreenRequest?
    /// Debug hooks: open a session in a new window.
    var newWindowRequest: OpenRequest?
    /// Open windows and what each shows.
    @ObservationIgnored private(set) var scenes: [UUID: UUID?] = [:]
    /// The window last brought to the front: notification taps open there.
    @ObservationIgnored private(set) var activeScene: UUID?
    /// The window that last started a session: it shows it once the Mac has it.
    @ObservationIgnored private var startingScene: UUID?

    static let deviceName = UIDevice.current.name
    /// Poll intervals (s) with a Mac that pushes conversation changes (`Feature.conversationPush`):
    /// long, to save battery; 4 s without.
    static let pushedConversationPoll: Double = 20
    static let pushedEditsPoll: Double = 15

    var connectedVia: String? { hostConnection?.connectedAddress }
    /// Through the in-app Tailscale node rather than the system's network.
    var connectedInApp: Bool { hostConnection?.connectedRoute == .inApp }

    /// Settings › In-App Tailscale. Off: never started, connections as before.
    let tailnet = InAppTailnet()
    /// Per tailnet address, the way that worked on the current network (system or in-app).
    /// Forgotten when the network changes.
    @ObservationIgnored private var rememberedRoutes: [String: RemoteRoute] = [:]
    /// Watches for network changes (routes to forget, a retry to bring forward).
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkSignature: String?

    /// ClaudeDeck Macs advertising on this network (Bonjour).
    private(set) var lanHosts: [DiscoveredHost] = []
    /// The Local Network permission is off: the Mac at home can't be found directly.
    private(set) var localNetworkDenied = false
    @ObservationIgnored private let discovery = RemoteDiscovery()
    /// The addresses the current connection attempt is racing.
    @ObservationIgnored private var attemptAddresses: Set<String> = []

    init() {
        let saved = PairingKeychain.load()
        pairing = saved
        connection = saved == nil ? .unpaired : .paused
        transfers.send = { [weak self] message in self?.send(message) ?? false }
        transfers.onDownloaded = { Transfers.share($0) }
        transfers.onUploaded = { [weak self] projectID, folder, _ in self?.listDirectory(projectID, path: folder) }
        discovery.onChange = { [weak self] hosts in
            MainActor.assumeIsolated { self?.lanHostsChanged(hosts) }
        }
        discovery.onDeniedChange = { [weak self] denied in
            MainActor.assumeIsolated { self?.localNetworkDenied = denied }
        }
        tailnet.onChange = { [weak self] in self?.tailnetChanged() }
        watchNetwork()
    }

    /// Always on (cheap): a network change while waiting to retry tries again at once.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Which interfaces are up, and how: a new Wi-Fi, cellular, a VPN coming or going.
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            DispatchQueue.main.async { self?.networkChanged(signature) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged(_ signature: String) {
        guard signature != networkSignature else { return }
        let first = networkSignature == nil
        networkSignature = signature
        rememberedRoutes = [:]
        // Wi-Fi back, a VPN up, cellular instead: don't wait out the backoff (up to 30 s). Not on
        // the monitor's first report, which is just the network as it is.
        guard !first, isActive, pairing != nil, case .retrying = connection else { return }
        retryDelay = 2
        reconnect()
    }

    /// The in-app node came up or the setting changed: try again if we aren't connected.
    private func tailnetChanged() {
        rememberedRoutes = [:]
        guard isActive, pairing != nil, !isRefused, connection != .connected else { return }
        retryDelay = 2
        reconnect()
    }

    /// The pairing screen lists Macs on this network before anything is paired.
    func startLANDiscovery() { discovery.start() }

    private func lanHostsChanged(_ hosts: [DiscoveredHost]) {
        lanHosts = hosts
        guard isActive, let pairing, connection != .connected, !isRefused else { return }
        // Just got home: go local if we aren't connected. Mid-attempt too, when the Mac's local
        // address wasn't in it (found after the app came to the front), but once per address set.
        let local = Set(hosts.filter { $0.hostID == pairing.id }.map(\.address))
        if connection != .connecting || (!local.isEmpty && !local.isSubset(of: attemptAddresses)) { reconnect() }
    }

    private var isRefused: Bool { if case .refused = connection { true } else { false } }

    /// The paired Mac's addresses for this attempt: its local-network name first when it's
    /// advertising here, then the stored ones (Tailscale).
    private func effectivePairing(_ pairing: RemotePairing) -> RemotePairing {
        var copy = pairing
        // The user's order (Settings › Mac › Addresses) comes first, as typed; what the Mac
        // reports and doesn't appear there still follows, so a new address isn't lost.
        if !addressOrder.isEmpty {
            copy.addresses = addressOrder + pairing.addresses.filter { !addressOrder.contains($0) && RemoteBonjour.serviceName(of: $0) == nil }
            return copy
        }
        // The Mac's own order: as it listed them, this network's Bonjour name after them.
        if macOrdered {
            let local = lanHosts.filter { $0.hostID == pairing.id }.map(\.address)
            copy.addresses = pairing.addresses + local.filter { !pairing.addresses.contains($0) }
            return copy
        }
        let local = lanHosts.filter { $0.hostID == pairing.id }.map(\.address)
        copy.addresses = local + pairing.addresses.filter { !local.contains($0) }
        return copy
    }

    /// The snapshot says who the Mac is and how to reach it away from home: keep that.
    private func learn(from snapshot: RemoteSnapshot) {
        guard var stored = pairing else { return }
        let before = stored
        if let id = snapshot.hostID { stored.id = id }
        stored.hostName = snapshot.hostName
        if let remote = snapshot.addresses, !remote.isEmpty {
            let bonjour = stored.addresses.filter { RemoteBonjour.serviceName(of: $0) != nil }
            let typed = stored.addresses.filter { RemoteBonjour.serviceName(of: $0) == nil && !remote.contains($0) }
            // Ordered on the Mac: its list as is, the rest after it.
            stored.addresses = snapshot.addressesOrdered == true ? remote + bonjour + typed : bonjour + remote + typed
        }
        if macOrdered != (snapshot.addressesOrdered == true) { macOrdered = snapshot.addressesOrdered == true }
        guard stored != before else { return }
        stored.updatedAt = Date()
        PairingKeychain.save(stored)
        pairing = stored
    }

    // MARK: Pairing

    /// `claudedeck://pair?…` from the QR code, a tapped link or the clipboard.
    @discardableResult
    func pair(link: String) -> Bool {
        guard let pairing = RemotePairing.parse(link: link) else { return false }
        use(pairing)
        return true
    }

    /// The Mac's Tailscale name (or IP) and the password set on it.
    /// A Mac found on this network and the password set on it.
    func pair(lanHost: DiscoveredHost, password: String) {
        var pairing = RemotePairing(
            id: lanHost.hostID ?? UUID(), hostName: lanHost.name, addresses: [lanHost.address], port: RemotePairing.defaultPort,
            key: RemoteHandshake.key(fromPassword: password), updatedAt: Date()
        )
        pairing.hostName = lanHost.name
        use(pairing)
    }

    func pair(host: String, password: String, port: UInt16 = RemotePairing.defaultPort) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairing = RemotePairing(
            id: UUID(), hostName: RemoteBonjour.serviceName(of: address) ?? address, addresses: [address], port: port,
            key: RemoteHandshake.key(fromPassword: password), updatedAt: Date()
        )
        use(pairing)
    }

    private func use(_ pairing: RemotePairing) {
        PairingKeychain.save(pairing)
        self.pairing = pairing
        snapshot = nil
        retryDelay = 2
        reconnect()
    }

    func forget() {
        PairingKeychain.delete()
        addressOrder = []
        macOrdered = false
        close()
        pairing = nil
        snapshot = nil
        connection = .unpaired
    }

    // MARK: Lifecycle

    /// Scene phase: connect in front, let go in the background.
    func setActive(_ active: Bool) {
        inForeground = active
        tailnet.setForeground(active)
        if active { discovery.start() } else { discovery.stop() }
        // After a refusal (wrong password) only a new pairing retries: each attempt counts
        // against the Mac's limit.
        if active, case .refused = connection { isActive = true; return }
        guard active != isActive || (active && connection != .connected && hostConnection == nil) else { return }
        isActive = active
        if active {
            retryDelay = 2
            reconnect()
        } else {
            close()
            if pairing != nil { connection = .paused }
        }
    }

    func reconnect() {
        guard let pairing else { connection = .unpaired; return }
        retryTask?.cancel()
        hostConnection?.close()
        connection = .connecting
        let effective = effectivePairing(pairing)
        attemptAddresses = Set(effective.addresses)
        let next = RemoteHostConnection(pairing: effective, deviceName: Self.deviceName)
        next.keepsOrder = !addressOrder.isEmpty || macOrdered
        if tailnet.enabled {
            next.inAppDialer = tailnet.dialer
            next.rememberedRoutes = rememberedRoutes
            // Start the node now if a tailnet address may need it (signed in before only).
            if effective.addresses.contains(where: InAppTailscale.isTailnetAddress) { tailnet.prewarm() }
        }
        next.onStateChange = { [weak self, weak next] state in
            MainActor.assumeIsolated {
                guard let self, let next, self.hostConnection === next else { return }
                self.connectionChanged(state)
            }
        }
        next.onSnapshot = { [weak self] snapshot in
            MainActor.assumeIsolated { self?.received(snapshot) }
        }
        next.onPermissionResult = { [weak self] id, _, applied in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.answering.remove(id)
                self.answerError = applied ? nil : String(localized: "That prompt was already answered or changed on the other Mac.")
                self.answerWaiters.removeValue(forKey: id)?.resume(returning: applied)
            }
        }
        next.onSessionStarted = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.open(id, in: self.startingScene)
            }
        }
        next.onFolder = { [weak self] message in
            MainActor.assumeIsolated {
                if case .folder(let requested, let path, let names, let error) = message {
                    self?.folders[requested] = FolderState(path: path, folders: names, error: error)
                }
            }
        }
        next.onPermissionMode = { [weak self] id, mode in
            MainActor.assumeIsolated { self?.permissionModes[id] = mode }
        }
        next.onAgentDetails = { [weak self] details in
            MainActor.assumeIsolated { self?.agentDetails = details }
        }
        next.onProjectActionResult = { [weak self] _, error in
            MainActor.assumeIsolated { self?.projectError = error }
        }
        next.onPromptResult = { [weak self] id, error in
            MainActor.assumeIsolated {
                guard let self, self.sendingFiles.remove(id) != nil else { return }
                self.promptError = error
            }
        }
        next.onFileReply = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch message {
                case .directory(let projectID, let path, let entries, let error):
                    self.directories[Self.fileKey(projectID, path)] = DirectoryState(entries: entries, error: error)
                case .file(let projectID, let path, let text, let size, let error):
                    self.files[Self.fileKey(projectID, path)] = FileState(text: text, size: size, error: error)
                case .fileChunk(let projectID, let path, let offset, let total, let data, let error):
                    self.transfers.received(projectID, path: path, offset: offset, total: total, data: data, error: error)
                case .uploadAck(let projectID, let folder, let name, let received, let path, let error):
                    self.transfers.acknowledged(projectID, folder: folder, name: name, received: received, path: path, error: error)
                default: break
                }
            }
        }
        next.onPastConversations = { [weak self] projectID, items in
            MainActor.assumeIsolated { self?.pastConversations[projectID] = items }
        }
        next.onHistory = { [weak self] id, page in
            MainActor.assumeIsolated { self?.received(page, for: id) }
        }
        next.onConversationChanged = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.openConversations[id] != nil { self.requestNewer(id) }
                // New lines may be edits: the Edits view polls slowly with such a Mac.
                if self.openEdits[id] != nil { self.requestEdits(id) }
            }
        }
        next.onEdits = { [weak self] id, page in
            MainActor.assumeIsolated { self?.received(page, for: id) }
        }
        next.onNetDiff = { [weak self] id, path, diff in
            MainActor.assumeIsolated {
                guard let self, self.edits[id] != nil else { return }
                self.edits[id]?.netDiffs[path] = diff
            }
        }
        next.onTerminalStart = { [weak self] id, cols, rows, screen in
            MainActor.assumeIsolated {
                guard let self, let sinks = self.sinks[id] else { return }
                self.terminalStates[id] = .live
                for sink in sinks { sink.start(cols: cols, rows: rows, screen: screen) }
            }
        }
        next.onTerminalOutput = { [weak self] id, bytes in
            MainActor.assumeIsolated { self?.sinks[id]?.forEach { $0.feed(bytes) } }
        }
        next.onTerminalEnded = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, self.sinks[id] != nil else { return }
                self.terminalStates[id] = .ended
            }
        }
        next.onAttemptEnded = { [weak self] address, route, startedAt, outcome in
            MainActor.assumeIsolated { self?.connectionLog.attempt(address: address, route: route, startedAt: startedAt, outcome: outcome) }
        }
        next.onServerPlanRepairResult = { [weak self] deploymentID, sessionID, error in
            MainActor.assumeIsolated { self?.serverPlanRepaired(deploymentID, sessionID: sessionID, error: error) }
        }
        hostConnection = next
        next.start()
    }

    private func close() {
        retryTask?.cancel()
        hostConnection?.close()
        hostConnection = nil
        answering = []
        failAnswerWaiters()
    }

    /// Notification answers waiting for a result that won't come over this connection: not applied.
    private func failAnswerWaiters() {
        let waiters = answerWaiters
        answerWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: false) }
    }

    private func connectionChanged(_ state: RemoteHostConnection.State) {
        switch state {
        case .connecting:
            connection = .connecting
        case .connected:
            connection = .connected
            retryDelay = 2
            if let address = hostConnection?.connectedAddress, let route = hostConnection?.connectedRoute,
               tailnet.enabled, InAppTailscale.isTailnetAddress(address) {
                rememberedRoutes[address] = route
            }
            for id in sinks.keys {
                terminalStates[id] = .waiting
                hostConnection?.openTerminal(id)
                if let grid = fitGrids[id] { hostConnection?.send(.terminalFit(sessionID: id, cols: grid.0, rows: grid.1)) }
            }
            historyAsked = [:]
            historyAgain = []
            announcedConversations = []
            for id in openConversations.keys { requestLatest(id) }
            editsAsked = [:]
            for id in openEdits.keys { requestEdits(id) }
            onConnected?()
        case .disconnected(let reason):
            hostConnection = nil
            answering = []
            failAnswerWaiters()
            announcedConversations = []
            transfers.connectionLost()
            guard isActive else { connection = .paused; return }
            connectionLog.backoff(wait: retryDelay, reason: reason)
            connection = .retrying(reason, at: Date().addingTimeInterval(retryDelay))
            scheduleRetry(after: retryDelay)
            retryDelay = min(retryDelay * 2, 30)
        case .refused(let reason):
            hostConnection = nil
            answering = []
            failAnswerWaiters()
            connection = .refused(reason)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.reconnect()
        }
    }

    private func received(_ new: RemoteSnapshot) {
        let old = snapshot
        let fresh = RemoteSnapshot.newAttention(from: snapshot, to: new)
        snapshot = new
        learn(from: new)
        announceConversations()
        for id in openConversations.keys {
            guard let session = new.session(id) else { continue }
            // Watching it finish here counts as seeing it.
            if session.state == .idle, session.unseen { _ = send(.markSeen(sessionID: id)) }
            if old?.session(id) != session { requestNewer(id) }
        }
        for id in openEdits.keys where old?.session(id) != new.session(id) || old?.supports(RemoteSnapshot.Feature.edits) != true {
            requestEdits(id)
        }
        // A terminal on screen whose command finished: seen, like the Mac's selected terminal.
        for id in sinks.keys { markTerminalSeen(id) }
        answering = answering.filter { new.session($0)?.permissionStamp != nil || new.session($0)?.state == .needsAnswer }
        for session in fresh { LocalAlerts.post(session, hostName: new.hostName) }
    }

    // MARK: Answers

    @discardableResult
    func answer(_ id: UUID, stamp: Double?, approve: Bool) -> Bool {
        guard let stamp, let hostConnection, hostConnection.sendPermission(sessionID: id, stamp: stamp, approve: approve) else { return false }
        answering.insert(id)
        answerError = nil
        return true
    }

    /// Answers Claude's question (one answer per question); the Mac types it into the prompt.
    @discardableResult
    func answerQuestion(_ id: UUID, toolUseID: String, answers: [QuestionAnswer]) -> Bool {
        guard send(.answerQuestion(sessionID: id, toolUseID: toolUseID, answers: answers)) else { return false }
        answering.insert(id)
        answerError = nil
        // A Mac without question support never replies.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.answering.remove(id) != nil else { return }
            self.answerError = String(localized: "The other Mac didn't answer. Update ClaudeDeck on it, or answer in the terminal.")
        }
        return true
    }

    /// For a notification action: connect if needed, answer, wait for the Mac's result.
    func answerAndWait(_ id: UUID, stamp: Double, approve: Bool, timeout: TimeInterval = 20) async -> Bool {
        let applied = await answerConnecting(id, stamp: stamp, approve: approve, timeout: timeout)
        // Answered from the lock screen: let go now. A socket left open until iOS suspends us would
        // make the Mac think this phone is connected and skip its next push.
        if !inForeground {
            close()
            isActive = false
            if pairing != nil, connection == .connected || connection == .connecting { connection = .paused }
        }
        return applied
    }

    private func answerConnecting(_ id: UUID, stamp: Double, approve: Bool, timeout: TimeInterval) async -> Bool {
        if connection != .connected {
            isActive = true
            reconnect()
            let deadline = Date().addingTimeInterval(timeout / 2)
            while connection != .connected, Date() < deadline {
                if case .refused = connection { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let hostConnection, hostConnection.sendPermission(sessionID: id, stamp: stamp, approve: approve) else { return false }
        return await withCheckedContinuation { continuation in
            answerWaiters[id]?.resume(returning: false)
            answerWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout / 2))
                self?.answerWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    // MARK: Sessions

    var projects: [RemoteProject] { snapshot?.projects ?? [] }

    /// A new Claude session in a project on the Mac; it opens here once started.
    func startSession(in projectID: UUID, prompt: String, from scene: UUID? = nil) {
        startingScene = scene
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = send(.startSession(projectID: projectID, prompt: text.isEmpty ? nil : text))
    }

    func stopSession(_ id: UUID) { _ = send(.stopSession(sessionID: id)) }

    func startShell(in projectID: UUID, command: String, from scene: UUID? = nil) {
        startingScene = scene
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = send(.startShell(projectID: projectID, command: text.isEmpty ? nil : text))
    }

    /// The project's past conversations, by project (filled by the Mac's answer).
    private(set) var pastConversations: [UUID: [RemotePastConversation]] = [:]

    func loadPastConversations(_ projectID: UUID) {
        _ = send(.pastConversationsRequest(projectID: projectID))
    }

    func resumeConversation(_ conversationID: String, in projectID: UUID, from scene: UUID? = nil) {
        startingScene = scene
        _ = send(.resumeConversation(projectID: projectID, conversationID: conversationID))
    }

    // MARK: Files (FileBrowser)

    struct DirectoryState: Equatable { var entries: [RemoteFileEntry]; var error: String? }
    struct FileState: Equatable { var text: String?; var size: Int; var error: String? }
    private(set) var directories: [String: DirectoryState] = [:]
    private(set) var files: [String: FileState] = [:]
    /// Downloads and uploads (Browse Files).
    let transfers = RemoteTransferClient()

    static func fileKey(_ projectID: UUID, _ path: String) -> String { "\(projectID.uuidString)/\(path)" }

    func listDirectory(_ projectID: UUID, path: String) {
        _ = send(.listDirectory(projectID: projectID, path: path))
    }

    func readFile(_ projectID: UUID, path: String) {
        _ = send(.readFile(projectID: projectID, path: path))
    }

    /// Esc in a working session.
    func interrupt(_ id: UUID) { _ = send(.interrupt(sessionID: id)) }

    /// Asks the Mac for the session's permission mode; `cycle` presses Shift+Tab first.
    func permissionMode(_ id: UUID, cycle: Bool = false) { _ = send(.permissionMode(sessionID: id, cycle: cycle)) }

    /// The project picker: folders on the Mac by requested path ("" = home).
    struct FolderState: Equatable { var path: String; var folders: [String]; var error: String? }
    private(set) var folders: [String: FolderState] = [:]
    func browseFolder(_ path: String) { _ = send(.browseFolder(path: path)) }
    func addProject(_ path: String) { _ = send(.addProject(path: path)) }

    /// The Mac's session menu (rename, restart, close, start fresh, remove).
    func sessionAction(_ id: UUID, _ action: RemoteSessionAction) { _ = send(.sessionAction(sessionID: id, action: action)) }

    /// The prompt queue (hosts with `Feature.queue`): sent at "your turn", one per turn.
    @discardableResult
    func queuePrompt(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return send(.queuePrompt(sessionID: id, text: trimmed))
    }

    func queueAction(_ id: UUID, prompt: UUID, _ action: QueueAction) {
        _ = send(.queueAction(sessionID: id, promptID: prompt, action: action))
    }

    /// Agents (hosts with `Feature.agents`): ask about a session; notes come with the pages.
    @discardableResult
    func askAgents(_ id: UUID, agents: [UUID], request: String) -> Bool {
        guard !agents.isEmpty else { return false }
        // The Mac bumps the session's notes revision; the snapshot brings the new page.
        return send(.askAgents(sessionID: id, agentIDs: agents, request: request.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The note stays until the Mac's page drops it (or shows why it couldn't send).
    @discardableResult
    func agentNoteAction(_ id: UUID, note: UUID, _ action: AgentNoteAction) -> Bool {
        send(.agentNoteAction(sessionID: id, noteID: note, action: action))
    }

    /// Asks the Mac for its agents and their activity; `agentDetails` updates when it answers.
    @discardableResult
    func loadAgentDetails() -> Bool { send(.agentDetails) }

    /// An agent that signed itself up on the Mac: approve or reject it (the next snapshot drops it).
    @discardableResult
    func agentRegistration(_ id: UUID, approve: Bool, url: String? = nil, authHeader: String? = nil) -> Bool {
        // The header goes only over the encrypted connection; nothing here keeps or logs it.
        send(.agentRegistration(agentID: id, approve: approve, url: url, authHeader: authHeader))
    }

    /// Pin / unpin or rename one of the Mac's projects.
    func projectAction(_ projectID: UUID, _ action: RemoteProjectAction) { _ = send(.projectAction(projectID: projectID, action: action)) }

    /// Clears "your turn" without opening the session.
    func markSeen(_ id: UUID) { _ = send(.markSeen(sessionID: id)) }

    /// A plain terminal's result (Program Status) is seen once its terminal is open here.
    private func markTerminalSeen(_ id: UUID) {
        guard let session = snapshot?.session(id), session.state == .shell, session.unseen,
              program(of: session)?.isOutcome == true else { return }
        markSeen(id)
    }

    /// A terminal's program status, from a Mac with `Feature.programStatus` (states this build knows).
    func program(of session: RemoteSession) -> RemoteProgramStatus? {
        guard session.state == .shell, let program = session.program, ProgramStyle.knows(program),
              snapshot?.supports(RemoteSnapshot.Feature.programStatus) == true else { return nil }
        return program
    }

    // MARK: ServerPlan

    /// Fix with Claude for a failed deploy: the Mac starts the session (its own repair flow) and
    /// the window that asked opens it.
    func fixDeploy(_ deploymentID: Int, from scene: UUID? = nil) {
        guard snapshot?.supports(RemoteSnapshot.Feature.serverPlanRepair) == true, !repairingDeploys.contains(deploymentID),
              send(.serverPlanRepair(deploymentID: deploymentID)) else { return }
        repairingDeploys.insert(deploymentID)
        startingScene = scene
        serverPlanError = nil
        // The log is fetched first; a Mac that never answers frees the button.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.repairingDeploys.remove(deploymentID)
        }
    }

    private func serverPlanRepaired(_ deploymentID: Int, sessionID: UUID?, error: String?) {
        repairingDeploys.remove(deploymentID)
        if let sessionID {
            open(sessionID, in: startingScene)
        } else {
            serverPlanError = error ?? String(localized: "Fix with Claude didn't start on the Mac.")
        }
    }

    func clearConnectionLog() { connectionLog.removeAll() }

    func resumeSession(_ id: UUID, from scene: UUID? = nil) {
        guard send(.resumeSession(sessionID: id)) else { return }
        open(id, in: scene)
    }

    // MARK: Windows

    /// Shows a session in a window (default: the one last in front).
    func open(_ id: UUID, in scene: UUID? = nil) {
        let target = scene ?? activeScene
        openRequest = OpenRequest(session: id, scene: target.flatMap { scenes[$0] != nil ? $0 : nil })
    }

    func sceneAppeared(_ scene: UUID) { if scenes[scene] == nil { scenes[scene] = .some(nil) } }
    func sceneActivated(_ scene: UUID) { activeScene = scene }
    func sceneSelected(_ scene: UUID, session: UUID?) { scenes[scene] = .some(session) }

    func sceneDisappeared(_ scene: UUID) {
        scenes[scene] = nil
        if activeScene == scene { activeScene = nil }
        if startingScene == scene { startingScene = nil }
    }

    // MARK: Conversations

    func openConversation(_ id: UUID) {
        openConversations[id, default: 0] += 1
        _ = send(.markSeen(sessionID: id))
        requestLatest(id)
        announceConversations()
        // Tool results and long answers grow without a state change: check every few seconds,
        // or only now and then when the Mac says when the transcript changes (the poll is the
        // safety net for a notice it couldn't send yet: before a session's first hook).
        if conversationPoll == nil {
            conversationPoll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let pushed = self?.snapshot?.supports(RemoteSnapshot.Feature.conversationPush) == true
                    try? await Task.sleep(for: .seconds(pushed ? RemoteStore.pushedConversationPoll : 4))
                    guard let self, !Task.isCancelled else { return }
                    for id in self.openConversations.keys { self.requestNewer(id) }
                }
            }
        }
    }

    func closeConversation(_ id: UUID) {
        guard let count = openConversations[id] else { return }
        openConversations[id] = count > 1 ? count - 1 : nil
        if openConversations.isEmpty {
            conversationPoll?.cancel()
            conversationPoll = nil
        }
        announceConversations()
    }

    /// Tells a Mac with `Feature.conversationPush` which conversations are open here (their
    /// edits too: the notice brings those as well).
    private func announceConversations() {
        guard hostConnection != nil, snapshot?.supports(RemoteSnapshot.Feature.conversationPush) == true else { return }
        let open = Set(openConversations.keys).union(openEdits.keys)
        for id in open where !announcedConversations.contains(id) {
            if send(.conversationOpen(sessionID: id)) { announcedConversations.insert(id) }
        }
        for id in announcedConversations where !open.contains(id) {
            _ = send(.conversationClose(sessionID: id))
            announcedConversations.remove(id)
        }
    }

    private func requestLatest(_ id: UUID) {
        if send(.historyRequest(sessionID: id, before: nil, after: nil, limit: 80)) { historyAsked[id] = Date() }
    }

    /// What's new since the last request (see `ChatSync.anchor`). One request at a time: asked
    /// again meanwhile, it goes when the page is in.
    private func requestNewer(_ id: UUID) {
        if let asked = historyAsked[id], Date().timeIntervalSince(asked) < 8 {
            historyAgain.insert(id)
            return
        }
        guard let conversation = conversations[id], conversation.loaded,
              let anchor = ChatSync.anchor(conversation.entries, hostSendsUpdates: snapshot?.supports(RemoteSnapshot.Feature.historyUpdates) == true)
        else { requestLatest(id); return }
        if send(.historyRequest(sessionID: id, before: nil, after: anchor, limit: 120)) { historyAsked[id] = Date() }
    }

    func loadOlder(_ id: UUID) {
        guard var conversation = conversations[id], conversation.hasMoreBefore, !conversation.loadingOlder,
              let first = conversation.entries.first else { return }
        conversation.loadingOlder = true
        conversations[id] = conversation
        _ = send(.historyRequest(sessionID: id, before: first.id, after: nil, limit: 80))
    }

    /// Every conversation page as it arrives (DebugHooks' latency log).
    @ObservationIgnored var onHistoryPage: ((UUID, ChatPage) -> Void)?

    private func received(_ page: ChatPage, for id: UUID) {
        onHistoryPage?(id, page)
        var conversation = conversations[id] ?? Conversation()
        let fitted = ChatSync.merge(page, into: &conversation.entries, hasMoreBefore: &conversation.hasMoreBefore)
        if page.before != nil { conversation.loadingOlder = false }
        conversation.loaded = true
        if let tokens = page.contextTokens { conversation.contextTokens = tokens }
        if let notes = page.agentNotes { conversation.agentNotes = notes }
        if conversations[id] != conversation { conversations[id] = conversation }
        guard page.before == nil else { return }
        historyAsked[id] = nil
        guard openConversations[id] != nil else { historyAgain.remove(id); return }
        // After an entry this phone no longer has: start over from the latest page.
        if !fitted {
            historyAgain.remove(id)
            requestLatest(id)
        } else if historyAgain.remove(id) != nil {
            requestNewer(id)
        }
    }

    /// Typed into the session on the Mac (not while it shows a prompt).
    @discardableResult
    func sendPrompt(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, snapshot?.session(id)?.state.isBlocked == false else { return false }
        guard send(.sendPrompt(sessionID: id, text: trimmed)) else { return false }
        // The answer shows up through the conversation updates.
        Task { @MainActor [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                self?.requestNewer(id)
            }
        }
        return true
    }

    /// A message with photos / files: the Mac saves them and puts them in with the text.
    @discardableResult
    func sendPrompt(_ id: UUID, text: String, files: [RemoteUpload]) -> Bool {
        guard !files.isEmpty else { return sendPrompt(id, text: text) }
        guard snapshot?.supports(RemoteSnapshot.Feature.files) == true else {
            promptError = String(localized: "Update ClaudeDeck on the Mac to send photos and files.")
            return false
        }
        guard snapshot?.session(id)?.state.isBlocked == false, !sendingFiles.contains(id) else { return false }
        guard send(.sendPromptWithFiles(sessionID: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), files: files)) else { return false }
        sendingFiles.insert(id)
        promptError = nil
        Task { @MainActor [weak self] in
            // An older Mac skips the message without answering.
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.sendingFiles.remove(id) != nil else { return }
            self.promptError = String(localized: "The other Mac didn't answer. Update ClaudeDeck on it.")
        }
        Task { @MainActor [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(1.5))
                self?.requestNewer(id)
            }
        }
        return true
    }

    // MARK: Edits

    var supportsEdits: Bool { snapshot?.supports(RemoteSnapshot.Feature.edits) == true }

    /// The Edits tab, or the conversation with its diffs, is showing the session: keep its edits current.
    func openEdits(_ id: UUID) {
        openEdits[id, default: 0] += 1
        requestEdits(id)
        announceConversations()
        // Like the conversation: new edits come without a state change.
        if editsPoll == nil {
            editsPoll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    // A Mac that says when the transcript changes brings new edits with that notice.
                    let pushed = self?.snapshot?.supports(RemoteSnapshot.Feature.conversationPush) == true
                    try? await Task.sleep(for: .seconds(pushed ? RemoteStore.pushedEditsPoll : 4))
                    guard let self, !Task.isCancelled else { return }
                    for id in self.openEdits.keys { self.requestEdits(id) }
                }
            }
        }
    }

    func closeEdits(_ id: UUID) {
        guard let count = openEdits[id] else { return }
        openEdits[id] = count > 1 ? count - 1 : nil
        if openEdits.isEmpty {
            editsPoll?.cancel()
            editsPoll = nil
        }
        announceConversations()
    }

    /// The changes after the last one here (only from a Mac that has them).
    private func requestEdits(_ id: UUID) {
        guard supportsEdits else { return }
        // One request at a time; one unanswered for long was lost.
        if let asked = editsAsked[id], Date().timeIntervalSince(asked) < 15 { return }
        if send(.editsRequest(sessionID: id, after: edits[id]?.lastID)) { editsAsked[id] = Date() }
    }

    private func received(_ page: RemoteEditsPage, for id: UUID) {
        editsAsked[id] = nil
        var state = edits[id] ?? RemoteEditsState()
        let fitted = state.merge(page)
        if edits[id] != state { edits[id] = state }
        // More waiting on the Mac (or the page was for another anchor): ask on at once.
        if openEdits[id] != nil, !fitted || state.hasMore { requestEdits(id) }
    }

    /// A changed file's net diff; `edits[id].netDiffs[path]` fills in when the Mac answers.
    func loadNetDiff(_ id: UUID, path: String) {
        guard supportsEdits else { return }
        _ = send(.netDiffRequest(sessionID: id, path: path))
    }

    /// A message to Claude about a change: through the session's queue (in at once on Claude's
    /// turn, else when its turn comes), as on the Mac.
    @discardableResult
    func sendAboutChange(_ id: UUID, text: String) -> Bool {
        if snapshot?.supports(RemoteSnapshot.Feature.queue) == true { return queuePrompt(id, text: text) }
        return sendPrompt(id, text: text)
    }

    // MARK: Terminals

    func attachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        // Opening again gives every view of it a fresh screen, the new one included.
        sinks[id, default: []].append(sink)
        markTerminalSeen(id)
        if terminalStates[id] != .live { terminalStates[id] = .waiting }
        hostConnection?.openTerminal(id)
        if let grid = fitGrids[id] { hostConnection?.send(.terminalFit(sessionID: id, cols: grid.0, rows: grid.1)) }
    }

    func detachTerminal(_ id: UUID, sink: RemoteTerminalSink) {
        guard let views = sinks[id], views.contains(where: { $0 === sink }) else { return }
        let rest = views.filter { $0 !== sink }
        guard rest.isEmpty else {
            sinks[id] = rest
            return
        }
        sinks[id] = nil
        terminalStates[id] = nil
        hostConnection?.closeTerminal(id)
    }

    func sendTerminalInput(_ id: UUID, data: Data) {
        guard terminalStates[id] == .live else { return }
        hostConnection?.sendInput(id, data: data)
    }

    /// Fit mode: size the Mac's terminal to this screen (0 cols gives it back). Re-sent after reconnects.
    func fitTerminal(_ id: UUID, cols: Int, rows: Int) {
        // Closing one of several views keeps the size the others fit.
        if cols == 0, (sinks[id]?.count ?? 0) > 1 { return }
        if cols == 0 { fitGrids[id] = nil } else { fitGrids[id] = (cols, rows) }
        hostConnection?.send(.terminalFit(sessionID: id, cols: cols, rows: rows))
    }
    @ObservationIgnored private var fitGrids: [UUID: (Int, Int)] = [:]

    func redrawTerminal(_ id: UUID) {
        guard sinks[id] != nil else { return }
        hostConnection?.openTerminal(id)
    }

    /// Open terminal views (DebugHooks).
    func debugTerminals() -> [UUID: RemoteTerminalUIView] {
        sinks.compactMapValues { $0.first as? RemoteTerminalUIView }
    }

    /// Sends a message only while connected (push registration).
    func send(_ message: RemoteMessage) -> Bool {
        hostConnection?.send(message) ?? false
    }
}

/// Receives one session's stream.
@MainActor
protocol RemoteTerminalSink: AnyObject {
    func start(cols: Int, rows: Int, screen: Data)
    func feed(_ bytes: Data)
}

/// Banners while the app is open (the Mac's pushes cover the background).
enum LocalAlerts {
    static let permissionCategory = "permission"
    static let approveAction = "approve"
    static let denyAction = "deny"

    static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
            identifier: permissionCategory,
            actions: [
                UNNotificationAction(identifier: approveAction, title: String(localized: "Allow"), options: [.authenticationRequired]),
                UNNotificationAction(identifier: denyAction, title: String(localized: "Deny"), options: [.destructive, .authenticationRequired]),
            ],
            intentIdentifiers: []
        )])
    }

    static func post(_ session: RemoteSession, hostName: String) {
        let content = UNMutableNotificationContent()
        content.title = session.project.isEmpty || session.name.hasPrefix(session.project) ? session.name : "\(session.name) — \(session.project)"
        content.subtitle = hostName
        // A terminal's program status: its detail starts with the badge ("Failed (exit 1) · …").
        let program = session.state == .shell ? session.program.flatMap { ProgramStyle.knows($0) ? $0 : nil } : nil
        if let program {
            content.body = session.detail ?? ProgramStyle.label(program)
        } else {
            content.body = SessionStyle.label(session.state) + (session.detail.map { ": \($0)" } ?? "")
        }
        content.sound = session.state.isBlocked || program?.isBlocked == true ? .default : nil
        content.userInfo = ["sessionID": session.id.uuidString]
        if let stamp = session.permissionStamp {
            content.categoryIdentifier = permissionCategory
            content.userInfo["stamp"] = String(stamp)
        }
        content.threadIdentifier = session.id.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil))
    }
}
