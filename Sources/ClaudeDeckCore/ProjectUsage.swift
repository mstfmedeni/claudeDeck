import Foundation

// Token and cost usage per project, from the Claude Code transcripts (`message.usage` of every
// assistant reply, sub-agents included). The plan's own meter (ClaudeUsage, `api/oauth/usage`)
// only says how full the 5-hour and weekly windows are; this splits that by project: each
// project's share of the estimated cost in the window, applied to the window's percent.
//
// Read incrementally (only what was appended since the last read), in 5-minute slots, and kept
// for 7 days: nothing of the conversation's text is held.

/// Token counts and the estimated API cost of some replies.
public struct UsageTotals: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    /// Estimated cost at API prices, in millionths of a dollar.
    public var costMicros: Int64 = 0
    public var messages = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, costMicros: Int64 = 0, messages: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.costMicros = costMicros
        self.messages = messages
    }

    /// Every token, cache reads included.
    public var tokens: Int { input + output + cacheWrite + cacheRead }
    public var cost: Double { Double(costMicros) / 1_000_000 }

    public static func += (a: inout UsageTotals, b: UsageTotals) {
        a.input += b.input
        a.output += b.output
        a.cacheWrite += b.cacheWrite
        a.cacheRead += b.cacheRead
        a.costMicros += b.costMicros
        a.messages += b.messages
    }
}

/// API prices per million tokens by model family (an estimate: the plan isn't billed per token,
/// but its limits follow what the models cost). Unknown models count at Opus 5 prices.
public enum ModelPricing {
    public struct Price: Sendable, Equatable {
        public var input: Double
        public var output: Double
    }

    public static func price(_ model: String) -> Price {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return Price(input: 10, output: 50) }
        if m.contains("opus") {
            if m.contains("opus-5-5") { return Price(input: 4, output: 20) }
            // Opus 4.0 / 4.1 and Claude 3 Opus were priced higher.
            if m.contains("opus-4-0") || m.contains("opus-4-1") || m.contains("opus-4-2025") || m.contains("3-opus") {
                return Price(input: 15, output: 75)
            }
            return Price(input: 5, output: 25)
        }
        if m.contains("sonnet") { return m.contains("sonnet-5") ? Price(input: 2, output: 10) : Price(input: 3, output: 15) }
        if m.contains("haiku") { return m.contains("haiku-4") ? Price(input: 1, output: 5) : Price(input: 0.8, output: 4) }
        return Price(input: 5, output: 25)
    }

    /// Cache writes cost 1.25× input (5-minute) or 2× (1-hour); cache reads 0.1× input.
    public static func costMicros(model: String, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int) -> Int64 {
        let p = price(model)
        let dollars = (Double(input) * p.input + Double(output) * p.output + Double(cacheWrite5m) * p.input * 1.25
            + Double(cacheWrite1h) * p.input * 2 + Double(cacheRead) * p.input * 0.1) / 1_000_000
        return Int64((dollars * 1_000_000).rounded())
    }
}

/// One transcript read incrementally into 5-minute slots of `UsageTotals`.
public struct TranscriptUsage: Sendable {
    public private(set) var slots: [Date: UsageTotals] = [:]
    public private(set) var offset: UInt64 = 0
    private var started = false
    /// Replies already counted here (one line per content block, each with the message's usage).
    private var counted: [String] = []

    public static let slot: TimeInterval = 300

    public init() {}

    /// Reads what was appended (the first read takes the last `tailBytes`). False when the file
    /// is now shorter than what was read: start over. `seen` dedupes replies across files
    /// (a resumed or forked conversation copies earlier lines).
    public mutating func read(_ url: URL, since: Date, seen: inout [String: Date], tailBytes: Int = 64 << 20) -> Bool {
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
        guard let last = data.lastIndex(of: 0x0A), last >= from else { return true }
        append(data[from...last], since: since, seen: &seen)
        offset += UInt64(last + 1 - from)
        return true
    }

    public mutating func append(_ text: String, since: Date, seen: inout [String: Date]) {
        append(Data(text.utf8), since: since, seen: &seen)
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)

