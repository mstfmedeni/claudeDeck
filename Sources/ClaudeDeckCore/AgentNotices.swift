import Foundation

// Where ClaudeDeck's own news about agent sessions goes. Notes beside a session are read by the
// owner only (Claude never sees them), so news meant for an agent goes into its message queue
// instead (typed only when it is idle, between turns, never interrupting), and news nobody needs
// to act on goes to the Activity Log alone. Owner notes are kept for what needs the owner.

public enum AgentNotice: Equatable, Sendable {
    /// A session closed or removed one another session started (`claudedeck close` / `remove`).
    case childClosed
    /// The stall watch acted on a session another session started.
    case childStalled
    /// The Mac became overloaded (once per episode), for an agent-started session.
    case overloaded
}

public enum AgentNoticeRoute: Equatable, Sendable {
    /// The Activity Log only.
    case logOnly
    /// The log, and a message queued for the session (sent once it is idle).
    case queue
}

public enum AgentNoticeRouting {
    /// `recipientIsLiveClaude`: the session the news is for is a Claude session that runs.
    /// `enabled`: the setting for this kind of news (close: "tell the starter", off by default;
    /// stall: the stall watch's "tell the session that started it"; overload: always).
    /// `alreadyQueued`: the same text is waiting in its queue (a Mac swinging in and out of
    /// overload doesn't stack copies).
    public static func route(_ notice: AgentNotice, recipientIsLiveClaude: Bool, enabled: Bool, alreadyQueued: Bool = false) -> AgentNoticeRoute {
        guard recipientIsLiveClaude, !alreadyQueued else { return .logOnly }
        switch notice {
        case .childClosed, .childStalled: return enabled ? .queue : .logOnly
        case .overloaded: return .queue
        }
    }

    /// The overload message, in Turkish whatever the UI language (agents read it, the owner
    /// works in Turkish).
    public static let overloadMessage = "[ClaudeDeck] Mac aşırı yüklü: ağır işleri (derleme, simülatör) ertele, bitmiş simülatörleri bırak."

    /// Which sessions get the overload message: running agent-started Claude sessions.
    public static func overloadRecipients(_ sessions: [(id: UUID, isClaude: Bool, startedBy: UUID?, running: Bool)]) -> [UUID] {
        sessions.filter { $0.isClaude && $0.startedBy != nil && $0.running }.map(\.id)
    }
}
