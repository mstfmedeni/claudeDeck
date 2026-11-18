import Foundation

// What the dashboard counts from a Claude transcript: replies, prompts, tool calls, output
// tokens and the lines Claude's edits added and removed, per hour, and the files edited per day.
// Read a piece at a time (only what was appended since the last read) and kept as counters, so a
// long-running session never gets parsed twice and nothing of the conversation's text is held.

/// Counts for one hour.
public struct PulseBucket: Sendable, Equatable {
    public var replies = 0
    public var prompts = 0
    public var toolCalls = 0
    public var outputTokens = 0
    public var added = 0
    public var removed = 0

    public init() {}

    /// Something happened in this hour (the heat map's measure).
    public var events: Int { replies + prompts + toolCalls }

    public static func += (a: inout PulseBucket, b: PulseBucket) {
        a.replies += b.replies
        a.prompts += b.prompts
        a.toolCalls += b.toolCalls
        a.outputTokens += b.outputTokens
        a.added += b.added
        a.removed += b.removed
    }
}

/// Claude's edits to one file on one day.
public struct PulseFile: Sendable, Equatable {
    public var path: String
    public var edits = 0
    public var added = 0
    public var removed = 0
    public var lastAt: Date?

    public init(path: String) { self.path = path }
}

/// The counters of one transcript (or several added up).
public struct PulseDigest: Sendable, Equatable {
    /// By start of the hour.
    public var hours: [Date: PulseBucket] = [:]
    /// Tool calls by tool name, by start of the day.
    public var tools: [Date: [String: Int]] = [:]
    /// Edited files by path, by start of the day.
    public var files: [Date: [String: PulseFile]] = [:]
    /// The newest timestamp seen.
    public var lastAt: Date?

    public init() {}

    public static func += (a: inout PulseDigest, b: PulseDigest) {
        for (hour, bucket) in b.hours { a.hours[hour, default: PulseBucket()] += bucket }
        for (day, counts) in b.tools {
            for (tool, count) in counts { a.tools[day, default: [:]][tool, default: 0] += count }
        }
        for (day, files) in b.files {
            for (path, file) in files {
                var merged = a.files[day]?[path] ?? PulseFile(path: path)
                merged.edits += file.edits
                merged.added += file.added
                merged.removed += file.removed
                merged.lastAt = [merged.lastAt, file.lastAt].compactMap { $0 }.max()
                a.files[day, default: [:]][path] = merged
            }
        }
        a.lastAt = [a.lastAt, b.lastAt].compactMap { $0 }.max()
    }

    /// Sum of the hours in `interval`.
    public func total(in interval: DateInterval) -> PulseBucket {
        var sum = PulseBucket()
        for (hour, bucket) in hours where hour >= interval.start && hour < interval.end { sum += bucket }
        return sum
    }

    /// Drops everything that started before `cutoff`.
    public mutating func prune(before cutoff: Date) {
        hours = hours.filter { $0.key >= cutoff.addingTimeInterval(-3600) }
        let dayCutoff = cutoff.addingTimeInterval(-86400)
        tools = tools.filter { $0.key >= dayCutoff }
        files = files.filter { $0.key >= dayCutoff }
    }
}

/// Reads one transcript incrementally into a `PulseDigest`.
public struct TranscriptPulse: Sendable {
    public private(set) var digest = PulseDigest()
    /// Where the next read starts: just after the last complete line read.
    public private(set) var offset: UInt64 = 0
    private var started = false
    private let calendar: Calendar
    /// Lines older than this are skipped.
    private let since: Date
    /// Assistant message ids already counted (Claude Code writes one line per content block,
    /// each carrying the message's usage).
    private var countedMessages: [String] = []
    /// Lines longer than this are only parsed when they hold an edit (big tool results).
    static let maxParsedLine = 256 * 1024

    public init(since: Date, calendar: Calendar = .current) {
        self.since = since
        self.calendar = calendar
    }

    /// Reads what was appended since the last read (the first read takes the last `tailBytes`).
    /// False when the file is now shorter than what was read: start over with a new pulse.
    public mutating func read(_ url: URL, tailBytes: Int = 8 << 20) -> Bool {
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
        if dropPartial {
            guard let newline = data.firstIndex(of: 0x0A) else { return true }
            from = newline + 1
            offset += UInt64(from - data.startIndex)
        }
        // Complete lines only: one being written now is read next time.
        guard let last = data.lastIndex(of: 0x0A), last >= from else { return true }
        append(data[from...last])
        offset += UInt64(last + 1 - from)
        return true
    }

