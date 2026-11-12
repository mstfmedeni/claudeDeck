import Foundation

// Claude's edits for a remote (the phone's Edits tab and the diffs in its conversation): the
// host reads them from the transcript (SessionChanges.swift) only when a remote asks, and sends
// them a page at a time, each change and page capped in lines.

/// One hunk on the wire: its numbers and its lines as in a patch (" ", "+", "-", "\" first).
public struct RemoteDiffHunk: Codable, Sendable, Equatable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [String]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    /// The hunk's first `maxLines` lines, each at most `RemoteEdits.maxLineLength` characters.
    init(_ hunk: DiffHunk, maxLines: Int) {
        oldStart = hunk.oldStart
        oldCount = hunk.oldCount
        newStart = hunk.newStart
        newCount = hunk.newCount
        lines = hunk.lines.prefix(maxLines).map { line in
            let text = line.text.count > RemoteEdits.maxLineLength ? String(line.text.prefix(RemoteEdits.maxLineLength)) + "…" : line.text
            switch line.kind {
            case .added: return "+" + text
            case .removed: return "-" + text
            case .noNewline: return text
            case .context: return " " + text
            }
        }
    }

    /// The hunk with its lines numbered (only the lines that came: a cut hunk numbers its start).
    public var hunk: DiffHunk? {
        SessionChanges.hunk(["oldStart": oldStart, "oldLines": oldCount, "newStart": newStart, "newLines": newCount, "lines": lines])
    }
}

/// One change of `SessionChanges.all` on the wire.
public struct RemoteFileChange: Codable, Sendable, Equatable, Identifiable {
    /// The tool call's id (the conversation's tool entry has the same).
    public var id: String
    public var tool: String
    public var path: String
    public var created: Bool
    public var date: Date?
    public var hunks: [RemoteDiffHunk]
    /// The whole change's counts and lines, also when `omitted` lines didn't come.
    public var added: Int
    public var removed: Int
    public var firstLine: Int?
    public var lastLine: Int?
    /// Diff lines left out: the change is longer than a remote is sent.
    public var omitted: Int

    public init(_ change: FileChange, maxLines: Int) {
        id = change.id
        tool = change.tool
        path = change.path
        created = change.kind == .created
        date = change.date
        added = change.added
        removed = change.removed
        firstLine = change.lineRange?.lowerBound
        lastLine = change.lineRange?.upperBound
        let cut = RemoteEdits.cut(change.hunks, maxLines: maxLines)
        hunks = cut.hunks
        omitted = cut.omitted
    }

    public var lineRange: ClosedRange<Int>? {
        guard let firstLine, let lastLine, firstLine <= lastLine else { return nil }
        return firstLine...lastLine
    }

    /// The hunks with numbered lines.
    public var diffHunks: [DiffHunk] { hunks.compactMap(\.hunk) }
}

/// A page of a session's edits. `after` echoes the request; `reset`: the page starts from the
/// first change and replaces what the remote has (first request, or the anchor is gone: a new
/// transcript after /clear).
public struct RemoteEditsPage: Codable, Sendable, Equatable {
    public var changes: [RemoteFileChange]
    public var reset: Bool
    public var after: String?
    /// More changes follow the page: ask again after its last one.
    public var hasMore: Bool
    /// The session's folder: paths are shown and mentioned relative to it.
    public var root: String?

    public init(changes: [RemoteFileChange], reset: Bool, after: String? = nil, hasMore: Bool = false, root: String? = nil) {
        self.changes = changes
        self.reset = reset
        self.after = after
        self.hasMore = hasMore
        self.root = root
    }
}

/// A file's net diff (first original to current content) on the wire; nil hunks: not available
/// (the transcript doesn't have the file's whole content).
public struct RemoteNetDiff: Codable, Sendable, Equatable {
    public var hunks: [RemoteDiffHunk]?
    public var omitted: Int
    /// How many changes of the file it covers: a remote asks again when the file has more.
    public var changes: Int

    public init(hunks: [RemoteDiffHunk]?, omitted: Int = 0, changes: Int) {
        self.hunks = hunks
        self.omitted = omitted
        self.changes = changes
    }
}

public enum RemoteEdits {
    /// Diff lines sent per change (a new file is all lines) and per page; at least one change
    /// goes in each page.
    public static let maxLinesPerChange = 300
    public static let maxLinesPerPage = 2_000
    /// A net diff's lines.
    public static let maxNetLines = 1_500
    /// Characters per line (a minified file is one huge line).
    public static let maxLineLength = 1_000

