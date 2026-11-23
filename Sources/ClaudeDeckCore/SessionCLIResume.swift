import Foundation

/// Who ended a Claude session's process last: a session's `claudedeck close` (`agent`), or the
/// owner (End Session, `/exit` typed in the pane, the process ending by itself). Cleared on every
/// start. Only `agent` stops are resumed automatically when a message or an answer arrives.
public enum SessionStopper: String, Codable, Sendable, Equatable {
    case agent
    case owner
}

/// What's left of a Claude session a session removed from the deck (`close --remove`, `remove`,
/// or `close` with "Closed sessions are removed from the list"): enough to put it back and
/// `claude --resume` its conversation with the same ClaudeDeck id (`claudedeck resume`). Kept in
/// deck.json for `SessionCLI.tombstoneKeep` (30 days).
public struct SessionTombstone: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var claudeSessionID: String
    public var transcriptPath: String?
    public var workingDirectory: String?
    public var worktreeName: String?
    public var startedBy: UUID?
    public var launchOptions: ClaudeLaunchOptions?
    public var account: String?
    public var accountPinned: Bool
    public var stoppedBy: SessionStopper?
    public var removedAt: Date

    /// Only a Claude session with a known conversation leaves one.
    public init?(_ session: DeckSession, removedAt: Date = Date()) {
        guard session.kind == .claude, let sid = session.claudeSessionID, !sid.isEmpty else { return nil }
        id = session.id
        projectID = session.projectID
        name = session.name
        claudeSessionID = sid
        transcriptPath = session.transcriptPath
        workingDirectory = session.workingDirectory
        worktreeName = session.worktreeName
        startedBy = session.startedBy
        launchOptions = session.launchOptions
        account = session.account
        accountPinned = session.accountPinned
        stoppedBy = session.stoppedBy
        self.removedAt = removedAt
    }

    /// The deck entry it came from (not running, no pane).
    public func restored() -> DeckSession {
        var session = DeckSession(id: id, projectID: projectID, name: name, kind: .claude, claudeSessionID: claudeSessionID,
                                  isOpen: false, worktreeName: worktreeName)
        session.transcriptPath = transcriptPath
        session.workingDirectory = workingDirectory
        session.startedBy = startedBy
        session.launchOptions = launchOptions
        session.account = account
        session.accountPinned = accountPinned
        session.stoppedBy = stoppedBy
        return session
    }
}

extension DeckData {
    /// Before a session removes `id` from the deck: its tombstone (Claude sessions with a
    /// conversation only), replacing an older one, and the old ones pruned.
    public mutating func addTombstone(for id: UUID, at now: Date = Date()) {
        guard let session = session(id), let tombstone = SessionTombstone(session, removedAt: now) else { return }
        removedSessions.removeAll { $0.id == id }
        removedSessions.append(tombstone)
        removedSessions = SessionCLI.pruneTombstones(removedSessions, now: now)
    }

    public func tombstone(_ id: UUID) -> SessionTombstone? {
        removedSessions.first { $0.id == id }
    }

    /// Whether a removed session can come back with its conversation: its project is still in
    /// the deck and `claude --resume` would find its transcript (`resumableID`).
    public func tombstoneResumable(_ id: UUID, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let tombstone = tombstone(id), project(tombstone.projectID) != nil, session(id) == nil else { return false }
        var probe = self
        probe.sessions = [tombstone.restored()]
        return probe.resumableID(for: id, fileExists: fileExists) != nil
    }

    /// Puts a removed session back in the deck (stopped, no pane); nil when its project is gone.
    @discardableResult
    public mutating func restoreTombstone(_ id: UUID) -> DeckSession? {
        guard let tombstone = tombstone(id), project(tombstone.projectID) != nil, session(id) == nil else { return nil }
        removedSessions.removeAll { $0.id == id }
        let session = tombstone.restored()
        sessions.append(session)
        return session
    }
}

extension SessionCLI {
    /// How long a removed session stays restorable.
    public static let tombstoneKeep: TimeInterval = 30 * 24 * 3600
    /// The most kept (the newest win).
    public static let maxTombstones = 200

    /// Older than `tombstoneKeep` go; at most `maxTombstones`, the newest.
    public static func pruneTombstones(_ list: [SessionTombstone], now: Date = Date()) -> [SessionTombstone] {
        let kept = list.filter { now.timeIntervalSince($0.removedAt) < tombstoneKeep }
        guard kept.count > maxTombstones else { return kept }
        return Array(kept.sorted { $0.removedAt < $1.removedAt }.suffix(maxTombstones))
    }

    // MARK: Resuming

