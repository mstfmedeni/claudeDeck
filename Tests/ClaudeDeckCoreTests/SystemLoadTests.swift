import Foundation
import Testing
@testable import ClaudeDeckCore

/// The load monitor (level with hysteresis, the overload episode), build slots, throttling, the
/// `load` / `slot` / `heavy` routes and script, and the phone's load field.
@Suite struct SystemLoadTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var thresholds: LoadThresholds { LoadThresholds.resolve(LoadSettings(), cores: 20) }

    private func sample(_ seconds: Double, load: Double, pressure: MemoryPressure = .normal, compilers: Int = 0,
                        simulators: Int = 0, sessions: Int = 0) -> LoadSample {
        LoadSample(at: t0.addingTimeInterval(seconds), load1: load, cores: 20, pressure: pressure, simulators: simulators,
                   compilers: compilers, sessions: sessions)
    }

    // MARK: Thresholds

    @Test func defaultsScaleWithTheCores() {
        let t = thresholds
        #expect(t.overloadLoad == 40 && t.busyLoad == 20)
        #expect(t.overloadCompilers == 12 && t.busyCompilers == 6)
        #expect(t.maxSimulators == 4 && t.buildSlots == 3)
        #expect(t.maxSlotHold == 3600 && t.overloadSustain == 60)
        let small = LoadThresholds.resolve(LoadSettings(), cores: 8)
        #expect(small.overloadLoad == 16 && small.overloadCompilers == 5 && small.maxSimulators == 2 && small.buildSlots == 1)
        let big = LoadThresholds.resolve(LoadSettings(), cores: 64)
        #expect(big.maxSimulators == 10 && big.buildSlots == 8)
        var custom = LoadSettings()
        custom.maxSimulators = 7
        custom.buildSlots = 5
        custom.maxCompilers = 30
        custom.busyFactor = 3 // never above the overload factor
        let c = LoadThresholds.resolve(custom, cores: 20)
        #expect(c.maxSimulators == 7 && c.buildSlots == 5 && c.overloadCompilers == 30 && c.busyLoad == 40)
    }

    @Test func settingsDecodeOldFilesAndClamp() throws {
        let old = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(old.load == LoadSettings())
        #expect(old.load.throttle && old.load.notify && old.load.maxSimulators == nil)
        let json = #"{"load":{"throttle":false,"overloadFactor":99,"buildSlots":0,"maxSimulators":3,"maxSlotHoldMinutes":1}}"#
        let decoded = try JSONDecoder().decode(DeckSettings.self, from: Data(json.utf8))
        #expect(!decoded.load.throttle)
        #expect(decoded.load.overloadFactor == 10 && decoded.load.buildSlots == 1 && decoded.load.maxSimulators == 3)
        #expect(decoded.load.maxSlotHoldMinutes == 5)
        let back = try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(decoded))
        #expect(back.load == decoded.load)
        // A broken value doesn't lose the rest of the settings.
        let broken = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"load":7,"notifications":false}"#.utf8))
        #expect(broken.load == LoadSettings() && !broken.notifications)
    }

    // MARK: Level and episode

    @Test func highLoadMustLastAMinute() {
        var monitor = LoadMonitor()
        #expect(monitor.add(sample(0, load: 50), thresholds: thresholds) == [.level(from: .ok, to: .busy)])
        monitor.add(sample(30, load: 50), thresholds: thresholds)
        #expect(monitor.level == .busy && !monitor.throttled)
        let events = monitor.add(sample(60, load: 50), thresholds: thresholds)
        #expect(events == [.level(from: .busy, to: .overloaded), .episodeStarted(1)])
        #expect(monitor.throttled && monitor.episode == 1)
        // A dip resets the minute.
        var dip = LoadMonitor()
        dip.add(sample(0, load: 50), thresholds: thresholds)
        dip.add(sample(30, load: 30), thresholds: thresholds)
        dip.add(sample(70, load: 50), thresholds: thresholds)
        #expect(dip.level == .busy)
    }

    @Test func criticalPressureOrTooManyCompilersAreImmediate() {
        var monitor = LoadMonitor()
        #expect(monitor.add(sample(0, load: 5, pressure: .critical), thresholds: thresholds).contains(.episodeStarted(1)))
        var builds = LoadMonitor()
        builds.add(sample(0, load: 5, compilers: 13), thresholds: thresholds)
        #expect(builds.level == .overloaded)
        var twelve = LoadMonitor()
        twelve.add(sample(0, load: 5, compilers: 12), thresholds: thresholds)
        #expect(twelve.level == .busy)
        var sims = LoadMonitor()
        sims.add(sample(0, load: 5, simulators: 4), thresholds: thresholds)
        #expect(sims.level == .busy)
    }

    @Test func hysteresisAndOneEpisodeUntilOK() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 5, compilers: 30), thresholds: thresholds)
        #expect(monitor.level == .overloaded && monitor.episode == 1)
        // Just under the threshold isn't calm enough (exit margin).
        monitor.add(sample(10, load: 35), thresholds: thresholds)
        monitor.add(sample(100, load: 35), thresholds: thresholds)
        #expect(monitor.level == .overloaded)
        // Calm (under 80% of 40) for a minute: down to busy (load still above 20).
        monitor.add(sample(110, load: 25), thresholds: thresholds)
        monitor.add(sample(150, load: 25), thresholds: thresholds)
        #expect(monitor.level == .overloaded)
        #expect(monitor.add(sample(170, load: 25), thresholds: thresholds) == [.level(from: .overloaded, to: .busy)])
        // Still the same episode: throttling stays until ok, and overloaded again is no new episode.
        #expect(monitor.throttled)
        #expect(monitor.add(sample(180, load: 5, compilers: 20), thresholds: thresholds) == [.level(from: .busy, to: .overloaded)])
        #expect(monitor.episode == 1)
        // Calm all the way: overloaded → ok directly once busy is clear too; the episode ends.
        monitor.add(sample(190, load: 5), thresholds: thresholds)
        let events = monitor.add(sample(250, load: 5), thresholds: thresholds)
        #expect(events == [.level(from: .overloaded, to: .ok), .episodeEnded(1)])
        #expect(!monitor.throttled)
        // The next overload is a new episode.
        #expect(monitor.add(sample(260, load: 5, pressure: .critical), thresholds: thresholds).contains(.episodeStarted(2)))
    }

    @Test func busyNeedsThirtyCalmSecondsToClear() {
        var monitor = LoadMonitor()
        monitor.add(sample(0, load: 25), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(10, load: 17), thresholds: thresholds) // under 20 but not under 16
        monitor.add(sample(60, load: 17), thresholds: thresholds)
        #expect(monitor.level == .busy)
        monitor.add(sample(70, load: 10), thresholds: thresholds)
        monitor.add(sample(90, load: 10), thresholds: thresholds)
        #expect(monitor.level == .busy)
        #expect(monitor.add(sample(100, load: 10), thresholds: thresholds) == [.level(from: .busy, to: .ok)])
    }

    @Test func keepsTheLastSamplesForTheChart() {
        var monitor = LoadMonitor()
        for i in 0..<(LoadMonitor.keep + 20) { monitor.add(sample(Double(i) * 12, load: 1), thresholds: thresholds) }
        #expect(monitor.samples.count == LoadMonitor.keep)
        #expect(monitor.latest?.at == t0.addingTimeInterval(Double(LoadMonitor.keep + 19) * 12))
    }

    @Test func contributorsNameWhatStandsOut() {
        let s = sample(0, load: 120, pressure: .warning, compilers: 30, simulators: 11, sessions: 37)
        #expect(LoadContributor.of(s, thresholds: thresholds) ==
                [.simulators(11), .compilers(30), .sessions(37), .memory(.warning), .load(120, cores: 20)])
        #expect(LoadContributor.of(sample(0, load: 3, simulators: 1), thresholds: thresholds) == [.load(3, cores: 20)])
        #expect(LoadContributor.simulators(11).text == "11 simulators booted")
    }

    @Test func processNamesAreCounted() {
        let names = ["launchd_sim", "launchd_sim", "swift-frontend", "clang", "ld", "xcodebuild", "zsh", "claude", "SimMetalHost"]
        let counted = LoadProcesses.count(names)
        #expect(counted.simulators == 2 && counted.compilers == 4)
        #expect(MemoryPressure(kernelLevel: 1) == .normal && MemoryPressure(kernelLevel: 2) == .warning && MemoryPressure(kernelLevel: 4) == .critical)
    }

    // MARK: Throttling

    @Test func throttlingDecisions() {
        #expect(LoadThrottle.start(throttled: false, enabled: true, queue: false) == .allow)
        #expect(LoadThrottle.start(throttled: true, enabled: true, queue: false) == .refuse)
        #expect(LoadThrottle.start(throttled: true, enabled: true, queue: true) == .queue)
        #expect(LoadThrottle.start(throttled: true, enabled: false, queue: false) == .allow)
        #expect(!LoadThrottle.drains(throttled: true, enabled: true))
        #expect(LoadThrottle.drains(throttled: true, enabled: false) && LoadThrottle.drains(throttled: false, enabled: true))
        #expect(LoadThrottle.simulator(throttled: true, enabled: true, booted: 0, wanted: 1, max: 4) == .overloaded)
        #expect(LoadThrottle.simulator(throttled: false, enabled: true, booted: 3, wanted: 1, max: 4) == .allow)
        #expect(LoadThrottle.simulator(throttled: false, enabled: true, booted: 3, wanted: 2, max: 4) == .tooManyBooted)
        #expect(LoadThrottle.simulator(throttled: true, enabled: false, booted: 11, wanted: 2, max: 4) == .allow)
        #expect(LoadThrottle.slotCapacity(3, throttled: true, enabled: true) == 1)
        #expect(LoadThrottle.slotCapacity(3, throttled: true, enabled: false) == 3)
        #expect(LoadThrottle.slotCapacity(0, throttled: false, enabled: true) == 1)
    }

    // MARK: Build slots

    @Test func slotsAcquireAndRelease() {
        var book = BuildSlotBook()
        let a = UUID(), b = UUID()
        guard case .acquired(let first) = book.acquire(session: a, ticket: nil, label: "xcodebuild", capacity: 2, now: t0) else {
            Issue.record("no slot"); return
        }
        #expect(first.id.hasPrefix("b_") && first.id.count == 10 && first.label == "xcodebuild")
        guard case .acquired = book.acquire(session: b, ticket: nil, label: nil, capacity: 2, now: t0) else { Issue.record("no slot"); return }
        #expect(book.acquire(session: b, ticket: nil, label: nil, capacity: 2, now: t0) == .full(position: nil))
        #expect(book.release(session: b, id: first.id).isEmpty) // not b's
        #expect(book.release(session: a, id: first.id) == [first])
        #expect(book.held(by: a).isEmpty && book.held(by: b).count == 1)
        #expect(book.release(session: b).count == 1 && book.slots.isEmpty)
    }

    @Test func waitersAreServedInOrder() {
        var book = BuildSlotBook()
        let holder = UUID(), first = UUID(), second = UUID()
        _ = book.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0)
        #expect(book.acquire(session: first, ticket: "t1", label: nil, capacity: 1, now: t0) == .full(position: 1))
        #expect(book.acquire(session: second, ticket: "t2", label: nil, capacity: 1, now: t0.addingTimeInterval(1)) == .full(position: 2))
        book.release(session: holder)
        // The second asks first, but the first is ahead in line; nobody jumps it without a ticket either.
        #expect(book.acquire(session: second, ticket: "t2", label: nil, capacity: 1, now: t0.addingTimeInterval(2)) == .full(position: 2))
        #expect(book.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0.addingTimeInterval(2)) == .full(position: nil))
        guard case .acquired(let slot) = book.acquire(session: first, ticket: "t1", label: nil, capacity: 1, now: t0.addingTimeInterval(3)) else {
            Issue.record("first in line didn't get it"); return
        }
        #expect(slot.session == first && book.waiters.map(\.ticket) == ["t2"])
        // A waiter that stops asking gives up its place.
        book.release(session: first)
        #expect(book.acquire(session: holder, ticket: nil, label: nil, capacity: 1,
                             now: t0.addingTimeInterval(3 + BuildSlotBook.waiterTimeout + 1)) != .full(position: nil))
        #expect(book.waiters.isEmpty)
        // Leaving the line.
        var other = BuildSlotBook()
        _ = other.acquire(session: holder, ticket: nil, label: nil, capacity: 1, now: t0)
        _ = other.acquire(session: first, ticket: "x", label: nil, capacity: 1, now: t0)
        other.leave(ticket: "x", session: first)
        #expect(other.waiters.isEmpty)
    }

    @Test func slotsGoBackWhenTheSessionEndsOrAfterTheLongestHold() {
        var book = BuildSlotBook()
        let alive = UUID(), gone = UUID()
        _ = book.acquire(session: alive, ticket: nil, label: nil, capacity: 3, now: t0)
        _ = book.acquire(session: gone, ticket: nil, label: nil, capacity: 3, now: t0)
        _ = book.acquire(session: alive, ticket: "w", label: nil, capacity: 2, now: t0)
        #expect(book.prune(running: [alive], maxHold: 3600, now: t0.addingTimeInterval(10)).map(\.session) == [gone])
        #expect(book.slots.count == 1)
        #expect(book.prune(running: [alive], maxHold: 3600, now: t0.addingTimeInterval(3600)).count == 1)
        #expect(book.slots.isEmpty)
        var waiting = BuildSlotBook()
        _ = waiting.acquire(session: alive, ticket: nil, label: nil, capacity: 1, now: t0)
        _ = waiting.acquire(session: gone, ticket: "g", label: nil, capacity: 1, now: t0)
        waiting.prune(running: [alive], maxHold: 3600, now: t0)
        #expect(waiting.waiters.isEmpty)
        #expect(BuildSlotBook.isValidTicket("t123-456") && !BuildSlotBook.isValidTicket("") && !BuildSlotBook.isValidTicket("a b"))
    }

    // MARK: API and script

    @Test func routes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/load") == .route(.load))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/slot/build/acquire") == .route(.slotAcquire("build")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/slot/build/release") == .route(.slotRelease("build")))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/slot/build/acquire") == .methodNotAllowed)
        #expect(SessionCLI.Route.load.scope == .list && SessionCLI.Route.slotAcquire("build").scope == .slots)
        // A terminal a session opened runs the builds: it may take a slot, not start sessions.
        #expect(SessionCLI.openedScopes.contains(.slots) && SessionCLI.fullScopes.contains(.slots))
    }

    @Test func loadReport() throws {
        let slot = SessionCLILoad.Slot(id: "b_12345678", session: UUID(), sessionName: "Build bot", label: "xcodebuild", since: Date())
        let report = SessionCLILoad(level: .overloaded, throttled: true, throttle: true,
                                    sample: sample(0, load: 120, pressure: .warning, compilers: 30, simulators: 11, sessions: 37),
                                    thresholds: thresholds, capacity: 1, slots: [slot], waiting: 2)
        #expect(report.text.contains("level: overloaded (new sessions, simulators and builds are held back)"))
        #expect(report.text.contains("simulators: 11 booted") && report.text.contains("build slots: 1/1 used, 2 waiting"))
        #expect(report.text.contains("b_12345678  Build bot"))
        let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(json.contains(#""level":"overloaded""#) && json.contains(#""slotsAvailable":0"#) && json.contains(#""loadPerCore":6"#))
        let empty = SessionCLILoad(level: .ok, throttled: false, throttle: true, sample: nil, thresholds: thresholds, capacity: 3, slots: [], waiting: 0)
        #expect(empty.text == "level: ok\nno sample yet")
    }

    @Test func statusListsSlots() {
        let status = SessionCLIStatus(id: UUID(), name: "a", kind: "claude", state: "working", detail: nil, project: "p", startedBy: nil,
                                      stall: nil, simulators: [], slots: ["b_1"])
        #expect(status.text.contains("build slots: b_1"))
    }

    @Test func remoteLoadIsOptional() throws {
        let old = #"{"hostName":"Mac","sessions":[]}"#
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(old.utf8))
        #expect(decoded.load == nil)
        var snapshot = RemoteSnapshot(hostName: "Mac", sessions: [])
        snapshot.features = RemoteSnapshot.Feature.all
        snapshot.load = RemoteLoad(level: "overloaded", throttled: true, loadPerCore: 2.345, cores: 20, memoryPercent: 81,
                                   memoryPressure: "warning", simulators: 11, builds: 30, sessions: 37, slotsUsed: 1, slots: 1)
        #expect(snapshot.load?.loadPerCore == 2.3)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(back.load == snapshot.load && back.supports(RemoteSnapshot.Feature.load))
        // An older phone (no `load` key in its model) still decodes the snapshot: unknown keys are ignored.
        struct OldSnapshot: Decodable { var hostName: String; var sessions: [RemoteSession] }
        #expect(try JSONDecoder().decode(OldSnapshot.self, from: JSONEncoder().encode(snapshot)).hostName == "Mac")
    }

    // MARK: The script (a stand-in curl)

    private struct Run {
        var code: Int32
        var out: String
        var err: String
        var calls: [[String]]
    }

    private func run(_ args: [String], answers: [(body: String, status: String)] = [], session: Bool = true) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claudedeck-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "claudedeck")
        try Data(SessionCLI.script.utf8).write(to: script)
        for (index, answer) in answers.enumerated() {
            try Data(answer.body.utf8).write(to: dir.appending(path: "body\(index)"))
            try Data(answer.status.utf8).write(to: dir.appending(path: "status\(index)"))
        }
        let curl = dir.appending(path: "curl")
        try Data(#"""
        #!/bin/sh
        d=$(dirname "$0")
        n=$(cat "$d/count" 2>/dev/null || echo 0)
        echo $((n + 1)) > "$d/count"
        for a in "$@"; do printf '%s\037' "$a"; done >> "$d/calls"
        printf '\036' >> "$d/calls"
        [ -f "$d/status$n" ] || { printf '\n000 '; exit 7; }
        cat "$d/body$n"; printf '\n'; cat "$d/status$n"
        """#.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + args
        var env = ["PATH": dir.path + ":/usr/bin:/bin", "HOME": dir.path]
        if session {
            env["CLAUDEDECK_CLI_TOKEN"] = "tok-123"
            env["CLAUDEDECK_CLI_URL"] = "http://127.0.0.1:47832/v1/cli"
        }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = (try? String(contentsOf: dir.appending(path: "calls"), encoding: .utf8)) ?? ""
        let calls = raw.split(separator: "\u{1E}").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        return Run(code: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self), calls: calls)
    }

    @Test func scriptLoad() throws {
        let load = try run(["load"], answers: [("level: ok", "200 0")])
        #expect(load.code == 0 && load.out == "level: ok\n")
        #expect(load.calls.first?.last == "http://127.0.0.1:47832/v1/cli/load" && load.calls.first?.contains("format=text") == true)
        #expect(try run(["load", "--json"], answers: [("{}", "200 0")]).calls.first?.contains("format=json") == true)
        #expect(try run(["load", "extra"]).code == 2)
    }

    @Test func scriptSlot() throws {
        let acquired = try run(["slot", "acquire", "build", "--label", "ios build"], answers: [("b_12345678", "200 0")])
        #expect(acquired.code == 0 && acquired.out == "b_12345678\n")
        let call = try #require(acquired.calls.first)
        #expect(call.last == "http://127.0.0.1:47832/v1/cli/slot/build/acquire")
        #expect(call.contains("label=ios build") && call.contains("ticket=") && call.contains("timeout=0"))
        // --wait: the same ticket again until a slot is free.
        let waited = try run(["slot", "acquire", "build", "--wait", "60"],
                             answers: [(#"{"error":"no_slot"}"#, "429 124"), ("b_aaaabbbb", "200 0")])
        #expect(waited.code == 0 && waited.out == "b_aaaabbbb\n" && waited.calls.count == 2)
        let ticket = waited.calls.map { $0.first { $0.hasPrefix("ticket=t") } }
        #expect(ticket[0] != nil && ticket[0] == ticket[1])
        let full = try run(["slot", "acquire"], answers: [(#"{"error":"no_slot"}"#, "429 124")])
        #expect(full.code == 124 && full.err.contains("every build slot is taken"))
        let release = try run(["slot", "release", "build", "b_12345678"], answers: [("released b_12345678", "200 0")])
        #expect(release.code == 0 && release.calls.first?.contains("id=b_12345678") == true)
        #expect(release.calls.first?.last == "http://127.0.0.1:47832/v1/cli/slot/build/release")
        #expect(try run(["slot", "grab"]).code == 2)
        #expect(try run(["slot", "acquire", "--wait", "soon"]).code == 2)
    }

    @Test func scriptHeavy() throws {
        // A slot, the command, the release; the command's code comes through.
        let ran = try run(["heavy", "--", "sh", "-c", "echo built; exit 3"], answers: [("b_12345678", "200 0"), ("released", "200 0")])
        #expect(ran.code == 3 && ran.out == "built\n")
        #expect(ran.calls.count == 2)
        #expect(ran.calls[0].last == "http://127.0.0.1:47832/v1/cli/slot/build/acquire" && ran.calls[0].contains("label=sh -c echo built; exit 3"))
        #expect(ran.calls[1].last == "http://127.0.0.1:47832/v1/cli/slot/build/release" && ran.calls[1].contains("id=b_12345678"))
        // No slot in time: the command doesn't run, the place in line is given up, 124.
        let late = try run(["heavy", "--wait", "0", "--", "sh", "-c", "echo should-not-run"],
                           answers: [(#"{"error":"no_slot"}"#, "429 124"), ("ok", "200 0")])
        #expect(late.code == 124 && !late.out.contains("should-not-run"))
        #expect(late.calls.last?.contains { $0.hasPrefix("ticket=t") } == true)
        // ClaudeDeck not answering: it runs anyway.
        let down = try run(["heavy", "--", "sh", "-c", "echo anyway"])
        #expect(down.code == 0 && down.out == "anyway\n" && down.err.contains("without a build slot"))
        // Outside ClaudeDeck: just runs it, no curl.
        let outside = try run(["heavy", "sh", "-c", "exit 5"], session: false)
        #expect(outside.code == 5 && outside.calls.isEmpty)
        #expect(try run(["heavy"]).code == 2)
    }

    @Test func scriptHints() throws {
        let new = try run(["new", "--prompt", "x"], answers: [(#"{"error":"overloaded"}"#, "429 4")])
        #expect(new.code == 4 && new.err.contains("new --queue"))
        let sim = try run(["sim", "acquire"], answers: [(#"{"error":"too_many_booted"}"#, "429 4")])
        #expect(sim.code == 4 && sim.err.contains("too many simulators are booted"))
        #expect(SessionCLI.skill.contains("claudedeck heavy --") && SessionCLI.skill.contains("claudedeck load"))
    }
}
