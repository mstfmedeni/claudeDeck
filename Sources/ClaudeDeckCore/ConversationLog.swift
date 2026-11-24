import Foundation

// A Claude transcript (JSONL) as a readable conversation: what the phone shows instead of a
// terminal too wide for its screen. Only the main thread of the session (no subagents), no
// thinking, tool calls as one-line summaries with a short excerpt of their result.

public struct ChatEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool, system }

    public var id: String
    public var kind: Kind
    /// User / assistant text, the tool call's summary, or the system note.
    public var text: String
    public var toolName: String?
    /// Start of the tool's result.
    public var result: String?
    public var isError: Bool
    public var date: Date?
    /// AskUserQuestion: what Claude asked, and once answered, the answers by question text.
    public var questions: [ChatQuestion]?
    public var answers: [String: String]?

    public init(id: String, kind: Kind, text: String, toolName: String? = nil, result: String? = nil, isError: Bool = false, date: Date? = nil,
                questions: [ChatQuestion]? = nil, answers: [String: String]? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.result = result
        self.isError = isError
        self.date = date
        self.questions = questions
        self.answers = answers
    }
}

/// One question of an AskUserQuestion call (the terminal shows each as a tab).
public struct ChatQuestion: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var header: String?
    public var question: String
    public var multiSelect: Bool
    public var options: [Option]

    public init(header: String? = nil, question: String, multiSelect: Bool = false, options: [Option]) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }

    static func parse(_ input: [String: Any]) -> [ChatQuestion]? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        let questions = raw.compactMap { q -> ChatQuestion? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o in
                (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String) }
            }
            return ChatQuestion(header: q["header"] as? String, question: text, multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
        return questions.isEmpty ? nil : questions
    }
}

/// The phone's answer to one question: chosen option indexes, or (single choice) its own text.
public struct QuestionAnswer: Codable, Sendable, Equatable {
    public var options: [Int]
    public var text: String?
    public init(options: [Int] = [], text: String? = nil) {
        self.options = options
        self.text = text
    }
}

/// The keys that answer an AskUserQuestion prompt in the terminal, typed one chunk at a time with
/// a short pause (sent at once, the prompt drops some). Verified against Claude Code 2.1:
/// - one single-choice question: its number answers it;
/// - otherwise each question is a tab, then a Submit tab: a single choice's number answers and
///   moves on; a multiple choice's numbers toggle and Tab moves on; "1" on Submit sends.
/// - own text: the number of "Type something", the text, Return (it moves on too).
public enum QuestionKeys {
    public static func keys(for questions: [ChatQuestion], answers: [QuestionAnswer]) -> [String]? {
        guard !questions.isEmpty, answers.count == questions.count else { return nil }
        let tabbed = questions.count > 1 || questions.contains(where: \.multiSelect)
        var keys: [String] = []
        for (question, answer) in zip(questions, answers) {
            let count = question.options.count
            // The prompt numbers options 1-9; "Type something" comes right after them.
            guard count > 0, count < 9, answer.options.allSatisfy({ (0..<count).contains($0) }) else { return nil }
            if question.multiSelect {
                guard !answer.options.isEmpty, answer.text == nil else { return nil }
                keys += Set(answer.options).sorted().map { String($0 + 1) }
                keys.append("\t")
            } else if let text = answer.text {
                let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard answer.options.isEmpty, !line.isEmpty else { return nil }
                keys += [String(count + 1), line, "\r"]
            } else {
                guard answer.options.count == 1 else { return nil }
                keys.append(String(answer.options[0] + 1))
            }
        }
        if tabbed { keys.append("1") }
        return keys
    }
}

/// A slice of a conversation. `before` / `after` echo the request so the phone knows where it goes.
public struct ChatPage: Codable, Sendable, Equatable {
    public var entries: [ChatEntry]
    /// Older entries exist before the first one.
    public var hasMoreBefore: Bool
    /// The page replaces what the phone has (a new transcript after /clear, or the anchor is gone).
    public var reset: Bool
    public var before: String?
    public var after: String?
    /// Tokens in Claude's context as of the transcript's last turn (nil from older hosts).
    public var contextTokens: Int?
    /// Agents' notes on this session, newest last (hosts with `Feature.agents`); the whole list
    /// each time, it replaces what the remote has.
    public var agentNotes: [AgentNote]?
    /// With `after`: entries at or before the anchor that changed since it was added (a tool's
    /// result came in later), to replace the remote's copies. Hosts with `Feature.historyUpdates`;
    /// older remotes ignore it.
    public var updated: [ChatEntry]?

