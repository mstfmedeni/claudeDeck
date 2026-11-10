import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ProjectFolderRenameTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func newPathStaysNextToTheFolder() throws {
        #expect(try ProjectFolderRename.newPath(for: "/Users/me/Projects/old", name: " new app ") == "/Users/me/Projects/new app")
        #expect(throws: ProjectFolderRename.Problem.badName) { try ProjectFolderRename.newPath(for: "/a/b", name: "x/y") }
        #expect(throws: ProjectFolderRename.Problem.badName) { try ProjectFolderRename.newPath(for: "/a/b", name: "..") }
        #expect(throws: ProjectFolderRename.Problem.badName) { try ProjectFolderRename.newPath(for: "/a/b", name: "  ") }
    }

    @Test func movedOnlyInsideTheFolder() {
        #expect(ProjectFolderRename.moved("/a/foo", from: "/a/foo", to: "/a/bar") == "/a/bar")
        #expect(ProjectFolderRename.moved("/a/foo/.claude/worktrees/x", from: "/a/foo", to: "/a/bar") == "/a/bar/.claude/worktrees/x")
        #expect(ProjectFolderRename.moved("/a/foobar", from: "/a/foo", to: "/a/bar") == nil)
    }

    @Test func movesTheFolderAndItsConversations() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appending(path: "claude-projects")
        let old = root.appending(path: "Projects/old").path
        let worktree = old + "/.claude/worktrees/fix"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try "x".write(toFile: old + "/README.md", atomically: true, encoding: .utf8)
        for dir in [old, worktree] {
            let transcripts = claude.appending(path: Transcript.projectDirectoryName(for: dir))
            try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try "{}".write(to: transcripts.appending(path: "s1.jsonl"), atomically: true, encoding: .utf8)
        }
        let new = try ProjectFolderRename.newPath(for: old, name: "new")
        let moved = try ProjectFolderRename.move(old, to: new, insideDirectories: [worktree], claudeRoot: claude)

        #expect(FileManager.default.fileExists(atPath: new + "/README.md"))
        #expect(!FileManager.default.fileExists(atPath: old))
        for dir in [new, new + "/.claude/worktrees/fix"] {
            #expect(FileManager.default.fileExists(atPath: claude.appending(path: Transcript.projectDirectoryName(for: dir)).appending(path: "s1.jsonl").path))
        }
        #expect(moved.count == 2)

        // The deck follows: project path, working directory, transcript.
        var deck = DeckData()
        let project = Project(path: old, name: "old")
        deck.projects = [project]
        var session = DeckSession(projectID: project.id, name: "s")
        session.workingDirectory = worktree
        session.transcriptPath = claude.appending(path: Transcript.projectDirectoryName(for: old)).appending(path: "s1.jsonl").path
        deck.sessions = [session]
        deck.relocateProject(project.id, from: old, to: new, transcripts: moved)
        #expect(deck.projects[0].path == new)
        #expect(deck.sessions[0].workingDirectory == new + "/.claude/worktrees/fix")
        #expect(deck.sessions[0].transcriptPath == claude.appending(path: Transcript.projectDirectoryName(for: new)).appending(path: "s1.jsonl").path)
    }

    @Test func refusesAnExistingName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "old").path, taken = root.appending(path: "taken").path
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: taken, withIntermediateDirectories: true)
        #expect(throws: ProjectFolderRename.Problem.exists) { try ProjectFolderRename.move(old, to: taken, claudeRoot: root) }
        #expect(FileManager.default.fileExists(atPath: old))
    }
}
