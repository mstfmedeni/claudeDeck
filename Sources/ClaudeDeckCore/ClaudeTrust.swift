import Darwin
import Foundation

/// Folder trust for Claude sessions that another session started with `claudedeck new`.
///
/// Claude Code asks "Quick safety check: Is this a project you created or one you trust?" the
/// first time it runs in a folder, and nothing else (hooks included) happens until it's answered.
/// The answer is kept in its global config (`~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`)
/// as `projects[<folder>].hasTrustDialogAccepted`; a folder (or, outside a git repository, any
/// folder above it) with that key set doesn't ask. Claude Code's own messages point users at
/// that key, and it's the only route that doesn't need keystrokes: the dialog's focus starts on
/// "No, exit" and it refuses keys typed right after it opens.
///
/// Running Claude processes rewrite the same file, so the change is made the way they make
/// theirs: under their lock (`<file>.lock`, a folder), on a fresh read, as one atomic rename,
/// and only if the file didn't change since it was read. Only that one key is added; everything
/// else in the file is kept.
public enum ClaudeTrust {
    // MARK: When

    /// Whether a session's folder is trusted for it: only sessions another session started
    /// (`startedBy`), with "Sessions may add projects and start Claude sessions" on, and a folder
    /// `project add --create` could make (`folder(_:roots:)`).
    public static func decide(startedByCLI: Bool, settingOn: Bool, path: String, roots: [String]) -> Result<String, Refusal> {
        guard startedByCLI else { return .failure(.notStartedByCLI) }
        guard settingOn else { return .failure(.settingOff) }
        return folder(path, roots: roots)
    }

    public enum Refusal: String, Error, Sendable, Equatable {
        case notStartedByCLI = "not_started_by_cli"
        case settingOff = "setting_off"
        case notAbsolute = "not_absolute"
        case systemPath = "system_path"
        /// Not below the home folder (or is the home folder itself: Claude Code never saves
        /// trust for it either).
        case outsideHome = "outside_home"
        /// A folder whose name starts with a dot (`~/.config/x`), or `~/Library`.
        case hiddenFolder = "hidden_folder"
    }

