import Foundation
import Testing
@testable import ClaudeDeckCore

/// Where ClaudeDeck's news about agent sessions goes: never an owner note for close, stall or
/// overload; a queued message to a live Claude session when its setting allows.
@Suite struct AgentNoticesTests {
    @Test func closeGoesToTheLogUnlessTurnedOn() throws {
        #expect(AgentNoticeRouting.route(.childClosed, recipientIsLiveClaude: true, enabled: false) == .logOnly)
        #expect(AgentNoticeRouting.route(.childClosed, recipientIsLiveClaude: true, enabled: true) == .queue)
        #expect(AgentNoticeRouting.route(.childClosed, recipientIsLiveClaude: false, enabled: true) == .logOnly)
        #expect(!DeckSettings().tellStarterOnClose)
        let decoded = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"tellStarterOnClose":true}"#.utf8))
        #expect(decoded.tellStarterOnClose)
    }

    @Test func stallFollowsTheWatchSetting() {
        #expect(StallSettings().tellParent)
        #expect(AgentNoticeRouting.route(.childStalled, recipientIsLiveClaude: true, enabled: true) == .queue)
        #expect(AgentNoticeRouting.route(.childStalled, recipientIsLiveClaude: true, enabled: false) == .logOnly)
        #expect(AgentNoticeRouting.route(.childStalled, recipientIsLiveClaude: false, enabled: true) == .logOnly)
    }

    @Test func overloadIsQueuedForRunningAgentsOnce() {
        #expect(AgentNoticeRouting.route(.overloaded, recipientIsLiveClaude: true, enabled: false) == .queue)
        #expect(AgentNoticeRouting.route(.overloaded, recipientIsLiveClaude: true, enabled: true, alreadyQueued: true) == .logOnly)
        #expect(AgentNoticeRouting.overloadMessage
                == "[ClaudeDeck] Mac aşırı yüklü: ağır işleri (derleme, simülatör) ertele, bitmiş simülatörleri bırak.")
        let owner = UUID(), agent = UUID(), stopped = UUID(), terminal = UUID()
        let recipients = AgentNoticeRouting.overloadRecipients([
            (id: owner, isClaude: true, startedBy: nil, running: true),
            (id: agent, isClaude: true, startedBy: owner, running: true),
            (id: stopped, isClaude: true, startedBy: owner, running: false),
            (id: terminal, isClaude: false, startedBy: owner, running: true),
        ])
        #expect(recipients == [agent])
    }
}
