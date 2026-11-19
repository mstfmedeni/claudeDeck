import Foundation
import Testing
@testable import ClaudeDeckCore

/// Several Claude accounts (ClaudeAccounts.swift). Every file here lives in a temporary folder;
/// the real `~/.claude` and `~/.claude.json` are never touched.
@Suite struct ClaudeAccountsTests {
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "claude-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Names

    @Test func slugsAndIDs() {
        #expect(ClaudeAccounts.slug("İş Hesabı #2") == "is-hesabi-2")
        #expect(ClaudeAccounts.slug("  Work  ") == "work")
        #expect(ClaudeAccounts.slug("!!!") == "")
        #expect(ClaudeAccounts.newID(for: "Work", taken: []) == "work")
        #expect(ClaudeAccounts.newID(for: "Work", taken: ["work", "work-2"]) == "work-3")
        #expect(ClaudeAccounts.newID(for: "Default", taken: []) == "default-2")
        #expect(ClaudeAccounts.newID(for: "auto", taken: []) == "auto-2")
        #expect(ClaudeAccounts.newID(for: "???", taken: []) == nil)
        #expect(ClaudeAccounts.isValidID("work-2"))
        #expect(!ClaudeAccounts.isValidID("default"))
        #expect(!ClaudeAccounts.isValidID("Work"))
    }

    // MARK: Where Claude Code keeps things

    /// The same name Claude Code 2.1 computes:
    /// `node -e 'console.log(require("crypto").createHash("sha256").update("/x".normalize("NFC")).digest("hex").slice(0,8))'` → b3d1db31.
    @Test func keychainServiceMatchesClaudeCode() {
        #expect(ClaudeAccounts.keychainService(configDir: nil) == "Claude Code-credentials")
        #expect(ClaudeAccounts.keychainService(configDir: "") == "Claude Code-credentials")
        #expect(ClaudeAccounts.keychainService(configDir: "/x") == "Claude Code-credentials-b3d1db31")
        // NFC: a decomposed "é" names the same item as a precomposed one.
        #expect(ClaudeAccounts.keychainService(configDir: "/caf\u{65}\u{301}") == ClaudeAccounts.keychainService(configDir: "/caf\u{e9}"))
    }

    @Test func files() {
        #expect(ClaudeAccounts.globalConfigFile(configDir: nil, home: "/Users/me").path == "/Users/me/.claude.json")
        #expect(ClaudeAccounts.globalConfigFile(configDir: "/a/b", home: "/Users/me").path == "/a/b/.claude.json")
        #expect(ClaudeAccounts.credentialsFile(configDir: nil, home: "/Users/me").path == "/Users/me/.claude/.credentials.json")
        #expect(ClaudeAccounts.credentialsFile(configDir: "/a/b", home: "/Users/me").path == "/a/b/.credentials.json")
        #expect(ClaudeAccounts.environment(for: nil).isEmpty)
        let account = ClaudeAccount(id: "work", label: "Work", configDir: "/a/work")
        #expect(ClaudeAccounts.environment(for: account) == ["CLAUDE_CONFIG_DIR": "/a/work"])
    }

    @Test func priorityOrder() {
        let accounts = [ClaudeAccount(id: "a", label: "A", configDir: "/a"), ClaudeAccount(id: "b", label: "B", configDir: "/b")]
        #expect(ClaudeAccounts.order(saved: [], accounts: accounts) == ["default", "a", "b"])
        #expect(ClaudeAccounts.order(saved: ["b", "gone", "default", "b"], accounts: accounts) == ["b", "default", "a"])
    }

    // MARK: The shared setup

