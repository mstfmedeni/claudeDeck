import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ConversationReaderTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private var lines: [String] {
        [
            line(["type": "user", "uuid": "u1", "message": ["content": "Fix the build"]]),
            line(["type": "assistant", "uuid": "a1", "message": ["content": [
                ["type": "text", "text": "Looking."],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "make"]],
            ]]]),
            line(["type": "user", "uuid": "u2", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "ok"],
            ]]]),
            line(["type": "assistant", "uuid": "a2", "message": ["content": [["type": "text", "text": "Done."]]]]),
        ]
    }

    private func file(_ text: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reader-\(UUID().uuidString).jsonl")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try! handle.close()
    }

    @Test func readingOnMatchesReadingAtOnce() {
        let url = file(lines[0] + lines[1])
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = ConversationLog.Reader()
        let first = reader.read(url)
        #expect(first)
        #expect(reader.entries.count == 3)
        #expect(reader.entries[2].result == nil)
        append(lines[2] + lines[3], to: url)
        let second = reader.read(url)
        #expect(second)
        // The result read later fills in the call read before.
        #expect(reader.entries == ConversationLog.entries(fromJSONL: lines.joined()))
        #expect(reader.entries[2].result == "ok")
    }

    @Test func aLineBeingWrittenWaits() {
        // One serialization: dictionaries can come out in another key order on each `lines`.
        let last = lines[3]
        let url = file(lines[0] + String(last.dropLast(5)))
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = ConversationLog.Reader()
        _ = reader.read(url)
        #expect(reader.entries.map(\.id) == ["u1"])
        append(String(last.suffix(5)), to: url)
        _ = reader.read(url)
        #expect(reader.entries.map(\.id) == ["u1", "a2#0"])
    }

    @Test func startsMidFileOnALineBoundary() {
        let url = file(lines.joined())
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = ConversationLog.Reader()
        _ = reader.read(url, tailBytes: lines[3].utf8.count + 3)
        #expect(reader.entries.map(\.id) == ["a2#0"])
    }

    @Test func aShorterFileIsReportedForANewReader() {
        let url = file(lines.joined())
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = ConversationLog.Reader()
        _ = reader.read(url)
        try! lines[0].write(to: url, atomically: true, encoding: .utf8)
        let same = reader.read(url)
        #expect(!same)
    }
}