    /// The page answering a request for the changes after `after`.
    public static func page(_ changes: SessionChanges, after: String?, root: String?,
                            maxLinesPerChange: Int = maxLinesPerChange, maxLinesPerPage: Int = maxLinesPerPage) -> RemoteEditsPage {
        var start = 0
        var reset = true
        if let after, let index = changes.all.firstIndex(where: { $0.id == after }) {
            start = index + 1
            reset = false
        }
        var sent: [RemoteFileChange] = []
        var lines = 0
        var index = start
        while index < changes.all.count {
            let change = RemoteFileChange(changes.all[index], maxLines: maxLinesPerChange)
            let count = change.hunks.reduce(0) { $0 + $1.lines.count }
            if !sent.isEmpty, lines + count > maxLinesPerPage { break }
            sent.append(change)
            lines += count
            index += 1
        }
        return RemoteEditsPage(changes: sent, reset: reset, after: reset ? nil : after, hasMore: index < changes.all.count, root: root)
    }

    /// The net diff of the file at `path` (nil hunks when it can't be worked out).
    public static func netDiff(_ changes: SessionChanges, path: String, maxLines: Int = maxNetLines) -> RemoteNetDiff {
        guard let file = changes.files.first(where: { $0.path == path }) else { return RemoteNetDiff(hunks: nil, changes: 0) }
        guard let original = file.original, let current = file.current else { return RemoteNetDiff(hunks: nil, changes: file.changes.count) }
        let cut = cut(SessionChanges.netDiff(from: original, to: current), maxLines: maxLines)
        return RemoteNetDiff(hunks: cut.hunks, omitted: cut.omitted, changes: file.changes.count)
    }

    /// The hunks' first `maxLines` lines (whole hunks while they fit, then part of one).
    static func cut(_ hunks: [DiffHunk], maxLines: Int) -> (hunks: [RemoteDiffHunk], omitted: Int) {
        var out: [RemoteDiffHunk] = []
        var left = maxLines
        var omitted = 0
        for hunk in hunks {
            if left <= 0 {
                omitted += hunk.lines.count
                continue
            }
            out.append(RemoteDiffHunk(hunk, maxLines: left))
            omitted += max(0, hunk.lines.count - left)
            left -= hunk.lines.count
        }
        return (out, omitted)
    }
}

/// A remote's copy of a session's edits, filled a page at a time.
public struct RemoteEditsState: Sendable, Equatable {
    public private(set) var changes: [RemoteFileChange] = []
    private var index: [String: Int] = [:]
    /// The changes' hunks with numbered lines, by change (worked out once, as pages come).
    private var numbered: [String: [DiffHunk]] = [:]
    public private(set) var root: String?
    /// Something came from the host (maybe nothing changed yet).
    public private(set) var loaded = false
    /// The host has more after the last page: ask again.
    public private(set) var hasMore = false
    /// Net diffs by path, as last sent.
    public var netDiffs: [String: RemoteNetDiff] = [:]

    public init() {}

    public func change(_ id: String) -> RemoteFileChange? { index[id].map { changes[$0] } }

    /// A change's hunks with numbered lines.
    public func hunks(_ id: String) -> [DiffHunk] { numbered[id] ?? [] }

    /// The anchor of the next request: the last change here.
    public var lastID: String? { changes.last?.id }

    /// Adds a page. False when it doesn't fit (asked after a change that is no longer the last):
    /// drop it, the next request asks again.
    @discardableResult
    public mutating func merge(_ page: RemoteEditsPage) -> Bool {
        if page.reset {
            changes = []
            index = [:]
            numbered = [:]
            netDiffs = [:]
        } else if page.after != lastID {
            return false
        }
        for change in page.changes {
            numbered[change.id] = change.diffHunks
            if let at = index[change.id] {
                changes[at] = change
            } else {
                index[change.id] = changes.count
                changes.append(change)
            }
        }
        if let root = page.root { self.root = root }
        hasMore = page.hasMore
        loaded = true
        return true
    }

    /// Changed files in the order they were first touched, each with its changes (oldest first).
    public var files: [(path: String, changes: [RemoteFileChange])] {
        var order: [String] = []
        var byPath: [String: [RemoteFileChange]] = [:]
        for change in changes {
            if byPath[change.path] == nil { order.append(change.path) }
            byPath[change.path, default: []].append(change)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }
}
