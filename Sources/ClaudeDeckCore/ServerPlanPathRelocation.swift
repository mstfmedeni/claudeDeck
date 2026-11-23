import Foundation

/// ServerPlan's stored local paths following a moved folder: `POST /paths/relocate`
/// (`{old_prefix, new_prefix, dry_run, confirm}`; `/me` lists the `paths_relocate` feature).
/// It rewrites projects.path, project_dirs.path / local_path and domains.local_sync_path that are
/// `old_prefix` or inside it (on path components), keeping every id. A real run without
/// `confirm` = the normalized old prefix answers 428 with a summary; 409 on a collision, or on a
/// real run when the new folder doesn't exist.
public enum ServerPlanPathRelocation {
    public static let feature = "paths_relocate"
    public static let path = "/paths/relocate"

    public enum PrefixProblem: Error, Equatable, Sendable {
        /// Not absolute, or `/`.
        case notAbsolute
        case same
        /// One inside the other.
        case nested

        public var code: String {
            switch self {
            case .notAbsolute: "bad_prefix"
            case .same: "same_prefix"
            case .nested: "nested_prefix"
            }
        }

        public var message: String {
            switch self {
            case .notAbsolute: "both prefixes must be absolute folder paths, not /"
            case .same: "the old and new prefix are the same"
            case .nested: "one prefix is inside the other"
            }
        }
    }

