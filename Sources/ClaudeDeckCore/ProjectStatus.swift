import Foundation

/// A short status line next to a project's name in the sidebar ("1.0 in review", "Live · Nov 22",
/// "Design", "Stopped"), with an optional summary for the tooltip. Sessions set it with
/// `claudedeck project status set` (their own project only, unless their project is a status
/// coordinator: `Project.coordinator`); the owner clears it from the project's menu.
/// Stored on the project in deck.json (optional, so older files decode). Contract: docs/agents.md.
public struct ProjectStatus: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable, CaseIterable {
        /// Done, live, approved: green.
        case ok
        /// Waiting on someone (review, the owner, a build): orange.
        case wait
        /// Something is wrong or stopped: red.
        case warn
    }

    public var text: String
    public var summary: String?
    /// nil: no tone, shown in the secondary color.
    public var tone: Tone?
    public var updatedAt: Date
    /// The session that wrote it (its name when it was written).
    public var updatedBy: String?

    public init(text: String, summary: String? = nil, tone: Tone? = nil, updatedAt: Date = Date(), updatedBy: String? = nil) {
        self.text = text
        self.summary = summary
        self.tone = tone
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    private enum CodingKeys: String, CodingKey { case text, summary, tone, updatedAt, updatedBy }

    /// Never throws on what a newer version might write (an unknown tone is no tone), so a
    /// status can't make deck.json unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        tone = (try? c.decodeIfPresent(String.self, forKey: .tone)).flatMap { $0.flatMap(Tone.init(rawValue:)) }
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
        updatedBy = try? c.decodeIfPresent(String.self, forKey: .updatedBy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(tone, forKey: .tone)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
    }

    // MARK: Limits

    /// The sidebar shows this many characters; longer text ends in "…".
    public static let displayLimit = 24
    /// Longer text is refused (`text_too_long`).
    public static let maxText = 80
    /// Longer summaries are refused (`summary_too_long`).
    public static let maxSummary = 600
    /// Older than this, the status is dimmed.
    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// What the sidebar shows: at most `limit` characters, the last one "…" when cut.
    public static func displayText(_ text: String, limit: Int = displayLimit) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public var displayText: String { Self.displayText(text) }

    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > Self.staleAfter }

    // MARK: Writing

    public enum Refusal: String, Error, Sendable, Equatable {
        case emptyText = "empty_text"
        case textTooLong = "text_too_long"
        case summaryTooLong = "summary_too_long"
        case badTone = "bad_tone"
    }

    /// The status a `set` writes: the text on one line (runs of white space become one space),
    /// the summary trimmed (empty: none), the tone one of `Tone` (empty: none).
    public static func make(text: String, summary: String?, tone: String?, by session: String?,
                            now: Date = Date()) -> Result<ProjectStatus, Refusal> {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !line.isEmpty else { return .failure(.emptyText) }
        guard line.count <= maxText else { return .failure(.textTooLong) }
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, summary.count > maxSummary { return .failure(.summaryTooLong) }
        var parsedTone: Tone?
        if let tone = tone?.trimmingCharacters(in: .whitespaces).lowercased(), !tone.isEmpty {
            guard let known = Tone(rawValue: tone) else { return .failure(.badTone) }
            parsedTone = known
        }
        return .success(ProjectStatus(text: line, summary: summary?.isEmpty == false ? summary : nil, tone: parsedTone,
                                      updatedAt: now, updatedBy: session))
    }

    /// Who may write a project's status: a session in that project, or one whose project is a
    /// status coordinator (the owner's per-project switch). The owner's own terminals count as
    /// sessions of their project too.
    public static func mayWrite(callerProject: UUID?, target: UUID, callerIsCoordinator: Bool) -> Bool {
        callerIsCoordinator || callerProject == target
    }
}
