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

    /// A window is at or above `threshold` percent (0: never near).
    public func isNearLimit(threshold: Double) -> Bool {
        guard threshold > 0, let usage else { return false }
        return [usage.fiveHour, usage.sevenDay].compactMap { $0 }.contains { $0.usedPercent >= threshold }
    }
}

public enum AccountPolicy {
    public enum Pick: Equatable, Sendable {
        case account(String)
        /// Nothing usable; the earliest moment one of them resets (nil: unknown).
        case none(earliestReset: Date?)
    }

    /// For moving a session that hit its limit: the first account in `order` that isn't
    /// `excluding`, is logged in, isn't limited and isn't near its limit. Never a limited or
    /// near-limit one.
    public static func pickForSwitch(order: [String], standings: [String: AccountStanding], excluding: Set<String>,
                                     threshold: Double, now: Date = Date()) -> Pick {
        let candidates = order.filter { !excluding.contains($0) }.compactMap { standings[$0] }.filter(\.loggedIn)
        if let ok = candidates.first(where: { !$0.isLimited(now: now) && !$0.isNearLimit(threshold: threshold) }) {
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
}

/// What ClaudeDeck types into a session after moving it to another account, when it was in the
/// middle of something (an idle session is resumed silently).
public enum AccountSwitchMessage {
    public static let afterLimit = "[ClaudeDeck] Account switched after a usage limit. Continue exactly where you left off: re-read docs/AGENDA.md (and HANDOFF.md if present), then resume the current task."
    public static let manual = "[ClaudeDeck] Account switched. Continue exactly where you left off: re-read docs/AGENDA.md (and HANDOFF.md if present), then resume the current task."
}
