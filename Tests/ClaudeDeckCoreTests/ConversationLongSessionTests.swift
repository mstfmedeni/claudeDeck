import Foundation
import Testing
@testable import ClaudeDeckCore

/// A long orchestrator session followed from a phone (the AppFactory report: the phone's
/// conversation stopped at the owner's message while the terminal showed Claude's reply).
/// Synthetic lines shaped like that turn: the owner's message, an empty thinking block, tool calls
/// with hook attachments in between, a cross-session message (meta), Claude Code's bookkeeping
/// lines, queue operations, and the reply. The transcript is larger than the reader's tail, the
/// file grows a piece at a time with lines cut mid-write, and the Mac's reader is sometimes a new
/// one (its cache evicted). After every step the phone must have exactly the Mac's latest entries.
@Suite struct ConversationLongSessionTests {
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    private func assistant(_ uuid: String, _ blocks: [[String: Any]]) -> String {
        json(["type": "assistant", "uuid": uuid, "isSidechain": false, "timestamp": "2026-11-23T00:51:17.833Z",
              "message": ["role": "assistant", "content": blocks]])
    }

    private func toolResult(_ uuid: String, _ id: String, _ content: String) -> String {
        json(["type": "user", "uuid": uuid, "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content]]]])
    }

    /// Earlier work: enough of it that the transcript is bigger than the reader's tail.
    private func filler(_ n: Int) -> String {
        let pad = String(repeating: "lorem ipsum ", count: 30)
        return assistant("f\(n)a", [["type": "tool_use", "id": "toolu_f\(n)", "name": "Read", "input": ["file_path": "/p/File\(n).swift"]]])
            + toolResult("f\(n)r", "toolu_f\(n)", pad)
            + assistant("f\(n)t", [["type": "text", "text": "Step \(n) done. " + pad]])
            + json(["type": "system", "subtype": "turn_duration", "uuid": "f\(n)s"])
    }

    /// One turn like the reported one (`tag` makes every id unique).
    private func turn(_ tag: String) -> [String] {
        [
            json(["type": "user", "uuid": "\(tag)-u", "isSidechain": false, "origin": ["kind": "human"], "promptSource": "typed",
                  "message": ["role": "user", "content": "\(tag): add the rule, then have the agent run again"]]),
            json(["type": "file-history-snapshot", "messageId": "\(tag)-u"]),
            assistant("\(tag)-think", [["type": "thinking", "thinking": "", "signature": "sig"]]),
            assistant("\(tag)-a1", [["type": "tool_use", "id": "toolu_\(tag)_1", "name": "Bash",
                                     "input": ["command": "python3 - <<'EOF'\nEOF", "description": "Add allow rule"]]]),
            toolResult("\(tag)-r1", "toolu_\(tag)_1", "added"),
            json(["type": "attachment", "uuid": "\(tag)-h1", "isSidechain": false, "attachment": ["type": "hook_success", "content": ""]]),
            json(["type": "attachment", "uuid": "\(tag)-h2", "isSidechain": false,
                  "attachment": ["type": "hook_additional_context", "content": ["note"]]]),
            assistant("\(tag)-a2", [["type": "tool_use", "id": "toolu_\(tag)_2", "name": "SendMessage",
                                     "input": ["to": "other", "message": "Allow rule added: retry now"]]]),
            assistant("\(tag)-a3", [["type": "tool_use", "id": "toolu_\(tag)_3", "name": "Bash",
                                     "input": ["command": "echo log >> notes.md", "description": "Log allow rule"]]]),
            toolResult("\(tag)-r3", "toolu_\(tag)_3", ""),
            json(["type": "last-prompt", "lastPrompt": "\(tag): add the rule"]),
            json(["type": "custom-title", "customTitle": "Factory"]),
            json(["type": "agent-name", "agentName": "Factory"]),
            json(["type": "mode", "mode": "normal"]),
            json(["type": "permission-mode", "permissionMode": "auto"]),
            toolResult("\(tag)-r2", "toolu_\(tag)_2", "sent"),
            assistant("\(tag)-reply", [["type": "text", "text": "\(tag): I added the rule. The agent is running again."]]),
            json(["type": "system", "subtype": "stop_hook_summary", "uuid": "\(tag)-s1"]),
            json(["type": "system", "subtype": "turn_duration", "uuid": "\(tag)-s2"]),
            json(["type": "queue-operation", "operation": "enqueue", "content": "<cross-session-message from=\"uds:x\">hi</cross-session-message>"]),
            json(["type": "queue-operation", "operation": "dequeue"]),
            json(["type": "user", "uuid": "\(tag)-meta", "isSidechain": false, "isMeta": true,
                  "message": ["role": "user", "content": "Another Claude session sent a message:\n<cross-session-message from=\"uds:x\">hi</cross-session-message>"]]),
            assistant("\(tag)-after", [["type": "text", "text": "\(tag): the other session confirmed."]]),
        ]
    }

    private struct Phone {
        var entries: [ChatEntry] = []
        var hasMoreBefore = false

        /// The phone's entries end like the Mac's (a new reader starts later in the file, so
        /// only the part both have is compared).
        static func sameTail(_ phone: [ChatEntry], _ mac: [ChatEntry]) -> Bool {
            let count = min(phone.count, mac.count)
            return count > 0 && Array(phone.suffix(count)) == Array(mac.suffix(count))
        }

        mutating func sync(_ reader: ConversationLog.Reader) {
            let anchor = ChatSync.anchor(entries, hostSendsUpdates: true)
            let page = reader.page(before: nil, after: anchor, limit: 120)
            if !ChatSync.merge(page, into: &entries, hasMoreBefore: &hasMoreBefore) {
                ChatSync.merge(reader.page(before: nil, after: nil, limit: 80), into: &entries, hasMoreBefore: &hasMoreBefore)
            }
        }
    }

    @Test func phoneKeepsUpWithALongSessionPieceByPiece() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-session-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = 64 << 10
        try (0..<160).map(filler).joined().write(to: url, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: url).count > tail)

        var mac = ConversationLog.Reader()
        _ = mac.read(url, tailBytes: tail)
        var phone = Phone()
        phone.sync(mac)
        #expect(phone.entries.last?.text.hasPrefix("Step 159 done") == true)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for (round, tag) in ["T1", "T2", "T3"].enumerated() {
            for (index, line) in turn(tag).enumerated() {
                let bytes = Data(line.utf8)
                // Each line in two writes, the phone asking in between (a line cut mid-write).
                for piece in [bytes.prefix(bytes.count / 2), bytes.dropFirst(bytes.count / 2)] {
                    try handle.seekToEnd()
                    handle.write(Data(piece))
                    // Now and then the Mac's cache was evicted: a new reader on the grown file.
                    if (index + round) % 7 == 3 {
                        mac = ConversationLog.Reader()
                    }
                    _ = mac.read(url, tailBytes: tail)
                    phone.sync(mac)
                    #expect(Phone.sameTail(phone.entries, mac.entries), "\(tag) line \(index)")
                }
            }
            // The reply and what followed it are on the phone; the meta message and the
            // bookkeeping lines are not.
            let texts = phone.entries.map(\.text)
            #expect(texts.contains("\(tag): add the rule, then have the agent run again"))
            #expect(texts.contains("\(tag): I added the rule. The agent is running again."))
            #expect(phone.entries.last?.text == "\(tag): the other session confirmed.")
            #expect(!texts.contains { $0.contains("cross-session-message") })
            let calls = phone.entries.filter { $0.id.hasPrefix("toolu_\(tag)_") }
            #expect(calls.map(\.toolName) == ["Bash", "SendMessage", "Bash"])
            #expect(calls.allSatisfy { $0.result != nil || $0.toolName == "Bash" })
        }
    }

    /// The page the phone gets after its anchor carries the reply even when the Mac's reader is
    /// new and started inside the transcript (its tail), past where the phone's first page began.
    @Test func freshReaderAnswersTheAnchorOfAnOlderOne() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-session-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = 32 << 10
        let before = (0..<120).map(filler).joined() + turn("T1").prefix(2).joined()
        try before.write(to: url, atomically: true, encoding: .utf8)
        var first = ConversationLog.Reader()
        _ = first.read(url, tailBytes: tail)
        var phone = Phone()
        phone.sync(first)
        #expect(phone.entries.last?.id == "T1-u")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data(turn("T1").dropFirst(2).joined().utf8))
        try handle.close()
        var fresh = ConversationLog.Reader()
        _ = fresh.read(url, tailBytes: tail)
        phone.sync(fresh)
        #expect(phone.entries.last?.text == "T1: the other session confirmed.")
        #expect(phone.entries.contains { $0.text == "T1: I added the rule. The agent is running again." })
        #expect(Phone.sameTail(phone.entries, fresh.entries))
    }
}