    mutating func append(_ data: Data, since: Date, seen: inout [String: Date]) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            // Only assistant replies carry usage: other lines (tool results, the bulk) aren't parsed.
            if end > start, data[start..<end].range(of: Self.assistantMarker) != nil, data[start..<end].range(of: Self.usageMarker) != nil {
                line(data[start..<end], since: since, seen: &seen)
            }
            start = end + 1
        }
    }

    private mutating func line(_ bytes: Data, since: Date, seen: inout [String: Date]) {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String, let date = Transcript.parseDate(stamp), date >= since else { return }
        if let id = message["id"] as? String {
            let key = id + "|" + ((object["requestId"] as? String) ?? "")
            guard !counted.contains(key), seen[key] == nil else { return }
            counted.append(key)
            if counted.count > 64 { counted.removeFirst() }
            seen[key] = date
        }
        func int(_ key: String, _ dict: [String: Any] = usage) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        let input = int("input_tokens"), output = int("output_tokens"), read = int("cache_read_input_tokens")
        let write = int("cache_creation_input_tokens")
        var write1h = 0
        if let detail = usage["cache_creation"] as? [String: Any] { write1h = min(write, int("ephemeral_1h_input_tokens", detail)) }
        let model = message["model"] as? String ?? ""
        let cost = ModelPricing.costMicros(model: model, input: input, output: output, cacheWrite5m: write - write1h,
                                           cacheWrite1h: write1h, cacheRead: read)
        let slot = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / Self.slot).rounded(.down) * Self.slot)
        slots[slot, default: UsageTotals()] += UsageTotals(input: input, output: output, cacheWrite: write, cacheRead: read,
                                                          costMicros: cost, messages: 1)
    }

    public mutating func prune(before cutoff: Date) {
        slots = slots.filter { $0.key >= cutoff.addingTimeInterval(-Self.slot) }
    }
}

/// Every transcript of the deck's projects, read incrementally; usage by project and slot.
public struct ProjectUsageScanner: Sendable {
    public struct Source: Sendable, Equatable {
        public var path: String
        public var project: UUID
        public init(path: String, project: UUID) {
            self.path = path
            self.project = project
        }
    }

    private var files: [String: (project: UUID, usage: TranscriptUsage)] = [:]
    private var seen: [String: Date] = [:]

    public init() {}

    /// Reads what the sources gained (files not modified since `since` are skipped until they are).
    public mutating func refresh(_ sources: [Source], since: Date, tailBytes: Int = 64 << 20) -> [UUID: [Date: UsageTotals]] {
        var result: [UUID: [Date: UsageTotals]] = [:]
        let wanted = Set(sources.map(\.path))
        files = files.filter { wanted.contains($0.key) }
        seen = seen.filter { $0.value >= since.addingTimeInterval(-86400) }
        for source in sources {
            let url = URL(fileURLWithPath: source.path)
            if files[source.path] == nil {
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= since else { continue }
                files[source.path] = (source.project, TranscriptUsage())
            }
            files[source.path]?.project = source.project
            if files[source.path]?.usage.read(url, since: since, seen: &seen, tailBytes: tailBytes) == false {
                files[source.path]?.usage = TranscriptUsage()
                _ = files[source.path]?.usage.read(url, since: since, seen: &seen, tailBytes: tailBytes)
            }
            files[source.path]?.usage.prune(before: since)
            guard let entry = files[source.path] else { continue }
            for (slot, totals) in entry.usage.slots { result[entry.project, default: [:]][slot, default: UsageTotals()] += totals }
        }
        return result
    }

    // MARK: Sources

    /// Claude Code's folder name for a working directory (`/a/b.c` → `-a-b-c`).
    public static func folderName(for path: String) -> String {
        Transcript.projectDirectoryName(for: path)
    }

    /// The project a transcript folder belongs to: the longest project path whose folder name is
    /// the folder's, or a prefix of it at a `-` (worktrees and subfolders of the project).
    public static func project(forFolder folder: String, projects: [(id: UUID, path: String)]) -> UUID? {
        var best: (UUID, Int)?
        for project in projects {
            let name = folderName(for: project.path)
            guard folder == name || folder.hasPrefix(name + "-") else { continue }
            if best == nil || name.count > best!.1 { best = (project.id, name.count) }
        }
        return best?.0
    }

    /// Every `.jsonl` modified since `since` in the projects' folders under `root`
    /// (`~/.claude/projects`), sub-agents' transcripts included, plus `extra` (sessions' own
    /// transcripts wherever they are). One entry per file.
    public static func sources(root: URL, projects: [(id: UUID, path: String)], extra: [Source], since: Date,
                               fileManager: FileManager = .default) -> [Source] {
        var result: [String: UUID] = [:]
        for source in extra { result[source.path] = source.project }
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            guard let project = project(forFolder: folder.lastPathComponent, projects: projects) else { continue }
            guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified >= since else { continue }
                if result[file.path] == nil { result[file.path] = project }
            }
        }
        return result.map { Source(path: $0.key, project: $0.value) }.sorted { $0.path < $1.path }
    }
}

/// One project's usage in the 5-hour and weekly windows.
public struct ProjectUsageShare: Codable, Sendable, Equatable, Identifiable {
    public var projectID: UUID
    public var name: String
    public var fiveHour: UsageTotals
    public var week: UsageTotals
    /// Share of the tracked cost in the window, 0–1.
    public var fiveHourShare: Double
    public var weekShare: Double
    /// That share of the plan's window percent (nil when the plan's usage isn't known).
    public var fiveHourPercent: Double?
    public var weekPercent: Double?
    public var id: UUID { projectID }

