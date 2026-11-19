import Foundation
import Testing
@testable import ClaudeDeckCore

/// Clearing ServerPlan errors: local bookkeeping in deck.json (nothing changes on the panel).
@Suite struct ServerIssueTests {
    let panel = URL(string: "https://panel.example.com")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func clearedDeployStaysClearedAndANewOneShows() {
        var deck = DeckData()
        let failed = ServerIssue.deploy(panel: panel, deploymentID: 41)
        #expect(!deck.isDismissed(failed))
        deck.dismissServerIssues([failed], now: now)
        #expect(deck.isDismissed(failed))
        // The redeploy that fails is another deployment id: it shows.
        #expect(!deck.isDismissed(.deploy(panel: panel, deploymentID: 42)))
        // The same id on another panel is another deploy.
        #expect(!deck.isDismissed(.deploy(panel: URL(string: "https://other.example.com")!, deploymentID: 41)))
        // Clearing it again doesn't add a second entry.
        deck.dismissServerIssues([failed, failed], now: now)
        #expect(deck.dismissedServerIssues.count == 1)
    }

    @Test func aDifferentErrorOnTheSameServerShowsAgain() {
        var deck = DeckData()
        deck.dismissServerIssues([.server(panel: panel, serverID: 3, message: "unreachable:ssh timeout")], now: now)
        #expect(deck.isDismissed(.server(panel: panel, serverID: 3, message: "unreachable:ssh timeout")))
        #expect(!deck.isDismissed(.server(panel: panel, serverID: 3, message: "docker")))
        #expect(!deck.isDismissed(.server(panel: panel, serverID: 4, message: "unreachable:ssh timeout")))
    }

    /// A server back up / the panel answering again forgets the clearing: the next failure with
    /// the very same text shows.
    @Test func recoveryForgetsTheClearing() {
        var deck = DeckData()
        let down = ServerIssue.server(panel: panel, serverID: 3, message: "offline")
        let panelError = ServerIssue.panel(panel, message: "Couldn't connect")
        let deploy = ServerIssue.deploy(panel: panel, deploymentID: 9)
        deck.dismissServerIssues([down, panelError, deploy], now: now)
        let forgot = deck.forgetServerIssues([down.key, panelError.key])
        #expect(forgot)
        #expect(!deck.isDismissed(down) && !deck.isDismissed(panelError))
        #expect(deck.isDismissed(deploy))
        let again = deck.forgetServerIssues([down.key])
        #expect(!again)
    }

    @Test func pruningDropsOldEntriesButKeepsListedFailures() {
        var deck = DeckData()
        let old = ServerIssue.deploy(panel: panel, deploymentID: 1)
        let stillListed = ServerIssue.deploy(panel: panel, deploymentID: 2)
        let recent = ServerIssue.deploy(panel: panel, deploymentID: 3)
        deck.dismissServerIssues([old, stillListed], now: now.addingTimeInterval(-31 * 24 * 3600))
        deck.dismissServerIssues([recent], now: now.addingTimeInterval(-29 * 24 * 3600))
        let pruned = deck.pruneDismissedServerIssues(keeping: [stillListed.key], now: now)
        #expect(pruned)
        #expect(!deck.isDismissed(old))
        #expect(deck.isDismissed(stillListed))
        #expect(deck.isDismissed(recent))
        let prunedAgain = deck.pruneDismissedServerIssues(keeping: [stillListed.key], now: now)
        #expect(!prunedAgain)
    }

    @Test func entriesAreCapped() {
        var deck = DeckData()
        deck.dismissServerIssues((0..<(ServerIssues.maxEntries + 20)).map { ServerIssue.deploy(panel: panel, deploymentID: $0) }, now: now)
        #expect(deck.dismissedServerIssues.count == ServerIssues.maxEntries)
        #expect(deck.isDismissed(.deploy(panel: panel, deploymentID: ServerIssues.maxEntries + 19)))
        #expect(!deck.isDismissed(.deploy(panel: panel, deploymentID: 0)))
    }

    @Test func survivesSavingAndOldFilesLoad() throws {
        var deck = DeckData()
        deck.dismissServerIssues([.deploy(panel: panel, deploymentID: 7)], now: now)
        let decoded = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(decoded.isDismissed(.deploy(panel: panel, deploymentID: 7)))
        #expect(decoded.dismissedServerIssues.first?.dismissedAt == now)
        // A deck.json from before the key: nothing cleared, the rest intact.
        let legacy = try JSONDecoder().decode(DeckData.self, from: Data(#"{"sessions":[],"deployRepairRequests":[{"key":"k","requestedAt":0}]}"#.utf8))
        #expect(legacy.dismissedServerIssues.isEmpty)
        #expect(legacy.deployRepairRequest("k") != nil)
        // A broken entry is skipped, not the whole deck.
        let partial = try JSONDecoder().decode(DeckData.self, from: Data(#"{"dismissedServerIssues":[{"key":"a#deploy:1","signature":"failed","dismissedAt":0},{"key":5}]}"#.utf8))
        #expect(partial.dismissedServerIssues.map(\.key) == ["a#deploy:1"])
    }

    /// The phone's message round-trips; the phone only sends it to Macs that list the feature.
    @Test func phoneMessageAndFeature() throws {
        let message = RemoteMessage.dismissServerIssues(deploymentIDs: [3, 4], all: false)
        #expect(try RemoteMessage.decode(try message.frame()) == message)
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.dismissServerIssues))
        let older = #"{"snapshot":{"_0":{"hostName":"h","sessions":[],"features":["serverPlan","serverPlanRepair"],"serverPlan":{"servers":[],"deploys":[],"projects":[{"id":1,"name":"api","lastDeployStatus":"failed"}]}}}}"#
        guard case .snapshot(let snapshot)? = try RemoteMessage.decode(RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: Data(older.utf8))) else {
            Issue.record("not a snapshot"); return
        }
        #expect(!snapshot.supports(RemoteSnapshot.Feature.dismissServerIssues))
        #expect(snapshot.serverPlan?.projects?.first?.lastDeployCleared == nil)
    }
}
