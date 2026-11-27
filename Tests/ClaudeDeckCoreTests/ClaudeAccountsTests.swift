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

    func window(_ percent: Double, resets: Date?) -> UsageWindow { UsageWindow(usedPercent: percent, resetsAt: resets) }

    @Test func staleWindowsAndRoom() {
        let now = Date()
        // The 5-hour window read at 95 % has rolled over since: it counts as empty.
        let rolled = AccountStanding(id: "a", usage: ClaudeUsage(fiveHour: window(95, resets: now.addingTimeInterval(-60)),
                                                                 sevenDay: window(40, resets: now.addingTimeInterval(86400)), fetchedAt: now))
        #expect(rolled.usedPercent(now: now) == 40)
        #expect(!rolled.isNearLimit(threshold: 90, now: now))
        #expect(AccountStanding(id: "a").usedPercent(now: now) == nil)
        let at82 = AccountStanding(id: "a", usage: usage(82))
        #expect(at82.hasRoom(threshold: 90, now: now))
        #expect(at82.hasRoom(threshold: 90, margin: 5, now: now))
        #expect(!AccountStanding(id: "a", usage: usage(87)).hasRoom(threshold: 90, margin: 5, now: now))
        #expect(!AccountStanding(id: "a").hasRoom(threshold: 90, allowUnknown: false, now: now))
        #expect(!AccountStanding(id: "a", loggedIn: false, usage: usage(1)).hasRoom(threshold: 90, now: now))
        #expect(AccountStanding(id: "a", usage: usage(99)).hasRoom(threshold: 0, now: now)) // no threshold
    }

    @Test func pickForSwitchPrefersKnownUsage() {
        let now = Date()
        let order = ["default", "a", "b"]
        let standings: [String: AccountStanding] = [
            "default": AccountStanding(id: "default", limitedUntil: now.addingTimeInterval(3600)),
            "a": AccountStanding(id: "a"),                         // can't be read
            "b": AccountStanding(id: "b", usage: usage(50)),
        ]
        #expect(AccountPolicy.pickForSwitch(order: order, standings: standings, excluding: ["default"], threshold: 90, now: now) == .account("b"))
        var noB = standings
        noB["b"] = AccountStanding(id: "b", usage: usage(100, resets: now.addingTimeInterval(600)))
        #expect(AccountPolicy.pickForSwitch(order: order, standings: noB, excluding: ["default"], threshold: 90, now: now) == .account("a"))
        #expect(AccountPolicy.pickForSwitch(order: order, standings: noB, excluding: ["default"], threshold: 90, allowUnknown: false, now: now)
                == .none(earliestReset: now.addingTimeInterval(600)))
    }

    /// 2026-11-26 22:14Z: a session stopped on apple-loginli's 5-hour limit was moved to the
    /// default account, whose weekly window was full but whose usage couldn't be read (expired
    /// token) and whose limit ClaudeDeck had forgotten in a relaunch. With the record kept, the
    /// default account is no target, and the session waits for 3:10am.
    @Test func neverMovesOntoAnAccountKnownToBeUsedUp() {
        let now = ClaudeUsageAPI.parseISODate("2026-11-26T22:14:50Z")!
        let fiveHourReset = ClaudeUsageAPI.parseISODate("2026-11-27T00:10:00Z")!
        let weeklyReset = ClaudeUsageAPI.parseISODate("2026-11-29T05:00:00Z")!
        let order = ["default", "apple"]
        let standings: [String: AccountStanding] = [
            "default": AccountStanding(id: "default", usage: nil, limitedUntil: weeklyReset),
            "apple": AccountStanding(id: "apple", usage: ClaudeUsage(fiveHour: window(100, resets: fiveHourReset),
                                                                     sevenDay: window(57, resets: weeklyReset), fetchedAt: now)),
        ]
        let facts = AccountPolicy.SessionFacts(account: "apple", atLimit: true)
        #expect(AccountPolicy.decideMove(facts, trigger: .limit, order: order, standings: standings, threshold: 90, now: now)
                == .stay(.noRoom(earliestReset: fiveHourReset)))
        // At 3:10am apple has room again: it isn't limited, so the session continues in place.
        let later = fiveHourReset.addingTimeInterval(120)
        #expect(AccountPolicy.decideMove(facts, trigger: .limit, order: order, standings: standings, threshold: 90, now: later)
                == .stay(.accountHasRoom))
        // The idle sessions left on the weekly-limited default account move to apple then (82 %
        // is below 90 - 5), silently, unless something keeps them.
        var withRoom = standings
        withRoom["apple"] = AccountStanding(id: "apple", usage: usage(82, 57))
        let idle = AccountPolicy.SessionFacts(account: "default")
        #expect(AccountPolicy.decideMove(idle, trigger: .idle, order: order, standings: withRoom, threshold: 90, now: later) == .move(to: "apple"))
        var busy = idle
        busy.working = true
        #expect(AccountPolicy.decideMove(busy, trigger: .idle, order: order, standings: withRoom, threshold: 90, now: later) == .stay(.working))
    }

    @Test func decideMove() {
        let now = Date()
        let order = ["default", "a", "b"]
        let limited = AccountStanding(id: "default", usage: usage(10, 100, resets: nil), limitedUntil: now.addingTimeInterval(3600))
        var standings: [String: AccountStanding] = [
            "default": limited,
            "a": AccountStanding(id: "a", usage: usage(87)), // below 90 but not clearly
            "b": AccountStanding(id: "b", loggedIn: false),
        ]
        func decide(_ facts: AccountPolicy.SessionFacts, _ trigger: AccountPolicy.MoveTrigger) -> AccountPolicy.MoveDecision {
            AccountPolicy.decideMove(facts, trigger: trigger, order: order, standings: standings, threshold: 90, now: now)
        }
        let idle = AccountPolicy.SessionFacts(account: "default")
        var atLimit = idle
        atLimit.atLimit = true
        // Stopped on the limit: any account below the threshold beats waiting.
        #expect(decide(atLimit, .limit) == .move(to: "a"))
        // Idle, ahead of time: only an account clearly below it (hysteresis). A message about to
        // go in: staying means a certain limit, so any account below it.
        #expect(decide(idle, .idle) == .stay(.noRoom(earliestReset: now.addingTimeInterval(3600))))
        #expect(decide(idle, .delivery) == .move(to: "a"))
        standings["a"] = AccountStanding(id: "a", usage: usage(30))
        #expect(decide(idle, .idle) == .move(to: "a"))
        #expect(decide(idle, .delivery) == .move(to: "a"))
        // Never: pinned, a prompt on screen, mid-turn, or an account that still has room.
        var pinned = idle
        pinned.pinned = true
        #expect(decide(pinned, .delivery) == .stay(.pinned))
        var blocked = atLimit
        blocked.blocked = true
        #expect(decide(blocked, .limit) == .stay(.blocked))
        var working = idle
        working.working = true
        #expect(decide(working, .delivery) == .stay(.working))
        #expect(decide(AccountPolicy.SessionFacts(account: "a"), .idle) == .stay(.accountHasRoom))
        // Background tasks keep an idle session where it is until it is used.
        var tasks = idle
        tasks.backgroundTasks = true
        #expect(decide(tasks, .idle) == .stay(.backgroundTasks))
        #expect(decide(tasks, .delivery) == .move(to: "a"))
        // At most one move per ten minutes.
        var moved = atLimit
        moved.lastMovedAt = now.addingTimeInterval(-120)
        #expect(decide(moved, .limit) == .stay(.cooldown(until: now.addingTimeInterval(-120 + AccountPolicy.moveCooldown))))
        moved.lastMovedAt = now.addingTimeInterval(-AccountPolicy.moveCooldown - 1)
        #expect(decide(moved, .limit) == .move(to: "a"))
        // Unknown usage: a stopped session takes the chance, an idle one doesn't.
        standings["a"] = AccountStanding(id: "a")
        #expect(decide(atLimit, .limit) == .move(to: "a"))
        #expect(decide(idle, .idle) == .stay(.noRoom(earliestReset: now.addingTimeInterval(3600))))
        // Both windows count: weekly full on one, 5-hour full on the other.
        let soon = now.addingTimeInterval(1800)
        standings["a"] = AccountStanding(id: "a", usage: usage(100, 40, resets: soon))
        #expect(decide(atLimit, .limit) == .stay(.noRoom(earliestReset: soon)))
    }

    @Test func redirectNewHasHysteresis() {
        let now = Date()
        let order = ["default", "a"]
        func redirect(_ main: ClaudeUsage?, _ other: ClaudeUsage?, limitedUntil: Date? = nil) -> String? {
            AccountPolicy.redirectNew(from: "default", order: order,
                                      standings: ["default": AccountStanding(id: "default", usage: main, limitedUntil: limitedUntil),
                                                  "a": AccountStanding(id: "a", usage: other)], threshold: 90, now: now)
        }
        #expect(redirect(usage(50), usage(10)) == nil)       // room: stays
        #expect(redirect(usage(91), usage(87)) == nil)       // near, other not clearly better
        #expect(redirect(usage(91), usage(80)) == "a")
        #expect(redirect(usage(20), usage(87), limitedUntil: now.addingTimeInterval(60)) == "a") // limited: any room
        #expect(redirect(usage(100, resets: now.addingTimeInterval(60)), usage(95)) == nil)
    }

    @Test func limitRecords() {
        let now = Date()
        let weekly = now.addingTimeInterval(2 * 86400)
        let full = ClaudeUsage(fiveHour: nil, sevenDay: window(100, resets: weekly), fetchedAt: now)
        // A full window is recorded until its reset, and extends a shorter record.
        #expect(AccountPolicy.limitRecord(nil, after: full, now: now) == AccountLimitRecord(until: weekly, recordedAt: now))
        let short = AccountLimitRecord(until: now.addingTimeInterval(600), recordedAt: now.addingTimeInterval(-60))
        #expect(AccountPolicy.limitRecord(short, after: full, now: now)?.until == weekly)
        // A reading right after a limit message doesn't drop it (the API lags), nor one at 99 %.
        let hit = AccountLimitRecord(until: now.addingTimeInterval(3600), recordedAt: now.addingTimeInterval(-30))
        #expect(AccountPolicy.limitRecord(hit, after: usage(50), now: now) == hit)
        let older = AccountLimitRecord(until: now.addingTimeInterval(3600), recordedAt: now.addingTimeInterval(-600))
        #expect(AccountPolicy.limitRecord(older, after: usage(99), now: now) == older)
        // A later reading clearly below full drops it (lifted early, or a guess).
        #expect(AccountPolicy.limitRecord(older, after: usage(40), now: now) == nil)
        // …unless a session still waits on that limit: its own message wins.
        #expect(AccountPolicy.limitRecord(older, after: usage(40), heldUntil: now.addingTimeInterval(1800), now: now) == older)
        #expect(AccountPolicy.limitRecord(older, after: usage(40), heldUntil: now.addingTimeInterval(-1), now: now) == nil)
        // Expired records go.
        #expect(AccountPolicy.limitRecord(AccountLimitRecord(until: now.addingTimeInterval(-1)), after: usage(99), now: now) == nil)
    }

    @Test func continueDue() {
        let hit = Date(timeIntervalSince1970: 1_000_000)
        let message = hit.addingTimeInterval(3600), account = hit.addingTimeInterval(7200)
        #expect(AccountPolicy.continueDue(hitAt: hit, messageReset: message, accountReset: account, grace: 60) == message.addingTimeInterval(60))
        #expect(AccountPolicy.continueDue(hitAt: hit, messageReset: nil, accountReset: account, grace: 60) == account.addingTimeInterval(60))
        #expect(AccountPolicy.continueDue(hitAt: hit, messageReset: nil, accountReset: nil, grace: 0) == hit.addingTimeInterval(1800))
    }

    // MARK: claudedeck account

    @Test func routesAndWaitStates() {
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/accounts") == .route(.accounts))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/accounts/current") == .route(.currentAccount))
        #expect(SessionCLI.match(method: "POST", path: "/v1/cli/accounts/switch") == .route(.switchAccount))
        #expect(SessionCLI.match(method: "GET", path: "/v1/cli/accounts/switch") == .methodNotAllowed)
        #expect(SessionCLI.Route.accounts.scope == .list)
        #expect(SessionCLI.Route.switchAccount.scope == .account)
        // A terminal a session opened may look, not move anything.
        #expect(!SessionCLI.openedScopes.contains(.account) && SessionCLI.fullScopes.contains(.account))
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SessionCLI.Progress.limited(reset).result == "limited")
        #expect(SessionCLI.waitText(.limited(reset), detail: nil).hasPrefix("limited"))
        // --all: a limited one ends the wait with 6 (after anything that needs the user).
        #expect(SessionCLI.combine([(false, .ok), (false, .limited)], mode: .all) == (true, .limited, nil))
        #expect(SessionCLI.combine([(false, .blocked), (false, .limited)], mode: .all) == (true, .blocked, nil))
        #expect(SessionCLI.resultName(.limited) == "limited")
    }

    @Test func accountListText() throws {
        let now = Date()
        let infos = [
            SessionCLIAccountInfo(name: "default", label: "Default", priority: 1, active: true, current: false, loggedIn: true,
                                  fiveHour: 99.6, weekly: 40, limited: true, nearLimit: true, resetAt: now.addingTimeInterval(3600), sessions: 2),
            SessionCLIAccountInfo(name: "work", label: "Work", priority: 2, active: false, current: true, loggedIn: true,
                                  fiveHour: nil, weekly: nil, limited: false, nearLimit: false, resetAt: nil, sessions: 0),
        ]
        let text = ClaudeAccounts.listText(infos, now: now)
        #expect(text.contains("100%") && text.contains("limited") && text.contains("active") && text.contains("current"))
        let json = try #require(JSONSerialization.jsonObject(with: AgentJSON.encode(infos[1])) as? [String: Any])
        #expect(json["five_hour"] is NSNull && json["near_limit"] as? Bool == false && json["name"] as? String == "work" && json["current"] as? Bool == true)
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