    public init(projectID: UUID, name: String, fiveHour: UsageTotals, week: UsageTotals, fiveHourShare: Double, weekShare: Double,
                fiveHourPercent: Double?, weekPercent: Double?) {
        self.projectID = projectID
        self.name = name
        self.fiveHour = fiveHour
        self.week = week
        self.fiveHourShare = fiveHourShare
        self.weekShare = weekShare
        self.fiveHourPercent = fiveHourPercent
        self.weekPercent = weekPercent
    }
}

public enum ProjectUsageReport {
    public static let fiveHours: TimeInterval = 5 * 3600
    public static let week: TimeInterval = 7 * 86400

    /// Where a window starts: its reset minus its length, else `length` before now.
    public static func windowStart(resetsAt: Date?, length: TimeInterval, now: Date) -> Date {
        guard let resetsAt, resetsAt > now, resetsAt.timeIntervalSince(now) <= length else { return now.addingTimeInterval(-length) }
        return resetsAt.addingTimeInterval(-length)
    }

    /// The shares, biggest weekly cost first; projects with nothing in the week are left out.
    public static func make(_ slots: [UUID: [Date: UsageTotals]], names: [UUID: String], usage: ClaudeUsage?, now: Date) -> [ProjectUsageShare] {
        let fiveStart = windowStart(resetsAt: usage?.fiveHour?.resetsAt, length: fiveHours, now: now)
        let weekStart = windowStart(resetsAt: usage?.sevenDay?.resetsAt, length: week, now: now)
        var rows: [(UUID, UsageTotals, UsageTotals)] = []
        for (project, bySlot) in slots {
            var five = UsageTotals(), seven = UsageTotals()
            for (slot, totals) in bySlot {
                // A slot counts when it ends after the window began.
                if slot.addingTimeInterval(TranscriptUsage.slot) > fiveStart { five += totals }
                if slot.addingTimeInterval(TranscriptUsage.slot) > weekStart { seven += totals }
            }
            if seven.messages > 0 || five.messages > 0 { rows.append((project, five, seven)) }
        }
        let fiveTotal = rows.reduce(Int64(0)) { $0 + $1.1.costMicros }
        let weekTotal = rows.reduce(Int64(0)) { $0 + $1.2.costMicros }
        func share(_ part: Int64, _ total: Int64) -> Double { total > 0 ? Double(part) / Double(total) : 0 }
        return rows.map { project, five, seven in
            let fs = share(five.costMicros, fiveTotal), ws = share(seven.costMicros, weekTotal)
            return ProjectUsageShare(projectID: project, name: names[project] ?? "?", fiveHour: five, week: seven,
                                     fiveHourShare: fs, weekShare: ws,
                                     fiveHourPercent: usage?.fiveHour.map { $0.usedPercent * fs },
                                     weekPercent: usage?.sevenDay.map { $0.usedPercent * ws })
        }
        .sorted { ($0.week.costMicros, $0.fiveHour.costMicros, $0.name) > ($1.week.costMicros, $1.fiveHour.costMicros, $1.name) }
    }

    /// "1.2M", "48k", "950".
    public static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 10_000...: "\(n / 1000)k"
        case 1_000...: String(format: "%.1fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    public static func text(_ shares: [ProjectUsageShare], usage: ClaudeUsage?) -> String {
        guard !shares.isEmpty else { return "no usage in the transcripts of this week" }
        func pct(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "-" }
        let rows = shares.map { s in
            [s.name, pct(s.fiveHourPercent), String(format: "%.0f%%", s.fiveHourShare * 100), compact(s.fiveHour.tokens),
             pct(s.weekPercent), String(format: "%.0f%%", s.weekShare * 100), compact(s.week.tokens), String(format: "$%.2f", s.week.cost)]
        }
        var lines = SessionCLI.table([["PROJECT", "5H", "5H SHARE", "5H TOKENS", "WEEK", "WEEK SHARE", "WEEK TOKENS", "WEEK COST"]] + rows)
        if let usage {
            let five = usage.fiveHour.map { String(format: "%.0f%%", $0.usedPercent) } ?? "-"
            let week = usage.sevenDay.map { String(format: "%.0f%%", $0.usedPercent) } ?? "-"
            lines += "\nplan: 5 hours \(five), week \(week); a project's percent is its share of the tracked cost in that window"
        } else {
            lines += "\nthe plan's usage isn't known (sign in to Claude Code); shares are of the tracked cost"
        }
        return lines + "\ncost: estimated at API prices (an estimate, not a bill)"
    }
}

/// `GET /v1/cli/usage`.
public struct SessionCLIUsage: Encodable, Sendable, Equatable {
    public var fiveHourPercent: Double?
    public var fiveHourResetsAt: Date?
    public var weekPercent: Double?
    public var weekResetsAt: Date?
    public var projects: [ProjectUsageShare]

    public init(usage: ClaudeUsage?, projects: [ProjectUsageShare]) {
        fiveHourPercent = usage?.fiveHour?.usedPercent
        fiveHourResetsAt = usage?.fiveHour?.resetsAt
        weekPercent = usage?.sevenDay?.usedPercent
        weekResetsAt = usage?.sevenDay?.resetsAt
        self.projects = projects
    }
}
