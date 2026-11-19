import Foundation

// A project's agenda: `docs/AGENDA.md` with a markdown table of work items (id, track, owner,
// status, depends-on, evidence), shown as a board grouped by status on the Mac and the phone.
// Read-only: the file is the source of truth, agents edit it.

public enum AgendaStatus: String, Codable, Sendable, CaseIterable {
    case todo, doing, review, blocked, done

    /// A status cell as people write it ("In progress", "**Done** ✅", "to-do"); nil when it's
    /// none of them.
    public init?(cell: String) {
        let words = cell.lowercased().filter { $0.isLetter || $0 == " " || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        switch words {
        case "todo", "to do", "open", "pending", "backlog", "planned", "not started", "new", "next": self = .todo
        case "doing", "in progress", "wip", "active", "started", "working", "ongoing", "progress": self = .doing
        case "review", "in review", "reviewing", "needs review", "pr", "qa", "testing", "verify": self = .review
        case "blocked", "on hold", "waiting", "stuck": self = .blocked
        case "done", "complete", "completed", "closed", "finished", "shipped", "merged", "resolved": self = .done
        default:
            if cell.contains("✅") || cell.contains("✔") { self = .done } else { return nil }
        }
    }
}

/// One row of the table.
public struct AgendaItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// A title/task/description column when the table has one.
    public var title: String?
    public var track: String?
    public var owner: String?
    /// The status cell as written.
    public var statusText: String
    /// nil: not a status the board knows (shown under "Other").
    public var status: AgendaStatus?
    public var dependsOn: [String]
    public var evidence: String?

    public init(id: String, title: String? = nil, track: String? = nil, owner: String? = nil, statusText: String,
                status: AgendaStatus?, dependsOn: [String] = [], evidence: String? = nil) {
        self.id = id
        self.title = title
        self.track = track
        self.owner = owner
        self.statusText = statusText
        self.status = status
        self.dependsOn = dependsOn
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, track, owner, statusText, status, dependsOn, evidence
    }

    /// Tolerant: a status a newer version knows reads as nil ("Other").
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        track = try? c.decodeIfPresent(String.self, forKey: .track)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        statusText = (try? c.decodeIfPresent(String.self, forKey: .statusText)) ?? ""
        status = try? c.decodeIfPresent(AgendaStatus.self, forKey: .status)
        dependsOn = (try? c.decodeIfPresent([String].self, forKey: .dependsOn)) ?? []
        evidence = try? c.decodeIfPresent(String.self, forKey: .evidence)
    }
}

public struct AgendaBoard: Codable, Sendable, Equatable {
    public var items: [AgendaItem]

    public init(items: [AgendaItem]) {
        self.items = items
    }

    /// `docs/AGENDA.md` in a project folder.
    public static let relativePath = "docs/AGENDA.md"
    /// Larger files aren't read.
    public static let maxFileSize = 1 << 20
    /// Rows kept (a remote gets as many).
    public static let maxItems = 500
    /// Characters per cell.
    public static let maxCell = 500

    /// The columns, in board order: what's moving first, done last; "Other" (nil) only when used.
    public var columns: [(status: AgendaStatus?, items: [AgendaItem])] {
        var out: [(status: AgendaStatus?, items: [AgendaItem])] = [AgendaStatus.todo, .doing, .review, .blocked, .done].map { status in
            (status: status, items: items.filter { $0.status == status })
        }
        let other = items.filter { $0.status == nil }
        if !other.isEmpty { out.append((status: nil, items: other)) }
        return out
    }

    public func count(_ status: AgendaStatus) -> Int { items.reduce(0) { $0 + ($1.status == status ? 1 : 0) } }

    // MARK: Parsing

    /// Which column a header names (case, spaces and punctuation don't matter; nil: ignored).
    enum Column: Equatable {
        case id, title, track, owner, status, dependsOn, evidence
    }

