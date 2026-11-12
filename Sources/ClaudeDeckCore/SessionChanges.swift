import Foundation

// What Claude changed in a session's files, read from its transcript: one change per Edit /
// Write / MultiEdit call that went through, as the patch Claude Code logged for it. Bash-made
// changes aren't in the transcript as patches and don't show.

/// One file change made by a Claude tool call.
public struct FileChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case created, updated }

    /// The tool call's id.
    public var id: String
    /// "Edit", "Write" or "MultiEdit".
    public var tool: String
    /// Absolute path of the changed file.
    public var path: String
    public var kind: Kind
    public var date: Date?
    public var hunks: [DiffHunk]

    public init(id: String, tool: String, path: String, kind: Kind, date: Date? = nil, hunks: [DiffHunk]) {
        self.id = id
        self.tool = tool
        self.path = path
        self.kind = kind
        self.date = date
        self.hunks = hunks
    }

    public var added: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }
    /// The lines of the file (as it is after the change) that the change touched.
    public var lineRange: ClosedRange<Int>? { SessionChanges.lineRange(of: hunks.flatMap(\.lines)) }
}

/// Every file a session changed, in the order Claude first touched them.
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    /// Indexes into `SessionChanges.all`, oldest first.
    public var changes: [Int]
    /// The file before Claude's first change ("" when Claude created it); nil when unknown.
    public var original: String?
    /// The file after Claude's last change, as far as the transcript tells; nil when unknown.
    public var current: String?
}

/// The changes of one transcript: built a line at a time by `ConversationLog.Reader` (with
/// `collectsChanges`), so a live session only adds what it appended.
public struct SessionChanges: Sendable, Equatable {
    public private(set) var all: [FileChange] = []
    public private(set) var files: [ChangedFile] = []
    private var fileIndex: [String: Int] = [:]

    public init() {}

    /// The changes made to the file at `path`, oldest first.
    public func changes(of path: String) -> [FileChange] {
        guard let index = fileIndex[path] else { return [] }
        return files[index].changes.map { all[$0] }
    }

    /// Adds a change from a tool result's `toolUseResult` (a string for a failed or rejected
    /// call: skipped, as is anything that isn't a file patch).
    mutating func record(toolUseID: String, tool: String, result: Any?, date: Date?) {
        guard let result = result as? [String: Any], let path = result["filePath"] as? String,
              let patch = result["structuredPatch"] as? [[String: Any]] else { return }
        let original = result["originalFile"] as? String ?? result["originalFileContents"] as? String
        let content = result["content"] as? String
        let created = result["type"] as? String == "create"
        var hunks = patch.compactMap(Self.hunk)
        // A new file is logged without a patch: all of it is added.
        if hunks.isEmpty, created, let content {
            hunks = Self.addedHunk(content).map { [$0] } ?? []
        }
        guard !hunks.isEmpty else { return }

        let change = FileChange(id: toolUseID, tool: tool, path: path, kind: created ? .created : .updated, date: date, hunks: hunks)
        let before = created ? "" : original
        if let index = fileIndex[path] {
            // Claude's changes build on each other, unless the file changed in between (then the
            // logged original says so).
            let base = before ?? files[index].current
            files[index].current = Self.after(change, base: base, content: content)
            files[index].changes.append(all.count)
        } else {
            fileIndex[path] = files.count
            files.append(ChangedFile(path: path, changes: [all.count], original: before,
                                     current: Self.after(change, base: before, content: content)))
        }
        all.append(change)
    }

    /// The file's content after `change`: a Write logs it whole, an Edit's patch applies to the
    /// content before it.
    static func after(_ change: FileChange, base: String?, content: String?) -> String? {
        if change.tool == "Write", let content { return content }
        return base.flatMap { apply(change.hunks, to: $0) }
    }

