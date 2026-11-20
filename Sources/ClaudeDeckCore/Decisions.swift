import Foundation

// Owner decisions: a session asks the owner to choose (`claudedeck decide`) and goes on working;
// the owner answers later on the Mac or the phone, and the answer reaches the session as a
// message (the prompt queue: typed at its next "your turn"). Contract: docs/agents.md.

/// One question for the owner.
public struct OwnerDecision: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// `cancelled`: withdrawn by the asking session (or one that started it), superseded by
        /// a newer one, or dismissed by the owner without an answer. Never sent to remotes (an
        /// older phone reads an unknown status as pending): `DecisionBook.forRemote` leaves them out.
        case pending, answered, cancelled
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
    /// `terminal` (a plain terminal asked: nothing is typed there) or `no_session` (the session
    /// is gone): only stored.
    public var delivery: String?
    /// Why it was cancelled (`claudedeck decision cancel --reason`, "superseded by d_…",
    /// "owner dismissed") and when.
    public var cancelReason: String?
    public var cancelledAt: Date?
    /// The asking session's starters when it asked (its parent and up), so a parent may still
    /// cancel it after the asking session is gone.
    public var ancestors: [UUID]
    /// Earlier answers, oldest first, when the owner changed the answer afterwards (`answer` is
    /// the current one); `changedAt`: when it last changed.
    public var answerHistory: [PreviousAnswer]
    public var changedAt: Date?

    /// An answer the owner later replaced.
    public struct PreviousAnswer: Codable, Sendable, Equatable {
        public var answer: String
        public var answeredAt: Date?
        public var answeredFrom: String?

        public init(answer: String, answeredAt: Date?, answeredFrom: String?) {
            self.answer = answer
            self.answeredAt = answeredAt
            self.answeredFrom = answeredFrom
        }
    }

    public init(id: String, question: String, options: [String], recommended: String?, context: String?,
                projectID: UUID?, project: String, sessionID: UUID?, session: String, ancestors: [UUID] = [],
                createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.options = options
        self.recommended = recommended
        self.context = context
        self.projectID = projectID
        self.project = project
        self.sessionID = sessionID
        self.session = session
        self.ancestors = ancestors
        answerHistory = []
        self.createdAt = createdAt
        status = .pending
    }

    public var isPending: Bool { status == .pending }
    public var isAnswered: Bool { status == .answered }
    public var isCancelled: Bool { status == .cancelled }
    /// Answered, and the answer changed since.
    public var isChanged: Bool { isAnswered && !answerHistory.isEmpty }
    /// When it stopped waiting (answered or cancelled), else when it was asked.
    public var resolvedAt: Date { answeredAt ?? cancelledAt ?? createdAt }

    /// "project · session", or one of them when the session is named after its project.
    public var origin: String {
        if session.isEmpty || session == project { return project }
        if project.isEmpty { return session }
        return "\(project) · \(session)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, options, recommended, context, projectID = "projectId", project, sessionID = "sessionId", session
        case createdAt, status, answer, answeredAt, answeredFrom, delivery, cancelReason, cancelledAt, ancestors
        case answerHistory, changedAt
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
        try c.encode(cancelReason, forKey: .cancelReason)
        try c.encode(cancelledAt, forKey: .cancelledAt)
        try c.encode(ancestors, forKey: .ancestors)
        try c.encode(answerHistory, forKey: .answerHistory)
        try c.encode(changedAt, forKey: .changedAt)
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
        cancelReason = try? c.decodeIfPresent(String.self, forKey: .cancelReason)
        cancelledAt = try? c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        ancestors = (try? c.decodeIfPresent([UUID].self, forKey: .ancestors)) ?? []
        answerHistory = (try? c.decodeIfPresent([PreviousAnswer].self, forKey: .answerHistory)) ?? []
        changedAt = try? c.decodeIfPresent(Date.self, forKey: .changedAt)
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

    /// `decision cancel --reason`: at most this many characters (cut, not refused).
    public static let maxReason = 500
    /// The reason when the owner dismisses one without answering.
    public static let ownerDismissed = "owner dismissed"

    /// A cancel reason as stored: on one line, cut at `maxReason`; nil when blank.
    public static func cleanReason(_ reason: String) -> String? {
        let text = oneLine(reason, max: maxReason)
        return text.isEmpty ? nil : text
    }

    /// Who may cancel a decision (`decision cancel`, `decide --supersedes`): the session that asked,
    /// or one in its `startedBy` ancestry (its parent and up), from the deck now (`startedBy`) or
    /// as it was when it asked (`decision.ancestors`, for an asking session that's gone).
    public static func mayCancel(caller: UUID, decision: OwnerDecision, startedBy: [UUID: UUID]) -> Bool {
        guard let asker = decision.sessionID else { return false }
        if caller == asker || decision.ancestors.contains(caller) { return true }
        // Not SessionCLI.mayClose: this file is also in the phone's build, that one isn't.
        return ancestors(of: asker, startedBy: startedBy).contains(caller)
    }

    /// The asking session's starters, parent first (bounded, like `SessionCLI.mayClose`).
    public static func ancestors(of session: UUID, startedBy: [UUID: UUID]) -> [UUID] {
        var out: [UUID] = []
        var current = session
        for _ in 0..<64 {
            guard let parent = startedBy[current], !out.contains(parent), parent != session else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    /// `X-ClaudeDeck-Note` on a `decide` that went through: comma-separated codes without spaces
    /// the script turns into warnings on stderr (`already_pending:d_…`, `not_turkish`).
    public static let noteHeader = "X-ClaudeDeck-Note"

    /// An answer as given: trimmed, not empty, at most `maxAnswer` characters.
    public static func cleanAnswer(_ answer: String) -> String? {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxAnswer else { return nil }
        return text
    }

    /// What the asking session gets: one line (it's typed into Claude Code and sent with Return).
    public static func message(for decision: OwnerDecision) -> String {
        "[ClaudeDeck decision \(decision.id)] The owner answered your question “\(oneLine(decision.question, max: 300))”: "
            + oneLine(decision.answer ?? "", max: maxAnswer)
    }

    /// What the asking session gets when the owner changes an answer it already got.
    public static func changedMessage(for decision: OwnerDecision, was old: String) -> String {
        "[ClaudeDeck decision \(decision.id)] The owner changed the answer to your question “\(oneLine(decision.question, max: 300))”: "
            + oneLine(decision.answer ?? "", max: maxAnswer) + " (was: \(oneLine(old, max: 300)))"
    }

    /// What the asking session gets when the owner dismisses its question without answering.
    public static func dismissedMessage(for decision: OwnerDecision) -> String {
        "[ClaudeDeck decision \(decision.id)] The owner dismissed your question “\(oneLine(decision.question, max: 300))” "
            + "without answering. Don't wait for it; ask again only if it still matters."
    }

    /// Text on one line (line breaks and the spaces around them folded), cut at `max`.
    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// A question as the duplicate guard compares it: trimmed, runs of white space as one space,
    /// case folded (Turkish rules), trailing punctuation dropped: "Hangi DB?" and "hangi  db" match.
    public static func normalizedQuestion(_ question: String) -> String {
        let words = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var folded = words.lowercased(with: Locale(identifier: "tr"))
        while let last = folded.last, last.isPunctuation || last.isWhitespace { folded.removeLast() }
        return folded
    }

    /// Letters only Turkish uses among the Latin alphabets (as composed characters).
    static let turkishLetters = Set("çğıöşüÇĞİÖŞÜ")
    /// Short words common in Turkish questions.
    static let turkishWords: Set<String> = ["ve", "bir", "mi", "mı", "mu", "mü", "için", "ile", "bu", "ne", "hangi", "olsun"]

    /// Whether the owner-facing text (the question and the options) reads as Turkish: a
    /// Turkish-only letter, or one of a few common Turkish words. `decide` only warns when not.
    public static func looksTurkish(question: String, options: [String]) -> Bool {
        // Composed first: "ş" typed as "s" + combining cedilla is still "ş".
        let text = ([question] + options).joined(separator: "\n").precomposedStringWithCanonicalMapping
        if text.contains(where: { turkishLetters.contains($0) }) { return true }
        return text.lowercased(with: Locale(identifier: "tr"))
            .split(whereSeparator: { !$0.isLetter })
            .contains { turkishWords.contains(String($0)) }
    }

    /// `claudedeck decision get` as text: the status first ("pending", "answered: …", "cancelled: …").
    public static func text(_ decision: OwnerDecision) -> String {
        let status = switch decision.status {
        case .pending: "pending"
        case .answered: "answered: \(decision.answer ?? "")" + (decision.isChanged ? " (changed)" : "")
        case .cancelled: "cancelled: \(decision.cancelReason ?? "")"
        }
        var lines = [status]
        lines.append("id: \(decision.id)")
        lines.append("question: \(decision.question)")
        if !decision.options.isEmpty {
            lines.append("options: " + decision.options.map { $0 == decision.recommended ? "\($0) (recommended)" : $0 }.joined(separator: ", "))
        }
        if !decision.project.isEmpty { lines.append("project: \(decision.project)") }
        for previous in decision.answerHistory { lines.append("was: \(previous.answer)") }
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
        let rows = decisions.map {
            [$0.id, $0.status.rawValue, cut($0.project, 24), cut($0.question, 60),
             cut($0.isCancelled ? "(\($0.cancelReason ?? ""))" : $0.answer ?? "", 40)]
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

    public enum Cancelled: Equatable, Sendable {
        case cancelled(OwnerDecision)
        case alreadyAnswered(OwnerDecision)
        case alreadyCancelled(OwnerDecision)
        case unknown
    }

    /// What `cancel` would do now (`.cancelled` with the pending decision), without changing anything.
    public func cancellable(_ id: String) -> Cancelled {
        guard let decision = decision(id) else { return .unknown }
        switch decision.status {
        case .pending: return .cancelled(decision)
        case .answered: return .alreadyAnswered(decision)
        case .cancelled: return .alreadyCancelled(decision)
        }
    }

    /// Withdraws a pending decision: it leaves the pending lists and stays in the history.
    public mutating func cancel(_ id: String, reason: String, at date: Date = Date()) -> Cancelled {
        guard let index = decisions.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return .unknown }
        switch decisions[index].status {
        case .answered: return .alreadyAnswered(decisions[index])
        case .cancelled: return .alreadyCancelled(decisions[index])
        case .pending: break
        }
        decisions[index].status = .cancelled
        decisions[index].cancelReason = reason
        decisions[index].cancelledAt = date
        let cancelled = decisions[index]
        prune()
        return .cancelled(cancelled)
    }

    /// The session's own pending decision with the same question (`Decisions.normalizedQuestion`),
    /// if any; `except` is left out (the one `--supersedes` replaces).
    public func pendingDuplicate(session: UUID, question: String, except: String? = nil) -> OwnerDecision? {
        let wanted = Decisions.normalizedQuestion(question)
        return decisions.first {
            $0.isPending && $0.sessionID == session && $0.id.caseInsensitiveCompare(except ?? "") != .orderedSame
                && Decisions.normalizedQuestion($0.question) == wanted
        }
    }

    public enum Changed: Equatable, Sendable {
        /// The new answer is in; `was`: the one it replaced.
        case changed(OwnerDecision, was: String)
        /// The same answer again: nothing changed.
        case same(OwnerDecision)
        /// Pending or cancelled: answer it, don't change it.
        case notAnswered(OwnerDecision)
        case unknown
    }

    /// The owner changes an answer already given (the old one goes to `answerHistory`).
    public mutating func changeAnswer(_ id: String, to answer: String, from: String, at date: Date = Date()) -> Changed {
        guard let index = decisions.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return .unknown }
        let decision = decisions[index]
        guard decision.isAnswered, let old = decision.answer else { return .notAnswered(decision) }
        guard old != answer else { return .same(decision) }
        decisions[index].answerHistory.append(.init(answer: old, answeredAt: decision.answeredAt, answeredFrom: decision.answeredFrom))
        decisions[index].answer = answer
        decisions[index].answeredAt = date
        decisions[index].answeredFrom = from
        decisions[index].changedAt = date
        decisions[index].delivery = nil
        return .changed(decisions[index], was: old)
    }

    /// What became of the answer (after `answer`).
    public mutating func setDelivery(_ id: String, _ delivery: String) {
        guard let index = decisions.firstIndex(where: { $0.id == id }) else { return }
        decisions[index].delivery = delivery
    }

    /// Pending ones stay; of the answered and cancelled ones, the newest `maxAnswered`.
    mutating func prune() {
        let answered = decisions.filter { !$0.isPending }
        guard answered.count > Decisions.maxAnswered else { return }
        let keep = Set(answered.sorted { $0.resolvedAt > $1.resolvedAt }
            .prefix(Decisions.maxAnswered).map(\.id))
        decisions.removeAll { !$0.isPending && !keep.contains($0.id) }
    }

    /// For a remote: every pending one and those answered in the last `recent` seconds (at most
    /// `maxAnswered` of them), newest first. Cancelled ones are never sent: an older phone reads
    /// a status it doesn't know as pending.
    public func forRemote(now: Date = Date(), recent: TimeInterval = 24 * 3600, maxAnswered: Int = 50) -> [OwnerDecision] {
        let pending = decisions.filter(\.isPending)
        let answered = decisions.filter { $0.isAnswered && now.timeIntervalSince($0.answeredAt ?? $0.createdAt) < recent }
            .suffix(maxAnswered)
        return (pending + answered).sorted { $0.createdAt > $1.createdAt }.map(Self.trimmed)
    }

    /// The phone's history (`RemoteSnapshot.decisionHistory`): answered and cancelled decisions
    /// of the last `days` that `forRemote` leaves out, newest first, at most `max`.
    public func historyForRemote(now: Date = Date(), days: Int = 7, max: Int = 50, recent: TimeInterval = 24 * 3600) -> [OwnerDecision] {
        let sent = Set(forRemote(now: now, recent: recent).map(\.id))
        return decisions.filter { !$0.isPending && !sent.contains($0.id) && now.timeIntervalSince($0.resolvedAt) < TimeInterval(days) * 24 * 3600 }
            .sorted { $0.resolvedAt > $1.resolvedAt }
            .prefix(max).map(Self.trimmed)
    }

    /// Long contexts are cut for the wire (the Mac keeps the whole text).
    static func trimmed(_ decision: OwnerDecision) -> OwnerDecision {
        var copy = decision
        if let context = copy.context, context.count > 2_000 { copy.context = String(context.prefix(2_000)) + "…" }
        return copy
    }
}

/// How the tab (and the phone's screen) splits the answered ones: the newest few always shown,
/// the rest of today's behind a disclosure; older days aren't shown (the file keeps them).
public enum DecisionSections {
    public static let recentCount = 5

    public static func answered(_ decisions: [OwnerDecision], now: Date = Date(), calendar: Calendar = .current)
        -> (recent: [OwnerDecision], otherToday: [OwnerDecision]) {
        let answered = decisions.filter(\.isAnswered).sorted { $0.resolvedAt > $1.resolvedAt }
        let recent = Array(answered.prefix(recentCount))
        let otherToday = answered.dropFirst(recentCount).filter { calendar.isDate($0.resolvedAt, inSameDayAs: now) }
        return (recent, Array(otherToday))
    }

    public static func cancelledToday(_ decisions: [OwnerDecision], now: Date = Date(), calendar: Calendar = .current) -> [OwnerDecision] {
        decisions.filter { $0.isCancelled && calendar.isDate($0.resolvedAt, inSameDayAs: now) }
            .sorted { $0.resolvedAt > $1.resolvedAt }
    }
}
