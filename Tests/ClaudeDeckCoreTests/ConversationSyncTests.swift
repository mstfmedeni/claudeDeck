import Foundation
import Testing
@testable import ClaudeDeckCore

/// The phone keeping a conversation current: anchors, `ChatPage.updated` and merging pages.
@Suite struct ConversationSyncTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func user(_ uuid: String, _ text: String) -> String {
        line(["type": "user", "uuid": uuid, "message": ["content": text]])
    }

    private func text(_ uuid: String, _ text: String) -> String {
        line(["type": "assistant", "uuid": uuid, "message": ["content": [["type": "text", "text": text]]]])
    }

    private func call(_ uuid: String, _ id: String, _ name: String = "Bash") -> String {
        line(["type": "assistant", "uuid": uuid, "message": ["content": [
            ["type": "tool_use", "id": id, "name": name, "input": ["command": "make \(id)"]],
        ]]])
    }

    private func result(_ uuid: String, _ id: String, _ content: String = "ok") -> String {
        line(["type": "user", "uuid": uuid, "message": ["content": [
            ["type": "tool_result", "tool_use_id": id, "content": content],
        ]]])
    }

    /// A phone: asks with `ChatSync.anchor`, merges with `ChatSync.merge` (RemoteStore's logic).
    private struct Phone {
        var entries: [ChatEntry] = []
        var hasMoreBefore = false
        let hostSendsUpdates: Bool

        mutating func poll(_ reader: ConversationLog.Reader) {
            let anchor = entries.isEmpty ? nil : ChatSync.anchor(entries, hostSendsUpdates: hostSendsUpdates)
            var page = reader.page(before: nil, after: anchor, limit: 120)
            // An older host doesn't send `updated`.
            if !hostSendsUpdates { page.updated = nil }
            if !ChatSync.merge(page, into: &entries, hasMoreBefore: &hasMoreBefore) {
                ChatSync.merge(reader.page(before: nil, after: nil, limit: 80), into: &entries, hasMoreBefore: &hasMoreBefore)
            }
        }

        func entry(_ id: String) -> ChatEntry? { entries.first { $0.id == id } }
    }

    /// Parallel calls: B and C finish first, A (slow) later, with Claude writing on meanwhile.
    private var parallelTurn: [String] {
        [
            user("u1", "Run the checks"),
            text("a1", "Running three checks at once."),
            call("a2", "A"), call("a3", "B", "Read"), call("a4", "C", "Agent"),
            result("r1", "B"), result("r2", "C", "launched"),
            // The phone polls here.
            result("r3", "A", "PASS"),
            text("a5", "All green."),
        ]
    }

    @Test(arguments: [true, false])
    func toolResultsThatComeOutOfOrderReachThePhone(hostSendsUpdates: Bool) {
        let lines = parallelTurn
        var reader = ConversationLog.Reader()
        var phone = Phone(hostSendsUpdates: hostSendsUpdates)
        reader.append(lines[0..<7].joined())
        phone.poll(reader)
        #expect(phone.entry("A")?.result == nil)
        #expect(phone.entry("B")?.result == "ok")
        reader.append(lines[7])
        phone.poll(reader)
        reader.append(lines[8])
        phone.poll(reader)
        #expect(phone.entry("A")?.result == "PASS")
        #expect(phone.entries.map(\.id) == reader.entries.map(\.id))
        #expect(phone.entries == reader.entries)
    }

    /// What 0.5.6 did: the anchor was the last complete entry, so A's result never came.
    @Test func theOldAnchorLostThePendingResult() {
        let lines = parallelTurn
        var reader = ConversationLog.Reader()
        reader.append(lines[0..<7].joined())
        var entries = reader.page(before: nil, after: nil, limit: 80).entries
        reader.append(lines[7] + lines[8])
        let oldAnchor = entries.last { $0.kind != .tool || $0.result != nil }!
        #expect(oldAnchor.id == "C")
        var page = ConversationLog.page(reader.entries, before: nil, after: oldAnchor.id, limit: 120)
        #expect(!page.entries.contains { $0.id == "A" })
        // With the reader's revisions the page carries it.
        page = reader.page(before: nil, after: oldAnchor.id, limit: 120)
        // (B and C too: their results came after C was added; sending them again is harmless.)
        #expect(page.updated?.map(\.id) == ["A", "B", "C"])
        var more = false
        ChatSync.merge(page, into: &entries, hasMoreBefore: &more)
        #expect(entries.first { $0.id == "A" }?.result == "PASS")
    }

    @Test func theAnchorItselfGettingItsResultIsSent() {
        var reader = ConversationLog.Reader()
        reader.append(user("u1", "Go") + call("a1", "T"))
        reader.append(result("r1", "T", "done"))
        let page = reader.page(before: nil, after: "T", limit: 120)
        #expect(page.entries.isEmpty)
        #expect(page.updated?.map(\.id) == ["T"])
        #expect(page.updated?.first?.result == "done")
    }

    @Test func nothingChangedMeansNoUpdates() {
        var reader = ConversationLog.Reader()
        reader.append(user("u1", "Go") + call("a1", "T") + result("r1", "T") + text("a2", "Done"))
        let page = reader.page(before: nil, after: "a2#0", limit: 120)
        #expect(page.entries.isEmpty)
        #expect(page.updated == [])
        // Without revisions (plain entries) the field stays out, like an older host.
        #expect(ConversationLog.page(reader.entries, before: nil, after: "a2#0", limit: 120).updated == nil)
    }

    @Test func farBehindStartsOver() {
        var reader = ConversationLog.Reader()
        reader.append(user("u0", "Start"))
        reader.append((1...30).map { text("a\($0)", "Step \($0)") }.joined())
        let page = reader.page(before: nil, after: "u0", limit: 10)
        #expect(page.reset)
        #expect(page.entries.count == 10)
        #expect(page.entries.last?.id == "a30#0")
    }

    @Test func anchorRules() {
        let done = ChatEntry(id: "d", kind: .assistant, text: "x")
        let tool = { (id: String, result: String?) in ChatEntry(id: id, kind: .tool, text: "", toolName: "Bash", result: result) }
        // A host with updates: always the last entry, even a call still running.
        #expect(ChatSync.anchor([done, tool("p", nil)], hostSendsUpdates: true) == "p")
        // An older host: just before the first call still waiting.
        #expect(ChatSync.anchor([done, tool("p", nil), tool("q", "ok")], hostSendsUpdates: false) == "d")
        #expect(ChatSync.anchor([done, tool("q", "ok")], hostSendsUpdates: false) == "q")
        // Waiting from the very first entry: the latest page instead.
        #expect(ChatSync.anchor([tool("p", nil), done], hostSendsUpdates: false) == nil)
        // A call cut off long ago (no result ever) doesn't hold the anchor back.
        let old = [tool("p", nil)] + (0..<70).map { ChatEntry(id: "e\($0)", kind: .assistant, text: "") }
        #expect(ChatSync.anchor(old, hostSendsUpdates: false, window: 60) == "e69")
        #expect(ChatSync.anchor([], hostSendsUpdates: true) == nil)
    }

    @Test func mergeRules() {
        let a = ChatEntry(id: "a", kind: .user, text: "a")
        let b = ChatEntry(id: "b", kind: .tool, text: "b", toolName: "Bash")
        let c = ChatEntry(id: "c", kind: .assistant, text: "c")
        var entries = [a, b]
        var more = false
        var filled = b
        filled.result = "ok"
        var page = ChatPage(entries: [c], hasMoreBefore: true, reset: false, after: "b")
        page.updated = [filled, ChatEntry(id: "unknown", kind: .assistant, text: "?")]
        #expect(ChatSync.merge(page, into: &entries, hasMoreBefore: &more))
        #expect(entries.map(\.id) == ["a", "b", "c"])
        #expect(entries[1].result == "ok")
        // A page after an entry the phone no longer has doesn't go in.
        let stray = ChatPage(entries: [c], hasMoreBefore: true, reset: false, after: "gone")
        #expect(!ChatSync.merge(stray, into: &entries, hasMoreBefore: &more))
        #expect(entries.count == 3)
        // Older entries go on top, without doubles.
        let older = ChatPage(entries: [ChatEntry(id: "z", kind: .user, text: "z"), a], hasMoreBefore: false, reset: false, before: "a")
        #expect(ChatSync.merge(older, into: &entries, hasMoreBefore: &more))
        #expect(entries.map(\.id) == ["z", "a", "b", "c"])
        // A reset replaces everything.
        #expect(ChatSync.merge(ChatPage(entries: [c], hasMoreBefore: true, reset: true), into: &entries, hasMoreBefore: &more))
        #expect(entries.map(\.id) == ["c"])
        #expect(more)
    }

    @Test func drawnWindowMovesInSteps() {
        #expect(ChatSync.windowStart(count: 100, window: 160, step: 80) == 0)
        #expect(ChatSync.windowStart(count: 239, window: 160, step: 80) == 0)
        #expect(ChatSync.windowStart(count: 240, window: 160, step: 80) == 80)
        #expect(ChatSync.windowStart(count: 319, window: 160, step: 80) == 80)
        // Between `window` and `window + step - 1` entries drawn, however long the conversation.
        for count in 160...2000 {
            let drawn = count - ChatSync.windowStart(count: count, window: 160, step: 80)
            #expect((160...239).contains(drawn))
        }
    }

    // MARK: Protocol

    @Test func conversationPushMessagesRoundTrip() throws {
        let id = UUID()
        for message: RemoteMessage in [.conversationOpen(sessionID: id), .conversationClose(sessionID: id), .conversationChanged(sessionID: id)] {
            #expect(try RemoteMessage.decode(message.frame()) == message)
        }
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.conversationPush))
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.historyUpdates))
    }

    /// Both directions skip what they don't know: an unknown message fails to decode (the channel
    /// drops it), an unknown page field is ignored, a missing one is nil.
    @Test func olderAndNewerSidesGetAlong() throws {
        let unknown = RemoteFrame(kind: RemoteFrameKind.message.rawValue, payload: Data(#"{"somethingNew":{"sessionID":"\#(UUID().uuidString)"}}"#.utf8))
        #expect((try? RemoteMessage.decode(unknown)) == nil)

        let decoder = JSONDecoder()
        let withFuture = #"{"entries":[],"hasMoreBefore":false,"reset":true,"futureField":[1,2]}"#
        let page = try decoder.decode(ChatPage.self, from: Data(withFuture.utf8))
        #expect(page.updated == nil)
        #expect(page.reset)

        // A page with `updated` reads fine without it (what an older phone's ChatPage sees).
        var newer = ChatPage(entries: [], hasMoreBefore: true, reset: false, after: "x")
        newer.updated = [ChatEntry(id: "x", kind: .tool, text: "", toolName: "Bash", result: "ok")]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(newer)) as? [String: Any]
        #expect(json?["updated"] != nil)
        struct OldPage: Decodable { var entries: [ChatEntry]; var hasMoreBefore: Bool; var reset: Bool; var after: String? }
        let old = try decoder.decode(OldPage.self, from: JSONEncoder().encode(newer))
        #expect(old.after == "x")
    }
}