    public enum ResumeCheck: Equatable, Sendable {
        case allowed
        /// "Sessions may add projects and start Claude sessions" is off (`403 setting_off`).
        case settingOff
        /// The owner's session, or one another session started (`403 not_yours`).
        case notYours
        /// A plain terminal (`400 not_claude`; `restart` is for those).
        case notClaude
        /// Its process runs (`409 running`); the caller itself always does.
        case running
        /// No conversation `claude --resume` could find (`409 not_resumable`).
        case notResumable

        public var response: AgentHTTPResponse? {
            switch self {
            case .allowed: nil
            case .settingOff: failure(403, "setting_off", exit: .refused)
            case .notYours: failure(403, "not_yours", exit: .refused)
            case .notClaude: failure(400, "not_claude", exit: .usage)
            case .running: failure(409, "running", exit: .failed)
            case .notResumable: failure(409, "not_resumable", exit: .failed)
            }
        }
    }

    /// `resume`: the sessions `close` may end (`mayClose`: the ones it started, directly or
    /// through sessions it started), Claude sessions only, once stopped, with a conversation to
    /// resume. Itself is running by definition.
    public static func mayResume(caller: UUID, target: UUID, targetKind: SessionKind, running: Bool, resumable: Bool,
                                 startedBy: [UUID: UUID], openedBy: [UUID: UUID] = [:], settingOn: Bool) -> ResumeCheck {
        guard settingOn else { return .settingOff }
        guard target != caller else { return .running }
        guard mayClose(caller: caller, target: target, startedBy: startedBy, openedBy: openedBy) else { return .notYours }
        guard targetKind == .claude else { return .notClaude }
        guard !running else { return .running }
        return resumable ? .allowed : .notResumable
    }

    /// Whether a start (`new`, `resume`) goes now, waits in the start queue, or is refused.
    public enum Admission: Equatable, Sendable {
        case now
        /// Queued; the reason is what it waits for (`overloaded`, `busy`, `too_many_running`, `too_many_starts`).
        case queue(String)
        /// `429` with this code.
        case refuse(String)
    }

    /// The Mac's load first (`LoadThrottle.start`, `heldBy` names it), then the running cap and
    /// the caller's rate limit (`admitStart`'s refusal code, nil when it allowed it). `queue`:
    /// `--queue`, and always for automatic resumes.
    public static func admission(load: LoadThrottle.Start, heldBy: String, startRefusal: String?, queue: Bool) -> Admission {
        switch load {
        case .refuse: return .refuse(heldBy)
        case .queue: return .queue(heldBy)
        case .allow:
            guard let code = startRefusal else { return .now }
            return queue ? .queue(code) : .refuse(code)
        }
    }

    // MARK: Automatic resume

    public enum AutoResumeCheck: String, Equatable, Sendable {
        case resume
        /// Settings › Agents › the automatic resume is off.
        case off
        case notClaude = "not_claude"
        case running
        /// The owner stopped it (or it ended by itself): it stays stopped.
        case notAgentClosed = "not_agent_closed"
        /// Removed and no longer restorable, or no conversation to resume.
        case notResumable = "not_resumable"
    }

    /// A message (`send`) or the owner's answer (`decide`) for a stopped session: it's resumed
    /// only with the setting on, when it's a Claude session a session closed (never one the
    /// owner stopped), and its conversation can be resumed.
    public static func autoResume(enabled: Bool, kind: SessionKind, running: Bool, stoppedBy: SessionStopper?,
                                  resumable: Bool) -> AutoResumeCheck {
        guard enabled else { return .off }
        guard kind == .claude else { return .notClaude }
        guard !running else { return .running }
        guard stoppedBy == .agent else { return .notAgentClosed }
        return resumable ? .resume : .notResumable
    }

    /// Whether `send`'s caller may have its message resume `target`: the same chain as `resume`
    /// and its setting, and a token with the `start` scope (never a terminal a session opened).
    public static func sendMayResume(caller: UUID, callerOpenedBy: UUID?, target: UUID, startedBy: [UUID: UUID],
                                     openedBy: [UUID: UUID] = [:], startSetting: Bool) -> Bool {
        guard startSetting, scopes(openedBy: callerOpenedBy).contains(.start), target != caller else { return false }
        return mayClose(caller: caller, target: target, startedBy: startedBy, openedBy: openedBy)
    }

    /// Text for `resume`'s answer.
    public static func resumedText(restored: Bool) -> String {
        restored ? "resumed (restored to the list)" : "resumed"
    }
}

/// `claudedeck resume`: `{"resumed":true,"id":…,"name":…,"restored":false}`.
public struct SessionCLIResumed: Encodable, Sendable, Equatable {
    public var resumed = true
    public var id: UUID
    public var name: String
    /// It had been removed from the list and was put back.
    public var restored: Bool

    public init(id: UUID, name: String, restored: Bool) {
        self.id = id
        self.name = name
        self.restored = restored
    }
}
