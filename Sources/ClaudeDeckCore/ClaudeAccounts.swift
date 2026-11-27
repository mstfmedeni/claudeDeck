import CryptoKit
import Darwin
import Foundation

// Several Claude accounts (Settings › Accounts). An account is a Claude Code config folder:
// the default one is the owner's normal setup (`~/.claude` + `~/.claude.json`, no environment),
// every other one a folder ClaudeDeck keeps under Application Support and passes to `claude` as
// `CLAUDE_CONFIG_DIR`. ClaudeDeck never handles a password or a token for them: the owner logs
// in with `claude auth login` in a ClaudeDeck terminal, and Claude Code keeps that login in its
// own Keychain item for the folder.
//
// What Claude Code 2.1 does with `CLAUDE_CONFIG_DIR` (read from its code, verified with the CLI):
// - global config: `$CLAUDE_CONFIG_DIR/.claude.json` instead of `~/.claude.json`
// - transcripts: `$CLAUDE_CONFIG_DIR/projects/<encoded cwd>/<session id>.jsonl`
// - credentials (macOS): the Keychain item "Claude Code-credentials-<first 8 hex digits of the
//   SHA-256 of the folder path (NFC)>" for `$USER`, instead of "Claude Code-credentials"; elsewhere
//   `$CLAUDE_CONFIG_DIR/.credentials.json`
// - `CLAUDE_SECURESTORAGE_CONFIG_DIR` overrides which folder the Keychain item is named after
//   (empty: the default item), so it is never passed to a session.
//
// Account folders link the owner's shared setup from `~/.claude` (settings and hooks, skills,
// agents, commands, plugins, CLAUDE.md) and, importantly, `projects`: every account writes its
// transcripts into the same place, so a session resumes on any account with the same id
// (`claude --resume <id>` finds it), and ClaudeDeck keeps following one transcript.

/// A Claude account besides the default one.
public struct ClaudeAccount: Codable, Identifiable, Sendable, Equatable, Hashable {
    /// Its name in the CLI and in `deck.json` (lowercase letters, digits, `-`); never
    /// `default` or `auto`. Also its folder's name.
    public var id: String
    /// What the owner called it.
    public var label: String
    /// The `CLAUDE_CONFIG_DIR` (absolute, no trailing slash). The Keychain item is named after
    /// this exact string, so it never changes once the account exists.
    public var configDir: String
    public var addedAt: Date

    public init(id: String, label: String, configDir: String, addedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.configDir = configDir
        self.addedAt = addedAt
    }
}

/// How a session that hit the usage limit moves to another account.
public enum AccountSwitchMode: String, Codable, Sendable, CaseIterable {
    /// Nothing happens (the session waits for its own reset, as before).
    case off
    /// The owner gets a notification with a "Switch account" action.
    case notify
    /// ClaudeDeck restarts the session on the next account with headroom.
    case auto
}

public enum ClaudeAccounts {
    /// The owner's normal Claude Code setup.
    public static let defaultID = "default"
    /// `claudedeck new --account auto` / new sessions: the first account (by priority) with headroom.
    public static let autoID = "auto"

    // MARK: Names

    /// A name for a new account from what the owner typed: lowercase ASCII letters and digits,
    /// other runs become `-`; at most 32 characters. Empty when nothing usable is left.
    public static func slug(_ text: String) -> String {
        var out = ""
        // Turkish dotless/dotted i first: neither folds to "i" on its own.
        let plain = text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        for scalar in plain.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id != defaultID && id != autoID && slug(id) == id
    }