    @Test func prepareFolderLinksTheSharedSetup() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "home/.claude")
        try FileManager.default.createDirectory(at: source.appending(path: "skills"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appending(path: "settings.json"))
        try Data("x".utf8).write(to: source.appending(path: ".credentials.json"))
        let account = root.appending(path: "accounts/work")
        let blocked = try ClaudeAccounts.prepareFolder(account, source: source)
        #expect(blocked.isEmpty)
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: account.appending(path: "skills").path) == source.appending(path: "skills").path)
        #expect(try fm.destinationOfSymbolicLink(atPath: account.appending(path: "settings.json").path) == source.appending(path: "settings.json").path)
        // Transcripts are shared even before the default account wrote any.
        #expect(try fm.destinationOfSymbolicLink(atPath: account.appending(path: "projects").path) == source.appending(path: "projects").path)
        #expect(fm.fileExists(atPath: source.appending(path: "projects").path))
        // Never the login, never the global config; nothing for what doesn't exist.
        #expect(!fm.fileExists(atPath: account.appending(path: ".credentials.json").path))
        #expect(!fm.fileExists(atPath: account.appending(path: ".claude.json").path))
        #expect(!fm.fileExists(atPath: account.appending(path: "agents").path))
        // Again: nothing changes; a real file in the way is reported and kept.
        try fm.removeItem(at: account.appending(path: "settings.json"))
        try Data("{\"own\":1}".utf8).write(to: account.appending(path: "settings.json"))
        #expect(try ClaudeAccounts.prepareFolder(account, source: source) == ["settings.json"])
        #expect(try String(contentsOf: account.appending(path: "settings.json"), encoding: .utf8) == "{\"own\":1}")
    }

    // MARK: The account's .claude.json

    @Test func syncedConfigCopiesTrustAndMCP() throws {
        let source: [String: Any] = [
            "mcpServers": ["pencil": ["command": "pen"]],
            "hasCompletedOnboarding": true,
            "oauthAccount": ["emailAddress": "owner@example.com"],
            "projects": ["/p": ["hasTrustDialogAccepted": true, "mcpServers": ["db": ["command": "db"]], "other": 1]],
        ]
        let account: [String: Any] = ["oauthAccount": ["emailAddress": "second@example.com"], "numStartups": 3]
        let synced = try #require(ClaudeAccounts.syncedConfig(account, sources: [source], folders: ["/p", "/q"]))
        #expect((synced["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "second@example.com")
        #expect(synced["numStartups"] as? Int == 3)
        #expect(synced["hasCompletedOnboarding"] as? Bool == true)
        #expect((synced["mcpServers"] as? [String: Any])?["pencil"] != nil)
        let entry = try #require((synced["projects"] as? [String: Any])?["/p"] as? [String: Any])
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        #expect((entry["mcpServers"] as? [String: Any])?["db"] != nil)
        #expect(entry["other"] == nil)
        #expect((synced["projects"] as? [String: Any])?["/q"] == nil)
        // In sync: nothing to write.
        #expect(ClaudeAccounts.syncedConfig(synced, sources: [source], folders: ["/p", "/q"]) == nil)
    }

    /// Moving a session from account A to B: B trusts the folder when A (not the default) did.
    @Test func trustFromAnySource() throws {
        let defaultConfig: [String: Any] = ["projects": ["/p": ["hasTrustDialogAccepted": false]]]
        let previous: [String: Any] = ["projects": ["/p": ["hasTrustDialogAccepted": true]]]
        let synced = try #require(ClaudeAccounts.syncedConfig([:], sources: [defaultConfig, previous], folders: ["/p"]))
        #expect(ClaudeTrust.isTrusted(synced, folder: "/p"))
        #expect(ClaudeAccounts.isTrusted("/p", in: [defaultConfig, previous]))
        #expect(!ClaudeAccounts.isTrusted("/p", in: [defaultConfig]))
        // Nobody trusts it: no key appears.
        #expect(ClaudeAccounts.syncedConfig([:], sources: [defaultConfig], folders: ["/p"]) == nil)
    }

    @Test func syncConfigWritesTheAccountFile() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "default.json")
        try JSONSerialization.data(withJSONObject: ["projects": ["/p": ["hasTrustDialogAccepted": true]]]).write(to: source)
        let target = root.appending(path: "work/.claude.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(ClaudeAccounts.syncConfig(target, sources: [source], folders: ["/p"]) == .written)
        let written = try #require(ClaudeAccounts.readConfig(target))
        #expect(ClaudeTrust.isTrusted(written, folder: "/p"))
        #expect(ClaudeAccounts.syncConfig(target, sources: [source], folders: ["/p"]) == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: target.path + ".lock"))
        // Not JSON: left alone.
        try Data("nope".utf8).write(to: target)
        #expect(ClaudeAccounts.syncConfig(target, sources: [source], folders: ["/p"]) == .failed("not a JSON object"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "nope")
    }

    @Test func loggedIn() {
        #expect(ClaudeAccounts.loggedInEmail(nil) == nil)
        #expect(ClaudeAccounts.loggedInEmail(["numStartups": 1]) == nil)
        #expect(ClaudeAccounts.loggedInEmail(["oauthAccount": ["emailAddress": "a@b.c"]]) == "a@b.c")
    }

    // MARK: Choosing

    func usage(_ five: Double, _ week: Double = 10, resets: Date? = nil) -> ClaudeUsage {
        ClaudeUsage(fiveHour: UsageWindow(usedPercent: five, resetsAt: resets), sevenDay: UsageWindow(usedPercent: week, resetsAt: nil), fetchedAt: Date())
    }

    @Test func standing() {
        let now = Date()
        #expect(AccountStanding(id: "a", limitedUntil: now.addingTimeInterval(60)).isLimited(now: now))
        #expect(!AccountStanding(id: "a", limitedUntil: now.addingTimeInterval(-60)).isLimited(now: now))
        #expect(AccountStanding(id: "a", usage: usage(100, resets: now.addingTimeInterval(600))).isLimited(now: now))
        #expect(AccountStanding(id: "a", usage: usage(96)).isNearLimit(threshold: 95))
        #expect(AccountStanding(id: "a", usage: usage(10, 95)).isNearLimit(threshold: 95))
        #expect(!AccountStanding(id: "a", usage: usage(96)).isNearLimit(threshold: 0))
        #expect(!AccountStanding(id: "a").isNearLimit(threshold: 95))
    }

    @Test func pickForSwitch() {
        let now = Date()
        let soon = now.addingTimeInterval(1800), later = now.addingTimeInterval(7200)
        let order = ["default", "a", "b", "c"]
        var standings: [String: AccountStanding] = [
            "default": AccountStanding(id: "default", limitedUntil: later),
            "a": AccountStanding(id: "a", usage: usage(97)),            // near
            "b": AccountStanding(id: "b", loggedIn: false),             // nobody logged in
            "c": AccountStanding(id: "c", usage: usage(20)),
        ]
        #expect(AccountPolicy.pickForSwitch(order: order, standings: standings, excluding: ["default"], threshold: 95, now: now) == .account("c"))
        standings["c"] = AccountStanding(id: "c", usage: usage(100, resets: soon))
        #expect(AccountPolicy.pickForSwitch(order: order, standings: standings, excluding: ["default"], threshold: 95, now: now) == .none(earliestReset: soon))
        // Unknown usage counts as usable.
        standings["a"] = AccountStanding(id: "a")
        #expect(AccountPolicy.pickForSwitch(order: order, standings: standings, excluding: ["default"], threshold: 95, now: now) == .account("a"))
    }

    @Test func pickForNew() {
        let now = Date()
        let soon = now.addingTimeInterval(1800), later = now.addingTimeInterval(7200)
        let order = ["default", "a"]
        #expect(AccountPolicy.pickForNew(order: order, standings: ["default": AccountStanding(id: "default"), "a": AccountStanding(id: "a")], threshold: 95, now: now) == "default")
        #expect(AccountPolicy.pickForNew(order: order, standings: ["default": AccountStanding(id: "default", usage: usage(99)), "a": AccountStanding(id: "a")], threshold: 95, now: now) == "a")
        // Everything near: the first that isn't limited.
        #expect(AccountPolicy.pickForNew(order: order, standings: ["default": AccountStanding(id: "default", limitedUntil: later), "a": AccountStanding(id: "a", usage: usage(98))], threshold: 95, now: now) == "a")
        // Everything limited: the one that resets first.
        #expect(AccountPolicy.pickForNew(order: order, standings: ["default": AccountStanding(id: "default", limitedUntil: later), "a": AccountStanding(id: "a", limitedUntil: soon)], threshold: 95, now: now) == "a")
    }

    // MARK: Saved data

    @Test func decodesOldDecksAndKeepsNewFields() throws {
        let old = try JSONDecoder().decode(DeckData.self, from: Data(#"{"settings": {}, "sessions": [{"id": "6B29FC40-CA47-1067-B31D-00DD010662DA", "projectID": "6B29FC40-CA47-1067-B31D-00DD010662DB", "name": "x"}], "projects": [{"id": "6B29FC40-CA47-1067-B31D-00DD010662DB", "path": "/p", "name": "p", "pinned": false, "collapsed": false}]}"#.utf8))
        #expect(old.settings.accounts.isEmpty)
        #expect(old.settings.accountSwitchMode == .off)
        #expect(old.settings.newSessionAccount == "default")
        #expect(old.settings.accountPriority == ["default"])
        #expect(old.sessions[0].account == nil)
        #expect(!old.sessions[0].accountPinned)
        #expect(old.projects[0].account == nil)

        var deck = old
        deck.settings.accounts = [ClaudeAccount(id: "work", label: "Work", configDir: "/a/work")]
        deck.settings.accountOrder = ["work", "default"]
        deck.settings.accountSwitchMode = .auto
        deck.sessions[0].account = "work"
        deck.sessions[0].accountPinned = true
        deck.projects[0].account = "default"
        let again = try JSONDecoder().decode(DeckData.self, from: JSONEncoder().encode(deck))
        #expect(again.settings.accounts == deck.settings.accounts)
        #expect(again.settings.accountPriority == ["work", "default"])
        #expect(again.settings.accountSwitchMode == .auto)
        #expect(again.sessions[0].account == "work")
        #expect(again.sessions[0].accountPinned)
        #expect(again.projects[0].account == "default")
    }
}
