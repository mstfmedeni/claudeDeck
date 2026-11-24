import Darwin
import Foundation
import Testing
@testable import ClaudeDeckCore

/// The helper binary as built next to the tests (`swift test` builds it: the test target depends on it).
let helperBinary: URL? = {
    var dirs = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    dirs += [root.appending(path: ".build/debug"), root.appending(path: ".build/release")]
    return dirs.map { $0.appending(path: "claudedeck-ptyd") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// Collects a session's output; waits for text to show up.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: [UInt8]] = [:]
    private var exits: [String: PtydSessionInfo] = [:]
    private(set) var disconnected = false

    func add(_ id: String, _ chunk: [UInt8]) { lock.withLock { bytes[id, default: []] += chunk } }
    func exited(_ info: PtydSessionInfo) { lock.withLock { exits[info.id] = info } }
    func lost() { lock.withLock { disconnected = true } }
    func text(_ id: String) -> String { lock.withLock { String(decoding: bytes[id] ?? [], as: UTF8.self) } }
    func exit(_ id: String) -> PtydSessionInfo? { lock.withLock { exits[id] } }
    var isDisconnected: Bool { lock.withLock { disconnected } }
}

func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

/// A helper running as a child process in its own temporary folder (never launchd).
final class HelperProcess {
    let dir: URL
    let paths: PtydPaths
    let process = Process()
    /// The helper's stderr (its log), when asked for.
    private(set) var logFile: URL?

    /// - Parameters:
    ///   - binary: the helper to run (default: the one built next to the tests).
    ///   - logging: keep its log in `dir/stderr.log`.
    init(binary: URL? = nil, extra: [String] = [], logging: Bool = false) throws {
        // Short path: Unix socket paths are limited to 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/cdptyd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = PtydPaths(directory: dir)
        try launch(binary: binary, extra: extra, logging: logging)
    }

    init(sharing other: HelperProcess) throws {
        dir = other.dir
        paths = other.paths
        try launch(binary: nil, extra: [], logging: false)
    }

    private func launch(binary: URL?, extra: [String], logging: Bool) throws {
        process.executableURL = try binary ?? #require(helperBinary)
        process.arguments = ["--dir", dir.path, "--build", "test", "--ring-bytes", "65536"] + extra
        if logging {
            let url = dir.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: url)
            logFile = url
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
    }

    var log: String { logFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }

    func waitUntilListening() -> Bool {
        waitFor { (try? PtydClient.connect(socket: self.paths.socket, build: "test", timeout: 1, callbackQueue: DispatchQueue(label: "probe")))
            .map { $0.close(); return true } ?? false }
    }

    func connect(_ collector: Collector) throws -> PtydClient {
        let client = try PtydClient.connect(socket: paths.socket, build: "test", callbackQueue: DispatchQueue(label: "test.client"))
        client.onOutput = { id, bytes in collector.add(id, bytes) }
        client.onExit = { info in collector.exited(info) }
        client.onDisconnect = { collector.lost() }
        return client
    }

    func kill(_ signal: Int32 = SIGKILL) {
        if process.isRunning { Darwin.kill(process.processIdentifier, signal) }
        process.waitUntilExit()
    }

    deinit {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }
}

func sync<T: Sendable>(_ body: (@escaping @Sendable (Result<T, PtydClientError>) -> Void) -> Void) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, PtydClientError>?
    body { result = $0; semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 5) == .success, let result else { throw PtydClientError.timeout }
    return try result.get()
}

func shellSpawn(_ script: String, id: String = UUID().uuidString, env: [String] = [], cwd: String = "/tmp") -> PtydSpawn {
    PtydSpawn(id: id, executable: "/bin/sh", argv: ["sh", "-c", script], env: ["PATH=/usr/bin:/bin"] + env, cwd: cwd,
              cols: 80, rows: 24, meta: ["k": "v"])
}

let tickLoop = #"i=0; while :; do echo "tick $i"; i=$((i+1)); sleep 0.05; done"#