    /// A free id for `label` among `taken` ("work", "work-2", …); nil when the label has no usable characters.
    public static func newID(for label: String, taken: Set<String>) -> String? {
        let base = slug(label)
        guard !base.isEmpty else { return nil }
        let reserved = taken.union([defaultID, autoID])
        if !reserved.contains(base) { return base }
        var n = 2
        while reserved.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: Where Claude Code keeps things

    /// The Keychain service Claude Code reads the login from: "Claude Code-credentials" for the
    /// default setup, "Claude Code-credentials-<8 hex>" for a `CLAUDE_CONFIG_DIR`.
    public static func keychainService(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return ClaudeUsageAPI.keychainService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ClaudeUsageAPI.keychainService + "-" + hex.prefix(8)
    }

    /// The global config: `<configDir>/.claude.json`, else `<home>/.claude.json`.
    public static func globalConfigFile(configDir: String?, home: String) -> URL {
        if let configDir, !configDir.isEmpty { return URL(fileURLWithPath: configDir).appending(path: ".claude.json") }
        return URL(fileURLWithPath: home).appending(path: ".claude.json")
    }

    /// Where Claude Code keeps the login outside the Keychain.
    public static func credentialsFile(configDir: String?, home: String) -> URL {
        let dir = configDir.flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: dir).appending(path: ".credentials.json")
    }

    /// The environment for a session on `account` (nil: the default one, nothing to add).
    public static func environment(for account: ClaudeAccount?) -> [String: String] {
        guard let account else { return [:] }
        return ["CLAUDE_CONFIG_DIR": account.configDir]
    }

    // MARK: Priority

    /// Every account id in priority order: `saved` first (unknown ids dropped, no repeats), then
    /// the default and any account not in it yet.
    public static func order(saved: [String], accounts: [ClaudeAccount]) -> [String] {
        let known = [defaultID] + accounts.map(\.id)
        var out: [String] = []
        for id in saved where known.contains(id) && !out.contains(id) { out.append(id) }
        for id in known where !out.contains(id) { out.append(id) }
        return out
    }

    // MARK: The shared setup

    /// What every account folder links from the owner's `~/.claude`: the setup sessions should
    /// behave the same with (settings — ClaudeDeck's hooks are in there —, CLAUDE.md, skills,
    /// agents, commands, plugins, output styles, keybindings) and what belongs to a conversation
    /// rather than to an account (transcripts, file history for /rewind, todos, plans, shell
    /// snapshots, prompt history). Never the login, never `.claude.json`.
    public static let sharedEntries = [
        "settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins", "hooks", "output-styles",
        "keybindings.json", "statusline.sh", "projects", "file-history", "todos", "tasks", "plans",
        "shell-snapshots", "session-env", "history.jsonl", "ide",
    ]

    /// Folders created in `~/.claude` when missing, so the link is there before the first
    /// session writes into it (a transcript written into an account folder would be lost to
    /// the others).
    public static let sharedFolders: Set<String> = ["projects", "file-history", "todos", "shell-snapshots", "session-env"]