    static func column(_ header: String) -> Column? {
        let raw = header.trimmingCharacters(in: .whitespaces)
        if raw == "#" { return .id }
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "id", "key", "ref", "no", "nr": return .id
        case "title", "task", "item", "name", "description", "summary", "what", "work", "goal", "deliverable": return .title
        case "track", "lane", "stream", "area", "epic", "workstream", "phase": return .track
        case "owner", "agent", "owneragent", "assignee", "who", "session", "agentowner": return .owner
        case "status", "state": return .status
        case "dependson", "depends", "deps", "dependencies", "dependency", "blockedby", "after", "needs": return .dependsOn
        case "evidence", "proof", "links", "link", "artifacts", "result", "results": return .evidence
        default:
            if key.hasPrefix("owner") { return .owner }
            if key.hasPrefix("depend") { return .dependsOn }
            if key.hasPrefix("evidence") { return .evidence }
            if key.hasPrefix("status") { return .status }
            return nil
        }
    }

    /// The rows of every table in `markdown` whose header has an id and a status column (other
    /// tables are skipped). Columns may come in any order; unknown ones are ignored; a row with
    /// fewer cells leaves the rest empty. nil when there's no such table.
    public static func parse(_ markdown: String) -> AgendaBoard? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        var items: [AgendaItem] = []
        var found = false
        var index = 0
        var inFence = false
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); index += 1; continue }
            guard !inFence, index + 1 < lines.count, line.contains("|"), isSeparator(lines[index + 1]) else { index += 1; continue }
            let headers = cells(line).map(column)
            guard headers.contains(.id), headers.contains(.status) else { index += 2; continue }
            found = true
            index += 2
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                guard !row.isEmpty, row.contains("|") else { break }
                index += 1
                if let item = item(cells(row), headers: headers), items.count < maxItems { items.append(item) }
            }
        }
        return found ? AgendaBoard(items: items) : nil
    }

    static func item(_ cells: [String], headers: [Column?]) -> AgendaItem? {
        var values: [Column: String] = [:]
        for (index, column) in headers.enumerated() {
            guard let column, values[column] == nil else { continue }
            values[column] = index < cells.count ? clean(cells[index]) : ""
        }
        guard let id = values[.id], !id.isEmpty else { return nil }
        func optional(_ column: Column) -> String? { values[column].flatMap { $0.isEmpty || isNone($0) ? nil : $0 } }
        let statusText = values[.status] ?? ""
        return AgendaItem(id: id, title: optional(.title), track: optional(.track), owner: optional(.owner),
                          statusText: statusText, status: AgendaStatus(cell: statusText),
                          dependsOn: dependencies(values[.dependsOn] ?? ""), evidence: optional(.evidence))
    }

    /// "A1, A2", "A1 A2", "A1; A2", "[A1](#a1)", "—", "none".
    static func dependencies(_ cell: String) -> [String] {
        guard !isNone(cell) else { return [] }
        return cell.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "/" })
            .map { part in
                var text = String(part).trimmingCharacters(in: .whitespaces)
                // A markdown link's text.
                if text.hasPrefix("["), let close = text.firstIndex(of: "]") { text = String(text[text.index(after: text.startIndex)..<close]) }
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "`*_#()[] "))
            }
            .filter { !$0.isEmpty && !isNone($0) && $0.lowercased() != "and" }
    }

    static func isNone(_ text: String) -> Bool {
        ["", "-", "–", "—", "none", "n/a", "na", "nil", "null"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Bold, code and surrounding space off; at most `maxCell` characters.
    static func clean(_ cell: String) -> String {
        var text = cell.trimmingCharacters(in: .whitespaces)
        for mark in ["**", "__", "`"] where text.hasPrefix(mark) && text.hasSuffix(mark) && text.count >= mark.count * 2 {
            text = String(text.dropFirst(mark.count).dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "<br>", with: " ").replacingOccurrences(of: "<br/>", with: " ")
        return text.count > maxCell ? String(text.prefix(maxCell)) + "…" : text
    }

    /// A row's cells: split at unescaped pipes (`\|` stays a pipe), outer pipes dropped.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\")
                if character != "|" { current.append(character) }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// `|---|:--:|`, `--- | ---`.
    static func isSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return false }
        return parts.allSatisfy { part in
            let core = part.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return core.count >= 1 && core.allSatisfy { $0 == "-" }
        }
    }
}

/// A project's board for a remote (`RemoteSnapshot.agendas`).
public struct RemoteAgenda: Codable, Sendable, Equatable, Identifiable {
    public var projectID: UUID
    public var project: String
    public var items: [AgendaItem]
    /// The file's modification time.
    public var updatedAt: Date?

    public var id: UUID { projectID }

    public init(projectID: UUID, project: String, items: [AgendaItem], updatedAt: Date?) {
        self.projectID = projectID
        self.project = project
        self.items = items
        self.updatedAt = updatedAt
    }

    public var board: AgendaBoard { AgendaBoard(items: items) }
}
