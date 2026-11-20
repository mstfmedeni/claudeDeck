import Foundation

// Stall detection for Claude sessions another session started (`claudedeck new`): a session that
// is "working" but makes no progress (no hook event, nothing appended to its transcript) for N
// minutes, or that hits the same error again and again, gets the action the user picked in
// Settings › Agents (off by default): a notification, a nudge typed into it, or a restart.
// Every action is logged, and nudges and restarts are capped per session and hour.

/// What to do about a stalled session.
public enum StallAction: String, Codable, Sendable, CaseIterable {
    /// A notification only.
    case notify
    /// Types the nudge message into the session (and notifies).
    case nudge
    /// Restarts the session into the same conversation, then types the nudge (and notifies).
    case restart
}

/// Settings › Agents › Command-line tool › stall watch.
public struct StallSettings: Codable, Sendable, Equatable {
    public var enabled = false
    /// No progress for this many minutes while working counts as a stall.
    public var minutes = 15
    public var action: StallAction = .notify
    /// What a nudge types; empty: the localized default ("Devam et" in Turkish).
    public var nudgeMessage = ""
    /// This many identical errors in a row count as a stall too (0: off).
    public var errorRepeats = 3
    /// Also leave a note beside the session that started the stalled one.
    public var tellParent = true

    public static let minuteRange = 3...240

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StallSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        minutes = min(max(try c.decodeIfPresent(Int.self, forKey: .minutes) ?? d.minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        action = (try? c.decodeIfPresent(StallAction.self, forKey: .action)) ?? d.action
        nudgeMessage = try c.decodeIfPresent(String.self, forKey: .nudgeMessage) ?? d.nudgeMessage
        errorRepeats = try c.decodeIfPresent(Int.self, forKey: .errorRepeats) ?? d.errorRepeats
        tellParent = try c.decodeIfPresent(Bool.self, forKey: .tellParent) ?? d.tellParent
    }
}

/// Why a session counts as stalled.
public enum StallReason: Equatable, Sendable {
    /// Working, but nothing happened since `since`.
    case noProgress(since: Date)
    /// The same error `count` times in a row.
    case errorLoop(count: Int, error: String)

    public var code: String {
        switch self {
        case .noProgress: "no_progress"
        case .errorLoop: "error_loop"
        }
    }

