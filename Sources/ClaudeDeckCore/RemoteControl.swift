import Darwin
import Foundation

// Claude Code's Remote Control (claude.ai/code and the Claude app driving a local session) in the
// sessions ClaudeDeck runs: seeing where it is on, and turning it off the way the owner would.
//
// What Claude Code 2.1.283 does (read from its code and checked with a throwaway session):
// - Every interactive session keeps `<config dir>/sessions/<pid>.json` (the default config dir is
//   `~/.claude`, an account's is its `CLAUDE_CONFIG_DIR`; `sessions` isn't shared between them).
//   While Remote Control is connected it carries `"bridgeSessionId": "session_…"`; disconnecting
//   writes `null` (older code may drop the key, and an empty string never counts either).
// - Typed while connected, `/remote-control` opens a small dialog titled "Remote Control" with
//   three rows: "Disconnect this session", "Show QR code" ("Hide QR code" while shown) and
//   "Continue", focus on "Continue" (the last row), "Enter to select · Esc to continue" below.
//   Two Up arrows and Enter pick "Disconnect this session"; "Remote Control disconnected." follows.
//   Typed while NOT connected, the same command starts Remote Control, so it is only typed into a
//   session whose registry entry says it is on, and the keys after it only go in once the dialog
//   is on screen.
// - A disconnect appends `{"type":"bridge-session","bridgeSessionId":""}` to the transcript.
//   `claude --resume <id>` turns Remote Control back on by itself whenever the transcript's last
//   such record has a non-empty id, whatever `remoteControlAtStartup` says (that setting only
//   covers fresh sessions). So a session that had it on once comes back with it on every time
//   ClaudeDeck resumes it, until it is disconnected; after that, resumes stay off.
// - There is no flag or environment variable to start a session with it off. The setting
//   `disableRemoteControl` (meant for managed settings) blocks it altogether, including turning it
//   on by hand; ClaudeDeck doesn't use it.

public enum RemoteControl {
    // MARK: The session registry

    /// One `<pid>.json` of Claude Code's session registry.
    public struct RegistryEntry: Equatable, Sendable {
        public var pid: Int32
        /// The Claude session id (the transcript's name).
        public var sessionID: String
        /// Set while Remote Control is connected.
        public var bridgeSessionID: String?
        /// Milliseconds since 1970, when known.
        public var updatedAt: Double

        public init(pid: Int32, sessionID: String, bridgeSessionID: String?, updatedAt: Double = 0) {
            self.pid = pid
            self.sessionID = sessionID
            self.bridgeSessionID = bridgeSessionID
            self.updatedAt = updatedAt
        }

        public var isOn: Bool { bridgeSessionID != nil }
    }

    /// Parses one registry file; nil when it isn't one (no pid or session id). A missing, `null`
    /// or empty `bridgeSessionId` is off.
    public static func parseEntry(_ data: Data) -> RegistryEntry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        let bridge = (object["bridgeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updated = (object["updatedAt"] as? NSNumber)?.doubleValue ?? (object["startedAt"] as? NSNumber)?.doubleValue ?? 0
        return RegistryEntry(pid: pid, sessionID: sessionID, bridgeSessionID: bridge, updatedAt: updated)
    }

    /// One entry per Claude session id. A process that ended can leave its file behind, and a
    /// session id can show up twice (a resume while the old file lingers): a live process wins,
    /// then the newest `updatedAt`.
    public static func bySession(_ entries: [RegistryEntry], isAlive: (Int32) -> Bool) -> [String: RegistryEntry] {
        var out: [String: (entry: RegistryEntry, alive: Bool)] = [:]
        for entry in entries {
            let alive = isAlive(entry.pid)
            if let current = out[entry.sessionID] {
                if current.alive && !alive { continue }
                if current.alive == alive && current.entry.updatedAt >= entry.updatedAt { continue }
            }
            out[entry.sessionID] = (entry, alive)
        }
        return out.compactMapValues { $0.alive ? $0.entry : nil }
    }

    /// The registry folders to read: the default config dir's and each account's `sessions`.
    public static func registryFolders(defaultConfigDir: URL, accountConfigDirs: [String]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for dir in [defaultConfigDir] + accountConfigDirs.map({ URL(fileURLWithPath: $0) }) {
            let folder = dir.appending(path: "sessions").standardizedFileURL
            if seen.insert(folder.path).inserted { out.append(folder) }
        }
        return out
    }

    /// Reads every registry file in `folders` (unreadable ones are skipped), one entry per session
    /// id with a live process.
    public static func readRegistry(_ folders: [URL], isAlive: (Int32) -> Bool = processIsAlive) -> [String: RegistryEntry] {
        let fm = FileManager.default
        var entries: [RegistryEntry] = []
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
                if let data = try? Data(contentsOf: url), let entry = parseEntry(data) { entries.append(entry) }
            }
        }
        return bySession(entries, isAlive: isAlive)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// ClaudeDeck sessions (by id) whose Claude session has Remote Control on. `claudeIDs`: the
    /// running Claude sessions and their current Claude session id.
    public static func sessionsOn<ID: Hashable>(claudeIDs: [ID: String], registry: [String: RegistryEntry]) -> Set<ID> {
        Set(claudeIDs.compactMap { id, sid in registry[sid]?.isOn == true ? id : nil })
    }

