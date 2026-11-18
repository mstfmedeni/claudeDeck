import Foundation
import Testing
@testable import ClaudeDeckCore

/// Folder trust for sessions started with `claudedeck new` (ClaudeTrust.swift). Never touches the
/// real `~/.claude.json`: every file here is a copy in a temporary folder.
@Suite struct ClaudeTrustTests {
    /// Works under both `swift test` and Xcode (no Bundle.module there).
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-config.json")

    let home = NSHomeDirectory()

    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "claude-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func object(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Path rules

    @Test func pathRules() {
        let roots = [home]
        #expect(ClaudeTrust.folder("\(home)/code/new-service", roots: roots) == .success(SessionCLI.resolved("\(home)/code/new-service")))
        #expect(ClaudeTrust.folder("code/new-service", roots: roots) == .failure(.notAbsolute))
        #expect(ClaudeTrust.folder("/", roots: roots) == .failure(.systemPath))
        #expect(ClaudeTrust.folder("/etc/x", roots: roots) == .failure(.systemPath))
        #expect(ClaudeTrust.folder("/usr/local/src", roots: roots) == .failure(.systemPath))
        #expect(ClaudeTrust.folder("/Applications/Foo", roots: roots) == .failure(.systemPath))
        // The home folder itself (Claude Code never saves trust for it) and anything outside it.
        #expect(ClaudeTrust.folder(home, roots: roots) == .failure(.outsideHome))
        #expect(ClaudeTrust.folder("/private/tmp/project", roots: roots) == .failure(.outsideHome))
        #expect(ClaudeTrust.folder("/Users/someone-else/code", roots: roots) == .failure(.outsideHome))
        // Hidden folders and the home's Library.
        #expect(ClaudeTrust.folder("\(home)/.config/thing", roots: roots) == .failure(.hiddenFolder))
        #expect(ClaudeTrust.folder("\(home)/code/.secret/x", roots: roots) == .failure(.hiddenFolder))
        #expect(ClaudeTrust.folder("\(home)/Library/Application Support/x", roots: roots) == .failure(.hiddenFolder))
        // `..` can't climb out.
        #expect(ClaudeTrust.folder("\(home)/code/../../../etc", roots: roots) == .failure(.systemPath))
        #expect(ClaudeTrust.folder("\(home)/code/../..", roots: roots) != .success(home))
    }

    @Test func demoRootCounts() throws {
        let demo = try temporaryFolder()
        let folder = demo.appending(path: "projects/new-thing").path
        #expect(ClaudeTrust.folder(folder, roots: [home]) == .failure(.outsideHome))
        #expect(ClaudeTrust.folder(folder, roots: [home, demo.path]) == .success(SessionCLI.resolved(folder)))
    }

    // MARK: The decision

    @Test func onlyStartedSessionsWithTheSettingOn() {
        let path = "\(home)/code/new-service"
        #expect(ClaudeTrust.decide(startedByCLI: false, settingOn: true, path: path, roots: [home]) == .failure(.notStartedByCLI))
        #expect(ClaudeTrust.decide(startedByCLI: false, settingOn: false, path: path, roots: [home]) == .failure(.notStartedByCLI))
        #expect(ClaudeTrust.decide(startedByCLI: true, settingOn: false, path: path, roots: [home]) == .failure(.settingOff))
        #expect(ClaudeTrust.decide(startedByCLI: true, settingOn: true, path: path, roots: [home]) == .success(SessionCLI.resolved(path)))
        #expect(ClaudeTrust.decide(startedByCLI: true, settingOn: true, path: "/etc", roots: [home]) == .failure(.systemPath))
    }

    // MARK: Which file

    @Test func configFile() {
        #expect(ClaudeTrust.configFile(environment: [:], home: "/Users/me", demo: false)?.path == "/Users/me/.claude.json")
        #expect(ClaudeTrust.configFile(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/alt"], home: "/Users/me", demo: false)?.path == "/Users/me/alt/.claude.json")
        // The demo only ever uses its own home; without one there's no file at all.
        #expect(ClaudeTrust.configFile(environment: ["CLAUDEDECK_CLAUDE_HOME": "/tmp/demo/home"], home: "/Users/me", demo: true)?.path == "/tmp/demo/home/.claude.json")
        #expect(ClaudeTrust.configFile(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/alt"], home: "/Users/me", demo: true) == nil)
    }

