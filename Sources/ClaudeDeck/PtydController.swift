import AppKit
import ClaudeDeckCore
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// The app's side of the session helper (`claudedeck-ptyd`, Settings › Sessions › "Keep sessions
/// running when ClaudeDeck quits"): finds or starts the helper, keeps the connection, and tells
/// AppModel which sessions to attach instead of starting (PtydLaunchPlan).
///
/// The helper runs as a launch agent registered with SMAppService (the plist ships in
/// Contents/Library/LaunchAgents), so macOS lists it under ClaudeDeck in Login Items. Privacy
/// (TCC) is another matter: macOS treats the launch agent as its own responsible process, so
/// ClaudeDeck.app's Full Disk Access / Desktop grants don't cover the sessions in it (verified),
/// and a new grant only applies once the helper process restarts. `checkAccess` compares what the
/// app and the helper can open (PtydAccessProbe) for Settings and the banner. In demo mode, with
/// CLAUDEDECK_DATA_DIR set, or when the build has no plist, it runs as a detached child process
/// instead (no launchd).
///
/// Upgrades: a helper of another build with no live session is replaced at once (`adopt`). One
/// that serves sessions and speaks protocol 3 is asked to `upgrade`: it re-execs itself into the
/// binary now on disk (same pid, same instance, every session kept; PtydHandover), so its code
/// matches its file again and privacy (TCC) grants keep applying. It also does that by itself
/// when it sees its binary replaced. The dropped connection is then carried over to the same
/// helper without stopping anything (`carryOver`). An older helper can't: it is restarted once
/// its sessions are quiet (`scheduleQuietRestart`, on by default), or from the banner; and once
/// its last session ends it is replaced too (`upgradeIfIdle`).
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
    /// What privacy (TCC) lets this app open, and the connected helper (`checkAccess`; nil:
    /// not checked yet). An old helper answers `.unknown`.
    private(set) var appAccess: PtydAccessReport?
    private(set) var helperAccess: PtydAccessReport?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var accessCheck: Task<Void, Never>?

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
        // A grant made in System Settings shows once the user comes back to the app.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessIfRelevant() }
        }
    }

    // MARK: Privacy (TCC)

    /// The helper definitely can't open something the app can (never on an unknown answer).
    var helperLacksAccess: Bool {
        guard let appAccess, let helperAccess else { return false }
        return helperAccess.lacks(comparedTo: appAccess)
    }

    /// Only while sessions run in the helper by the setting: the check is for them.
    private func checkAccessIfRelevant() {
        guard client != nil, model?.deck.settings.keepSessionsRunning == true else { return }
        Task { await checkAccess() }
    }

    /// Runs the probe in the app and in the helper (one check at a time).
    func checkAccess() async {
        if let accessCheck { return await accessCheck.value }
        let task = Task { @MainActor in
            appAccess = await Task.detached { PtydAccessProbe.run() }.value
            helperAccess = await client?.probeAccess()
        }
        accessCheck = task
        await task.value
        accessCheck = nil
    }

    var isConnected: Bool { client != nil }
    /// The connected helper is another build than this app (or can't be fully driven).
    var isOutdated: Bool {
        guard let client else { return false }
        return client.welcome.build != Self.appBuild || !client.isFull
    }
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
        // A helper that answers the handshake but not the list (starved on an overloaded Mac)
        // is unresponsive, never "no sessions": that would mark its live sessions as ended.
        guard let sessions = try? await candidate.list(timeout: 15) else {
            ptydLog.error("the helper didn't list its sessions in time")
            candidate.close()
            setState(paths.helperHoldsLock() ? .unresponsive : .gone)
            return
        }
        let alive = sessions.filter(\.alive)
        let outdated = candidate.welcome.build != Self.appBuild || !candidate.isFull
        if outdated, alive.isEmpty, startIfNeeded {
            ptydLog.info("replacing helper build \(candidate.welcome.build, privacy: .public) with \(Self.appBuild, privacy: .public)")
            stopHelper(candidate)
            if await waitForLockRelease(.seconds(6)) {
                candidate.close()
                kickstart()
                if mode == .child { _ = startHelper() }
                if let fresh = await tryConnect(for: .seconds(6)), let listed = try? await fresh.list(timeout: 15) {
                    install(fresh, sessions: listed)
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
                self?.lastHelperOutput = .now
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
                self.upgradeIfIdle()
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
        // A new helper process (connect, restart, upgrade): its grants may differ from the last one's.
        helperAccess = nil
        checkAccessIfRelevant()
        upgradeOutdatedHelper()
    }

    // MARK: Upgrading in place

    /// Helper builds already asked to upgrade (instance + build): asked once, not in a loop if
    /// it refuses (e.g. this app is the older one).
    @ObservationIgnored private var upgradeAsked: Set<String> = []

    /// The connected helper is another build: one that can swap its code in place is asked to;
    /// one that can't is restarted at a quiet moment (or the banner offers it).
    private func upgradeOutdatedHelper() {
        guard let client, client.isFull, client.welcome.build != Self.appBuild,
              // This app is the older one (the helper already took an update): nothing to ask.
              !PtydUpgradeCheck.isNewer(client.welcome.build, than: Self.appBuild) else { return }
        guard client.supportsUpgrade else {
            scheduleQuietRestart()
            return
        }
        let key = client.welcome.instance + "/" + client.welcome.build
        guard !upgradeAsked.contains(key) else { return }
        upgradeAsked.insert(key)
        ptydLog.info("asking helper build \(client.welcome.build, privacy: .public) to upgrade in place to \(Self.appBuild, privacy: .public)")
        client.upgrade { result in
            switch result {
            case .success:
                // The connection drops in a moment; `connectionLost` carries the sessions over.
                ptydLog.info("the helper is upgrading in place")
            case .failure(let error):
                ptydLog.error("the helper didn't upgrade: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The same helper process answered again after the connection dropped (it re-exec'd into an
    /// update, or only the connection broke): its sessions still run, so they move to the new
    /// connection without stopping (replaying their scrollback). Those it no longer has alive
    /// ended meanwhile and take the usual path. False if it didn't list its sessions.
    private func carryOver(from lost: PtydClient, to fresh: PtydClient) async -> Bool {
        guard let sessions = try? await fresh.list(timeout: 15) else {
            fresh.close()
            return false
        }
        guard client == nil else {
            // Something else connected meanwhile (a restart): it decides.
            fresh.close()
            return false
        }
        install(fresh, sessions: sessions)
        let alive = Dictionary(sessions.filter(\.alive).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var carried = 0
        for id in model?.terminals.helperSessionIDs ?? [] {
            guard let info = alive[id.uuidString] else { continue }
            model?.terminals.attachHelper(id, client: fresh, readOnly: !fresh.isFull, known: info)
            carried += 1
        }
        let rest = model?.terminals.helperLost(lost) ?? []
        ptydLog.info("reattached \(carried) sessions to helper build \(fresh.welcome.build, privacy: .public) (same process); \(rest.count) ended meanwhile")
        // Started while the helper was away (held): decided again now that it answers.
        model?.resolveHeldSessions()
        if !rest.isEmpty { await model?.recoverHelperSessions(rest) }
        return true
    }

    // MARK: Restarting a helper that can't upgrade in place

    /// Settings › Sessions: restart an outdated helper by itself once its sessions are quiet
    /// (default on). Per Mac user, like the banner's dismissal.
    nonisolated static let autoRestartKey = "ptyd.autoRestartOutdatedHelper"
    static var autoRestartOutdated: Bool {
        UserDefaults.standard.object(forKey: autoRestartKey) as? Bool ?? true
    }

    @ObservationIgnored private var lastHelperOutput = ContinuousClock.now
    @ObservationIgnored private var quietRestartTask: Task<Void, Never>?
    /// Waiting for a quiet moment to restart an outdated helper.
    private(set) var awaitingQuietRestart = false

    /// A helper from before in-place upgrades (protocol < 3) runs another build's code and
    /// serves sessions: only a restart (which ends and resumes them) brings this build's helper.
    /// Happens once; every helper from then on upgrades in place.
    var needsRestartToUpgrade: Bool {
        // `state` and `helperBuild` first: they are what views observe (`client` isn't).
        guard case .live(_, _, let sessions) = state, let build = helperBuild, build != Self.appBuild,
              let client, client.isFull, !client.supportsUpgrade else { return false }
        return sessions.values.contains(where: \.alive)
    }

    /// The one-time restart of an outdated helper (PtydMigrationPlan). Its access is probed
    /// first: lost (the update replaced its binary under it, so its sessions already get
    /// "Operation not permitted") means a restart right away, after at most a minute for working
    /// Claude sessions to finish their turn. Otherwise it waits for a quiet moment (no output from
    /// its sessions and no typing for 30 s, no Claude session working, three checks in a row),
    /// 30 minutes at most. Checked every 5 s.
    func scheduleQuietRestart() {
        guard quietRestartTask == nil, needsRestartToUpgrade, Self.autoRestartOutdated,
              model?.deck.settings.keepSessionsRunning == true else { return }
        ptydLog.info("helper build \(self.helperBuild ?? "?", privacy: .public) can't upgrade in place; checking its access before restarting it")
        awaitingQuietRestart = true
        quietRestartTask = Task { @MainActor [weak self] in
            let started = Date()
            var accessLostAt: Date?
            var quietChecks = 0
            if let self, self.helperAccess == nil { await self.checkAccess() }
            while let self, !Task.isCancelled {
                guard self.needsRestartToUpgrade, self.model?.deck.settings.keepSessionsRunning == true else { break }
                let access: PtydMigrationPlan.Access = self.helperLacksAccess ? .lost
                    : self.helperAccess == nil || self.helperAccess?.level == .unknown ? .unknown : .intact
                if access == .lost, accessLostAt == nil {
                    accessLostAt = Date()
                    ptydLog.error("the outdated helper lost disk access after the update; restarting it now")
                }
                quietChecks = self.isQuiet ? quietChecks + 1 : 0
                let decision = PtydMigrationPlan.decide(
                    autoRestart: Self.autoRestartOutdated, access: access,
                    waited: Date().timeIntervalSince(started),
                    accessLostFor: accessLostAt.map { Date().timeIntervalSince($0) },
                    claudeWorking: self.claudeWorkingInHelper, quietChecks: quietChecks)
                if case .restart(let reason) = decision {
                    let count = (self.model?.terminals.helperSessionIDs.count ?? 0) + self.held.count
                    ptydLog.info("restarting the outdated helper build \(self.helperBuild ?? "?", privacy: .public) (\(String(describing: reason), privacy: .public))")
                    await self.restartHelper()
                    Self.notifyHelperRestarted(sessions: count)
                    break
                }
                if decision == .banner { break }
                try? await Task.sleep(for: .seconds(5))
            }
            self?.quietRestartTask = nil
            self?.awaitingQuietRestart = false
        }
    }

    private var claudeWorkingInHelper: Bool {
        guard let model else { return false }
        return model.terminals.helperSessionIDs.contains { model.status(of: $0).display.isRunning }
    }

    /// "ClaudeDeck updated; the session helper was restarted (N sessions resume)", once, after
    /// the automatic migration restart.
    private static func notifyHelperRestarted(sessions: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "ClaudeDeck"
        content.body = String(localized: "ClaudeDeck was updated; the session helper was restarted (\(sessions) sessions resume where they left off).")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ptyd-migration-restart", content: content, trigger: nil))
    }

    private var isQuiet: Bool {
        guard !restarting, held.isEmpty, model != nil, let client else { return false }
        let quietFor: Duration = .seconds(30)
        guard ContinuousClock.now - lastHelperOutput > quietFor else { return false }
        if let typed = client.lastInputAt, Date().timeIntervalSince(typed) < 30 { return false }
        // Claude waiting on a long tool call can be silent: its status still says it's working.
        return !claudeWorkingInHelper
    }

    private func setState(_ new: PtydHelperState) {
        if case .live = new {} else {
            client = nil
            helperBuild = nil
            helperAccess = nil
            liveSessions = [:]
        }
        state = new
        // Alive but not answering (an overloaded Mac): keep trying instead of leaving its
        // sessions held for good.
        if case .unresponsive = new { reconnectWithBackoff() }
    }

    // MARK: Reconnecting

    /// A helper that holds its lock but didn't answer is tried again (2 s, 4 s, 8 s… up to 30 s
    /// apart, with a longer handshake each time) until it answers or is gone. Meanwhile its
    /// sessions stay held ("Connecting to the session helper…"): nothing that may still run there
    /// is started a second time. Once it answers, the held sessions are attached.
    private(set) var reconnecting = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    private func reconnectWithBackoff() {
        guard reconnectTask == nil else { return }
        reconnecting = true
        reconnectTask = Task { @MainActor [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled, self.client == nil {
                attempt += 1
                try? await Task.sleep(for: .seconds(min(30, 1 << min(attempt, 5))))
                guard self.client == nil else { break }
                let handshake = min(15, 2 + Double(attempt) * 2)
                if let found = await self.tryConnect(for: .seconds(1), handshake: handshake) {
                    ptydLog.info("the helper answered after \(attempt) retries")
                    // While this task is set, a failed adopt (unresponsive again) starts no second loop.
                    await self.adopt(found, startIfNeeded: false)
                    if self.client != nil { break }
                    continue
                }
                if !self.paths.helperHoldsLock() {
                    // The helper is gone (crashed, or quit): its sessions take the usual path.
                    ptydLog.info("the unresponsive helper is gone")
                    self.state = .gone
                    break
                }
            }
            self?.reconnectTask = nil
            self?.reconnecting = false
            self?.model?.resolveHeldSessions()
        }
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

    private func tryConnect(for duration: Duration, handshake: TimeInterval = 2) async -> PtydClient? {
        let socket = paths.socket
        let deadline = ContinuousClock.now + duration
        repeat {
            let found = await Task.detached { try? PtydClient.connect(socket: socket, build: PtydController.appBuild, timeout: handshake) }.value
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

    /// Ends the helper process (and with it its sessions). A read-only connection may not ask
    /// it to shut down, so then the lock holder gets SIGTERM; its children get SIGHUP either way.
    private func stopHelper(_ connection: PtydClient?) {
        if let connection, connection.isFull {
            connection.shutdown()
        } else if paths.helperHoldsLock(), let pid = paths.lockHolderPID() {
            kill(pid, SIGTERM)
        }
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

    /// The connection dropped: the helper re-exec'd into an update, quit, crashed or was
    /// restarted. The same helper answering again keeps every session (`carryOver`). Otherwise
    /// its sessions got SIGHUP and end; once they're gone, AppModel resumes them (never twice:
    /// see PtydLaunchPlan).
    private func connectionLost(_ lostClient: PtydClient) {
        guard client === lostClient else { return }
        ptydLog.error("lost the helper connection")
        client = nil
        helperBuild = nil
        helperAccess = nil
        liveSessions = [:]
        state = .unknown
        Task { @MainActor in
            // A helper that's still alive (it re-exec'd, or only the connection broke) is
            // reconnected; a dead one has released its lock already. Meanwhile its sessions stay
            // as they are on screen: nothing is marked stopped for a reconnect.
            let deadline = ContinuousClock.now + .seconds(6)
            var reconnected: PtydClient?
            while ContinuousClock.now < deadline, paths.helperHoldsLock() {
                if let again = await tryConnect(for: .milliseconds(500)) { reconnected = again; break }
            }
            var reusable = reconnected
            if let reconnected, !restarting, reconnected.welcome.instance == lostClient.welcome.instance {
                if await carryOver(from: lostClient, to: reconnected) { return }
                reusable = nil // closed by carryOver
            }
            let lost = model?.terminals.helperLost(lostClient) ?? []
            if let reusable {
                await adopt(reusable, startIfNeeded: false)
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
        if endSessions || aliveCount == 0 || !client.isFull {
            stopHelper(client)
            _ = await waitForLockRelease(.seconds(6))
            liveSessions = [:]
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
        stopHelper(client)
        liveSessions = [:]
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
        }
        stopHelper(client)
        guard await waitForLockRelease(.seconds(8)) else {
            problem = String(localized: "The session helper didn't stop.")
            return
        }
        // The dropped connection starts the new helper too; `connect` runs one attempt at a time.
        await connect(startIfNeeded: model?.deck.settings.keepSessionsRunning == true)
        await model?.recoverHelperSessions(toRecover)
    }

    /// An outdated helper kept serving sessions (`adopt`): once the last one has ended, it is
    /// replaced by this build's, which interrupts nothing. Checked again after a moment, so a
    /// session starting right then isn't caught in the restart.
    private func upgradeIfIdle() {
        guard isOutdated, aliveCount == 0, held.isEmpty, !restarting,
              model?.deck.settings.keepSessionsRunning == true else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isOutdated, self.aliveCount == 0, self.held.isEmpty, !self.restarting,
                  self.model?.deck.settings.keepSessionsRunning == true else { return }
            ptydLog.info("upgrading the idle helper build \(self.helperBuild ?? "?", privacy: .public) to \(Self.appBuild, privacy: .public)")
            await self.restartHelper()
        }
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
