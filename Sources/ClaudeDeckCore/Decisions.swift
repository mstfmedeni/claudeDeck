import Foundation

// Owner decisions: a session asks the owner to choose (`claudedeck decide`) and goes on working;
// the owner answers later on the Mac or the phone, and the answer reaches the session as a
// message (the prompt queue: typed at its next "your turn"). Contract: docs/agents.md.

/// One question for the owner.
public struct OwnerDecision: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, answered
    }

    /// `d_` and 10 lowercase hex digits.
    public var id: String
    public var question: String
    /// The choices offered (may be empty: free text only).
    public var options: [String]
    /// The asking agent's recommendation: one of `options`.
    public var recommended: String?
    /// Why it's asking, what it knows.
    public var context: String?
    /// The project it's about (names kept: the decision outlives the session and the project).
    public var projectID: UUID?
    public var project: String
    public var sessionID: UUID?
    public var session: String
    public var createdAt: Date
    public var status: Status
    public var answer: String?
    public var answeredAt: Date?
    /// Where it was answered: `mac` or `phone`.
    public var answeredFrom: String?
    /// What happened to the answer: `queued` (in the session's queue, typed at its turn),
    /// `no_session` (the session is gone, or isn't a Claude session): only stored.
    public var delivery: String?

    public init(id: String, question: String, options: [String], recommended: String?, context: String?,
                projectID: UUID?, project: String, sessionID: UUID?, session: String, createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.options = options
        self.recommended = recommended
        self.context = context
        self.projectID = projectID
        self.project = project
        self.sessionID = sessionID
        self.session = session
        self.createdAt = createdAt
        status = .pending
    }

    public var isPending: Bool { status == .pending }

    private enum CodingKeys: String, CodingKey {
        case id, question, options, recommended, context, projectID = "projectId", project, sessionID = "sessionId", session
        case createdAt, status, answer, answeredAt, answeredFrom, delivery
    }

    /// Every key is always there (null when unknown), as the command's other JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(question, forKey: .question)
        try c.encode(options, forKey: .options)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(context, forKey: .context)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(project, forKey: .project)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(session, forKey: .session)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(status, forKey: .status)
        try c.encode(answer, forKey: .answer)
        try c.encode(answeredAt, forKey: .answeredAt)
        try c.encode(answeredFrom, forKey: .answeredFrom)
        try c.encode(delivery, forKey: .delivery)
    }

    /// Tolerant: a later version's status reads as pending, missing keys as empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
        recommended = try? c.decodeIfPresent(String.self, forKey: .recommended)
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? ""
        sessionID = try? c.decodeIfPresent(UUID.self, forKey: .sessionID)
        session = (try? c.decodeIfPresent(String.self, forKey: .session)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .pending
        answer = try? c.decodeIfPresent(String.self, forKey: .answer)
        answeredAt = try? c.decodeIfPresent(Date.self, forKey: .answeredAt)
        answeredFrom = try? c.decodeIfPresent(String.self, forKey: .answeredFrom)
        delivery = try? c.decodeIfPresent(String.self, forKey: .delivery)
    }
}

/// The rules for asking and answering (lengths, options, the recommendation) and the message the
/// session gets.
public enum Decisions {
    public static let maxQuestion = 2_000
    public static let maxContext = 8_000
    public static let maxOptions = 10
    public static let maxOption = 200
    public static let maxAnswer = 4_000
    /// Waiting at once, all sessions together.
    public static let maxPending = 50
    /// Answered ones kept (the newest).
    public static let maxAnswered = 200