    // MARK: The merge

    @Test func mergeKeepsEverythingElse() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let before = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let merged = try #require(try ClaudeTrust.merged(data, folder: "/Users/someone/code/new-service"))
        let after = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        // The new key, and only it.
        #expect(ClaudeTrust.isTrusted(after, folder: "/Users/someone/code/new-service"))
        var expected = before
        var projects = try #require(expected["projects"] as? [String: Any])
        projects["/Users/someone/code/new-service"] = ["hasTrustDialogAccepted": true]
        expected["projects"] = projects
        #expect(NSDictionary(dictionary: after).isEqual(to: expected))
        // Every other byte stays: the file is the old one with just the new entry inserted.
        let text = try #require(String(data: merged, encoding: .utf8))
        let original = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(text.replacingOccurrences(of: #""/Users/someone/code/new-service": {"hasTrustDialogAccepted": true}, "#, with: "") == original)
    }

    @Test func mergeFlipsAFalseFlagInPlace() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let merged = try #require(try ClaudeTrust.merged(data, folder: "/Users/someone/code/payments-api"))
        let original = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        let expected = original.replacingOccurrences(of: #""allowedTools": ["Bash(npm test)"],"# + "\n" + #"      "hasTrustDialogAccepted": false"#,
                                                     with: #""allowedTools": ["Bash(npm test)"],"# + "\n" + #"      "hasTrustDialogAccepted": true"#)
        #expect(expected != original)
        #expect(String(data: merged, encoding: .utf8) == expected)
    }

    @Test func mergeAddsTheKeyToAnEntryWithoutIt() throws {
        let data = Data(#"{"a": 1.2345, "projects": {"/x": {"lastCost": 0.1}, "/y": {}}}"#.utf8)
        #expect(try ClaudeTrust.merged(data, folder: "/x") == Data(#"{"a": 1.2345, "projects": {"/x": {"hasTrustDialogAccepted": true, "lastCost": 0.1}, "/y": {}}}"#.utf8))
        #expect(try ClaudeTrust.merged(data, folder: "/y") == Data(#"{"a": 1.2345, "projects": {"/x": {"lastCost": 0.1}, "/y": {"hasTrustDialogAccepted": true}}}"#.utf8))
        // No projects yet; an empty config; a folder with characters JSON escapes.
        #expect(try ClaudeTrust.merged(Data(#"{"a": "}{\"projects\""}"#.utf8), folder: "/x")
                == Data(#"{"projects": {"/x": {"hasTrustDialogAccepted": true}}, "a": "}{\"projects\""}"#.utf8))
        #expect(try ClaudeTrust.merged(Data("{}".utf8), folder: "/x") == Data(#"{"projects": {"/x": {"hasTrustDialogAccepted": true}}}"#.utf8))
        let odd = try #require(try ClaudeTrust.merged(Data(#"{"projects": {}}"#.utf8), folder: "/Users/me/a \"quoted\" ğ"))
        let parsed = try #require(JSONSerialization.jsonObject(with: odd) as? [String: Any])
        #expect(ClaudeTrust.isTrusted(parsed, folder: "/Users/me/a \"quoted\" ğ"))
    }

    @Test func mergeOfAnExistingEntryKeepsItsOtherKeys() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let merged = try #require(try ClaudeTrust.merged(data, folder: "/Users/someone/code/payments-api"))
        let after = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let entry = try #require((after["projects"] as? [String: Any])?["/Users/someone/code/payments-api"] as? [String: Any])
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        #expect(entry["allowedTools"] as? [String] == ["Bash(npm test)"])
        #expect(entry["lastDuration"] as? Int == 523411)
    }

    @Test func mergeOfATrustedFolderIsNothing() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        #expect(try ClaudeTrust.merged(data, folder: "/Users/someone/code/acme-storefront") == nil)
    }

    @Test func mergeRefusesWhatIsntAConfig() {
        #expect(throws: ClaudeTrust.MergeError.unreadable) { try ClaudeTrust.merged(Data("not json".utf8), folder: "/a") }
        #expect(throws: ClaudeTrust.MergeError.unreadable) { try ClaudeTrust.merged(Data("[1,2]".utf8), folder: "/a") }
        #expect(throws: ClaudeTrust.MergeError.unreadable) { try ClaudeTrust.merged(Data(#"{"projects": []}"#.utf8), folder: "/a") }
        #expect(throws: ClaudeTrust.MergeError.unreadable) { try ClaudeTrust.merged(Data(#"{"projects": {"/a": 1}}"#.utf8), folder: "/a") }
    }

    // MARK: The write

    @Test func trustWritesAtomicallyAndKeepsTheRest() throws {
        let dir = try temporaryFolder()
        let file = dir.appending(path: ".claude.json")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: file)
        #expect(ClaudeTrust.trust("/Users/someone/code/new-service", in: file) == .trusted)
        let after = try object(file)
        #expect(ClaudeTrust.isTrusted(after, folder: "/Users/someone/code/new-service"))
        #expect((after["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "someone@example.com")
        #expect(after["numStartups"] as? Int == 412)
        // No lock or temporary file left behind; the file is private to the user.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".claude.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Again: nothing to do.
        #expect(ClaudeTrust.trust("/Users/someone/code/new-service", in: file) == .alreadyTrusted)
    }