    public init(entries: [ChatEntry], hasMoreBefore: Bool, reset: Bool, before: String? = nil, after: String? = nil) {
        self.entries = entries
        self.hasMoreBefore = hasMoreBefore
        self.reset = reset
        self.before = before
        self.after = after
    }
}

/// The remote's side of conversation pages (the phone's ConversationView): which entry to ask
/// for newer ones after, and how a page goes into what it has.
public enum ChatSync {
    /// The anchor for the next `historyRequest(after:)`; nil: ask for the latest page.
    /// - A host that sends `ChatPage.updated` (`Feature.historyUpdates`) also sends what changed up
    ///   to the anchor: the last entry.
    /// - An older host sends only what comes after the anchor, so a tool call still waiting for its
    ///   result has to come after it: the anchor goes just before the first such call, looking at
    ///   the last `window` entries (one older than that, cut off without a result, would hold the
    ///   anchor back for good). Calls answered out of order (parallel calls, background tasks)
    ///   still get their results.
    public static func anchor(_ entries: [ChatEntry], hostSendsUpdates: Bool, window: Int = 60) -> String? {
        guard let last = entries.last else { return nil }
        if hostSendsUpdates { return last.id }
        let start = max(0, entries.count - window)
        guard let pending = entries[start...].firstIndex(where: { $0.kind == .tool && $0.result == nil }) else { return last.id }
        return pending > 0 ? entries[pending - 1].id : nil
    }

    /// The first of `count` entries to draw: about the last `window`, moved in steps of `step` so
    /// what's on screen doesn't shift with every new entry.
    public static func windowStart(count: Int, window: Int, step: Int) -> Int {
        guard count > window, step > 0 else { return 0 }
        return (count - window) / step * step
    }

    /// Puts a page into `entries`. False when it doesn't fit (a page after an entry that isn't
    /// there any more): ask for the latest page instead.
    @discardableResult
    public static func merge(_ page: ChatPage, into entries: inout [ChatEntry], hasMoreBefore: inout Bool) -> Bool {
        if page.reset {
            // The latest page again (a refresh): what was loaded before its first entry stays, so
            // "Earlier messages" already read isn't lost.
            if let first = page.entries.first, let at = entries.firstIndex(where: { $0.id == first.id }), at > 0 {
                entries = Array(entries[..<at]) + page.entries
                return true
            }
            entries = page.entries
            hasMoreBefore = page.hasMoreBefore
            return true
        }
        if page.before != nil {
            let known = Set(entries.map(\.id))
            entries = page.entries.filter { !known.contains($0.id) } + entries
            hasMoreBefore = page.hasMoreBefore
            return true
        }
        var index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let after = page.after, index[after] == nil { return false }
        for entry in page.updated ?? [] {
            if let at = index[entry.id] { entries[at] = entry }
        }
        for entry in page.entries {
            if let at = index[entry.id] {
                entries[at] = entry
            } else {
                index[entry.id] = entries.count
                entries.append(entry)
            }
        }
        return true
    }
}

public enum ConversationLog {
    static let maxResult = 1_200
    static let maxText = 20_000

