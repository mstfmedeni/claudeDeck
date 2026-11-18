import AppKit
import ClaudeDeckCore
import Foundation
import Observation
import ServiceManagement

/// The app's side of the session helper (`claudedeck-ptyd`, Settings › Sessions › "Keep sessions
/// running when ClaudeDeck quits"): finds or starts the helper, keeps the connection, and tells
/// AppModel which sessions to attach instead of starting (PtydLaunchPlan).
///
/// The helper runs as a launch agent registered with SMAppService (the plist ships in
/// Contents/Library/LaunchAgents), so macOS lists it under ClaudeDeck in Login Items and the
/// sessions keep ClaudeDeck's privacy permissions. In demo mode, with CLAUDEDECK_DATA_DIR set,
/// or when the build has no plist, it runs as a detached child process instead (no launchd).
@MainActor
@Observable
final class PtydController {
    enum Mode: Equatable {
        case launchAgent
        case child
    }

    private(set) var state: PtydHelperState = .unknown
    @ObservationIgnored private(set) var client: PtydClient?
    /// The connected helper's build (shown in Settings).
    private(set) var helperBuild: String?
    /// Something the user should know (approval needed, the helper couldn't start).
    private(set) var problem: String?
    /// Sessions of this deck left alone because it can't be told whether they still run.
    var held: [UUID: PtydGate.HoldReason] = [:]
    /// Alive in the helper, but not a session of this deck.
    private(set) var orphans: [PtydSessionInfo] = []
    /// Set once the launch-time check is done; until then nothing that might be in the helper starts.
    private(set) var prepared = false
    /// A restart of the helper is under way.
    private(set) var restarting = false

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let paths = PtydPaths.default()
    @ObservationIgnored let mode: Mode
    @ObservationIgnored private var deferred: [() -> Void] = []
    @ObservationIgnored private var liveSessions: [String: PtydSessionInfo] = [:]
    @ObservationIgnored private var childPID: pid_t = 0
    @ObservationIgnored private var childExitSource: DispatchSourceProcess?

    nonisolated static let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"

    var label: String { PtydPaths.label(bundleID: Bundle.main.bundleIdentifier ?? "ClaudeDeck", demo: AppModel.isDemo) }
    var plistName: String { label + ".plist" }