    /// Makes `dir` an account folder: creates it, links each shared entry from `source` (the
    /// owner's `~/.claude`) that exists there (folders in `sharedFolders` are created first),
    /// and leaves anything already in place alone. Returns the entries it couldn't link because
    /// something else is in the way (a real file Claude Code wrote there).
    @discardableResult
    public static func prepareFolder(_ dir: URL, source: URL, fileManager fm: FileManager = .default) throws -> [String] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var blocked: [String] = []
        for name in sharedEntries {
            let target = source.appending(path: name)
            let link = dir.appending(path: name)
            if sharedFolders.contains(name), !fm.fileExists(atPath: target.path) {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
            guard fm.fileExists(atPath: target.path) else { continue }
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if existing == target.path { continue }
                // A link to somewhere else (the shared folder moved): point it here again.
                try? fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                blocked.append(name)
                continue
            }
            do {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            } catch {
                blocked.append(name)
            }
        }
        return blocked
    }

    // MARK: The account's .claude.json

    /// Keys of a folder's entry in `projects` that follow the owner's default config into an
    /// account's: the trust answer, the folder's MCP servers and its `.mcp.json` choices.
    public static let sharedProjectKeys = [
        "hasTrustDialogAccepted", "mcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers",
        "enableAllProjectMcpServers", "allowedTools",
    ]

    /// Top-level keys taken from the default config: the owner's own (user-scope) MCP servers,
    /// and the onboarding answers so an account's session doesn't greet with the theme picker.
    public static let sharedTopKeys = ["mcpServers", "hasCompletedOnboarding", "theme", "lastOnboardingVersion"]

    /// `account` with what `sources` (the default config first, then e.g. the account the
    /// session comes from) say about `folders`, and the default's shared top-level keys; nil
    /// when nothing changes. A folder is trusted when any source trusts it; every other key
    /// comes from the first source that has it. Nothing is ever removed.
    public static func syncedConfig(_ account: [String: Any], sources: [[String: Any]], folders: [String]) -> [String: Any]? {
        var out = account
        var changed = false
        if let primary = sources.first {
            for key in sharedTopKeys {
                guard let value = primary[key] else { continue }
                if !jsonEqual(out[key], value) { out[key] = value; changed = true }
            }
        }
        var projects = out["projects"] as? [String: Any] ?? [:]
        for folder in folders {
            var entry = projects[folder] as? [String: Any] ?? [:]
            var entryChanged = false
            for key in sharedProjectKeys {
                let values = sources.compactMap { (($0["projects"] as? [String: Any])?[folder] as? [String: Any])?[key] }
                guard !values.isEmpty else { continue }
                let value: Any = key == "hasTrustDialogAccepted" ? values.contains { $0 as? Bool == true } : values[0]
                if key == "hasTrustDialogAccepted", value as? Bool != true { continue }
                if !jsonEqual(entry[key], value) { entry[key] = value; entryChanged = true }
            }
            if entryChanged { projects[folder] = entry; changed = true }
        }
        if changed { out["projects"] = projects }
        return changed ? out : nil
    }

    /// Whether any of `configs` trusts `folder` (its own entry).
    public static func isTrusted(_ folder: String, in configs: [[String: Any]]) -> Bool {
        configs.contains { ClaudeTrust.isTrusted($0, folder: folder) }
    }

    static func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard JSONSerialization.isValidJSONObject([a]), JSONSerialization.isValidJSONObject([b]),
              let da = try? JSONSerialization.data(withJSONObject: [a], options: .sortedKeys),
              let db = try? JSONSerialization.data(withJSONObject: [b], options: .sortedKeys) else { return false }
        return da == db
    }

    public enum SyncOutcome: Equatable, Sendable {
        case unchanged, written
        case failed(String)
    }

    /// Brings an account's `.claude.json` up to date (`syncedConfig`) under Claude Code's lock
    /// (`<file>.lock`), from a fresh read, as one atomic rename. Only for account folders
    /// ClaudeDeck made; the owner's own config is only ever changed by `ClaudeTrust.trust`.
    public static func syncConfig(_ file: URL, sources: [URL], folders: [String], lockWait: TimeInterval = 3) -> SyncOutcome {
        let sourceConfigs = sources.compactMap(readConfig)
        let path = file.resolvingSymlinksInPath().path
        let lock = path + ".lock"
        guard ClaudeTrust.acquire(lock, wait: lockWait) else { return .failed("locked") }
        defer { rmdir(lock) }
        let current: [String: Any]
        if FileManager.default.fileExists(atPath: path) {
            guard let read = readConfig(URL(fileURLWithPath: path)) else { return .failed("not a JSON object") }
            current = read
        } else {
            current = [:]
        }
        guard let next = syncedConfig(current, sources: sourceConfigs, folders: folders) else { return .unchanged }
        guard let data = try? JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted]) else { return .failed("can't encode") }
        let temporary = (path as NSString).deletingLastPathComponent + "/.claude.json.claudedeck-\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return .failed("can't write")
        }
        guard rename(temporary, path) == 0 else { unlink(temporary); return .failed("can't replace") }
        return .written
    }

    public static func readConfig(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Who is logged in, from the config Claude Code writes at login (no secret in it): the
    /// e-mail address, or nil when nobody is.
    public static func loggedInEmail(_ config: [String: Any]?) -> String? {
        guard let account = config?["oauthAccount"] as? [String: Any] else { return nil }
        let email = (account["emailAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? String(localized: "logged in") : email
    }
}

// MARK: - Choosing an account

/// What ClaudeDeck knows about one account when it picks one.
public struct AccountStanding: Sendable, Equatable {
    public var id: String
    /// Someone is logged in (the default account always counts as logged in).
    public var loggedIn: Bool
    /// From the usage API; nil when unknown.
    public var usage: ClaudeUsage?
    /// A session on it hit the usage limit: until then (ClaudeDeck's own knowledge).
    public var limitedUntil: Date?

    public init(id: String, loggedIn: Bool = true, usage: ClaudeUsage? = nil, limitedUntil: Date? = nil) {
        self.id = id
        self.loggedIn = loggedIn
        self.usage = usage
        self.limitedUntil = limitedUntil
    }

    /// Used up: a session hit the limit and it hasn't reset, or the usage API says a window is full.
    public func isLimited(now: Date = Date()) -> Bool {
        if let limitedUntil, limitedUntil > now { return true }
        if let until = usage?.exhaustedUntil, until > now { return true }
        return false
    }

    /// When it is usable again (nil: not limited, or unknown).
    public func resetsAt(now: Date = Date()) -> Date? {
        [limitedUntil, usage?.exhaustedUntil].compactMap { $0 }.filter { $0 > now }.max()
    }

    /// A window is at or above `threshold` percent (0: never near). A window whose reset has
    /// passed counts as empty (that reading is from before it rolled over).
    public func isNearLimit(threshold: Double, now: Date = Date()) -> Bool {
        guard threshold > 0, let used = usedPercent(now: now) else { return false }
        return used >= threshold
    }

    /// The fuller window's percent (nil: usage unknown).
    public func usedPercent(now: Date = Date()) -> Double? {
        guard let usage else { return nil }
        let windows = [usage.fiveHour, usage.sevenDay].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return windows.map { window in
            if let reset = window.resetsAt, reset <= now { return 0 }
            return window.usedPercent
        }.max()
    }

    /// Has room: logged in, not limited and the fuller window below `threshold - margin`
    /// (unknown usage only when `allowUnknown`).
    public func hasRoom(threshold: Double, margin: Double = 0, allowUnknown: Bool = true, now: Date = Date()) -> Bool {
        guard loggedIn, !isLimited(now: now) else { return false }
        guard let used = usedPercent(now: now) else { return allowUnknown }
        return threshold <= 0 || used < max(0, threshold - margin)
    }
}

/// ClaudeDeck's own record of an account being used up: until when, and when it learned that
/// (a session's limit message, or the usage API showing a full window). Kept across relaunches
/// (`account-limits.json`), so an account whose usage can't be read for a while (an expired
/// token on an account nothing runs on) doesn't look free.
public struct AccountLimitRecord: Codable, Sendable, Equatable {
    public var until: Date
    public var recordedAt: Date

    public init(until: Date, recordedAt: Date = Date()) {
        self.until = until
        self.recordedAt = recordedAt
    }
}

public enum AccountPolicy {
    public enum Pick: Equatable, Sendable {
        case account(String)
        /// Nothing usable; the earliest moment one of them resets (nil: unknown).
        case none(earliestReset: Date?)
    }

    /// Points below the near-limit threshold an account must be to take a session that isn't
    /// stopped on a limit (an idle one, or a new one leaving a near-limit account): hysteresis,
    /// so a reading that wobbles around the threshold doesn't send sessions back and forth.
    public static let roomMargin: Double = 5
    /// At most one automatic move per session in this time.
    public static let moveCooldown: TimeInterval = 10 * 60
    /// A limit record that a fresh usage reading taken this much later contradicts is dropped.
    public static let recordTrustWindow: TimeInterval = 2 * 60

    /// For moving a session: the first account in `order` that isn't `excluding`, is logged in,
    /// isn't limited and is below `threshold - margin`. Accounts whose usage is known come
    /// first; one whose usage is unknown only when `allowUnknown`.
    public static func pickForSwitch(order: [String], standings: [String: AccountStanding], excluding: Set<String>,
                                     threshold: Double, margin: Double = 0, allowUnknown: Bool = true,
                                     now: Date = Date()) -> Pick {
        let roomy = order.filter { !excluding.contains($0) }.compactMap { standings[$0] }
            .filter { $0.hasRoom(threshold: threshold, margin: margin, allowUnknown: allowUnknown, now: now) }
        if let ok = roomy.first(where: { $0.usage != nil }) ?? roomy.first {
            return .account(ok.id)
        }
        let all = order.compactMap { standings[$0] }.filter(\.loggedIn)
        return .none(earliestReset: all.compactMap { $0.resetsAt(now: now) }.min())
    }

    /// For a new session (`auto`): like `pickForSwitch`, but when every account is near its
    /// limit the first one that isn't limited, and when all are limited the one that resets first
    /// (a session has to start somewhere; it waits for that reset).
    public static func pickForNew(order: [String], standings: [String: AccountStanding], threshold: Double,
                                  now: Date = Date()) -> String {
        if case .account(let id) = pickForSwitch(order: order, standings: standings, excluding: [], threshold: threshold, now: now) {
            return id
        }
        let usable = order.compactMap { standings[$0] }.filter(\.loggedIn)
        if let notLimited = usable.first(where: { !$0.isLimited(now: now) }) { return notLimited.id }
        if let soonest = usable.min(by: { ($0.resetsAt(now: now) ?? .distantFuture) < ($1.resetsAt(now: now) ?? .distantFuture) }) {
            return soonest.id
        }
        return order.first ?? ClaudeAccounts.defaultID
    }

    /// Where a start nobody chose an account for goes instead of `chosen` (nil: it stays). Away
    /// from a limited account to any with room; away from one that is only near its limit just
    /// to one clearly below it (`roomMargin`).
    public static func redirectNew(from chosen: String, order: [String], standings: [String: AccountStanding],
                                   threshold: Double, now: Date = Date()) -> String? {
        guard let standing = standings[chosen] else { return nil }
        let limited = standing.isLimited(now: now)
        guard limited || standing.isNearLimit(threshold: threshold, now: now) else { return nil }
        let pick = pickForSwitch(order: order, standings: standings, excluding: [chosen], threshold: threshold,
                                 margin: limited ? 0 : roomMargin, now: now)
        if case .account(let other) = pick { return other }
        return nil
    }

    // MARK: Moving sessions on their own

    /// Why ClaudeDeck moves a session by itself.
    public enum MoveTrigger: String, Sendable, Equatable {
        /// It stopped on its account's usage limit.
        case limit
        /// It is idle on an account that is used up: moved before it is next used.
        case idle
        /// A message (a queued prompt, `send`, a decision's answer) is about to go into it.
        case delivery
    }

    /// What ClaudeDeck knows about a session when it considers moving it.
    public struct SessionFacts: Sendable, Equatable {
        public var account: String
        /// Pinned itself, or its project is.
        public var pinned: Bool
        /// In the middle of a turn.
        public var working: Bool
        /// A permission prompt or a question is on screen.
        public var blocked: Bool
        /// Stopped on a usage limit and not going again yet.
        public var atLimit: Bool
        /// Background tasks (shells, agents) still run in it: a move would end them.
        public var backgroundTasks: Bool
        /// Its last automatic move.
        public var lastMovedAt: Date?

        public init(account: String, pinned: Bool = false, working: Bool = false, blocked: Bool = false,
                    atLimit: Bool = false, backgroundTasks: Bool = false, lastMovedAt: Date? = nil) {
            self.account = account
            self.pinned = pinned
            self.working = working
            self.blocked = blocked
            self.atLimit = atLimit
            self.backgroundTasks = backgroundTasks
            self.lastMovedAt = lastMovedAt
        }
    }

    public enum StayReason: Equatable, Sendable {
        case pinned
        /// Its account isn't used up.
        case accountHasRoom
        case working
        case blocked
        case backgroundTasks
        /// Moved recently; may move again then.
        case cooldown(until: Date)
        /// No other account has room; the earliest reset (nil: unknown).
        case noRoom(earliestReset: Date?)
    }

    public enum MoveDecision: Equatable, Sendable {
        case move(to: String)
        case stay(StayReason)
    }

    /// Whether ClaudeDeck moves a session to another account by itself now. Only ever away from
    /// an account that is used up (a session never leaves one that still has room, so accounts
    /// recovering never send sessions back and forth); never a pinned session, one in the middle
    /// of a turn or with a prompt on screen; at most once per `moveCooldown`. A session stopped
    /// on the limit, or one a message is about to go into, takes any account below the threshold
    /// (staying means a certain limit); an idle one moved ahead of time only one clearly below it
    /// (`roomMargin`) whose usage is known, and not while background tasks run in it (when it is
    /// next used it moves anyway).
    public static func decideMove(_ facts: SessionFacts, trigger: MoveTrigger, order: [String],
                                  standings: [String: AccountStanding], threshold: Double, now: Date = Date()) -> MoveDecision {
        if facts.pinned { return .stay(.pinned) }
        guard standings[facts.account]?.isLimited(now: now) ?? false else { return .stay(.accountHasRoom) }
        if facts.blocked { return .stay(.blocked) }
        if facts.working && !facts.atLimit { return .stay(.working) }
        if trigger == .idle && facts.backgroundTasks && !facts.atLimit { return .stay(.backgroundTasks) }
        if let last = facts.lastMovedAt, now.timeIntervalSince(last) < moveCooldown {
            return .stay(.cooldown(until: last.addingTimeInterval(moveCooldown)))
        }
        // Only a move nobody needs right now waits for clearly more room.
        let proactive = trigger == .idle && !facts.atLimit
        let pick = pickForSwitch(order: order, standings: standings, excluding: [facts.account], threshold: threshold,
                                 margin: proactive ? roomMargin : 0, allowUnknown: !proactive, now: now)
        switch pick {
        case .account(let id): return .move(to: id)
        case .none(let earliest): return .stay(.noRoom(earliestReset: earliest))
        }
    }

    // MARK: Keeping what is known

    /// The record after a usage reading: a full window extends it to that window's reset; a
    /// reading taken well after the record was made whose windows are all clearly below full
    /// (under `clearlyFreePercent`) drops it (the limit was lifted early, or the record was a
    /// guess); otherwise it stays (the API can lag a limit message, or show 99 % at the limit).
    public static func limitRecord(_ record: AccountLimitRecord?, after usage: ClaudeUsage, now: Date = Date()) -> AccountLimitRecord? {
        if let until = usage.exhaustedUntil, until > now {
            if let record, record.until >= until { return record }
            return AccountLimitRecord(until: until, recordedAt: now)
        }
        guard let record, record.until > now else { return nil }
        let used = AccountStanding(id: "", usage: usage).usedPercent(now: now)
        if let used, used < clearlyFreePercent, usage.fetchedAt.timeIntervalSince(record.recordedAt) > recordTrustWindow { return nil }
        return record
    }

    /// See `limitRecord`.
    public static let clearlyFreePercent: Double = 90

    /// When a session stopped on the limit is due its continue: the reset in its limit message,
    /// else its account's known reset, else half an hour after the hit (then it is tried, and a
    /// new limit message gives the real time); plus `grace`.
    public static func continueDue(hitAt: Date, messageReset: Date?, accountReset: Date?, grace: TimeInterval) -> Date {
        (messageReset ?? accountReset ?? hitAt.addingTimeInterval(30 * 60)).addingTimeInterval(grace)
    }
}

/// What ClaudeDeck types into a session after moving it to another account, when it was in the
/// middle of something (an idle session is resumed silently).
public enum AccountSwitchMessage {
    public static let afterLimit = "[ClaudeDeck] Account switched after a usage limit. Continue exactly where you left off: re-read docs/AGENDA.md (and HANDOFF.md if present), then resume the current task."
    public static let manual = "[ClaudeDeck] Account switched. Continue exactly where you left off: re-read docs/AGENDA.md (and HANDOFF.md if present), then resume the current task."
}

// MARK: - claudedeck account

/// `GET /v1/cli/accounts` (one entry) and `GET /v1/cli/accounts/current`.
public struct SessionCLIAccountInfo: Encodable, Sendable, Equatable {
    /// `default` or the account's id: what `--account` and `account switch --to` take.
    public var name: String
    public var label: String
    /// 1 = tried first.
    public var priority: Int
    /// New sessions start on it (`new` without `--account`).
    public var active: Bool
    /// The calling session runs on it.
    public var current: Bool
    public var loggedIn: Bool
    /// Percent used, nil when unknown.
    public var fiveHour: Double?
    public var weekly: Double?
    public var limited: Bool
    public var nearLimit: Bool
    /// When it is usable again, while limited.
    public var resetAt: Date?
    /// Claude sessions running on it.
    public var sessions: Int

    public init(name: String, label: String, priority: Int, active: Bool, current: Bool, loggedIn: Bool, fiveHour: Double?,
                weekly: Double?, limited: Bool, nearLimit: Bool, resetAt: Date?, sessions: Int) {
        self.name = name
        self.label = label
        self.priority = priority
        self.active = active
        self.current = current
        self.loggedIn = loggedIn
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.limited = limited
        self.nearLimit = nearLimit
        self.resetAt = resetAt
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case name, label, priority, active, current, loggedIn, fiveHour, weekly, limited, nearLimit, resetAt, sessions
    }

    /// Every key is always there (null when unknown).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(label, forKey: .label)
        try c.encode(priority, forKey: .priority)
        try c.encode(active, forKey: .active)
        try c.encode(current, forKey: .current)
        try c.encode(loggedIn, forKey: .loggedIn)
        try c.encode(fiveHour.map { $0.rounded() }, forKey: .fiveHour)
        try c.encode(weekly.map { $0.rounded() }, forKey: .weekly)
        try c.encode(limited, forKey: .limited)
        try c.encode(nearLimit, forKey: .nearLimit)
        try c.encode(resetAt, forKey: .resetAt)
        try c.encode(sessions, forKey: .sessions)
    }

    /// `ok`, `near`, `limited` or `logged_out`.
    public var stateName: String {
        !loggedIn ? "logged_out" : limited ? "limited" : nearLimit ? "near" : "ok"
    }
}

/// `POST /v1/cli/accounts/switch`.
public struct SessionCLIAccountSwitch: Encodable, Sendable, Equatable {
    public var from: String
    public var to: String
    /// The session ends and resumes on `to` a moment after this answer.
    public var scheduled: Bool
    public init(from: String, to: String, scheduled: Bool = true) {
        self.from = from
        self.to = to
        self.scheduled = scheduled
    }
}

extension ClaudeAccounts {
    public static func listText(_ accounts: [SessionCLIAccountInfo], now: Date = Date()) -> String {
        let header = ["PRIO", "NAME", "5H", "WEEK", "STATE", "RESET", "SESSIONS", ""]
        func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "-" }
        let rows = accounts.map { info in
            [String(info.priority), info.name, percent(info.fiveHour), percent(info.weekly), info.stateName,
             info.resetAt.map { UsageFormat.countdown(to: $0, now: now) } ?? "-", String(info.sessions),
             [info.active ? "active" : nil, info.current ? "current" : nil].compactMap { $0 }.joined(separator: ",")]
        }
        let all = [header] + rows
        let widths = (0..<(header.count - 1)).map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