    /// Parses a whole transcript (the last `tailBytes` of a big one).
    public static func entries(of url: URL, tailBytes: Int = 16 << 20) -> [ChatEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return [] }
        // Started mid-line: drop the partial first line.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return entries(fromJSONL: String(decoding: data, as: UTF8.self))
    }

    public static func entries(fromJSONL text: String) -> [ChatEntry] {
        var reader = Reader()
        reader.append(text)
        return reader.entries
    }

    /// A transcript read a piece at a time: the first `read` takes its last `tailBytes`, later ones
    /// only what was appended since. A running session's transcript grows a few lines at a time,
    /// so a conversation kept current from a phone doesn't parse megabytes on every change.
    public struct Reader: Sendable {
        public private(set) var entries: [ChatEntry] = []
        private var toolIndex: [String: Int] = [:]
        // Messages typed while Claude was busy are logged as queued commands; on the rare
        // occasion the same text is logged again as a user message, it shows once.
        private var queued: Set<String> = []
        /// Where the next read starts: just after the last complete line read.
        public private(set) var offset: UInt64 = 0
        private var started = false
        /// The file changes of Edit / Write / MultiEdit calls, when `collectsChanges`.
        public private(set) var changes = SessionChanges()
        private let collectsChanges: Bool
        /// Edit / Write / MultiEdit calls waiting for their result: tool name by call id.
        private var changeCalls: [String: String] = [:]
        /// When each entry last changed (added, or its result filled in), counting up from 1 per
        /// reader: `page(after:)` sends the entries before the anchor that changed after it came.
        public private(set) var revisions: [Int] = []
        /// When each entry was added (its first revision).
        public private(set) var added: [Int] = []
        private var revision = 0

        /// `collectsChanges`: also gather `changes` (the Changes panel; others leave them out).
        public init(collectsChanges: Bool = false) {
            self.collectsChanges = collectsChanges
        }

        /// Reads the lines added since the last read. False when the file is shorter than what was
        /// read (not the same file any more): read it with a new reader.
        public mutating func read(_ url: URL, tailBytes: Int = 16 << 20) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            guard size >= offset else { return false }
            var dropPartial = false
            if !started {
                started = true
                if size > UInt64(tailBytes) {
                    offset = size - UInt64(tailBytes)
                    dropPartial = true
                }
            }
            guard size > offset else { return true }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return true }
            var from = data.startIndex
            // Started mid-line: drop the partial first line.
            if dropPartial {
                guard let newline = data.firstIndex(of: 0x0A) else { return true }
                from = newline + 1
                offset += UInt64(from - data.startIndex)
            }
            // Complete lines only: one being written now is read next time.
            guard let last = data.lastIndex(of: 0x0A), last >= from else { return true }
            append(String(decoding: data[from...last], as: UTF8.self))
            offset += UInt64(last + 1 - from)
            return true
        }

        private mutating func add(_ entry: ChatEntry) {
            revision += 1
            entries.append(entry)
            revisions.append(revision)
            added.append(revision)
        }

        /// The page for a request, with `updated` filled in (see `ConversationLog.page`).
        public func page(before: String?, after: String?, limit: Int) -> ChatPage {
            ConversationLog.page(entries, revisions: (added, revisions), before: before, after: after, limit: limit)
        }

        /// Adds the entries of these JSONL lines (tool results fill in calls read earlier).
        public mutating func append(_ text: String) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = object["type"] as? String
                guard type == "user" || type == "assistant" || type == "attachment" else { continue }
                if object["isSidechain"] as? Bool == true { continue }
                let uuid = object["uuid"] as? String ?? UUID().uuidString
                let date = (object["timestamp"] as? String).flatMap { iso.date(from: $0) }
                let message = object["message"] as? [String: Any] ?? [:]

                if object["isCompactSummary"] as? Bool == true {
                    add(ChatEntry(id: uuid, kind: .system, text: String(localized: "Conversation compacted"), date: date))
                    continue
                }
                if type == "attachment" {
                    if let text = ConversationLog.queuedPrompt(object["attachment"] as? [String: Any]), let entry = ConversationLog.userEntry(text, id: uuid, date: date) {
                        queued.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        add(entry)
                    }
                    continue
                }
                if type == "user" {
                    if object["isMeta"] as? Bool == true { continue }
                    if let content = message["content"] as? String {
                        if queued.remove(content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { continue }
                        if let entry = ConversationLog.userEntry(content, id: uuid, date: date) { add(entry) }
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        for (index, block) in blocks.enumerated() {
                            switch block["type"] as? String {
                            case "text":
                                if let text = block["text"] as? String, let entry = ConversationLog.userEntry(text, id: "\(uuid)#\(index)", date: date) { add(entry) }
                            case "tool_result":
                                if collectsChanges, let toolID = block["tool_use_id"] as? String, let tool = changeCalls.removeValue(forKey: toolID),
                                   block["is_error"] as? Bool != true {
                                    changes.record(toolUseID: toolID, tool: tool, result: object["toolUseResult"], date: date)
                                }
                                guard let toolID = block["tool_use_id"] as? String, let at = toolIndex[toolID] else { continue }
                                revision += 1
                                revisions[at] = revision
                                entries[at].result = ConversationLog.resultText(block["content"])
                                entries[at].isError = block["is_error"] as? Bool ?? false
                                if entries[at].questions != nil {
                                    entries[at].answers = (object["toolUseResult"] as? [String: Any])?["answers"] as? [String: String]
                                }
                            default:
                                break
                            }
                        }
                    }
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for (index, block) in blocks.enumerated() {
                        switch block["type"] as? String {
                        // Claude Code also writes some of what it shows as a reply into a thinking block
                        // with text (real thinking is stored empty): shown like the terminal shows it.
                        case "text", "thinking":
                            let text = (block["text"] as? String ?? block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            add(ChatEntry(id: "\(uuid)#\(index)", kind: .assistant, text: String(text.prefix(ConversationLog.maxText)), date: date))
                        case "tool_use":
                            let name = block["name"] as? String ?? "Tool"
                            let id = block["id"] as? String ?? "\(uuid)#\(index)"
                            toolIndex[id] = entries.count
                            if collectsChanges, ["Edit", "Write", "MultiEdit"].contains(name) { changeCalls[id] = name }
                            let input = block["input"] as? [String: Any] ?? [:]
                            add(ChatEntry(id: id, kind: .tool, text: ConversationLog.summary(tool: name, input: input), toolName: name, date: date,
                                                     questions: name == "AskUserQuestion" ? ChatQuestion.parse(input) : nil))
                        default:
                            break // server tools
                        }
                    }
                }
            }
        }
    }

    /// A message the user typed while Claude was busy (Claude Code queues it and reads it in at
    /// the next step). Not other agents' messages; task notifications go through `userEntry`.
    static func queuedPrompt(_ attachment: [String: Any]?) -> String? {
        guard let attachment, attachment["type"] as? String == "queued_command" else { return nil }
        let origin = (attachment["origin"] as? [String: Any])?["kind"] as? String
        let mode = attachment["commandMode"] as? String
        guard origin == "human" || mode == "task-notification" else { return nil }
        if let prompt = attachment["prompt"] as? String { return prompt }
        guard let blocks = attachment["prompt"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": block["text"] as? String
            case "image": "[Image]"
            default: nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// A user line, or nil for the CLI's own bookkeeping (command echoes, caveats, reminders).
    static func userEntry(_ raw: String, id: String, date: Date?) -> ChatEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[Request interrupted by user") {
            return ChatEntry(id: id, kind: .system, text: String(localized: "Interrupted"), date: date)
        }
        if let command = tag("command-name", in: text) {
            let args = tag("command-args", in: text).map { $0.isEmpty ? "" : " " + $0 } ?? ""
            return ChatEntry(id: id, kind: .system, text: command + args, date: date)
        }
        if text.hasPrefix("<task-notification>") {
            let summary = tag("summary", in: text) ?? tag("status", in: text)
            return ChatEntry(id: id, kind: .system, text: String(localized: "Background task finished") + (summary.map { ": \($0)" } ?? ""), date: date)
        }
        // The CLI's own tagged messages (command output, reminders, hook notes…), not the user's words.
        if text.hasPrefix("Caveat:") || isTagBlock(text) { return nil }
        // A file sent from the phone (RemoteController saves them under ClaudeDeckUploads/): just its name.
        let shown = text.replacingOccurrences(of: #"@\S*/ClaudeDeckUploads/[0-9]+-[0-9A-F]{4}/(\S+)"#, with: "📎 $1", options: .regularExpression)
        return ChatEntry(id: id, kind: .user, text: String(shown.prefix(maxText)), date: date)
    }

    /// `<name …>…</name>` from start to end.
    static func isTagBlock(_ text: String) -> Bool {
        guard text.hasPrefix("<"), let close = text.firstIndex(where: { $0 == ">" || $0 == " " }) else { return false }
        let name = text[text.index(after: text.startIndex)..<close]
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        return text.hasSuffix("</\(name)>")
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resultText(_ content: Any?) -> String? {
        var text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxResult ? String(text.prefix(maxResult)) + "…" : text
    }

    /// "git status", "Views.swift", the pattern… — what the tool call was about, in one line.
    public static func summary(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func file(_ path: String) -> String {
            let parts = path.split(separator: "/")
            return parts.suffix(2).joined(separator: "/")
        }
        let value: String? = switch tool {
        case "Bash": string("description").map { d in string("command").map { "\(d) — \($0)" } ?? d } ?? string("command")
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": string("file_path").map(file) ?? string("notebook_path").map(file)
        case "Grep", "Glob": string("pattern")
        case "WebFetch": string("url")
        case "WebSearch": string("query")
        case "Agent", "Task": string("description")
        case "TodoWrite": (input["todos"] as? [Any]).map { "\($0.count)" }
        case "AskUserQuestion": ChatQuestion.parse(input)?.first?.question
        case "SendMessage": string("summary") ?? string("message")
        // By key: a dictionary's order differs between parses, and the same call read again (a
        // new reader) must keep its summary.
        default: input.keys.sorted().lazy.compactMap { (input[$0] as? String)?.nilIfEmpty }.first
        }
        let line = (value ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return String(line.prefix(200))
    }

    /// The page for a request (see `ChatPage`). `revisions` (the reader's `added` and `revisions`,
    /// one per entry): a page after an anchor also carries, in `updated`, the entries up to the
    /// anchor (itself included) that changed after the anchor was added. Whatever the remote had, it got after the anchor was added, so those
    /// are the only ones it can have old: a tool call that got its result later (parallel calls,
    /// background tasks) while newer entries were already complete.
    public static func page(_ entries: [ChatEntry], revisions: (added: [Int], changed: [Int])? = nil, before: String?, after: String?, limit: Int) -> ChatPage {
        let limit = max(1, min(limit, 200))
        if let after {
            if let index = entries.firstIndex(where: { $0.id == after }) {
                let newer = Array(entries[(index + 1)...])
                var updated: [ChatEntry] = []
                if let revisions, revisions.added.count == entries.count, revisions.changed.count == entries.count {
                    let since = revisions.added[index]
                    updated = entries.indices[...index].filter { revisions.changed[$0] > since }.map { entries[$0] }
                }
                // Far behind: start over with the latest page rather than a huge append.
                if newer.count + updated.count <= limit {
                    var page = ChatPage(entries: newer, hasMoreBefore: true, reset: false, after: after)
                    if revisions != nil { page.updated = updated }
                    return page
                }
            }
            let tail = Array(entries.suffix(limit))
            return ChatPage(entries: tail, hasMoreBefore: entries.count > tail.count, reset: true)
        }
        if let before, let index = entries.firstIndex(where: { $0.id == before }) {
            let start = max(0, index - limit)
            return ChatPage(entries: Array(entries[start..<index]), hasMoreBefore: start > 0, reset: false, before: before)
        }
        let tail = Array(entries.suffix(limit))
        return ChatPage(entries: tail, hasMoreBefore: entries.count > tail.count, reset: true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Markdown tables in Claude's answers, split out so the phone can draw them as tables (the rest
/// stays inline markdown).
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case text(String)
        case heading(level: Int, text: String)
        case table(header: [String], rows: [[String]])
    }

    /// "mcp__claude-in-chrome__javascript_tool" → "claude-in-chrome · javascript_tool", anywhere in
    /// the text (tool names and the status line's "Tool: input").
    public static func shortToolNames(_ text: String) -> String {
        text.replacingOccurrences(of: #"\bmcp__(.+?)__(\w+)"#, with: "$1 · $2", options: .regularExpression)
    }

    public static func split(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var pending: [String] = []
        var fenced = false
        var i = 0
        func flush() {
            let joined = pending.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            pending = []
        }
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            // A table: a | row, then a |---|---| row, then more | rows (not inside a code block).
            if !fenced, isRow(line), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isRow(lines[i]) {
                    var row = cells(lines[i])
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // "## Title" (not inside a code block): a heading of its own.
            if !fenced, let match = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*\s*$/) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                i += 1
                continue
            }
            pending.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
    }

    static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isRow(trimmed) && cells(trimmed).allSatisfy { !$0.isEmpty && $0.allSatisfy { ":-".contains($0) } && $0.contains("-") }
    }

    /// The cells of a `| a | b |` row (`\|` stays a bar inside a cell).
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