    @Test func trustFollowsASymlinkedConfig() throws {
        let dir = try temporaryFolder()
        let real = dir.appending(path: "dotfiles-claude.json")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: real)
        let link = dir.appending(path: ".claude.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ClaudeTrust.trust("/Users/someone/code/new-service", in: link) == .trusted)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(ClaudeTrust.isTrusted(try object(real), folder: "/Users/someone/code/new-service"))
    }

    @Test func trustCreatesAMissingConfig() throws {
        let file = try temporaryFolder().appending(path: ".claude.json")
        #expect(ClaudeTrust.trust("/Users/someone/code/x", in: file) == .trusted)
        #expect(ClaudeTrust.isTrusted(try object(file), folder: "/Users/someone/code/x"))
    }

    @Test func trustLeavesABrokenConfigAlone() throws {
        let file = try temporaryFolder().appending(path: ".claude.json")
        try Data("{ half a file".utf8).write(to: file)
        #expect(ClaudeTrust.trust("/Users/someone/code/x", in: file) == .failed("not a JSON object"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ half a file")
    }

    @Test func trustWaitsForClaudeCodesLockAndNeverBreaksIt() throws {
        let dir = try temporaryFolder()
        let file = dir.appending(path: ".claude.json")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: file)
        let lock = file.path + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        #expect(ClaudeTrust.trust("/Users/someone/code/x", in: file, lockWait: 0.2) == .failed("locked"))
        #expect(FileManager.default.fileExists(atPath: lock))
        #expect(!ClaudeTrust.isTrusted(try object(file), folder: "/Users/someone/code/x"))
        // Released a moment later: the write goes through.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? FileManager.default.removeItem(atPath: lock) }
        #expect(ClaudeTrust.trust("/Users/someone/code/x", in: file, lockWait: 3) == .trusted)
        #expect(ClaudeTrust.isTrusted(try object(file), folder: "/Users/someone/code/x"))
    }

    @Test func concurrentWritersDontLoseEachOthersKeys() async throws {
        let dir = try temporaryFolder()
        let file = dir.appending(path: ".claude.json")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: file)
        let folders = (0..<8).map { "/Users/someone/code/service-\($0)" }
        await withTaskGroup(of: Void.self) { group in
            for folder in folders { group.addTask { _ = ClaudeTrust.trust(folder, in: file) } }
        }
        let after = try object(file)
        for folder in folders { #expect(ClaudeTrust.isTrusted(after, folder: folder)) }
        #expect(ClaudeTrust.isTrusted(after, folder: "/Users/someone/code/acme-storefront"))
    }
}