    init() {
        let env = ProcessInfo.processInfo.environment
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/"
            + PtydPaths.label(bundleID: Bundle.main.bundleIdentifier ?? "ClaudeDeck", demo: false) + ".plist")
        // Demo mode and custom data folders never touch launchd.
        if AppModel.isDemo || env["CLAUDEDECK_DATA_DIR"] != nil || env["CLAUDEDECK_PTYD_CHILD"] == "1"
            || !FileManager.default.fileExists(atPath: bundled.path) {
            mode = .child
        } else {
            mode = .launchAgent
        }
    }

    var isConnected: Bool { client != nil }
    var isReadOnly: Bool { client?.compatibility == .readOnly }
    var aliveCount: Int { liveSessions.values.filter(\.alive).count }

    /// Where new sessions run: the helper when the setting is on and it can be driven, else nil
    /// (in the app, as before).
    func clientForNewSessions(enabled: Bool) -> PtydClient? {
        guard enabled, let client, client.isFull else { return nil }
        return client
    }

    func gate(for session: DeckSession) -> PtydGate {
        PtydLaunchPlan.gate(sessionID: session.id, host: session.helperHost, helper: state,
                            processAlive: PtydLaunchPlan.processAlive)
    }

    /// Runs `work` once the launch-time check is done (right away if it is).
    func whenPrepared(_ work: @escaping @MainActor () -> Void) {
        if prepared { work() } else { deferred.append(work) }
    }

    // MARK: Launch

    /// At launch, before any session starts: talk to a running helper, or start one when the
    /// setting is on. `needed`: the deck has sessions that ran in a helper.
    func prepare(enabled: Bool, needed: Bool) async {
        defer {
            prepared = true
            let work = deferred
            deferred = []
            work.forEach { $0() }
        }
        guard enabled || needed || FileManager.default.fileExists(atPath: paths.socket.path) else {
            state = .gone
            return
        }
        await connect(startIfNeeded: enabled)
    }

    /// One connection attempt at a time (launch, a dropped connection and a restart may overlap).
    @ObservationIgnored private var connecting: Task<Void, Never>?

    private func connect(startIfNeeded: Bool) async {
        if let connecting {
            await connecting.value
            if client != nil || !startIfNeeded { return }
        }
        let task = Task { @MainActor in await self.connectNow(startIfNeeded: startIfNeeded) }
        connecting = task
        await task.value
        connecting = nil
    }

    private func connectNow(startIfNeeded: Bool) async {
        if let found = await tryConnect(for: .seconds(1)) {
            await adopt(found, startIfNeeded: startIfNeeded)
            return
        }
        if paths.helperHoldsLock() {
            // Alive but not answering (or still starting): wait a little longer before giving up.
            if let late = await tryConnect(for: .seconds(4)) {
                await adopt(late, startIfNeeded: startIfNeeded)
            } else {
                setState(.unresponsive)
            }
            return
        }
        guard startIfNeeded else {
            setState(.gone)
            return
        }
        guard startHelper(), let started = await tryConnect(for: .seconds(6)) else {
            setState(paths.helperHoldsLock() ? .unresponsive : .gone)
            return
        }
        await adopt(started, startIfNeeded: startIfNeeded)
    }

    /// Takes a fresh connection into use. An outdated helper with nothing running is replaced
    /// by this build's; one with live sessions keeps serving them.
    private func adopt(_ candidate: PtydClient, startIfNeeded: Bool) async {
        let sessions = (try? await candidate.list()) ?? []
        let alive = sessions.filter(\.alive)
        let outdated = candidate.welcome.build != Self.appBuild || !candidate.isFull
        if outdated, alive.isEmpty, startIfNeeded, candidate.isFull {
            ptydLog.info("replacing helper build \(candidate.welcome.build, privacy: .public) with \(Self.appBuild, privacy: .public)")
            candidate.shutdown()
            if await waitForLockRelease(.seconds(6)) {
                candidate.close()
                kickstart()
                if mode == .child { _ = startHelper() }
                if let fresh = await tryConnect(for: .seconds(6)) {
                    install(fresh, sessions: (try? await fresh.list()) ?? [])
                    return
                }
            }
            setState(paths.helperHoldsLock() ? .unresponsive : .gone)
            return
        }
        if outdated, !alive.isEmpty {
            ptydLog.info("helper build \(candidate.welcome.build, privacy: .public) keeps serving \(alive.count) sessions")
        }
        install(candidate, sessions: sessions)
    }

    private func install(_ connected: PtydClient, sessions: [PtydSessionInfo]) {
        connected.onOutput = { [weak self] id, bytes in
            MainActor.assumeIsolated {
                guard let id = UUID(uuidString: id) else { return }
                self?.model?.terminals.helperOutput(id, bytes)
            }
        }
        connected.onExit = { [weak self, weak connected] info in
            MainActor.assumeIsolated {
                guard let self, let connected else { return }
                self.liveSessions[info.id] = info
                self.refreshState()
                self.model?.terminals.helperExited(info, from: connected)
                self.orphans.removeAll { $0.id == info.id }
                self.retireIfDone()
            }
        }
        connected.onDisconnect = { [weak self, weak connected] in
            MainActor.assumeIsolated {
                guard let self, let connected else { return }
                self.connectionLost(connected)
            }
        }
        client = connected
        helperBuild = connected.welcome.build
        problem = nil
        liveSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        refreshState()
        let known = Set(model?.deck.sessions.map(\.id.uuidString) ?? [])
        orphans = sessions.filter { $0.alive && !known.contains($0.id) }
        ptydLog.info("connected to helper \(connected.welcome.instance, privacy: .public) build \(connected.welcome.build, privacy: .public), \(sessions.count) sessions")
        retireIfDone()
    }

    private func setState(_ new: PtydHelperState) {
        if case .live = new {} else {
            client = nil
            helperBuild = nil
            liveSessions = [:]
        }
        state = new
    }

    private func refreshState() {
        guard let client else { return }
        state = .live(instance: client.welcome.instance, compatibility: client.compatibility, sessions: liveSessions)
    }

    /// A session started in (or attached to) the helper.
    func noteSession(_ info: PtydSessionInfo) {
        liveSessions[info.id] = info
        refreshState()
    }

    private func tryConnect(for duration: Duration) async -> PtydClient? {
        let socket = paths.socket
        let deadline = ContinuousClock.now + duration
        repeat {
            let found = await Task.detached { try? PtydClient.connect(socket: socket, build: PtydController.appBuild, timeout: 2) }.value
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        return nil
    }

    private func waitForLockRelease(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while paths.helperHoldsLock() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: Starting the helper

    /// Starts the helper the way this build runs it. False if it couldn't be started.
    @discardableResult
    private func startHelper() -> Bool {
        switch mode {
        case .child:
            return spawnChild()
        case .launchAgent:
            let service = SMAppService.agent(plistName: plistName)
            switch service.status {
            case .enabled:
                kickstart()
                return true
            case .requiresApproval:
                problem = String(localized: "Allow ClaudeDeck in System Settings › General › Login Items to keep sessions running.")
                return false
            default:
                do {
                    try service.register()
                    return true
                } catch {
                    ptydLog.error("helper registration failed: \(error.localizedDescription, privacy: .public)")
                    problem = error.localizedDescription
                    // Still useful until the next restart of the Mac.
                    return spawnChild()
                }
            }
        }
    }

    /// Asks launchd to start the agent now (after an exit it would otherwise wait out its throttle).
    private func kickstart() {
        guard mode == .launchAgent else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// The helper as a detached child process (own session, so quitting or killing the app
    /// leaves it running). It exits by itself after 10 minutes with no sessions and no app.
    private func spawnChild() -> Bool {
        let binary = Bundle.main.bundleURL.appending(path: "Contents/MacOS/claudedeck-ptyd").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            problem = String(localized: "The session helper is missing from this copy of ClaudeDeck.")
            return false
        }
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let args = [binary, "--dir", paths.directory.path, "--idle-exit", "600"]
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        let argv = args.map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, binary, &actions, &attributes, argv, env)
        guard result == 0 else {
            problem = String(cString: strerror(result))
            return false
        }
        childPID = pid
        // Reap it if it exits while the app runs (after a quit, launchd does).
        childExitSource = Self.reapWhenExits(pid)
        ptydLog.info("started helper as a child process (pid \(pid))")
        return true
    }

    /// Not main-actor isolated: the handler runs on a background queue.
    private nonisolated static func reapWhenExits(_ pid: pid_t) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { @Sendable in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        source.activate()
        return source
    }

    // MARK: Helper gone

    /// The connection dropped: the helper quit, crashed or was restarted. Its sessions get
    /// SIGHUP and end; once they're gone, AppModel resumes them (never twice: see PtydLaunchPlan).
    private func connectionLost(_ lostClient: PtydClient) {
        guard client === lostClient else { return }
        ptydLog.error("lost the helper connection")
        client = nil
        helperBuild = nil
        liveSessions = [:]
        state = .unknown
        let lost = model?.terminals.helperLost(lostClient) ?? []
        Task { @MainActor in
            // A helper that's still alive (only the connection broke) is reconnected; a dead one
            // releases its lock within moments.
            let deadline = ContinuousClock.now + .seconds(6)
            var reconnected: PtydClient?
            while ContinuousClock.now < deadline, paths.helperHoldsLock() {
                if let again = await tryConnect(for: .milliseconds(500)) { reconnected = again; break }
            }
            if let reconnected {
                await adopt(reconnected, startIfNeeded: false)
            } else {
                await connect(startIfNeeded: model?.deck.settings.keepSessionsRunning == true)
            }
            await model?.recoverHelperSessions(lost)
        }
    }

    // MARK: Settings

    /// Setting turned on: new sessions run in the helper from now on.
    func enable() async {
        model?.mutate { $0.settings.keepSessionsRunning = true; $0.settings.retireSessionHelper = false }
        problem = nil
        if client == nil { await connect(startIfNeeded: true) }
    }

    /// Setting turned off. `endSessions`: end the helper's sessions now; otherwise they keep
    /// running until they end, and the helper goes away after the last one.
    func disable(endSessions: Bool) async {
        model?.mutate { $0.settings.keepSessionsRunning = false }
        guard let client else {
            unregister()
            return
        }
        if endSessions {
            for id in model?.terminals.helperSessionIDs ?? [] { model?.stop(id) }
            for orphan in orphans {
                client.signal(orphan.id, SIGHUP)
                client.signal(orphan.id, SIGTERM, killAfter: 5)
            }
            orphans = []
        }
        if endSessions || aliveCount == 0 {
            client.shutdown()
            _ = await waitForLockRelease(.seconds(6))
            unregister()
        } else {
            model?.mutate { $0.settings.retireSessionHelper = true }
            client.drain()
        }
    }

    /// Turned off while sessions ran: once the last one has ended, remove the launch agent.
    private func retireIfDone() {
        guard let model, model.deck.settings.retireSessionHelper, !model.deck.settings.keepSessionsRunning,
              aliveCount == 0 else { return }
        model.mutate(userInitiated: false) { $0.settings.retireSessionHelper = false }
        client?.shutdown()
        unregister()
    }

    private func unregister() {
        guard mode == .launchAgent else { return }
        let service = SMAppService.agent(plistName: plistName)
        guard service.status != .notRegistered, service.status != .notFound else { return }
        // Only ever with no live session: unregistering stops the helper (SIGTERM).
        guard aliveCount == 0 else { return }
        Task {
            do {
                try await service.unregister()
            } catch {
                ptydLog.error("helper unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// "Restart helper (restarts sessions)": ends every session in the helper and starts this
    /// build's helper; the sessions then come back the way they do after a crash (resumed).
    func restartHelper() async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        var toRecover = Array(held.keys)
        held = [:]
        if let client {
            // Taken off the helper first: their exits during the shutdown are an interruption to
            // recover from, not the end of the session.
            toRecover += model?.terminals.helperLost(client) ?? []
            client.shutdown()
        } else if paths.helperHoldsLock(), let pid = paths.lockHolderPID() {
            kill(pid, SIGTERM)
        }
        guard await waitForLockRelease(.seconds(8)) else {
            problem = String(localized: "The session helper didn't stop.")
            return
        }
        // The dropped connection starts the new helper too; `connect` runs one attempt at a time.
        await connect(startIfNeeded: model?.deck.settings.keepSessionsRunning == true)
        await model?.recoverHelperSessions(toRecover)
    }

    /// Ends the sessions running in the helper that this deck doesn't know.
    func endOrphans() {
        guard let client, client.isFull else { return }
        for orphan in orphans {
            client.signal(orphan.id, SIGHUP)
            client.signal(orphan.id, SIGTERM, killAfter: 5)
        }
        orphans = []
    }

    /// On quit: disconnect; the helper keeps every session running.
    func detachForQuit() {
        client?.onDisconnect = nil
        client?.close()
        client = nil
    }
}
