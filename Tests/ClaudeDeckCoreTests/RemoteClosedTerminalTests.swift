import Foundation
import Testing
@testable import ClaudeDeckCore

/// Stopped plain terminals on the wire: listed with the closed sessions (`.notStarted`) and marked
/// by `kind`, so a remote can start them again; older remotes and hosts keep working.
@Suite struct RemoteClosedTerminalTests {
    static let terminalID = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
    static let claudeID = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!

    static func snapshot() -> RemoteSnapshot {
        var terminal = RemoteSession(id: terminalID, name: "dev server", project: "web", state: .notStarted)
        terminal.kind = RemoteSession.terminalKind
        var claude = RemoteSession(id: claudeID, name: "web", project: "web", state: .notStarted)
        claude.kind = RemoteSession.claudeKind
        var snapshot = RemoteSnapshot(hostName: "mac", sessions: [terminal, claude])
        snapshot.features = RemoteSnapshot.Feature.all
        return snapshot
    }

    @Test func stoppedTerminalRoundTrips() throws {
        let frame = try RemoteMessage.snapshot(Self.snapshot()).frame()
        guard case .snapshot(let decoded)? = try RemoteMessage.decode(frame) else {
            Issue.record("not a snapshot"); return
        }
        #expect(decoded == Self.snapshot())
        let terminal = try #require(decoded.session(Self.terminalID))
        #expect(terminal.state == .notStarted)
        #expect(terminal.isTerminal)
        #expect(!terminal.needsAttention)
        #expect(decoded.session(Self.claudeID)?.isTerminal == false)
        #expect(decoded.supports(RemoteSnapshot.Feature.closedTerminals))
    }

    @Test func runningTerminalIsATerminalWithoutKind() {
        // Older hosts: no `kind`, a running terminal is `.shell`; a closed session is Claude.
        #expect(RemoteSession(id: UUID(), name: "zsh", project: "p", state: .shell).isTerminal)
        #expect(!RemoteSession(id: UUID(), name: "c", project: "p", state: .notStarted).isTerminal)
    }

    /// An older remote's `RemoteSession` (the keys and state values it knew, nothing else): the
    /// stopped terminal decodes as a closed session, and the snapshot as a whole still decodes.
    @Test func olderRemoteDecodesAStoppedTerminal() throws {
        struct OldSession: Decodable {
            enum State: String, Decodable { case notStarted, starting, shell, running, needsPermission, needsAnswer, idle, ended }
            var id: UUID
            var name: String
            var project: String
            var state: State
            var unseen: Bool
        }
        struct OldSnapshot: Decodable {
            var hostName: String
            var sessions: [OldSession]
        }
        enum OldMessage: Decodable { case snapshot(OldSnapshot) }

        let frame = try RemoteMessage.snapshot(Self.snapshot()).frame()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard case .snapshot(let old) = try decoder.decode(OldMessage.self, from: frame.payload) else { return }
        #expect(old.sessions.count == 2)
        #expect(old.sessions.first { $0.id == Self.terminalID }?.state == .notStarted)
    }

    /// A newer host's kind this build doesn't know: decodes, and isn't taken for a terminal.
    @Test func unknownKindIsIgnored() throws {
        let json = #"""
        {"snapshot":{"_0":{"hostName":"next","features":["closedTerminals"],
          "sessions":[{"id":"C0000000-0000-0000-0000-000000000003","name":"x","project":"p","state":"notStarted","unseen":false,"kind":"notebook"}]}}}
        """#
        let message = try RemoteMessage.decode(RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: Data(json.utf8)))
        guard case .snapshot(let snapshot)? = message else { Issue.record("not a snapshot"); return }
        let session = try #require(snapshot.sessions.first)
        #expect(session.kind == "notebook")
        #expect(!session.isTerminal)
    }

    @Test func startMessagesRoundTrip() throws {
        for message in [RemoteMessage.resumeSession(sessionID: Self.terminalID),
                        .sessionAction(sessionID: Self.terminalID, action: .startFresh)] {
            let decoded = try RemoteMessage.decode(try message.frame())
            switch (message, decoded) {
            case (.resumeSession(let a), .resumeSession(let b)?): #expect(a == b)
            case (.sessionAction(let a, let x), .sessionAction(let b, let y)?): #expect(a == b && x == y)
            default: Issue.record("round trip changed \(message)")
            }
        }
    }

    @Test func featureIsAdvertised() {
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.closedTerminals))
    }
}