    // MARK: Turning it off

    /// What is typed first (then Enter), only into a session that has it on.
    public static let command = "/remote-control"
    /// Up, Up, Enter: from "Continue" (where the dialog opens) to "Disconnect this session".
    /// `applicationCursor`: the terminal is in application cursor mode (Up is `ESC O A` there).
    public static func disconnectKeys(applicationCursor: Bool) -> [String] {
        let up = applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        return [up, up, "\r"]
    }
    public static let escape = "\u{1B}"

    /// The dialog's rows as Claude Code draws them.
    public static let disconnectRow = "Disconnect this session"
    static let qrRows = ["Show QR code", "Hide QR code"]
    static let continueRow = "Continue"
    static let footer = "Enter to select"
    /// Shown once it disconnected.
    public static let disconnectedText = "Remote Control disconnected"

    /// Whether the visible screen (top to bottom) ends with the Remote Control dialog: its three
    /// rows in order, then its footer, all within the last `window` lines. Text in the
    /// conversation that merely mentions "Disconnect this session" doesn't count.
    public static func showsDisconnectDialog(_ lines: [String], window: Int = 24) -> Bool {
        let tail = Array(lines.suffix(window))
        func index(after start: Int, where match: (String) -> Bool) -> Int? {
            guard start < tail.count else { return nil }
            return tail[start...].firstIndex(where: match)
        }
        // The last disconnect row, so an older one higher up doesn't anchor the search.
        guard let row = tail.lastIndex(where: { isRow($0, disconnectRow) }),
              let qr = index(after: row + 1, where: { line in qrRows.contains { isRow(line, $0) } }),
              let cont = index(after: qr + 1, where: { isRow($0, continueRow) }),
              index(after: cont + 1, where: { $0.contains(footer) }) != nil else { return false }
        return true
    }

    /// A dialog row: the label at the start of its line (maybe after the "❯" pointer), alone or
    /// followed by its hint after a gap ("Show QR code  Scan with your phone…").
    static func isRow(_ line: String, _ label: String) -> Bool {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("❯") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return text == label || text.hasPrefix(label + "  ")
    }

    /// What an off request does with a session right now.
    public enum OffStep: Equatable, Sendable {
        /// Type the command now.
        case now
        /// Its turn isn't over (or it waits on the owner): try again in a moment.
        case wait
        /// Nothing to do, or nothing that can be done (logged).
        case skip(SkipReason)
    }

    public enum SkipReason: String, Equatable, Sendable {
        case alreadyOff = "already off"
        case notRunning = "not running"
        case readOnly = "watched read-only"
        case notClaude = "not a Claude session"
    }

    /// `on`: the registry says Remote Control is on; `typingPending`: something else is about to be
    /// typed into it (the compact and continue message after a resume, a queued message);
    /// `switching`: it's moving to another account.
    public static func offStep(isClaude: Bool, running: Bool, readOnly: Bool, on: Bool, switching: Bool,
                               typingPending: Bool, progress: SessionCLI.Progress) -> OffStep {
        guard isClaude else { return .skip(.notClaude) }
        guard running else { return .skip(.notRunning) }
        guard !readOnly else { return .skip(.readOnly) }
        guard on else { return .skip(.alreadyOff) }
        if switching || typingPending { return .wait }
        switch progress {
        case .finished: return .now
        case .running, .blocked, .failed, .limited, .stopped: return .wait
        }
    }

    /// A deferred off (its turn wasn't over) is given up after this long (logged).
    public static let waitLimit: TimeInterval = 30 * 60
    /// After the keys, how long the registry gets to say it's off.
    public static let verifyLimit: TimeInterval = 10
    /// How long the dialog gets to show up after the command.
    public static let dialogLimit: TimeInterval = 3
    /// After ClaudeDeck resumes a session with "Keep Remote Control off" on: how long the bridge
    /// gets to come up before the session counts as having it off.
    public static let resumeWatch: TimeInterval = 90

    /// Settings › Sessions › "Keep Remote Control off": a session ClaudeDeck resumed whose Remote
    /// Control came back on by itself within `resumeWatch` is turned off once.
    public static func autoOffDue(launchedAt: Date?, on: Bool, now: Date = Date()) -> Bool {
        guard on, let launchedAt else { return false }
        return now.timeIntervalSince(launchedAt) <= resumeWatch
    }
}
