import Foundation
import Testing
@testable import ClaudeDeckCore

/// The phone's newer snapshot fields (dashboard, simulators, ServerPlan projects) and the
/// Fix with Claude message, between this build and older or newer versions on the other side.
@Suite struct PhoneSnapshotCompatibilityTests {
    static func decode(_ json: String) throws -> RemoteMessage? {
        try RemoteMessage.decode(RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: Data(json.utf8)))
    }

    static func sample() -> RemoteSnapshot {
        var snapshot = RemoteSnapshot(hostName: "mac", sessions: [])
        snapshot.features = RemoteSnapshot.Feature.all
        let waiting = RemoteDashboard.Waiting(sessionID: UUID(), name: "api", project: "p", reason: "permission", detail: "Bash: ls",
                                              since: Date(timeIntervalSince1970: 1_800_000_000))
        snapshot.dashboard = RemoteDashboard(working: 2, waiting: 1, yourTurn: 3, linesAdded: 120, linesRemoved: 7, waitingList: [waiting],
                                             fiveHour: RemoteDashboard.Window(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_800_010_000),
                                                                              limitAt: Date(timeIntervalSince1970: 1_800_005_000), ratePerHour: 12.5),
                                             week: nil)
        snapshot.simulators = [RemoteSimulator(udid: "U1", name: "iPhone 17", runtime: "iOS 26.0", state: "Booted",
                                               memoryBytes: 1_200_000_000, sessionIDs: [waiting.sessionID])]
        var plan = RemoteServerPlan(servers: [.init(id: 1, name: "web-1", status: "online")], deploys: [])
        plan.projects = [.init(id: 3, name: "shop", serverID: 1, lastDeployID: 9, lastDeployStatus: "failed", lastDeployAt: nil)]
        snapshot.serverPlan = plan
        return snapshot
    }

    @Test func newFieldsRoundTrip() throws {
        let snapshot = Self.sample()
        guard case .snapshot(let decoded)? = try RemoteMessage.decode(try RemoteMessage.snapshot(snapshot).frame()) else {
            Issue.record("not a snapshot"); return
        }
        #expect(decoded == snapshot)
        #expect(decoded.supports(RemoteSnapshot.Feature.dashboard))
        #expect(decoded.supports(RemoteSnapshot.Feature.simulators))
        #expect(decoded.supports(RemoteSnapshot.Feature.serverPlanRepair))
    }

    /// An older phone (0.5.9 types: no dashboard, simulators or projects) reads a new snapshot.
    @Test func olderRemoteDecodesANewSnapshot() throws {
        struct OldServerPlan: Decodable { var servers: [RemoteServerPlan.Server]; var deploys: [RemoteServerPlan.Deploy] }
        struct OldSnapshot: Decodable { var hostName: String; var sessions: [RemoteSession]; var features: Set<String>?; var serverPlan: OldServerPlan? }
        struct OldMessage: Decodable { var snapshot: [String: OldSnapshot] }
        let frame = try RemoteMessage.snapshot(Self.sample()).frame()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let old = try decoder.decode(OldMessage.self, from: frame.payload)
        let snapshot = try #require(old.snapshot["_0"])
        #expect(snapshot.hostName == "mac")
        #expect(snapshot.serverPlan?.servers.first?.name == "web-1")
    }

    /// A newer phone talking to an older Mac (and to one without the extras): nothing to show,
    /// and none of the new features to rely on.
    @Test func olderHostHasNoneOfTheNewFields() throws {
        guard case .snapshot(let snapshot)? = try Self.decode(RemoteCompatibilityTests.snapshotFrom059) else {
            Issue.record("not a snapshot"); return
        }
        #expect(snapshot.dashboard == nil)
        #expect(snapshot.simulators == nil)
        #expect(!snapshot.supports(RemoteSnapshot.Feature.dashboard))
        #expect(!snapshot.supports(RemoteSnapshot.Feature.simulators))
        #expect(!snapshot.supports(RemoteSnapshot.Feature.serverPlanRepair))
        // The integration build: ServerPlan without projects.
        let json = #"{"snapshot":{"_0":{"hostName":"h","sessions":[],"features":["serverPlan"],"serverPlan":{"servers":[],"deploys":[]}}}}"#
        guard case .snapshot(let integration)? = try Self.decode(json) else { Issue.record("not a snapshot"); return }
        #expect(integration.serverPlan?.projects == nil)
        #expect(!integration.supports(RemoteSnapshot.Feature.serverPlanRepair))
    }

    /// A newer Mac's extra fields and reasons are ignored.
    @Test func newerHostExtrasAreIgnored() throws {
        let json = #"""
        {"snapshot":{"_0":{"hostName":"next","sessions":[],"features":["dashboard","simulators","warp"],
          "dashboard":{"working":1,"waiting":0,"yourTurn":0,"waitingList":[{"sessionID":"A0000000-0000-0000-0000-000000000009","name":"x","project":"p","reason":"dreaming","since":1800000000,"mood":1}],
                       "moreWaiting":0,"burn":[1,2]},
          "simulators":[{"udid":"U","name":"n","runtime":"r","state":"Melting","sessionIDs":[],"gpu":3}]}}}
        """#
        guard case .snapshot(let snapshot)? = try Self.decode(json) else { Issue.record("not a snapshot"); return }
        let waiting = try #require(snapshot.dashboard?.waitingList.first)
        #expect(waiting.reason == "dreaming")
        #expect(!waiting.isBlocked)
        #expect(snapshot.dashboard?.linesAdded == nil)
        #expect(snapshot.simulators?.first?.isBooted == false)
    }

    /// Why the phone checks `Feature.serverPlanRepair` first: a Mac without the message can't
    /// decode it (it drops the message).
    @Test func repairMessageNeedsTheFeature() throws {
        let frame = try RemoteMessage.serverPlanRepair(deploymentID: 12).frame()
        #expect(try RemoteMessage.decode(frame) == .serverPlanRepair(deploymentID: 12))
        enum OldMessage: Codable { case ping, pong }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(OldMessage.self, from: frame.payload) }
        let result = RemoteMessage.serverPlanRepairResult(deploymentID: 12, sessionID: nil, error: "No project")
        #expect(try RemoteMessage.decode(try result.frame()) == result)
    }

    @Test func dashboardWaitingIsSortedAndCapped() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let list = (0..<8).map { i in
            RemoteDashboard.Waiting(sessionID: UUID(), name: "s\(i)", project: "", reason: i % 3 == 0 ? "idle" : "question", detail: nil,
                                    since: base.addingTimeInterval(Double(i) * 60))
        }
        let top = RemoteDashboard.top(list)
        #expect(top.list.count == RemoteDashboard.maxWaiting)
        #expect(top.more == 3)
        // Blocked first, longest wait (earliest) first.
        #expect(top.list.map(\.name) == ["s1", "s2", "s4", "s5", "s7"])
    }

    @Test func usageWindowIsStableBetweenBuilds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(4 * 3600))
        let samples = stride(from: 0, through: 60, by: 10).map { m in (at: now.addingTimeInterval(Double(m - 60) * 60), percent: 20 + Double(m) / 3) }
        let a = RemoteDashboard.Window.make(window, length: 5 * 3600, samples: samples, now: now)
        let b = RemoteDashboard.Window.make(window, length: 5 * 3600, samples: samples, now: now.addingTimeInterval(2))
        #expect(a.limitAt != nil)
        #expect(a == b)
        #expect(a.limitAt!.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)
        #expect(a.hitsLimitBeforeReset)
    }

    @Test func simulatorsForRemoteRunningFirst() {
        let list = [RemoteSimulator(udid: "b", name: "B", runtime: "", state: "Shutdown"),
                    RemoteSimulator(udid: "a", name: "Z", runtime: "", state: "Booted")]
        #expect(RemoteSimulator.forRemote(list).map(\.udid) == ["a", "b"])
        #expect(RemoteSimulator.forRemote(list, max: 1).count == 1)
    }
}

@Suite struct RemoteConnectionLogTests {
    @Test func routes() {
        typealias Route = RemoteConnectionLog.Route
        #expect(Route.of(address: "192.168.1.20", via: .system) == .lan)
        #expect(Route.of(address: "10.0.0.2", via: .system) == .lan)
        #expect(Route.of(address: "studio.local", via: .system) == .lan)
        #expect(Route.of(address: "100.101.102.103", via: .system) == .tailscale)
        #expect(Route.of(address: "studio.tail1234.ts.net", via: .system) == .tailscale)
        #expect(Route.of(address: "100.101.102.103", via: .inApp) == .inAppTailscale)
        #expect(Route.of(address: "mac.example.com", via: .system) == .other)
        #expect(Route.of(address: "fdserver", via: .system) == .other)
    }

    @Test func keepsTheLastFiftyNewestLast() {
        var log = RemoteConnectionLog()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<60 {
            log.attempt(address: "10.0.0.\(i)", route: .system, startedAt: t0, outcome: .failed("timeout"), now: t0.addingTimeInterval(1.5))
        }
        #expect(log.entries.count == RemoteConnectionLog.capacity)
        guard case .attempt(let address, _, _, let duration) = log.entries.last?.kind else { Issue.record("no attempt"); return }
        #expect(address == "10.0.0.59")
        #expect(duration == 1.5)
        #expect(Set(log.entries.map(\.id)).count == log.entries.count)
        log.removeAll()
        #expect(log.entries.isEmpty)
    }

    @Test func textForSupport() {
        var log = RemoteConnectionLog()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.attempt(address: "100.64.0.1", route: .system, startedAt: t0, outcome: .failed("Network is down"), now: t0.addingTimeInterval(8))
        log.backoff(wait: 4, reason: "Couldn't reach the Mac", at: t0.addingTimeInterval(8))
        log.attempt(address: "100.64.0.1", route: .inApp, startedAt: t0.addingTimeInterval(12), outcome: .connected, now: t0.addingTimeInterval(13))
        log.attempt(address: "mac.local", route: .system, startedAt: t0.addingTimeInterval(12), outcome: .cancelled, now: t0.addingTimeInterval(13))
        log.attempt(address: "10.0.0.2", route: .system, startedAt: t0, outcome: .refused("wrong key"), now: t0)
        let lines = log.text(timeZone: TimeZone(identifier: "UTC")!).split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        #expect(lines[0].hasSuffix("10.0.0.2 [lan] refused: wrong key (0.00 s)"))
        #expect(lines[2].contains("100.64.0.1 [inAppTailscale] connected (1.00 s)"))
        #expect(lines[3].contains("retry in 4 s after: Couldn't reach the Mac"))
        #expect(lines[4] == "2027-01-15 08:00:00.000 100.64.0.1 [tailscale] failed: Network is down (8.00 s)")
    }
}