    /// An absolute path without `.`/`..`, duplicate or trailing `/` (what ServerPlan's
    /// filepath.Clean gives); nil for a relative path or `/`.
    public static func normalized(_ prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        guard !parts.isEmpty else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    /// Both prefixes, normalized, or why ServerPlan would refuse them (its 400 rules).
    public static func prefixes(_ old: String, _ new: String) -> Result<(old: String, new: String), PrefixProblem> {
        guard let old = normalized(old), let new = normalized(new) else { return .failure(.notAbsolute) }
        guard old != new else { return .failure(.same) }
        if ProjectFolderRename.moved(new, from: old, to: old) != nil || ProjectFolderRename.moved(old, from: new, to: new) != nil {
            return .failure(.nested)
        }
        return .success((old, new))
    }

    /// `path` with `old` swapped for `new` when it is `old` or inside it (whole path components:
    /// `/a/WhatsCode` never matches `/a/WhatsCode2`); nil otherwise.
    public static func relocated(_ path: String, from old: String, to new: String) -> String? {
        guard let old = normalized(old), let new = normalized(new), let path = normalized(path) else { return nil }
        return ProjectFolderRename.moved(path, from: old, to: new)
    }

    public static func body(old: String, new: String, dryRun: Bool, confirm: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["old_prefix": old, "new_prefix": new, "dry_run": dryRun]
        if let confirm { body["confirm"] = confirm }
        return body
    }

    // MARK: Answers

    /// One rewritten field.
    public struct Change: Codable, Sendable, Equatable {
        /// `projects`, `project_dirs` or `domains`.
        public var table: String
        public var id: String
        public var name: String?
        /// `path`, `local_path` or `local_sync_path`.
        public var field: String
        public var old: String
        public var new: String

        public init(table: String, id: String, name: String?, field: String, old: String, new: String) {
            self.table = table
            self.id = id
            self.name = name
            self.field = field
            self.old = old
            self.new = new
        }
    }

    /// ServerPlan's 200, read tolerantly: `changes` may come as one list or grouped by table, the
    /// count may be missing (then it's the list's length), ids may be numbers or strings.
    public struct Answer: Sendable, Equatable {
        public var dryRun: Bool
        public var oldPrefix: String?
        public var newPrefix: String?
        public var changes: [Change]
        public var count: Int
        public var skippedDeleted: Int
        public var warnings: [String]

        public init(dryRun: Bool, oldPrefix: String? = nil, newPrefix: String? = nil, changes: [Change] = [], count: Int? = nil,
                    skippedDeleted: Int = 0, warnings: [String] = []) {
            self.dryRun = dryRun
            self.oldPrefix = oldPrefix
            self.newPrefix = newPrefix
            self.changes = changes
            self.count = count ?? changes.count
            self.skippedDeleted = skippedDeleted
            self.warnings = warnings
        }

        public static func parse(_ data: Data, dryRun: Bool) -> Answer {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Answer(dryRun: dryRun) }
            var changes: [Change] = []
            func add(_ rows: Any?, table: String?) {
                for row in rows as? [[String: Any]] ?? [] {
                    let rowTable = string(row["table"]) ?? table ?? "?"
                    let old = string(row["old"]) ?? string(row["from"]) ?? string(row["old_path"]) ?? ""
                    let new = string(row["new"]) ?? string(row["to"]) ?? string(row["new_path"]) ?? ""
                    changes.append(Change(table: rowTable, id: string(row["id"]) ?? "?",
                                          name: string(row["name"]) ?? string(row["display_name"]) ?? string(row["fqdn"]),
                                          field: string(row["field"]) ?? "path", old: old, new: new))
                }
            }
            switch object["changes"] {
            case let grouped as [String: Any]:
                for key in grouped.keys.sorted() { add(grouped[key], table: key) }
            case let list:
                add(list, table: nil)
            }
            let count = int(object["count"]) ?? int(object["changed"])
            return Answer(dryRun: (object["dry_run"] as? Bool) ?? dryRun, oldPrefix: string(object["old_prefix"]),
                          newPrefix: string(object["new_prefix"]), changes: changes, count: count,
                          skippedDeleted: int(object["skipped_deleted"]) ?? 0,
                          warnings: (object["warnings"] as? [Any] ?? []).compactMap(string))
        }

        public var text: String {
            let head = (dryRun ? "would change" : "changed") + " \(count) path(s)"
                + (oldPrefix.map { " under \($0)" } ?? "") + (newPrefix.map { " → \($0)" } ?? "")
                + (skippedDeleted > 0 ? " (\(skippedDeleted) deleted row(s) left alone)" : "")
            let rows = changes.map { "  \($0.table) #\($0.id)" + ($0.name.map { " \($0)" } ?? "") + " \($0.field): \($0.old) → \($0.new)" }
            return ([head] + rows + warnings.map { "  warning: \($0)" }).joined(separator: "\n")
        }

        public var json: Data {
            var object: [String: Any] = ["dry_run": dryRun, "count": count, "skipped_deleted": skippedDeleted, "warnings": warnings,
                                         "changes": changes.map { change -> [String: Any] in
                                             ["table": change.table, "id": change.id, "name": change.name ?? NSNull(), "field": change.field,
                                              "old": change.old, "new": change.new]
                                         }]
            if let oldPrefix { object["old_prefix"] = oldPrefix }
            if let newPrefix { object["new_prefix"] = newPrefix }
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    // MARK: After a project's folder moved

    /// What ClaudeDeck did with ServerPlan's paths after a project folder moved (UI or CLI).
    public struct Summary: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// Rewritten (`count` paths).
            case relocated
            /// ServerPlan had no path under the old folder.
            case nothing
            /// The panel doesn't offer `paths_relocate`: `stale` paths still point at the old folder.
            case notSupported = "not_supported"
            /// ServerPlan isn't set up in ClaudeDeck.
            case serverplanOff = "serverplan_off"
            /// The panel refused or failed (`message`); nothing was rewritten.
            case failed
        }

        public var status: Status
        public var count: Int
        public var changes: [Change]
        public var warnings: [String]
        /// `not_supported`: ServerPlan paths (as ClaudeDeck could read them) still under the old folder.
        public var stale: [String]
        public var message: String?

        public init(status: Status, count: Int = 0, changes: [Change] = [], warnings: [String] = [], stale: [String] = [], message: String? = nil) {
            self.status = status
            self.count = count
            self.changes = changes
            self.warnings = warnings
            self.stale = stale
            self.message = message
        }

        public var text: String {
            switch status {
            case .relocated:
                let rows = changes.map { "  \($0.table) #\($0.id)" + ($0.name.map { " \($0)" } ?? "") + " \($0.field): \($0.old) → \($0.new)" }
                return (["updated \(count) path(s)"] + rows + warnings.map { "  warning: \($0)" }).joined(separator: "\n")
            case .nothing: return "no paths under the old folder"
            case .notSupported:
                return "ServerPlan doesn't support moving paths yet (paths_relocate)"
                    + (stale.isEmpty ? "" : "; still pointing at the old folder:\n" + stale.map { "  \($0)" }.joined(separator: "\n"))
            case .serverplanOff: return "not set up in ClaudeDeck"
            case .failed: return "not updated: " + (message ?? "failed")
            }
        }
    }

    /// `not_supported`: the paths ClaudeDeck can read from ServerPlan's lists (projects, project
    /// dirs, domains) that are `old` or inside it, as "table #id field: path".
    public static func stalePaths(projects: Data?, dirs: Data?, domains: Data?, under old: String) -> [String] {
        func rows(_ data: Data?) -> [[String: Any]] {
            guard let data, let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
            if let list = value as? [[String: Any]] { return list }
            if let object = value as? [String: Any] {
                for key in ["items", "data", "projects", "domains", "dirs"] { if let list = object[key] as? [[String: Any]] { return list } }
            }
            return []
        }
        var found: [String] = []
        func check(_ data: Data?, table: String, fields: [String]) {
            for row in rows(data) {
                for field in fields {
                    guard let path = string(row[field]), !path.isEmpty, relocated(path, from: old, to: old) != nil else { continue }
                    found.append("\(table) #\(string(row["id"]) ?? "?") \(field): \(path)")
                }
            }
        }
        check(projects, table: "projects", fields: ["path", "repo_path"])
        check(dirs, table: "project_dirs", fields: ["path", "local_path"])
        check(domains, table: "domains", fields: ["local_sync_path"])
        return found
    }
}