@Suite(.serialized, .enabled(if: helperBinary != nil, "claudedeck-ptyd not built"))
struct PtydIntegrationTests {
    @Test func spawnDetachReattachReplaysScrollback() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let first = Collector()
        var client = try helper.connect(first)
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }
        #expect(info.alive)
        #expect(info.meta == ["k": "v"])
        #expect(waitFor { first.text(spawn.id).contains("tick 3") })

        // Detach (the app quits): the session keeps running in the helper.
        client.close()
        usleep(400_000)
        #expect(kill(info.pid, 0) == 0)

        let second = Collector()
        client = try helper.connect(second)
        let listed = try sync { client.list($0) }
        #expect(listed.map(\.id) == [spawn.id])
        #expect(listed.first?.alive == true)
        let (attached, replay) = try sync { client.attach(spawn.id, $0) }
        #expect(attached.pid == info.pid)
        let replayText = String(decoding: replay, as: UTF8.self)
        #expect(replayText.contains("tick 0"))
        // Output produced while nobody was attached is in the replay.
        let lastReplayed = replayText.components(separatedBy: "tick ").compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? -1
        #expect(lastReplayed > 8)
        // Live output continues right after the replay.
        #expect(waitFor { second.text(spawn.id).contains("tick \(lastReplayed + 2)") })
        #expect(!second.text(spawn.id).contains("tick \(lastReplayed)\r\n") || lastReplayed < 0)
        client.signal(spawn.id, SIGKILL)
        #expect(waitFor { second.exit(spawn.id) != nil })
        helper.kill()
    }

    @Test func childGetsExactEnvironmentAndDirectory() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let dir = helper.dir.appending(path: "work dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let spawn = PtydSpawn(id: UUID().uuidString, executable: "/bin/sh",
                              argv: ["-sh", "-c", #"echo "argv0=$0 id=$CLAUDEDECK_TERMINAL_ID ask=$CLAUDEDECK_ASK_TOKEN pwd=$(pwd) tmp=${TMPDIR-unset}"; stty size; sleep 5"#],
                              env: ["PATH=/usr/bin:/bin", "CLAUDEDECK_TERMINAL_ID=T-1", "CLAUDEDECK_ASK_TOKEN=tok"],
                              cwd: dir.path, cols: 100, rows: 30)
        _ = try sync { client.spawn(spawn, $0) }
        #expect(waitFor { collector.text(spawn.id).contains("30 100") })
        let text = collector.text(spawn.id)
        #expect(text.contains("argv0=-sh id=T-1 ask=tok pwd=/private\(dir.path) "))
        // Nothing from the helper's own environment leaks in.
        #expect(text.contains("tmp=unset"))
        helper.kill()
    }

    @Test func neverStartsASessionTwice() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }
        do {
            _ = try sync { client.spawn(spawn, $0) }
        } catch PtydClientError.refused(let code, let existing) {
            #expect(code == PtydErrorCode.exists)
            #expect(existing?.pid == info.pid)
        }
        // A second app connection gets the same answer.
        let other = try helper.connect(Collector())
        #expect(throws: PtydClientError.self) { _ = try sync { other.spawn(spawn, $0) } }
        #expect(try sync { other.list($0) }.count == 1)
        helper.kill()
    }

    @Test func inputResizeAndExitStatus() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let spawn = shellSpawn(#"while read line; do [ "$line" = quit ] && exit 3; echo "got:$line"; stty size; done"#)
        _ = try sync { client.spawn(spawn, $0) }
        client.resize(spawn.id, cols: 132, rows: 43)
        client.write(spawn.id, Array("hello\n".utf8))
        #expect(waitFor { collector.text(spawn.id).contains("got:hello") && collector.text(spawn.id).contains("43 132") })
        client.write(spawn.id, Array("quit\n".utf8))
        #expect(waitFor { collector.exit(spawn.id) != nil })
        #expect(collector.exit(spawn.id)?.exitCode == 3)
        let listed = try sync { client.list($0) }
        #expect(listed.first?.alive == false)
        #expect(listed.first?.exitCode == 3)
        client.forget(spawn.id)
        #expect(waitFor { ((try? sync { client.list($0) }) ?? [listed[0]]).isEmpty })
        helper.kill()
    }

    /// The helper dies: its sessions get SIGHUP and end; the app sees the socket drop; the
    /// decision table then resumes them (no twin: the old process is gone).
    @Test func helperCrashFallsBackToResume() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let spawn = shellSpawn(tickLoop)
        let info = try sync { client.spawn(spawn, $0) }
        let host = PtydHost(instance: client.welcome.instance, pid: info.pid, startedAt: info.startedAt)
        #expect(PtydLaunchPlan.processAlive(host))
        #expect(paths(helper).helperHoldsLock())

        helper.kill(SIGKILL)
        #expect(waitFor { collector.isDisconnected })
        #expect(waitFor { !PtydLaunchPlan.processAlive(host) })
        #expect(!paths(helper).helperHoldsLock())
        let id = try #require(UUID(uuidString: spawn.id))
        #expect(PtydLaunchPlan.gate(sessionID: id, host: host, helper: .gone, processAlive: PtydLaunchPlan.processAlive) == .proceed)

        // A new helper (launchd's KeepAlive, or the app) has a new instance and none of the old sessions.
        let next = try HelperProcess(sharing: helper)
        #expect(next.waitUntilListening())
        let again = try next.connect(Collector())
        #expect(again.welcome.instance != host.instance)
        let state = PtydHelperState.live(instance: again.welcome.instance, compatibility: again.compatibility, sessions: [:])
        #expect(PtydLaunchPlan.gate(sessionID: id, host: host, helper: state, processAlive: PtydLaunchPlan.processAlive) == .proceed)
        next.kill()
    }

    /// A child that ignores SIGHUP outlives the crashed helper: it is held, never resumed twice.
    @Test func survivorOfACrashIsHeld() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        let spawn = shellSpawn(#"trap '' HUP; exec sleep 30"#)
        let info = try sync { client.spawn(spawn, $0) }
        usleep(200_000)
        let host = PtydHost(instance: client.welcome.instance, pid: info.pid, startedAt: info.startedAt)
        helper.kill(SIGKILL)
        usleep(300_000)
        let id = try #require(UUID(uuidString: spawn.id))
        #expect(PtydLaunchPlan.gate(sessionID: id, host: host, helper: .gone, processAlive: PtydLaunchPlan.processAlive)
                == .hold(.processStillRunning))
        kill(info.pid, SIGKILL)
    }

    /// Started with SIGHUP ignored (nohup, a background job), the helper must not pass that on:
    /// its sessions have to end with it.
    @Test func childrenStartWithDefaultSignals() throws {
        let dir = URL(fileURLWithPath: "/tmp/cdptyd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"trap '' HUP INT; exec "$0" --dir "$1" --build test"#, try #require(helperBinary).path, dir.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let paths = PtydPaths(directory: dir)
        #expect(waitFor { (try? PtydClient.connect(socket: paths.socket, build: "test", timeout: 1, callbackQueue: DispatchQueue(label: "p"))) != nil })
        let collector = Collector()
        let client = try PtydClient.connect(socket: paths.socket, build: "test", callbackQueue: DispatchQueue(label: "c"))
        client.onExit = { collector.exited($0) }
        let spawn = shellSpawn("kill -HUP $$; sleep 5; echo survived")
        _ = try sync { client.spawn(spawn, $0) }
        #expect(waitFor { collector.exit(spawn.id) != nil })
        #expect(collector.exit(spawn.id)?.exitSignal == SIGHUP)
    }

    /// Restart Terminal on a helper session, as the app does it: SIGHUP + SIGTERM, wait until the
    /// pid is gone, start the same session id again. The new spawn is accepted, and the old
    /// process's exit notice (which may arrive after that) names the old pid, so the app can
    /// tell it from the new run's.
    @Test func restartedSessionsExitNoticeNamesTheOldProcess() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        let id = UUID().uuidString
        let old = try sync { client.spawn(shellSpawn("trap 'exit 129' HUP; while :; do sleep 0.05; done", id: id), $0) }
        client.signal(id, SIGHUP)
        client.signal(id, SIGTERM, killAfter: 5)
        #expect(waitFor { kill(old.pid, 0) != 0 })
        let new = try sync { client.spawn(shellSpawn(tickLoop, id: id), $0) }
        #expect(new.alive && new.pid != old.pid)
        #expect(waitFor { collector.exit(id) != nil })
        let notice = try #require(collector.exit(id))
        #expect(notice.pid == old.pid && !notice.alive)
        #expect(!PtydLaunchPlan.exitNoticeApplies(noticePID: notice.pid, currentPID: new.pid, retiredPIDs: [old.pid]))
        #expect(!PtydLaunchPlan.exitNoticeApplies(noticePID: notice.pid, currentPID: nil, retiredPIDs: [old.pid]))
        // The new run is untouched.
        #expect(try sync { client.list($0) }.first { $0.id == id }?.alive == true)
        client.signal(id, SIGKILL)
        helper.kill()
    }

    @Test func secondHelperForTheSameFolderStepsAside() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        let second = try HelperProcess(sharing: helper)
        second.process.waitUntilExit()
        #expect(second.process.terminationStatus == 0)
        // The first one still serves.
        #expect((try? sync { client.list($0) }) != nil)
        #expect(paths(helper).lockHolderPID() == helper.process.processIdentifier)
        helper.kill()
    }

    @Test func incompatibleHelperIsReadOnly() throws {
        // A helper from the future that no longer accepts this app as a full client.
        let helper = try HelperProcess(extra: ["--protocol-version", "\(PtydProtocol.version + 5)",
                                               "--oldest-client", "\(PtydProtocol.version + 1)"])
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        #expect(client.compatibility == .readOnly)
        #expect(throws: PtydClientError.refused(PtydErrorCode.readOnly, nil)) { _ = try sync { client.spawn(shellSpawn("sleep 5"), $0) } }
        #expect((try? sync { client.list($0) }) == [])
        // Nor may it shut the helper down (the app SIGTERMs the lock holder instead).
        #expect(throws: PtydClientError.refused(PtydErrorCode.readOnly, nil)) {
            _ = try sync { (done: @escaping @Sendable (Result<PtydFrame, PtydClientError>) -> Void) in client.shutdown(done) }
        }
        #expect(helper.process.isRunning)
        helper.kill()
    }

    @Test func drainExitsAfterTheLastSession() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        let spawn = shellSpawn("read x")
        _ = try sync { client.spawn(spawn, $0) }
        _ = try sync { (done: @escaping @Sendable (Result<PtydFrame, PtydClientError>) -> Void) in client.drain(done) }
        usleep(300_000)
        #expect(helper.process.isRunning)
        client.write(spawn.id, Array("\n".utf8))
        #expect(waitFor { !helper.process.isRunning })
        #expect(helper.process.terminationStatus == 0)
    }

    @Test func socketIsPrivate() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        var info = stat()
        #expect(stat(helper.paths.socket.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        helper.kill()
    }

    @Test func helperAnswersTheAccessProbe() throws {
        let helper = try HelperProcess()
        #expect(helper.waitUntilListening())
        let client = try helper.connect(Collector())
        #expect(client.supportsAccessProbe)
        let report = try sync { (done: @escaping @Sendable (Result<PtydAccessReport, PtydClientError>) -> Void) in
            client.probeAccess(timeout: 4) { done(.success($0)) }
        }
        // A child of this test runs under the same privacy grants as the test itself.
        #expect(report == PtydAccessProbe.run())
        #expect((try? sync { client.list($0) }) == [])
        helper.kill()
    }

    /// A helper from before protocol 2: the app never sends it the probe (it would drop the
    /// connection over the unknown op) and reads its access as unknown, with no error.
    @Test func oldHelperAccessIsUnknownWithoutAsking() throws {
        let helper = try HelperProcess(extra: ["--protocol-version", "1"])
        #expect(helper.waitUntilListening())
        let collector = Collector()
        let client = try helper.connect(collector)
        #expect(client.compatibility == .full(dialect: 1))
        #expect(!client.supportsAccessProbe)
        let report = try sync { (done: @escaping @Sendable (Result<PtydAccessReport, PtydClientError>) -> Void) in
            client.probeAccess(timeout: 2) { done(.success($0)) }
        }
        #expect(report == .unknown)
        // Asked anyway, a helper that doesn't answer it refuses; the connection survives.
        #expect(throws: PtydClientError.refused(PtydErrorCode.badRequest, nil)) {
            _ = try sync { (done: @escaping @Sendable (Result<PtydFrame, PtydClientError>) -> Void) in
                client.request(PtydMessage(op: .probeAccess), completion: done)
            }
        }
        #expect((try? sync { client.list($0) }) == [])
        #expect(!collector.isDisconnected)
        helper.kill()
    }

    private func paths(_ helper: HelperProcess) -> PtydPaths { helper.paths }
}