    /// One `structuredPatch` hunk ({oldStart, oldLines, newStart, newLines, lines}), its lines
    /// numbered like a git diff's.
    static func hunk(_ object: [String: Any]) -> DiffHunk? {
        guard let oldStart = object["oldStart"] as? Int, let newStart = object["newStart"] as? Int,
              let lines = object["lines"] as? [String] else { return nil }
        let oldCount = object["oldLines"] as? Int ?? 0
        let newCount = object["newLines"] as? Int ?? 0
        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        var hunk = DiffHunk(header: header, oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                            lines: [], raw: [header] + lines)
        var oldNo = oldStart, newNo = newStart
        for line in lines {
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                hunk.lines.append(DiffLine(kind: .added, text: body, oldLine: nil, newLine: newNo))
                newNo += 1
            case "-":
                hunk.lines.append(DiffLine(kind: .removed, text: body, oldLine: oldNo, newLine: nil))
                oldNo += 1
            case "\\":
                hunk.lines.append(DiffLine(kind: .noNewline, text: line, oldLine: nil, newLine: nil))
            default:
                hunk.lines.append(DiffLine(kind: .context, text: body, oldLine: oldNo, newLine: newNo))
                oldNo += 1; newNo += 1
            }
        }
        return hunk
    }

    /// A hunk adding all of `content` to an empty file.
    static func addedHunk(_ content: String) -> DiffHunk? {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let header = "@@ -0,0 +1,\(lines.count) @@"
        return DiffHunk(header: header, oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count,
                        lines: lines.enumerated().map { DiffLine(kind: .added, text: $1, oldLine: nil, newLine: $0 + 1) },
                        raw: [header] + lines.map { "+" + $0 })
    }

    /// `text` with the hunks applied, or nil when their context doesn't match it.
    static func apply(_ hunks: [DiffHunk], to text: String) -> String? {
        let old = text.components(separatedBy: "\n")
        var out: [String] = []
        var next = 0 // index into `old`
        for hunk in hunks {
            // Claude Code numbers a hunk from its first line even when its old side is empty
            // (unlike a unified diff's header, which then names the line before).
            let start = max(0, hunk.oldStart - 1)
            guard start >= next, start <= old.count else { return nil }
            out += old[next..<start]
            next = start
            for line in hunk.lines {
                switch line.kind {
                case .added:
                    out.append(line.text)
                case .removed, .context:
                    guard next < old.count, old[next] == line.text else { return nil }
                    if line.kind == .context { out.append(line.text) }
                    next += 1
                case .noNewline:
                    break
                }
            }
        }
        out += old[next...]
        return out.joined(separator: "\n")
    }

    /// The new-side lines a run of diff lines touches: added lines where they are, removed ones
    /// where they were (the line now in their place). Context-only: nil.
    public static func lineRange(of lines: [DiffLine]) -> ClosedRange<Int>? {
        var low = Int.max, high = Int.min
        var cursor: Int?
        for line in lines {
            switch line.kind {
            case .added:
                if let n = line.newLine { low = min(low, n); high = max(high, n); cursor = n + 1 }
            case .context:
                if let n = line.newLine { cursor = n + 1 }
            case .removed:
                let n = max(1, cursor ?? line.oldLine ?? 1)
                low = min(low, n); high = max(high, n)
            case .noNewline:
                break
            }
        }
        return low <= high ? low...high : nil
    }

    // MARK: Net diff

    /// The whole of a file's change, from its first original to its current content, in hunks
    /// with `context` lines around each change.
    public static func netDiff(from original: String, to current: String, context: Int = 3) -> [DiffHunk] {
        func split(_ text: String) -> [String] {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let old = split(original), new = split(current)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Every line in order, removals before insertions at the same spot.
        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append(DiffLine(kind: .removed, text: old[i], oldLine: i + 1, newLine: nil)); i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append(DiffLine(kind: .added, text: new[j], oldLine: nil, newLine: j + 1)); j += 1
            } else if i < old.count, j < new.count {
                lines.append(DiffLine(kind: .context, text: old[i], oldLine: i + 1, newLine: j + 1)); i += 1; j += 1
            } else {
                break // not reached: unchanged lines are on both sides
            }
        }
        // Group the changed lines with their context; groups closer than 2×context merge.
        let changed = lines.indices.filter { lines[$0].kind != .context }
        var groups: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = groups.last, range.lowerBound <= last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                groups.append(range)
            }
        }
        return groups.map { range in
            let body = Array(lines[range])
            let oldLines = body.compactMap(\.oldLine), newLines = body.compactMap(\.newLine)
            // An empty side's start is the line before the hunk (git's convention).
            let oldStart = oldLines.first ?? (lines[..<range.lowerBound].last { $0.oldLine != nil }?.oldLine ?? 0)
            let newStart = newLines.first ?? (lines[..<range.lowerBound].last { $0.newLine != nil }?.newLine ?? 0)
            let header = "@@ -\(oldStart),\(oldLines.count) +\(newStart),\(newLines.count) @@"
            let raw = body.map { line in
                switch line.kind {
                case .added: "+" + line.text
                case .removed: "-" + line.text
                default: " " + line.text
                }
            }
            return DiffHunk(header: header, oldStart: oldStart, oldCount: oldLines.count, newStart: newStart, newCount: newLines.count,
                            lines: body, raw: [header] + raw)
        }
    }

    // MARK: Messages about a change

    /// `@Sources/App.swift#L120-134`: the file relative to the session's folder (absolute when
    /// outside it) with the lines, in the form the app's other "ask Claude" actions use.
    public static func mention(path: String, root: String, lines: ClosedRange<Int>?) -> String {
        // As FileListing.relativePath, which the phone's build doesn't have.
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let relative = filePath.hasPrefix(rootPath + "/") ? String(filePath.dropFirst(rootPath.count + 1)) : filePath
        guard let lines else { return "@" + relative }
        return "@" + relative + (lines.count == 1 ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-\(lines.upperBound)")
    }

    /// The message for Claude about some changed lines: the reference, the lines as a diff
    /// snippet (at most `maxLines`), then what the user wrote.
    public static func message(path: String, root: String, lines: [DiffLine], text: String, maxLines: Int = 40) -> String {
        let reference = mention(path: path, root: root, lines: lineRange(of: lines) ?? contextRange(lines))
        let shown = lines.filter { $0.kind != .noNewline }
        var snippet = shown.prefix(maxLines).map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            default: " " + line.text
            }
        }
        if shown.count > maxLines { snippet.append("… (\(shown.count - maxLines) more lines)") }
        var parts = [reference]
        if !snippet.isEmpty { parts.append("```diff\n" + snippet.joined(separator: "\n") + "\n```") }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "\n")
    }

    /// Lines picked without a change among them: their own new-side numbers.
    private static func contextRange(_ lines: [DiffLine]) -> ClosedRange<Int>? {
        let numbers = lines.compactMap(\.newLine)
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        return low...high
    }
}

