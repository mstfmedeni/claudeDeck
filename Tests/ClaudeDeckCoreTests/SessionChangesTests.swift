import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct SessionChangesTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func call(_ id: String, _ tool: String, input: [String: Any], sidechain: Bool = false) -> String {
        line(["type": "assistant", "uuid": "a-\(id)", "isSidechain": sidechain, "message": ["content": [
            ["type": "tool_use", "id": id, "name": tool, "input": input],
        ]]])
    }

    private func result(_ id: String, _ toolUseResult: Any, isError: Bool = false, sidechain: Bool = false) -> String {
        line(["type": "user", "uuid": "u-\(id)", "isSidechain": sidechain, "timestamp": "2026-11-12T10:00:00.000Z",
              "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok", "is_error": isError]]],
              "toolUseResult": toolUseResult])
    }

    private let original = "a\nb\nc\nd\ne\n"

    /// Replaces "c" with "C1", "C2" (Claude Code's patch shape for an Edit: no `type`).
    private var edit: String {
        call("e1", "Edit", input: ["file_path": "/p/x.txt", "old_string": "c", "new_string": "C1\nC2"])
            + result("e1", ["filePath": "/p/x.txt", "oldString": "c", "newString": "C1\nC2", "originalFile": original,
                            "replaceAll": false, "userModified": false,
                            "structuredPatch": [["oldStart": 1, "oldLines": 5, "newStart": 1, "newLines": 6,
                                                 "lines": [" a", " b", "-c", "+C1", "+C2", " d", " e"]]]])
    }

    private var create: String {
        call("w1", "Write", input: ["file_path": "/p/new.txt", "content": "one\ntwo\n"])
            + result("w1", ["type": "create", "filePath": "/p/new.txt", "content": "one\ntwo\n", "structuredPatch": [] as [Any],
                            "originalFile": NSNull()])
    }

    private func read(_ text: String) -> SessionChanges {
        var reader = ConversationLog.Reader(collectsChanges: true)
        reader.append(text)
        return reader.changes
    }

    @Test func editBecomesAChangeWithNumberedLines() throws {
        let changes = read(edit)
        let change = try #require(changes.all.first)
        #expect(changes.all.count == 1)
        #expect(change.id == "e1" && change.tool == "Edit" && change.kind == .updated && change.path == "/p/x.txt")
        #expect(change.date != nil)
        let lines = change.hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .context, .removed, .added, .added, .context, .context])
        #expect(lines[2].oldLine == 3 && lines[3].newLine == 3 && lines[4].newLine == 4 && lines[5].newLine == 5)
        #expect(change.added == 2 && change.removed == 1)
        #expect(change.lineRange == 3...4)
    }

    @Test func writeCreateAddsTheWholeFile() throws {
        let change = try #require(read(create).all.first)
        #expect(change.kind == .created)
        #expect(change.hunks.count == 1)
        #expect(change.hunks[0].lines.map(\.text) == ["one", "two"])
        #expect(change.hunks[0].lines.allSatisfy { $0.kind == .added })
        #expect(change.lineRange == 1...2)
    }

    @Test func failedAndRejectedCallsAreSkipped() {
        let text = call("f1", "Edit", input: ["file_path": "/p/x.txt"])
            + result("f1", "Error: File has not been read yet. Read it first before writing to it.", isError: true)
            + call("f2", "Write", input: ["file_path": "/p/y.txt"])
            + result("f2", "User rejected write to /p/y.txt")
            // An error flag wins even over a patch-shaped result.
            + call("f3", "Edit", input: ["file_path": "/p/x.txt"])
            + result("f3", ["filePath": "/p/x.txt", "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-a", "+b"]]]],
                     isError: true)
        #expect(read(text).all.isEmpty)
    }

    @Test func otherToolsAndSidechainsAreIgnored() {
        let read = call("r1", "Read", input: ["file_path": "/p/x.txt"])
            + result("r1", ["type": "text", "file": ["filePath": "/p/x.txt", "content": "a"]])
        let sub = call("s1", "Edit", input: ["file_path": "/p/x.txt"], sidechain: true)
            + result("s1", ["filePath": "/p/x.txt", "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-a", "+b"]]]],
                     sidechain: true)
        #expect(self.read(read + sub).all.isEmpty)
    }

    @Test func plainReaderCollectsNothing() {
        var reader = ConversationLog.Reader()
        reader.append(edit + create)
        #expect(reader.changes.all.isEmpty)
        #expect(reader.entries.count == 2) // the two tool calls still show
    }

    @Test func resultReadLaterFillsIn() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "changes-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let parts = edit.split(separator: "\n").map { $0 + "\n" }
        try parts[0].write(to: url, atomically: true, encoding: .utf8)
        var reader = ConversationLog.Reader(collectsChanges: true)
        let read = reader.read(url)
        #expect(read)
        #expect(reader.changes.all.isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(parts[1].utf8))
        try handle.close()
        let readOn = reader.read(url)
        #expect(readOn)
        #expect(reader.changes.all.map(\.id) == ["e1"])
    }

    @Test func filesGroupInFirstTouchOrderWithNetContent() throws {
        let second = call("e2", "Edit", input: ["file_path": "/p/x.txt"])
            // originalFile left out (Claude Code does that for big files): builds on the last state.
            + result("e2", ["filePath": "/p/x.txt", "originalFile": NSNull(),
                            "structuredPatch": [["oldStart": 5, "oldLines": 2, "newStart": 5, "newLines": 2, "lines": [" d", "-e", "+E"]]]])
        let changes = read(edit + create + second)
        #expect(changes.files.map(\.path) == ["/p/x.txt", "/p/new.txt"])
        let x = changes.files[0]
        #expect(x.changes == [0, 2])
        #expect(changes.changes(of: "/p/x.txt").map(\.id) == ["e1", "e2"])
        #expect(x.original == original)
        #expect(x.current == "a\nb\nC1\nC2\nd\nE\n")
        #expect(changes.files[1].original == "" && changes.files[1].current == "one\ntwo\n")

        let net = SessionChanges.netDiff(from: try #require(x.original), to: try #require(x.current), context: 1)
        #expect(net.count == 1)
        #expect(net[0].lines.map(\.kind) == [.context, .removed, .added, .added, .context, .removed, .added])
        #expect(net[0].header == "@@ -2,4 +2,5 @@")
    }

    @Test func netDiffSplitsDistantChanges() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        var lines = (1...20).map(String.init)
        lines[1] = "two"
        lines[17] = "eighteen"
        let net = SessionChanges.netDiff(from: old, to: lines.joined(separator: "\n"))
        #expect(net.map(\.header) == ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"])
        #expect(SessionChanges.netDiff(from: old, to: old).isEmpty)
    }

    @Test func applyRejectsMismatchedContext() throws {
        let change = try #require(read(edit).all.first)
        #expect(SessionChanges.apply(change.hunks, to: original) == "a\nb\nC1\nC2\nd\ne\n")
        #expect(SessionChanges.apply(change.hunks, to: "a\nb\nX\nd\ne\n") == nil)
    }

    @Test func pureDeletionPointsAtItsPlace() {
        let lines = [DiffLine(kind: .context, text: "a", oldLine: 9, newLine: 9),
                     DiffLine(kind: .removed, text: "b", oldLine: 10, newLine: nil),
                     DiffLine(kind: .removed, text: "c", oldLine: 11, newLine: nil),
                     DiffLine(kind: .context, text: "d", oldLine: 12, newLine: 10)]
        #expect(SessionChanges.lineRange(of: lines) == 10...10)
    }

    @Test func messageHasReferenceSnippetAndText() throws {
        let change = try #require(read(edit).all.first)
        let lines = change.hunks[0].lines
        let message = SessionChanges.message(path: "/p/x.txt", root: "/p", lines: lines, text: "  Why two lines?  ")
        #expect(message == "@x.txt#L3-4\n```diff\n a\n b\n-c\n+C1\n+C2\n d\n e\n```\nWhy two lines?")
        // A picked range: only those lines, and their own numbers.
        let one = SessionChanges.message(path: "/p/x.txt", root: "/p", lines: [lines[3]], text: "")
        #expect(one == "@x.txt#L3\n```diff\n+C1\n```")
        #expect(SessionChanges.mention(path: "/elsewhere/y.txt", root: "/p", lines: nil) == "@/elsewhere/y.txt")
        let long = SessionChanges.message(path: "/p/x.txt", root: "/p", lines: lines, text: "", maxLines: 2)
        #expect(long.hasSuffix(" a\n b\n… (5 more lines)\n```"))
    }
}