    /// Adds the counts of these JSONL lines.
    public mutating func append(_ text: String) {
        append(Data(text.utf8))
    }

    mutating func append(_ data: Data) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start { line(data[start..<end], iso: iso, isoPlain: isoPlain) }
            start = end + 1
        }
    }

    private mutating func line(_ bytes: Data, iso: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter) {
        if bytes.count > Self.maxParsedLine, bytes.range(of: Self.patchMarker) == nil, bytes.range(of: Self.createMarker) == nil { return }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        let type = object["type"] as? String
        guard type == "user" || type == "assistant" else { return }
        guard let stamp = object["timestamp"] as? String,
              let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp), date >= since else { return }
        let hour = Self.hourStart(date)
        let day = calendar.startOfDay(for: date)
        let message = object["message"] as? [String: Any] ?? [:]
        digest.lastAt = max(digest.lastAt ?? date, date)
        if type == "assistant" {
            if object["isSidechain"] as? Bool == true { return }
            let blocks = message["content"] as? [[String: Any]] ?? []
            var bucket = PulseBucket()
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    bucket.toolCalls += 1
                    let name = block["name"] as? String ?? "Tool"
                    digest.tools[day, default: [:]][Self.shortToolName(name), default: 0] += 1
                case "text":
                    bucket.replies += 1
                default:
                    break
                }
            }
            if let id = message["id"] as? String {
                if !countedMessages.contains(id) {
                    countedMessages.append(id)
                    if countedMessages.count > 64 { countedMessages.removeFirst() }
                    bucket.outputTokens += (message["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
                }
            } else {
                bucket.outputTokens += (message["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
            }
            digest.hours[hour, default: PulseBucket()] += bucket
            return
        }
        // User lines: a typed prompt, or tool results (edits carry their patch).
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true { return }
        if let content = message["content"] as? String {
            if Self.isPrompt(content) { digest.hours[hour, default: PulseBucket()].prompts += 1 }
            return
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if blocks.contains(where: { $0["type"] as? String == "text" && Self.isPrompt($0["text"] as? String ?? "") }) {
            digest.hours[hour, default: PulseBucket()].prompts += 1
        }
        guard let result = object["toolUseResult"] as? [String: Any], let path = result["filePath"] as? String,
              blocks.contains(where: { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool != true }) else { return }
        var added = 0, removed = 0
        if let patch = result["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            for hunk in patch {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
            }
        } else if result["type"] as? String == "create", let content = result["content"] as? String {
            added = content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
        } else {
            return
        }
        digest.hours[hour, default: PulseBucket()].added += added
        digest.hours[hour, default: PulseBucket()].removed += removed
        var file = digest.files[day]?[path] ?? PulseFile(path: path)
        file.edits += 1
        file.added += added
        file.removed += removed
        file.lastAt = max(file.lastAt ?? date, date)
        digest.files[day, default: [:]][path] = file
    }

    private static let patchMarker = Data("\"structuredPatch\"".utf8)
    private static let createMarker = Data("\"type\":\"create\"".utf8)

    /// What the user typed (not the CLI's own tagged lines or interruptions).
    static func isPrompt(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasPrefix("[Request interrupted") || text.hasPrefix("Caveat:") { return false }
        if text.hasPrefix("<") { return text.hasPrefix("<command-name>") }
        return true
    }

    /// "mcp__github__create_issue" → "github: create_issue"; others as they are.
    static func shortToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]): \(parts[1...].joined(separator: "_"))" : name
    }

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - Heat map

/// The week's rhythm: activity per weekday row and hour column.
public struct ActivityHeatmap: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        /// 0 = the oldest day shown, `days - 1` = today.
        public var day: Int
        public var dayStart: Date
        public var hour: Int
        public var value: Double
        public var id: Int { day * 24 + hour }
    }

    public var cells: [Cell]
    public var maxValue: Double

    /// `days` rows ending today; each hour's value is `value(hourStart)`.
    public static func build(days: Int, now: Date, calendar: Calendar, value: (Date) -> Double) -> ActivityHeatmap {
        let today = calendar.startOfDay(for: now)
        var cells: [Cell] = []
        for row in 0..<days {
            guard let dayStart = calendar.date(byAdding: .day, value: row - (days - 1), to: today) else { continue }
            for hour in 0..<24 {
                guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
                let v = hourStart > now ? 0 : value(hourStart)
                cells.append(Cell(day: row, dayStart: dayStart, hour: hour, value: v))
            }
        }
        return ActivityHeatmap(cells: cells, maxValue: cells.map(\.value).max() ?? 0)
    }
}