    /// The same rules `project add --create` uses for folders it makes: absolute, resolved,
    /// strictly below one of `roots` (the home folder), not in its Library, no part of it hidden,
    /// never a system folder.
    public static func folder(_ raw: String, roots: [String]) -> Result<String, Refusal> {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("/") else { return .failure(.notAbsolute) }
        let path = SessionCLI.resolved(raw)
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        guard path != "/", !SessionCLI.systemFolders.contains(where: under) else { return .failure(.systemPath) }
        let roots = roots.map(SessionCLI.resolved).filter { $0 != "/" }
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return .failure(.outsideHome) }
        let inside = path.dropFirst(root.count + 1).split(separator: "/")
        guard inside.first != "Library", !inside.contains(where: { $0.hasPrefix(".") }) else { return .failure(.hiddenFolder) }
        return .success(path)
    }

    // MARK: Where

    /// Claude Code's global config: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`. In
    /// the demo only the demo's own home (`CLAUDEDECK_CLAUDE_HOME`) is used, never the real file.
    public static func configFile(environment: [String: String], home: String, demo: Bool) -> URL? {
        if demo {
            guard let demoHome = environment["CLAUDEDECK_CLAUDE_HOME"], !demoHome.isEmpty else { return nil }
            return URL(fileURLWithPath: demoHome).appendingPathComponent(".claude.json")
        }
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    // MARK: The change

    public enum MergeError: Error, Equatable {
        /// The file isn't a JSON object: it's left alone.
        case unreadable
    }

    /// Whether `config` already trusts `folder` (its own key; trust saved for a folder above it
    /// counts too only outside a repository, so that's left to Claude Code).
    public static func isTrusted(_ config: [String: Any], folder: String) -> Bool {
        ((config["projects"] as? [String: Any])?[folder] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
    }

    /// `data` with `projects[folder].hasTrustDialogAccepted` set; nil when it's already set
    /// (nothing to write). Empty data is a new file. The change is made in the text, so every
    /// other byte (numbers, order, spacing) stays as it was, and the result is checked: parsed,
    /// it must be the old config plus that one key, or nothing is written.
    public static func merged(_ data: Data, folder: String) throws -> Data? {
        let key = "hasTrustDialogAccepted"
        guard !data.isEmpty else { return Data(#"{"projects": {\#(try quoted(folder)): {"\#(key)": true}}}"#.utf8) + Data("\n".utf8) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let config = object as? [String: Any],
              let text = String(data: data, encoding: .utf8) else { throw MergeError.unreadable }
        if isTrusted(config, folder: folder) { return nil }
        let chars = Array(text.utf8)
        let scanner = Scanner(chars)
        guard let top = scanner.object(at: scanner.skipSpace(0)) else { throw MergeError.unreadable }
        let edit: (at: Range<Int>, with: String)
        if let projects = top.members.last(where: { $0.key == "projects" }) {
            guard let projectsObject = scanner.object(at: projects.value.lowerBound) else { throw MergeError.unreadable }
            if let entry = projectsObject.members.last(where: { $0.key == folder }) {
                guard let entryObject = scanner.object(at: entry.value.lowerBound) else { throw MergeError.unreadable }
                if let flag = entryObject.members.last(where: { $0.key == key }) {
                    edit = (flag.value, "true")
                } else {
                    edit = (entryObject.inside, "\"\(key)\": true" + (entryObject.members.isEmpty ? "" : ", "))
                }
            } else {
                edit = (projectsObject.inside, "\(try quoted(folder)): {\"\(key)\": true}" + (projectsObject.members.isEmpty ? "" : ", "))
            }
        } else {
            edit = (top.inside, "\"projects\": {\(try quoted(folder)): {\"\(key)\": true}}" + (top.members.isEmpty ? "" : ", "))
        }
        var output = chars
        output.replaceSubrange(edit.at, with: Array(edit.with.utf8))
        let result = Data(output)
        // The check: the old config plus the key, nothing else.
        guard let parsed = try? JSONSerialization.jsonObject(with: result) as? [String: Any], isTrusted(parsed, folder: folder) else {
            throw MergeError.unreadable
        }
        var expected = config
        var projects = config["projects"] as? [String: Any] ?? [:]
        var entry = projects[folder] as? [String: Any] ?? [:]
        entry[key] = true
        projects[folder] = entry
        expected["projects"] = projects
        guard NSDictionary(dictionary: parsed).isEqual(to: expected) else { throw MergeError.unreadable }
        return result
    }

    private static func quoted(_ string: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Just enough of a JSON reader to find where a member's value is in the text (the text is
    /// valid JSON: JSONSerialization read it first).
    private struct Scanner {
        let chars: [UInt8]
        init(_ chars: [UInt8]) { self.chars = chars }

        struct Object {
            /// Where a new first member goes: right after the `{`, empty.
            var inside: Range<Int>
            var members: [(key: String, value: Range<Int>)]
        }

        func skipSpace(_ index: Int) -> Int {
            var index = index
            while index < chars.count, [0x20, 0x09, 0x0A, 0x0D].contains(chars[index]) { index += 1 }
            return index
        }

        /// The index after the string starting at `index` (a `"`).
        func endOfString(_ index: Int) -> Int? {
            var index = index + 1
            while index < chars.count {
                switch chars[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): return index + 1
                default: index += 1
                }
            }
            return nil
        }

        /// The index after the value starting at `index`.
        func endOfValue(_ index: Int) -> Int? {
            guard index < chars.count else { return nil }
            switch chars[index] {
            case UInt8(ascii: "\""): return endOfString(index)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                var index = index
                while index < chars.count {
                    switch chars[index] {
                    case UInt8(ascii: "\""):
                        guard let end = endOfString(index) else { return nil }
                        index = end
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { return index + 1 }
                    default: break
                    }
                    index += 1
                }
                return nil
            default:
                var index = index
                while index < chars.count, !",}] \t\r\n".utf8.contains(chars[index]) { index += 1 }
                return index
            }
        }

        func object(at start: Int) -> Object? {
            guard start < chars.count, chars[start] == UInt8(ascii: "{") else { return nil }
            var object = Object(inside: (start + 1)..<(start + 1), members: [])
            var index = skipSpace(start + 1)
            if index < chars.count, chars[index] == UInt8(ascii: "}") { return object }
            while index < chars.count {
                guard chars[index] == UInt8(ascii: "\""), let keyEnd = endOfString(index),
                      let key = try? JSONSerialization.jsonObject(with: Data(chars[index..<keyEnd]), options: .fragmentsAllowed) as? String else { return nil }
                index = skipSpace(keyEnd)
                guard index < chars.count, chars[index] == UInt8(ascii: ":") else { return nil }
                let valueStart = skipSpace(index + 1)
                guard let valueEnd = endOfValue(valueStart) else { return nil }
                object.members.append((key, valueStart..<valueEnd))
                index = skipSpace(valueEnd)
                guard index < chars.count else { return nil }
                if chars[index] == UInt8(ascii: "}") { return object }
                guard chars[index] == UInt8(ascii: ",") else { return nil }
                index = skipSpace(index + 1)
            }
            return nil
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Written now.
        case trusted
        /// The folder already was.
        case alreadyTrusted
        /// Nothing written; the reason, for the activity log.
        case failed(String)
    }

    /// Adds the key to `file` (symlinks followed): under Claude Code's lock, from a fresh read,
    /// written to a temporary file next to it and renamed over it only if the file is still the
    /// one that was read (inode, size, modification time); otherwise read again (a few times).
    /// After the rename the file is read once more, in case a writer that ignores the lock
    /// replaced it in between.
    public static func trust(_ folder: String, in file: URL, attempts: Int = 5, lockWait: TimeInterval = 3) -> Outcome {
        let path = file.resolvingSymlinksInPath().path
        let lock = path + ".lock"
        for _ in 0..<attempts {
            guard acquire(lock, wait: lockWait) else { return .failed("locked") }
            let outcome = attempt(folder, path: path)
            rmdir(lock)
            switch outcome {
            case .changed: continue
            case .done(let result):
                guard result == .trusted else { return result }
                // Still there after the rename: done. Gone: a writer raced it; try again.
                if let data = FileManager.default.contents(atPath: path),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   isTrusted(object, folder: folder) { return .trusted }
            }
        }
        return .failed("changed while writing")
    }

    private enum Attempt { case changed, done(Outcome) }

    private struct Stamp: Equatable {
        var inode: UInt64, size: Int64, modified: timespec
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino); size = Int64(info.st_size); modified = info.st_mtimespec
        }
    }

    private static func attempt(_ folder: String, path: String) -> Attempt {
        let before = Stamp(path)
        let data: Data
        if before == nil {
            guard !FileManager.default.fileExists(atPath: path) else { return .done(.failed("unreadable")) }
            data = Data()
        } else {
            guard let read = FileManager.default.contents(atPath: path) else { return .done(.failed("unreadable")) }
            data = read
        }
        // A read torn by a writer: read again.
        guard Stamp(path) == before else { return .changed }
        let output: Data
        do {
            guard let merged = try merged(data, folder: folder) else { return .done(.alreadyTrusted) }
            output = merged
        } catch {
            return .done(.failed("not a JSON object"))
        }
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString).appendingPathComponent(".claude.json.claudedeck-\(UUID().uuidString).tmp")
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return .done(.failed("can't write")) }
        let written = output.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == output.count, synced else { unlink(temporary); return .done(.failed("can't write")) }
        // The file someone else wrote since the read wins; this change is made again on top of it.
        guard Stamp(path) == before else { unlink(temporary); return .changed }
        if before == nil {
            // A new file: only if there still is none.
            guard link(temporary, path) == 0 else { unlink(temporary); return .changed }
            unlink(temporary)
        } else {
            guard rename(temporary, path) == 0 else { unlink(temporary); return .done(.failed("can't replace")) }
        }
        return .done(.trusted)
    }

    /// Claude Code's lock on its config (proper-lockfile): the folder `<file>.lock`, made with
    /// mkdir. A held lock is waited for, never broken.
    private static func acquire(_ lock: String, wait: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if mkdir(lock, 0o755) == 0 { return true }
            guard errno == EEXIST, Date() < deadline else { return false }
            usleep(50_000)
        }
    }
}