/// Keeps a transcript's changes current for a view that polls: each poll reads only what was
/// appended (the reader stays here, so it's never copied), and reports changes only when there
/// are new ones.
public actor SessionChangesTracker {
    private let url: URL
    private let tailBytes: Int
    private var reader = ConversationLog.Reader(collectsChanges: true)
    private var reported: Int?

    /// `tailBytes`: how much of a long transcript to read at first (patches carry whole files,
    /// so transcripts with many edits grow fast).
    public init(transcriptURL: URL, tailBytes: Int = 64 << 20) {
        url = transcriptURL
        self.tailBytes = tailBytes
    }

    /// The changes last reported (nil before the first poll): what a view shown again starts from.
    public var latest: SessionChanges? { reported == nil ? nil : reader.changes }

    /// The changes when they differ from the last ones reported, else nil.
    public func poll() -> SessionChanges? {
        // Shorter than what was read: rewritten, read it again.
        if !reader.read(url, tailBytes: tailBytes) {
            reader = ConversationLog.Reader(collectsChanges: true)
            reported = nil
            _ = reader.read(url, tailBytes: tailBytes)
        }
        // Changes only ever add up, so their count tells whether there's something new.
        guard reported != reader.changes.all.count else { return nil }
        reported = reader.changes.all.count
        return reader.changes
    }
}
