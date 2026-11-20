import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck sim`, `usage` and `status`: simulator allocation, usage per project and the stall watch.
@Suite struct SessionCLIExtrasTests {
    // MARK: Routes and scopes

    @Test func routes() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sim") == .route(.simList))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sim/acquire") == .route(.simAcquire))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sim/release") == .route(.simRelease))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sim/acquire") == .methodNotAllowed)
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sim/erase") == .notFound)
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/usage") == .route(.usage))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/sessions/self/status") == .route(.status("self")))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/sessions/self/status") == .methodNotAllowed)
        #expect(SessionCLI.Route.simAcquire.scope == .simulators)
        #expect(SessionCLI.Route.usage.scope == .usage)
        #expect(SessionCLI.Route.status("x").scope == .list)
        // A terminal a session opened may look at usage, never take simulators.
        #expect(SessionCLI.openedScopes.contains(.usage))
        #expect(!SessionCLI.openedScopes.contains(.simulators))
        #expect(SessionCLI.fullScopes.isSuperset(of: [.simulators, .usage]))
    }

    @Test func settingsDefaultOffAndDecodeOldFiles() throws {
        let settings = try JSONDecoder().decode(DeckSettings.self, from: Data("{}".utf8))
        #expect(!settings.sessionsMayUseSimulators)
        #expect(settings.simulatorsShutDownOnRelease)
        #expect(!settings.stallWatch.enabled)
        #expect(settings.stallWatch.action == .notify)
        #expect(settings.stallWatch.minutes == 15)
        let partial = try JSONDecoder().decode(StallSettings.self, from: Data(#"{"enabled":true,"minutes":1,"action":"bogus"}"#.utf8))
        #expect(partial.enabled && partial.minutes == StallSettings.minuteRange.lowerBound && partial.action == .notify)
        // Round trip.
        var on = DeckSettings()
        on.sessionsMayUseSimulators = true
        on.stallWatch.action = .restart
        let back = try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(on))
        #expect(back.sessionsMayUseSimulators && back.stallWatch.action == .restart)
    }

    @Test func scriptKnowsTheCommands() {
        for needle in ["cmd_sim", "cmd_usage", "cmd_status", "/sim/acquire", "/sim/release", "/usage", "/status", "--duo",
                       "claudedeck sim acquire", "claudedeck usage", "claudedeck status ID"] {
            #expect(SessionCLI.script.contains(needle), "script lacks \(needle)")
        }
        #expect(SessionCLI.skill.contains("claudedeck sim acquire"))
    }

    // MARK: Simulators

    private let iPhone = SimulatorDeviceType(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", name: "iPhone 17 Pro")
    private let duo = SimulatorDeviceType(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", name: "iPhone Duo")

    private func runtime(_ id: String, _ types: [SimulatorDeviceType], available: Bool = true) -> SimulatorRuntimeInfo {
        SimulatorRuntimeInfo(runtime: SimulatorRuntime(identifier: id)!, isAvailable: available, supportedDeviceTypes: Set(types.map(\.identifier)))
    }

    @Test func requestedDevices() {
        #expect(SimulatorAllocation.requested(device: nil, duo: false) == ["iPhone 17 Pro"])
        #expect(SimulatorAllocation.requested(device: "  ", duo: true) == ["iPhone Duo"])
        #expect(SimulatorAllocation.requested(device: nil, duo: true) == ["iPhone Duo"])
        #expect(SimulatorAllocation.requested(device: "iPhone Duo", duo: true) == ["iPhone Duo"])
        #expect(SimulatorAllocation.requested(device: "iPhone 17 Pro", duo: true) == ["iPhone 17 Pro", "iPhone Duo"])
        #expect(SimulatorAllocation.requested(device: "iPad Pro 13-inch (M5)", duo: false) == ["iPad Pro 13-inch (M5)"])
        #expect(SimulatorAllocation.deviceType("iphone duo", in: [iPhone, duo]) == duo)
        #expect(SimulatorAllocation.deviceType(duo.identifier, in: [iPhone, duo]) == duo)
        #expect(SimulatorAllocation.deviceType("Pixel 9", in: [iPhone, duo]) == nil)
    }

    @Test func runtimeChoice() {
        let runtimes = [
            runtime("com.apple.CoreSimulator.SimRuntime.iOS-18-6", [iPhone]),
            runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-2", [iPhone]),
            runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", [duo]),
            runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-1", [duo]),
            runtime("com.apple.CoreSimulator.SimRuntime.iOS-28-0", [iPhone], available: false),
        ]
        #expect(SimulatorAllocation.runtime(for: iPhone, in: runtimes)?.runtime.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        // The iPhone Duo only runs on its device-specific build.
        #expect(SimulatorAllocation.runtime(for: duo, in: runtimes)?.runtime.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4")
        // A plain runtime wins a tie with a device-specific one.
        let both = [runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", [iPhone]), runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-2", [iPhone])]
        #expect(SimulatorAllocation.runtime(for: iPhone, in: both)?.runtime.variant == nil)
    }

    @Test func onlyClaudeDecksOwnFreeDevicesAreReused() {
        let rt = SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2")!
        func device(_ udid: String, _ name: String, _ state: String = "Shutdown", type: SimulatorDeviceType? = nil) -> Simulator {
            Simulator(udid: udid, name: name, state: state, deviceTypeIdentifier: (type ?? iPhone).identifier, runtime: rt)
        }
        let users = device("00000000-0000-0000-0000-000000000001", "iPhone 17 Pro")
        let poolBooted = device("00000000-0000-0000-0000-000000000002", "ClaudeDeck · iPhone 17 Pro · 1", "Booted")
        let poolFree = device("00000000-0000-0000-0000-000000000003", "ClaudeDeck · iPhone 17 Pro · 2")
        let poolHeld = device("00000000-0000-0000-0000-000000000004", "ClaudeDeck · iPhone 17 Pro · 3")
        let duoFree = device("00000000-0000-0000-0000-000000000005", "ClaudeDeck · iPhone Duo · 1", type: duo)
        var book = SimulatorHoldBook()
        book.hold(SimulatorHold(udid: poolHeld.udid, name: poolHeld.name, session: UUID(), created: true))
        let devices = [users, poolBooted, poolFree, poolHeld, duoFree]
        #expect(SimulatorAllocation.reusable(iPhone, devices: devices, book: book)?.udid == poolFree.udid)
        #expect(SimulatorAllocation.reusable(iPhone, devices: devices, book: book, excluding: [poolFree.udid]) == nil)
        #expect(SimulatorAllocation.reusable(duo, devices: devices, book: book)?.udid == duoFree.udid)
        // Created by ClaudeDeck but renamed: still its own.
        book.noteCreated(users.udid)
        #expect(SimulatorAllocation.reusable(iPhone, devices: [users], book: book)?.udid == users.udid)
        #expect(SimulatorAllocation.newName(for: iPhone, existing: devices.map(\.name)) == "ClaudeDeck · iPhone 17 Pro · 4")
        #expect(SimulatorAllocation.newName(for: duo, existing: []) == "ClaudeDeck · iPhone Duo · 1")
    }

    @Test func holdsAreNeverShared() throws {
        let a = UUID(), b = UUID()
        var book = SimulatorHoldBook()
        book.hold(SimulatorHold(udid: "aaaa-1", name: "one", session: a, created: true))
        book.hold(SimulatorHold(udid: "aaaa-2", name: "two", session: a, created: false))
        book.hold(SimulatorHold(udid: "bbbb-1", name: "three", session: b, created: true))
        #expect(book.holder(of: "AAAA-1") == a)
        #expect(book.created == ["AAAA-1", "BBBB-1"])
        // B can't release A's.
        #expect(book.release(session: b, udid: "aaaa-1").isEmpty)
        #expect(book.release(session: a, udid: "aaaa-1").map(\.udid) == ["AAAA-1"])
        #expect(book.held(by: a).map(\.udid) == ["AAAA-2"])
        // A session that's gone loses its holds; a deleted device leaves the pool.
        let gone = book.prune(sessions: [b], devices: ["BBBB-1"])
        #expect(gone.map(\.udid) == ["AAAA-2"])
        #expect(book.created == ["BBBB-1"])
        // Persisted as JSON.
        let back = try JSONDecoder().decode(SimulatorHoldBook.self, from: JSONEncoder().encode(book))
        #expect(back == book)
        #expect(book.release(session: b).count == 1 && book.holds.isEmpty)
    }

    @Test func parsesSimctlCatalogs() throws {
        let types = try SimulatorAllocation.parseDeviceTypes(Data(#"{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo","name":"iPhone Duo","productFamily":"iPhone","minRuntimeVersion":1}]}"#.utf8))
        #expect(types == [duo.withFamily("iPhone")])
        let runtimes = try SimulatorAllocation.parseRuntimes(Data(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4","isAvailable":true,"supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo","name":"iPhone Duo"}]},{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-0","isAvailable":true}]}"#.utf8))
        #expect(runtimes.count == 1)
        #expect(runtimes[0].supportedDeviceTypes == [duo.identifier])
    }

    // MARK: Usage per project

    private func assistant(_ id: String, at stamp: String, model: String = "claude-opus-5", input: Int = 10, output: Int = 100,
                           write: Int = 0, write1h: Int = 0, read: Int = 0, sidechain: Bool = false, text: String = "hi") -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"\#(stamp)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_1h_input_tokens":\#(write1h)}}}}"#
    }

    @Test func pricing() {
        // 1M output on Opus 5 = $25; on Opus 5.5 = $20; Sonnet 5 = $10; Fable = $50.
        #expect(ModelPricing.costMicros(model: "claude-opus-5", input: 0, output: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0) == 25_000_000)
        #expect(ModelPricing.costMicros(model: "claude-opus-5-5", input: 0, output: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0) == 20_000_000)
        #expect(ModelPricing.costMicros(model: "claude-sonnet-5", input: 0, output: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0) == 10_000_000)
        #expect(ModelPricing.costMicros(model: "claude-fable-5-1", input: 0, output: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0) == 50_000_000)
        // Cache: 5-minute write 1.25×, 1-hour write 2×, read 0.1× input ($5 on Opus 5).
        #expect(ModelPricing.costMicros(model: "claude-opus-5", input: 0, output: 0, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
                == 6_250_000 + 10_000_000 + 500_000)
        #expect(ModelPricing.price("something-new") == ModelPricing.price("claude-opus-5"))
    }

    @Test func transcriptUsageCountsEachReplyOnce() {
        var usage = TranscriptUsage()
        var seen: [String: Date] = [:]
        let since = Date(timeIntervalSince1970: 0)
        let lines = [
            assistant("msg_1", at: "2026-11-19T10:00:01.000Z", input: 5, output: 100, write: 1000, write1h: 1000, read: 20_000),
            // The same reply's next content block repeats the usage.
            assistant("msg_1", at: "2026-11-19T10:00:02.000Z", input: 5, output: 100, write: 1000, write1h: 1000, read: 20_000, text: "more"),
            #"{"type":"user","timestamp":"2026-11-19T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            // Sub-agents count too.
            assistant("msg_2", at: "2026-11-19T10:07:00.000Z", model: "claude-haiku-4-5", input: 1, output: 50, sidechain: true),
            // Before `since`: not counted (with since set later).
        ]
        usage.append(lines.joined(separator: "\n") + "\n", since: since, seen: &seen)
        let all = usage.slots.values.reduce(into: UsageTotals()) { $0 += $1 }
        #expect(all.messages == 2)
        #expect(all.input == 6 && all.output == 150 && all.cacheWrite == 1000 && all.cacheRead == 20_000)
        #expect(usage.slots.count == 2) // 10:00 and 10:05
        // Another file with the same reply (a resumed conversation) doesn't count it again.
        var other = TranscriptUsage()
        other.append(lines[0] + "\n", since: since, seen: &seen)
        #expect(other.slots.isEmpty)
        // Too old.
        var late = TranscriptUsage()
        var fresh: [String: Date] = [:]
        late.append(lines[0] + "\n", since: Transcript.parseDate("2026-11-20T00:00:00.000Z")!, seen: &fresh)
        #expect(late.slots.isEmpty)
    }

    @Test func transcriptUsageReadsIncrementally() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "t.jsonl")
        try (assistant("msg_a", at: "2026-11-19T10:00:00.000Z") + "\n" + #"{"type":"assistant","partial"#).write(to: file, atomically: true, encoding: .utf8)
        var usage = TranscriptUsage()
        var seen: [String: Date] = [:]
        #expect(usage.read(file, since: .distantPast, seen: &seen))
        #expect(usage.slots.values.reduce(0) { $0 + $1.messages } == 1)
        // The partial line is read once it's complete.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((":1}\n" + assistant("msg_b", at: "2026-11-19T10:01:00.000Z") + "\n").utf8))
        try handle.close()
        #expect(usage.read(file, since: .distantPast, seen: &seen))
        #expect(usage.slots.values.reduce(0) { $0 + $1.messages } == 2)
        // Shorter than read: start over.
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(!usage.read(file, since: .distantPast, seen: &seen))
    }

    @Test func transcriptFoldersMapToProjects() throws {
        let app = UUID(), appKit = UUID()
        let projects = [(id: app, path: "/Users/me/Projects/app"), (id: appKit, path: "/Users/me/Projects/app-kit")]
        #expect(ProjectUsageScanner.folderName(for: "/Users/me/Projects/my.app") == "-Users-me-Projects-my-app")
        #expect(ProjectUsageScanner.project(forFolder: "-Users-me-Projects-app", projects: projects) == app)
        #expect(ProjectUsageScanner.project(forFolder: "-Users-me-Projects-app-kit", projects: projects) == appKit)
        // A worktree below the project.
        #expect(ProjectUsageScanner.project(forFolder: "-Users-me-Projects-app--claude-worktrees-fix", projects: projects) == app)
        #expect(ProjectUsageScanner.project(forFolder: "-Users-me-Projects-apple", projects: projects) == nil)

        // Files on disk: recent ones in the project's folders (sub-agents included), plus extra sources.
        let root = FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "-Users-me-Projects-app/abc/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "-Users-me-Projects-app/abc.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: "agent-1.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "-Users-other"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "-Users-other/z.jsonl"), atomically: true, encoding: .utf8)
        let old = root.appending(path: "-Users-me-Projects-app/old.jsonl")
        try "x".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)], ofItemAtPath: old.path)
        let sources = ProjectUsageScanner.sources(root: root, projects: projects, extra: [.init(path: "/elsewhere/s.jsonl", project: appKit)],
                                                  since: Date(timeIntervalSinceNow: -7 * 86400))
        #expect(sources.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted() == ["abc.jsonl", "agent-1.jsonl", "s.jsonl"])
        #expect(sources.first { $0.path.hasSuffix("s.jsonl") }?.project == appKit)
        #expect(sources.first { $0.path.hasSuffix("abc.jsonl") }?.project == app)
    }

    @Test func sharesSplitThePlansWindows() {
        let a = UUID(), b = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(3600) // the 5-hour window began 4 hours ago
        func slot(_ ago: TimeInterval) -> Date { Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - ago) / 300).rounded(.down) * 300) }
        let slots: [UUID: [Date: UsageTotals]] = [
            a: [slot(600): UsageTotals(output: 1000, costMicros: 3_000_000, messages: 3),
                slot(5 * 3600): UsageTotals(output: 9000, costMicros: 6_000_000, messages: 9)], // before the 5-hour window
            b: [slot(1200): UsageTotals(output: 500, costMicros: 1_000_000, messages: 1)],
        ]
        let usage = ClaudeUsage(fiveHour: UsageWindow(usedPercent: 40, resetsAt: reset),
                                sevenDay: UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now)
        let shares = ProjectUsageReport.make(slots, names: [a: "A", b: "B"], usage: usage, now: now)
        #expect(shares.map(\.name) == ["A", "B"])
        let sa = shares[0], sb = shares[1]
        #expect(sa.fiveHour.messages == 3 && sa.week.messages == 12)
        #expect(abs(sa.fiveHourShare - 0.75) < 1e-9 && abs(sb.fiveHourShare - 0.25) < 1e-9)
        #expect(abs((sa.fiveHourPercent ?? 0) - 30) < 1e-9 && abs((sb.fiveHourPercent ?? 0) - 10) < 1e-9)
        #expect(abs(sa.weekShare - 0.9) < 1e-9 && abs((sa.weekPercent ?? 0) - 18) < 1e-9)
        // Without the plan's reading: shares only, the last 5 hours.
        let bare = ProjectUsageReport.make(slots, names: [:], usage: nil, now: now)
        #expect(bare.allSatisfy { $0.fiveHourPercent == nil && $0.weekPercent == nil })
        #expect(ProjectUsageReport.text(shares, usage: usage).contains("PROJECT"))
        #expect(ProjectUsageReport.windowStart(resetsAt: reset, length: ProjectUsageReport.fiveHours, now: now) == now.addingTimeInterval(-4 * 3600))
        #expect(ProjectUsageReport.windowStart(resetsAt: nil, length: ProjectUsageReport.fiveHours, now: now) == now.addingTimeInterval(-5 * 3600))
    }

    @Test func dashboardStaysCompatible() throws {
        // A snapshot from a Mac without `projects` decodes; one with it round-trips, rounded.
        let old = #"{"working":1,"waiting":0,"yourTurn":0,"waitingList":[],"moreWaiting":0}"#
        let decoded = try JSONDecoder().decode(RemoteDashboard.self, from: Data(old.utf8))
        #expect(decoded.projects == nil)
        let share = RemoteDashboard.ProjectShare(projectID: UUID(), name: "app", fiveHourPercent: 12.345, weekPercent: nil, fiveHourShare: 0.123456,
                                                 weekShare: 1, fiveHourTokens: 1_234_567, weekTokens: 999, weekCost: 3.14159)
        #expect(share.fiveHourPercent == 12.3 && share.fiveHourShare == 0.123 && share.fiveHourTokens == 1_230_000 && share.weekCost == 3.14)
        var dashboard = decoded
        dashboard.projects = [share]
        let back = try JSONDecoder().decode(RemoteDashboard.self, from: JSONEncoder().encode(dashboard))
        #expect(back.projects == [share])
        let sim = try JSONDecoder().decode(RemoteSimulator.self, from: Data(#"{"udid":"X","name":"n","runtime":"iOS 27","state":"Booted","sessionIDs":[]}"#.utf8))
        #expect(sim.heldBy == nil)
    }

    // MARK: Stall watch

    @Test func stallChecks() {
        var settings = StallSettings()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let tracker = StallTracker(lastProgress: start)
        let later = start.addingTimeInterval(16 * 60)
        // Off by default.
        #expect(StallWatch.check(tracker, working: true, startedBySession: true, settings: settings, now: later) == nil)
        settings.enabled = true
        #expect(StallWatch.check(tracker, working: true, startedBySession: true, settings: settings, now: later) == .noProgress(since: start))
        // Only sessions another session started, only while working, only after N minutes.
        #expect(StallWatch.check(tracker, working: true, startedBySession: false, settings: settings, now: later) == nil)
        #expect(StallWatch.check(tracker, working: false, startedBySession: true, settings: settings, now: later) == nil)
        #expect(StallWatch.check(tracker, working: true, startedBySession: true, settings: settings, now: start.addingTimeInterval(14 * 60)) == nil)
        var moved = tracker
        moved.progress(at: start.addingTimeInterval(10 * 60))
        #expect(StallWatch.check(moved, working: true, startedBySession: true, settings: settings, now: later) == nil)
    }

    @Test func errorLoops() {
        var settings = StallSettings()
        settings.enabled = true
        var tracker = StallTracker(lastProgress: Date())
        tracker.results(["Error: build failed at line #", "Error: build failed at line #"], texts: ["Error: build failed at line 12", nil])
        #expect(StallWatch.check(tracker, working: true, startedBySession: true, settings: settings) == nil)
        tracker.results(["Error: build failed at line #"])
        #expect(StallWatch.check(tracker, working: true, startedBySession: true, settings: settings)
                == .errorLoop(count: 3, error: "Error: build failed at line 12"))
        // A success in between ends the run; a different error starts a new one.
        tracker.results([nil, "Error: build failed at line #", "other", "other"])
        #expect(tracker.errorCount == 2 && tracker.errorSignature == "other")
        settings.errorRepeats = 0
        tracker.results(["other", "other"])
        #expect(StallWatch.check(tracker, working: false, startedBySession: true, settings: settings) == nil)
    }

    @Test func errorSignaturesFromTranscript() {
        let chunk = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":"Exit code 1\nerror: build failed (line 12)"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","is_error":true,"content":[{"type":"text","text":"Exit code 1\nerror: build failed (line 13)"}]}]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","is_error":true,"content":"sub-agent"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"d","content":"ok"}]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529 overloaded"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
        ].joined(separator: "\n")
        let results = StallWatch.results(in: chunk)
        #expect(results.count == 4)
        #expect(results[0].signature != nil && results[0].signature == results[1].signature)
        #expect(results[2].signature == nil)
        #expect(results[3].signature == "API Error: # overloaded")
    }

    @Test func nudgesAreCapped() {
        var settings = StallSettings()
        settings.enabled = true
        settings.action = .nudge
        let now = Date()
        var tracker = StallTracker(lastProgress: now.addingTimeInterval(-3600))
        for i in 0..<StallWatch.maxInterventionsPerHour {
            let decision = StallWatch.action(for: settings, tracker: tracker, now: now.addingTimeInterval(Double(i)))
            #expect(decision.action == .nudge && !decision.capped)
            StallWatch.acted(&tracker, action: decision.action, reason: .noProgress(since: tracker.lastProgress), now: now.addingTimeInterval(Double(i)))
        }
        // The fourth in the hour is a notification only.
        let capped = StallWatch.action(for: settings, tracker: tracker, now: now.addingTimeInterval(60))
        #expect(capped.action == .notify && capped.capped)
        // An hour later it may nudge again.
        #expect(StallWatch.action(for: settings, tracker: tracker, now: now.addingTimeInterval(3700)).action == .nudge)
        // Acting starts the clock over.
        #expect(tracker.lastProgress == now.addingTimeInterval(2) && tracker.lastAction == "nudge")
        settings.action = .notify
        #expect(StallWatch.action(for: settings, tracker: tracker, now: now).action == .notify)
    }

    @Test func statusText() {
        let status = SessionCLIStatus(id: UUID(), name: "api tests", kind: "claude", state: "running", detail: nil, project: "app",
                                      startedBy: UUID(uuidString: "C0000000-0000-0000-0000-000000000001"),
                                      stall: .init(watching: true, stalled: "no_progress", lastProgressAt: Date(), minutesWithoutProgress: 20,
                                                   repeatedErrors: 0, lastAction: "nudge", lastActionAt: Date(), interventionsLastHour: 1),
                                      simulators: ["UDID-1"])
        let text = status.text
        #expect(text.contains("stalled (no_progress)") && text.contains("20 min") && text.contains("C0000000") && text.contains("UDID-1"))
    }
}

private extension SimulatorDeviceType {
    func withFamily(_ family: String) -> SimulatorDeviceType { SimulatorDeviceType(identifier: identifier, name: name, productFamily: family) }
}
