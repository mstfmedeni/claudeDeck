import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct RemoteEditsTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    /// A Write creating `path` with `count` lines (its change is `count` added lines).
    private func write(_ id: String, _ path: String, lines count: Int) -> String {
        let content = (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
        return line(["type": "assistant", "uuid": "a-\(id)", "message": ["content": [
            ["type": "tool_use", "id": id, "name": "Write", "input": ["file_path": path, "content": content]],
        ]]])
            + line(["type": "user", "uuid": "u-\(id)", "timestamp": "2026-11-12T10:00:00.000Z",
                    "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
                    "toolUseResult": ["type": "create", "filePath": path, "content": content, "structuredPatch": [] as [Any]]])
    }

    private var edit: String {
        line(["type": "assistant", "uuid": "a-e1", "message": ["content": [
            ["type": "tool_use", "id": "e1", "name": "Edit", "input": ["file_path": "/p/x.txt"]],
        ]]])
            + line(["type": "user", "uuid": "u-e1", "message": ["content": [["type": "tool_result", "tool_use_id": "e1", "content": "ok"]]],
                    "toolUseResult": ["filePath": "/p/x.txt", "originalFile": "a\nb\nc\nd\ne\n",
                                      "structuredPatch": [["oldStart": 1, "oldLines": 5, "newStart": 1, "newLines": 6,
                                                           "lines": [" a", " b", "-c", "+C1", "+C2", " d", " e"]]]]])
    }

    private func read(_ text: String) -> SessionChanges {
        var reader = ConversationLog.Reader(collectsChanges: true)
        reader.append(text)
        return reader.changes
    }

    @Test func changeSurvivesTheWireWithItsNumbers() throws {
        let change = try #require(read(edit).all.first)
        let message = RemoteMessage.edits(sessionID: UUID(), page: RemoteEditsPage(
            changes: [RemoteFileChange(change, maxLines: 300)], reset: true, hasMore: false, root: "/p"))
        let back = try RemoteMessage.decode(message.frame())
        #expect(back == message)
        guard case .edits(_, let page) = back else { Issue.record("wrong case"); return }
        let remote = try #require(page.changes.first)
        #expect(remote.id == "e1" && remote.tool == "Edit" && !remote.created && remote.omitted == 0)
        #expect(remote.added == 2 && remote.removed == 1 && remote.lineRange == 3...4)
        #expect(remote.diffHunks == change.hunks)
    }

    @Test func requestsAndNetDiffRoundTrip() throws {
        let id = UUID()
        let messages: [RemoteMessage] = [
            .editsRequest(sessionID: id, after: nil),
            .editsRequest(sessionID: id, after: "toolu_1"),
            .netDiffRequest(sessionID: id, path: "/p/x.txt"),
            .netDiff(sessionID: id, path: "/p/x.txt", diff: RemoteNetDiff(hunks: nil, changes: 2)),
            .netDiff(sessionID: id, path: "/p/x.txt", diff: RemoteNetDiff(
                hunks: [RemoteDiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: ["-a", "+b"])], omitted: 3, changes: 1)),
        ]
        for message in messages {
            #expect(try RemoteMessage.decode(message.frame()) == message)
        }
        #expect(RemoteSnapshot.Feature.all.contains(RemoteSnapshot.Feature.edits))
    }

    @Test func longChangeIsCutButKeepsItsCounts() throws {
        let change = try #require(read(write("w1", "/p/big.txt", lines: 50)).all.first)
        let remote = RemoteFileChange(change, maxLines: 10)
        #expect(remote.hunks.flatMap(\.lines).count == 10)
        #expect(remote.omitted == 40)
        #expect(remote.added == 50 && remote.lineRange == 1...50 && remote.created)
        #expect(remote.diffHunks.first?.lines.last?.newLine == 10)
    }

    @Test func longLinesAreShortened() throws {
        let long = String(repeating: "x", count: RemoteEdits.maxLineLength + 50)
        let hunk = DiffHunk(header: "", oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
                            lines: [DiffLine(kind: .added, text: long, oldLine: nil, newLine: 1)], raw: [])
        let remote = RemoteDiffHunk(hunk, maxLines: 10)
        #expect(remote.lines[0].count == RemoteEdits.maxLineLength + 2) // "+", the text, "…"
    }

    @Test func pagesFollowTheAnchorAndStopAtTheLineBudget() {
        let changes = read(write("w1", "/p/a.txt", lines: 5) + write("w2", "/p/b.txt", lines: 5) + write("w3", "/p/c.txt", lines: 5))
        // From the start: two changes fit 12 lines, the third waits.
        let first = RemoteEdits.page(changes, after: nil, root: "/p", maxLinesPerPage: 12)
        #expect(first.reset && first.hasMore && first.root == "/p")
        #expect(first.changes.map(\.id) == ["w1", "w2"])
        let next = RemoteEdits.page(changes, after: "w2", root: "/p", maxLinesPerPage: 12)
        #expect(!next.reset && !next.hasMore && next.after == "w2")
        #expect(next.changes.map(\.id) == ["w3"])
        // Up to date: an empty page.
        let none = RemoteEdits.page(changes, after: "w3", root: "/p")
        #expect(!none.reset && none.changes.isEmpty && !none.hasMore)
        // An anchor that isn't there (a new transcript): everything again.
        let gone = RemoteEdits.page(changes, after: "elsewhere", root: "/p")
        #expect(gone.reset && gone.after == nil && gone.changes.count == 3)
        // A change bigger than the budget still goes, alone.
        let tight = RemoteEdits.page(changes, after: nil, root: nil, maxLinesPerPage: 2)
        #expect(tight.changes.map(\.id) == ["w1"] && tight.hasMore)
    }

    @Test func stateMergesPagesInOrder() {
        let changes = read(write("w1", "/p/a.txt", lines: 5) + write("w2", "/p/b.txt", lines: 5) + write("w3", "/p/a.txt", lines: 2))
        var state = RemoteEditsState()
        #expect(!state.loaded && state.lastID == nil)
        let merged1 = state.merge(RemoteEdits.page(changes, after: nil, root: "/p", maxLinesPerPage: 6))
        #expect(merged1)
        #expect(state.changes.map(\.id) == ["w1"] && state.hasMore && state.root == "/p")
        // A page after another anchor (an older request answered late) doesn't fit.
        let merged2 = state.merge(RemoteEdits.page(changes, after: "w2", root: "/p"))
        #expect(!merged2)
        let merged3 = state.merge(RemoteEdits.page(changes, after: state.lastID, root: "/p"))
        #expect(merged3)
        #expect(state.changes.map(\.id) == ["w1", "w2", "w3"] && !state.hasMore)
        #expect(state.change("w2")?.path == "/p/b.txt")
        #expect(state.files.map(\.path) == ["/p/a.txt", "/p/b.txt"])
        #expect(state.files[0].changes.map(\.id) == ["w1", "w3"])
        // A reset replaces everything.
        state.netDiffs["/p/a.txt"] = RemoteNetDiff(hunks: nil, changes: 2)
        let merged4 = state.merge(RemoteEditsPage(changes: [], reset: true))
        #expect(merged4)
        #expect(state.changes.isEmpty && state.netDiffs.isEmpty && state.change("w1") == nil)
    }

    @Test func netDiffIsCutOrUnavailable() {
        let changes = read(edit + write("w1", "/p/big.txt", lines: 30))
        let x = RemoteEdits.netDiff(changes, path: "/p/x.txt")
        #expect(x.changes == 1 && x.omitted == 0)
        #expect(x.hunks?.first?.hunk?.lines.map(\.kind) == [.context, .context, .removed, .added, .added, .context, .context])
        let big = RemoteEdits.netDiff(changes, path: "/p/big.txt", maxLines: 10)
        #expect(big.hunks?.flatMap(\.lines).count == 10 && big.omitted == 20)
        #expect(RemoteEdits.netDiff(changes, path: "/p/none.txt").hunks == nil)
        // Without the file's original content there's no net diff.
        let unknown = read(line(["type": "assistant", "uuid": "a-e9", "message": ["content": [
            ["type": "tool_use", "id": "e9", "name": "Edit", "input": ["file_path": "/p/y.txt"]],
        ]]]) + line(["type": "user", "uuid": "u-e9", "message": ["content": [["type": "tool_result", "tool_use_id": "e9", "content": "ok"]]],
                     "toolUseResult": ["filePath": "/p/y.txt", "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1,
                                                                                   "lines": ["-a", "+b"]]]]]))
        let none = RemoteEdits.netDiff(unknown, path: "/p/y.txt")
        #expect(none.hunks == nil && none.changes == 1)
    }
}
