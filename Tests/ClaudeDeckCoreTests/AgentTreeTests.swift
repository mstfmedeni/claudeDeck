import Foundation
import Testing
@testable import ClaudeDeckCore

/// The Agents overview's tree (AgentTree.swift).
@Suite struct AgentTreeTests {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    @Test func onlyAgentTreesAndNesting() {
        let members = [
            AgentTree.Member(id: id(1), group: "A", startedBy: nil),     // lead
            AgentTree.Member(id: id(2), group: "A", startedBy: id(1)),
            AgentTree.Member(id: id(3), group: "A", startedBy: id(2)),
            AgentTree.Member(id: id(4), group: "A", startedBy: nil),     // started nobody: left out
            AgentTree.Member(id: id(5), group: "A", startedBy: id(1)),
        ]
        let groups = AgentTree.build(members, groupOrder: ["A"])
        #expect(groups.count == 1)
        let rows = groups[0].rows { _ in true }
        #expect(rows.map(\.id) == [id(1), id(2), id(3), id(5)])
        #expect(rows.map(\.depth) == [0, 1, 2, 1])
        #expect(AgentTree.build([members[3]], groupOrder: ["A"]).isEmpty)
    }

    @Test func crossProjectStarts() {
        let members = [
            AgentTree.Member(id: id(1), group: "A", startedBy: nil),
            AgentTree.Member(id: id(2), group: "B", startedBy: id(1)),
            AgentTree.Member(id: id(3), group: "B", startedBy: id(1)),
            AgentTree.Member(id: id(4), group: "B", startedBy: id(2)),
            AgentTree.Member(id: id(5), group: "C", startedBy: id(1)),
        ]
        // B comes first in the sidebar order; C isn't in it and goes last.
        let groups = AgentTree.build(members, groupOrder: ["B", "A"])
        #expect(groups.map(\.key) == ["B", "A", "C"])
        let a = groups[1].roots[0]
        #expect(a.children.isEmpty)
        #expect(a.crossChildren == [AgentTree.CrossCount(group: "B", count: 2), AgentTree.CrossCount(group: "C", count: 1)])
        let b = groups[0].rows { _ in true }
        #expect(b.map(\.id) == [id(2), id(4), id(3)])
        #expect(b[0].node.crossStarter == id(1) && b[1].node.crossStarter == nil && b[2].node.crossStarter == id(1))
    }

    @Test func goneStarterAndLoops() {
        let members = [
            AgentTree.Member(id: id(1), group: "A", startedBy: id(99)),  // its starter was removed
            AgentTree.Member(id: id(2), group: "A", startedBy: id(3)),   // a loop: 2 ↔ 3
            AgentTree.Member(id: id(3), group: "A", startedBy: id(2)),
            AgentTree.Member(id: id(4), group: "A", startedBy: id(4)),   // itself: not a tree
        ]
        let rows = AgentTree.build(members, groupOrder: [])[0].rows { _ in true }
        #expect(rows.map(\.id) == [id(1), id(2), id(3)])
        #expect(rows[0].node.starterGone && !rows[1].node.starterGone)
        #expect(rows.map(\.depth) == [0, 0, 1])
    }

    @Test func filterKeepsStarters() {
        let members = [
            AgentTree.Member(id: id(1), group: "A", startedBy: nil),
            AgentTree.Member(id: id(2), group: "A", startedBy: id(1)),
            AgentTree.Member(id: id(3), group: "A", startedBy: id(2)),
            AgentTree.Member(id: id(4), group: "A", startedBy: id(1)),
        ]
        let group = AgentTree.build(members, groupOrder: ["A"])[0]
        let rows = group.rows { $0 == id(3) }
        #expect(rows.map(\.id) == [id(1), id(2), id(3)])
        #expect(rows.map(\.matches) == [false, false, true])
        #expect(group.rows { _ in false }.isEmpty)
        #expect(group.count == 4)
    }

    /// `RemoteSession.agent` and the snapshot's counts are optional both ways: an older phone
    /// ignores them, an older Mac's snapshot decodes without them.
    @Test func remoteCompatibility() throws {
        var session = RemoteSession(id: id(1), name: "lead", project: "A", state: .running)
        session.agent = RemoteAgentInfo(startedBy: id(2), model: "opus", effort: "high", permissionMode: "acceptEdits",
                                        limitState: "limit_reached", simulators: 1, pendingDecisions: 2, queuedStarts: 3)
        var snapshot = RemoteSnapshot(hostName: "Mac", sessions: [session])
        snapshot.agentsRunning = 4
        snapshot.agentsCap = 6
        snapshot.agentsQueued = 1
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        #expect(back == snapshot)
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.agentTree))
        let json = """
        {"hostName":"Mac","sessions":[{"id":"00000000-0000-0000-0000-000000000001","name":"s","project":"A","state":"idle","unseen":false}]}
        """
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(json.utf8))
        #expect(old.sessions[0].agent == nil && old.agentsCap == nil && !old.supports(RemoteSnapshot.Feature.agentTree))
    }
}