    public var summary: String {
        switch self {
        case .noProgress(let since): "no progress since \(Self.clock(since))"
        case .errorLoop(let count, let error): "the same error \(count) times in a row: \(error.prefix(120))"
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// What the watch knows about one session.
public struct StallTracker: Sendable, Equatable {
    /// The last sign of progress (a hook event, a transcript append, the start, or the last action).
    public var lastProgress: Date
    /// Identical consecutive errors: the error's signature and how many in a row.
    public var errorSignature: String?
    public var errorText: String?
    public var errorCount = 0
    /// The last stall acted on, and what was done.
    public var lastStall: String?
    public var lastAction: String?
    public var lastActionAt: Date?
    /// Nudges and restarts in the last hour.
    public var interventions: [Date] = []

    public init(lastProgress: Date) { self.lastProgress = lastProgress }

    public mutating func progress(at date: Date) {
        if date > lastProgress { lastProgress = date }
    }

    /// Errors and successes of tool calls in order (nil: a success, which ends a run of errors).
    public mutating func results(_ signatures: [String?], texts: [String?] = []) {
        for (index, signature) in signatures.enumerated() {
            guard let signature else {
                errorSignature = nil
                errorText = nil
                errorCount = 0
                continue
            }
            if signature == errorSignature {
                errorCount += 1
            } else {
                errorSignature = signature
                errorText = index < texts.count ? texts[index] : nil
                errorCount = 1
            }
        }
    }
}

public enum StallWatch {
    /// At most this many nudges and restarts per session per hour.
    public static let maxInterventionsPerHour = 3
    /// How often the app looks.
    public static let checkInterval: TimeInterval = 30

    /// A stall, or nil. Only working sessions another session started count; a no-progress stall
    /// needs `minutes` without a sign of progress, an error loop `errorRepeats` identical errors.
    public static func check(_ tracker: StallTracker, working: Bool, startedBySession: Bool, settings: StallSettings,
                             now: Date = Date()) -> StallReason? {
        guard settings.enabled, startedBySession else { return nil }
        if settings.errorRepeats > 1, tracker.errorCount >= settings.errorRepeats {
            return .errorLoop(count: tracker.errorCount, error: tracker.errorText ?? tracker.errorSignature ?? "")
        }
        guard working else { return nil }
        if now.timeIntervalSince(tracker.lastProgress) >= TimeInterval(settings.minutes * 60) {
            return .noProgress(since: tracker.lastProgress)
        }
        return nil
    }

    /// What is done this time: the chosen action, or a notification once the hour's cap is used.
    public static func action(for settings: StallSettings, tracker: StallTracker, now: Date = Date()) -> (action: StallAction, capped: Bool) {
        guard settings.action != .notify else { return (.notify, false) }
        let recent = tracker.interventions.filter { now.timeIntervalSince($0) < 3600 }
        return recent.count < maxInterventionsPerHour ? (settings.action, false) : (.notify, true)
    }

    /// After acting: the watch starts over from now (another N minutes before the next action).
    public static func acted(_ tracker: inout StallTracker, action: StallAction, reason: StallReason, now: Date = Date()) {
        tracker.lastProgress = now
        tracker.errorCount = 0
        tracker.errorSignature = nil
        tracker.lastStall = reason.code
        tracker.lastAction = action.rawValue
        tracker.lastActionAt = now
        tracker.interventions = tracker.interventions.filter { now.timeIntervalSince($0) < 3600 }
        if action != .notify { tracker.interventions.append(now) }
    }

    // MARK: Errors in the transcript

    /// The tool results in a chunk of transcript lines, in order: an error's signature (its text,
    /// trimmed, digits and hex ids folded so "line 12" and "line 13" or two temp paths match) and
    /// text, or nil for a success. API errors Claude Code records count as errors too.
    public static func results(in chunk: String) -> [(signature: String?, text: String?)] {
        var out: [(String?, String?)] = []
        for line in chunk.split(separator: "\n") {
            let isAPIError = line.contains(#""isApiErrorMessage":true"#)
            guard line.contains(#""tool_result""#) || isAPIError, !line.contains(#""isSidechain":true"#) else { continue }
            // Runs on the main actor as the transcript grows: only error lines are decoded (tool
            // outputs can be large); a success only ends a run of errors.
            if !isAPIError, !line.contains(#""is_error":true"#) {
                out.append((nil, nil))
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            if isAPIError, object["type"] as? String == "assistant" {
                let text = Transcript.messageText(object) ?? "API error"
                out.append((signature(text), String(text.prefix(300))))
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                if block["is_error"] as? Bool == true {
                    let text = resultText(block["content"])
                    out.append((signature(text), String(text.prefix(300))))
                } else {
                    out.append((nil, nil))
                }
            }
        }
        return out
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }

    static func signature(_ text: String) -> String {
        var out = ""
        var lastWasDigit = false
        for ch in text.prefix(2000) {
            if ch.isNumber || ch.isHexDigit && lastWasDigit {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                out.append(ch)
                lastWasDigit = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `GET /v1/cli/sessions/{ref}/status`.
public struct SessionCLIStatus: Encodable, Sendable, Equatable {
    public struct Stall: Encodable, Sendable, Equatable {
        public var watching: Bool
        /// `no_progress` or `error_loop` while stalled now; nil otherwise.
        public var stalled: String?
        public var lastProgressAt: Date?
        public var minutesWithoutProgress: Int?
        public var repeatedErrors: Int
        public var lastAction: String?
        public var lastActionAt: Date?
        public var interventionsLastHour: Int

        public init(watching: Bool, stalled: String?, lastProgressAt: Date?, minutesWithoutProgress: Int?, repeatedErrors: Int,
                    lastAction: String?, lastActionAt: Date?, interventionsLastHour: Int) {
            self.watching = watching
            self.stalled = stalled
            self.lastProgressAt = lastProgressAt
            self.minutesWithoutProgress = minutesWithoutProgress
            self.repeatedErrors = repeatedErrors
            self.lastAction = lastAction
            self.lastActionAt = lastActionAt
            self.interventionsLastHour = interventionsLastHour
        }
    }

    public var id: UUID
    public var name: String
    public var kind: String
    public var state: String
    public var detail: String?
    public var project: String
    public var startedBy: UUID?
    public var stall: Stall?
    public var simulators: [String]
    /// The build slots it holds (`claudedeck slot` / `heavy`).
    public var slots: [String]

    public init(id: UUID, name: String, kind: String, state: String, detail: String?, project: String, startedBy: UUID?,
                stall: Stall?, simulators: [String], slots: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.detail = detail
        self.project = project
        self.startedBy = startedBy
        self.stall = stall
        self.simulators = simulators
        self.slots = slots
    }

    public var text: String {
        var lines = ["\(name) (\(kind), \(project)): \(state)" + (detail.map { " — \($0)" } ?? "")]
        if let startedBy { lines.append("started by: \(startedBy.uuidString.prefix(8))") }
        if let stall {
            if !stall.watching {
                lines.append("stall watch: off")
            } else {
                var line = "stall watch: " + (stall.stalled.map { "stalled (\($0))" } ?? "ok")
                if let minutes = stall.minutesWithoutProgress { line += ", \(minutes) min without progress" }
                if stall.repeatedErrors > 1 { line += ", \(stall.repeatedErrors) identical errors in a row" }
                lines.append(line)
                if let action = stall.lastAction, let at = stall.lastActionAt {
                    lines.append("last action: \(action) at \(StallReason.clock(at)) (\(stall.interventionsLastHour) nudges/restarts in the last hour)")
                }
            }
        }
        if !simulators.isEmpty { lines.append("simulators: " + simulators.joined(separator: ", ")) }
        if !slots.isEmpty { lines.append("build slots: " + slots.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
