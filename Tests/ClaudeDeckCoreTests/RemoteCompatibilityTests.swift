import Foundation
import Testing
@testable import ClaudeDeckCore

/// Mixed versions: a phone or Mac on this build talking to a 0.5.9 host, a newer host talking to
/// this build, and deck.json files from either side. New fields and features are optional, and
/// what a side doesn't know is ignored.
@Suite struct RemoteCompatibilityTests {
    /// A snapshot exactly as a 0.5.9 host encodes it (captured from that version's types).
    static let snapshotFrom059 = #"""
    {"snapshot":{"_0":{"addresses":["10.0.0.2"],"features":["historyUpdates","queue","addProject","renameFolder","files","permissionMode","agentCompletion","agents","agentApproval","transfer","homeFiles","edits","conversationPush","sessionActions","projectActions","agentDetails"],"hostID":"A0000000-0000-0000-0000-000000000001","hostName":"main-mac","sessions":[{"id":"A0000000-0000-0000-0000-000000000001","name":"zsh","project":"p","state":"shell","unseen":false,"updatedAt":1800000000},{"detail":"Done","id":"A0000000-0000-0000-0000-000000000002","name":"c","project":"p","state":"idle","unseen":true,"updatedAt":1800000000}]}}}
    """#

    static func decode(_ json: String) throws -> RemoteMessage? {
        try RemoteMessage.decode(RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: Data(json.utf8)))
    }

    @Test func snapshotFromAnOlderHostDecodes() throws {
        guard case .snapshot(let snapshot)? = try Self.decode(Self.snapshotFrom059) else {
            Issue.record("not a snapshot"); return
        }
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.sessions.allSatisfy { $0.program == nil })
        #expect(snapshot.serverPlan == nil)
        #expect(!snapshot.supports(RemoteSnapshot.Feature.programStatus))
        #expect(!snapshot.supports(RemoteSnapshot.Feature.serverPlan))
        #expect(snapshot.supports(RemoteSnapshot.Feature.edits))
        #expect(!snapshot.sessions[0].needsAttention)
        #expect(snapshot.sessions[1].needsAttention)
    }

    @Test func unknownFeaturesFieldsAndStatesFromANewerHostAreIgnored() throws {
        let json = #"""
        {"snapshot":{"_0":{"hostName":"next","features":["files","programStatus","serverPlan","teleport"],"somethingNew":{"a":1},
          "serverPlan":{"servers":[{"id":1,"name":"h","status":"melting","cpu":3}],"deploys":[],"extra":true},
          "sessions":[{"id":"A0000000-0000-0000-0000-000000000003","name":"t","project":"p","state":"shell","unseen":true,
                       "program":{"state":"hibernating","glow":2},"futureField":[1,2]}]}}}
        """#
        guard case .snapshot(let snapshot)? = try Self.decode(json) else {
            Issue.record("not a snapshot"); return
        }
        #expect(snapshot.supports(RemoteSnapshot.Feature.programStatus))
        #expect(snapshot.supports(RemoteSnapshot.Feature.serverPlan))
        #expect(snapshot.serverPlan?.servers.first?.name == "h")
        let session = try #require(snapshot.sessions.first)
        #expect(session.program?.state == "hibernating")
        // A state this build doesn't know neither asks for the user nor counts as a result.
        #expect(!session.needsAttention)
    }

    @Test func everyNewFeatureIsAdvertised() {
        let all = RemoteSnapshot.Feature.all
        #expect(all.contains(RemoteSnapshot.Feature.programStatus))
        #expect(all.contains(RemoteSnapshot.Feature.serverPlan))
    }

    /// What an older remote reads from a terminal with Program Status: a plain terminal (`state`
    /// "shell") whose detail says it in words; the extra fields are left for newer remotes.
    @Test func programStatusTerminalStaysAPlainTerminalOnTheWire() throws {
        var session = RemoteSession(id: UUID(), name: "dev.sh", project: "p", state: .shell, detail: "Needs input", unseen: true)
        session.program = RemoteProgramStatus(state: "blocked", kind: "question")
        var snapshot = RemoteSnapshot(hostName: "h", sessions: [session])
        snapshot.serverPlan = RemoteServerPlan(servers: [], deploys: [])
        let frame = try RemoteMessage.snapshot(snapshot).frame()
        let object = try #require(try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        let inner = try #require((object["snapshot"] as? [String: Any])?["_0"] as? [String: Any])
        let wire = try #require((inner["sessions"] as? [[String: Any]])?.first)
        #expect(wire["state"] as? String == "shell")
        #expect(wire["detail"] as? String == "Needs input")
    }

    @Test func deckFromAnOlderVersionHasEveryNewSettingOff() throws {
        let json = #"""
        {"version":1,"projects":[{"id":"B0000000-0000-0000-0000-000000000001","path":"/tmp/p","name":"p","pinned":false,"collapsed":false}],
         "sessions":[{"id":"B0000000-0000-0000-0000-000000000002","projectID":"B0000000-0000-0000-0000-000000000001","name":"t","kind":"shell","futureField":1}],
         "settings":{"notifications":true,"futureSetting":"x"},"futureTop":[]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let deck = try decoder.decode(DeckData.self, from: Data(json.utf8))
        let session = try #require(deck.sessions.first)
        #expect(session.showProgramStatus == nil)
        #expect(session.openedBy == nil)
        #expect(session.serverPlanTerminal == nil)
        #expect(!deck.showsProgramStatus(session.id))
        #expect(!deck.settings.terminalProgramStatus)
        #expect(!deck.settings.simulators)
        #expect(!deck.settings.sessionCLIEnabled)
        #expect(!deck.settings.sessionsMayTypeIntoClaude)
        #expect(deck.settings.serverPlanURL.isEmpty)
        #expect(deck.deployRepairRequests.isEmpty)
    }
}