    /// `d_` and 10 random lowercase hex digits.
    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        return "d_" + String((0..<10).map { _ in digits[Int(generator.next() % 16)] })
    }

    /// An id as the command sends it: `d_` and letters or digits.
    public static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("d_") && id.count > 2 && id.count <= 40 && id.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `--options`: one per line when there are line breaks, else separated by commas. Blank and
    /// repeated ones (ignoring case) are dropped.
    public static func options(_ raw: String) -> [String] {
        let parts = raw.contains("\n") ? raw.components(separatedBy: "\n") : raw.components(separatedBy: ",")
        var out: [String] = []
        for part in parts {
            let option = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) else { continue }
            out.append(option)
        }
        return out
    }

    public struct Asked: Equatable, Sendable {
        public var question: String
        public var options: [String]
        public var recommended: String?
        public var context: String?
    }

    /// Checks a `decide` request. Refusal codes: `bad_request` (no question), `too_long`,
    /// `too_many_options`, `bad_recommend` (not one of the options, or no options to pick from).
    public static func validate(question: String, options raw: String, recommend: String, context: String) -> Result<Asked, DecisionRefusal> {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .failure(.init("bad_request")) }
        guard question.count <= maxQuestion else { return .failure(.init("too_long")) }
        let options = options(raw)
        guard options.count <= maxOptions else { return .failure(.init("too_many_options")) }
        guard options.allSatisfy({ $0.count <= maxOption }) else { return .failure(.init("too_long")) }
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count <= maxContext else { return .failure(.init("too_long")) }
        var recommended: String?
        let wanted = recommend.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty {
            // The option itself (any case), or its number (1 = the first).
            if let match = options.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
                recommended = match
            } else if let number = Int(wanted), options.indices.contains(number - 1) {
                recommended = options[number - 1]
            } else {
                return .failure(.init("bad_recommend"))
            }
        }
        return .success(Asked(question: question, options: options, recommended: recommended, context: context.isEmpty ? nil : context))
    }

    /// An answer as given: trimmed, not empty, at most `maxAnswer` characters.
    public static func cleanAnswer(_ answer: String) -> String? {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxAnswer else { return nil }
        return text
    }

    /// What the asking session gets: one line (it's typed into Claude Code and sent with Return).
    public static func message(for decision: OwnerDecision) -> String {
        func line(_ text: String, max: Int) -> String {
            let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return flat.count > max ? String(flat.prefix(max)) + "…" : flat
        }
        return "[ClaudeDeck decision \(decision.id)] The owner answered your question “\(line(decision.question, max: 300))”: "
            + line(decision.answer ?? "", max: maxAnswer)
    }

    /// `claudedeck decision get` as text: the status first ("pending", "answered: …").
    public static func text(_ decision: OwnerDecision) -> String {
        var lines = [decision.isPending ? "pending" : "answered: \(decision.answer ?? "")"]
        lines.append("id: \(decision.id)")
        lines.append("question: \(decision.question)")
        if !decision.options.isEmpty {
            lines.append("options: " + decision.options.map { $0 == decision.recommended ? "\($0) (recommended)" : $0 }.joined(separator: ", "))
        }
        if !decision.project.isEmpty { lines.append("project: \(decision.project)") }
        if let delivery = decision.delivery { lines.append("delivery: \(delivery)") }
        return lines.joined(separator: "\n")
    }

    /// `claudedeck decisions` as text: a table, newest first.
    public static func listText(_ decisions: [OwnerDecision]) -> String {
        let header = ["ID", "STATUS", "PROJECT", "QUESTION", "ANSWER"]
        func cut(_ text: String, _ max: Int) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
        }
        let rows = decisions.map { [$0.id, $0.status.rawValue, cut($0.project, 24), cut($0.question, 60), cut($0.answer ?? "", 40)] }
        let all = [header] + rows
        let widths = (0..<(header.count - 1)).map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

public struct DecisionRefusal: Error, Equatable, Sendable {
    public var code: String
    public init(_ code: String) { self.code = code }
}

/// Every decision, oldest first: all pending ones, and the newest `Decisions.maxAnswered`
/// answered ones. Kept in Application Support/decisions.json.
public struct DecisionBook: Codable, Sendable, Equatable {
    public private(set) var decisions: [OwnerDecision] = []

    public init(decisions: [OwnerDecision] = []) {
        self.decisions = decisions
    }

    public var pending: [OwnerDecision] { decisions.filter(\.isPending) }
    public var pendingCount: Int { decisions.reduce(0) { $0 + ($1.isPending ? 1 : 0) } }

    public func decision(_ id: String) -> OwnerDecision? {
        decisions.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Newest first (`claudedeck decisions`, the lists).
    public var newestFirst: [OwnerDecision] { decisions.reversed() }

    public mutating func add(_ decision: OwnerDecision) {
        decisions.append(decision)
        prune()
    }

    public enum Answered: Equatable, Sendable {
        case answered(OwnerDecision)
        /// Someone answered first (the Mac and the phone at once): the first answer stays.
        case alreadyAnswered(OwnerDecision)
        case unknown
    }

    public mutating func answer(_ id: String, with answer: String, from: String, at date: Date = Date()) -> Answered {
        guard let index = decisions.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return .unknown }
        guard decisions[index].isPending else { return .alreadyAnswered(decisions[index]) }
        decisions[index].status = .answered
        decisions[index].answer = answer
        decisions[index].answeredAt = date
        decisions[index].answeredFrom = from
        let answered = decisions[index]
        prune()
        return .answered(answered)
    }

    /// What became of the answer (after `answer`).
    public mutating func setDelivery(_ id: String, _ delivery: String) {
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return }
        decisions[index].delivery = delivery
    }

    /// Pending ones stay; of the answered ones, the newest `maxAnswered`.
    mutating func prune() {
        let answered = decisions.filter { !$0.isPending }
        guard answered.count > Decisions.maxAnswered else { return }
        let keep = Set(answered.sorted { ($0.answeredAt ?? $0.createdAt) > ($1.answeredAt ?? $1.createdAt) }
            .prefix(Decisions.maxAnswered).map(\.id))
        decisions.removeAll { !$0.isPending && !keep.contains($0.id) }
    }

    /// For a remote: every pending one and those answered in the last `recent` seconds (at most
    /// `maxAnswered` of them), newest first.
    public func forRemote(now: Date = Date(), recent: TimeInterval = 24 * 3600, maxAnswered: Int = 20) -> [OwnerDecision] {
        let pending = decisions.filter(\.isPending)
        let answered = decisions.filter { !$0.isPending && now.timeIntervalSince($0.answeredAt ?? $0.createdAt) < recent }
            .suffix(maxAnswered)
        return (pending + answered).sorted { $0.createdAt > $1.createdAt }.map(Self.trimmed)
    }

    /// Long contexts are cut for the wire (the Mac keeps the whole text).
    static func trimmed(_ decision: OwnerDecision) -> OwnerDecision {
        var copy = decision
        if let context = copy.context, context.count > 2_000 { copy.context = String(context.prefix(2_000)) + "…" }
        return copy
    }
}
