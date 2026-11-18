import Foundation
import Testing
@testable import ClaudeDeckCore

/// File requests from a paired device: reads that would never end, uploads left behind.
@Suite struct RemoteFileLimitTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        return root
    }

    @Test func namedPipesAreNotRead() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(root.appending(path: "docs/pipe").path, 0o600) == 0)
        // Reading one would wait for a writer forever; both answer at once instead.
        let text = RemoteFiles.read("docs/pipe", in: root.path)
        #expect(text.text == nil && text.error != nil)
        let piece = RemoteTransfer.read("docs/pipe", in: root.path, offset: 0)
        #expect(piece.data.isEmpty && piece.error != nil)
        // Regular files as before.
        try Data("hi".utf8).write(to: root.appending(path: "docs/a.txt"))
        #expect(RemoteFiles.read("docs/a.txt", in: root.path).text == "hi")
        #expect(RemoteTransfer.read("docs/a.txt", in: root.path, offset: 0).data == Data("hi".utf8))
        #expect(RemoteFiles.read("docs/missing.txt", in: root.path).error != nil)
    }

    @Test func abandonedUploadsAreCleanedUp() throws {
        final class Clock: @unchecked Sendable { var now = Date() }
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let receiver = RemoteTransfer.Receiver(abandonedAfter: 600, now: { clock.now })
        func parts() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "docs").path).filter { $0.hasSuffix(".part") }
        }
        // The device went away after the first piece.
        #expect(receiver.receive(root: root.path, folder: "docs", name: "a.bin", offset: 0, total: 10, data: Data(count: 4)).error == nil)
        #expect(try parts().count == 1)
        // A slow one that keeps going isn't touched; the abandoned one goes.
        clock.now += 500
        #expect(receiver.receive(root: root.path, folder: "docs", name: "b.bin", offset: 0, total: 10, data: Data(count: 4)).error == nil)
        clock.now += 500
        #expect(receiver.receive(root: root.path, folder: "docs", name: "b.bin", offset: 4, total: 10, data: Data(count: 4)).received == 8)
        #expect(receiver.pendingCount == 1)
        #expect(try parts().count == 1)
        let done = receiver.receive(root: root.path, folder: "docs", name: "b.bin", offset: 8, total: 10, data: Data(count: 2))
        #expect(done.path == "docs/b.bin")
        #expect(try parts().isEmpty)
        #expect(receiver.pendingCount == 0)
    }
}
