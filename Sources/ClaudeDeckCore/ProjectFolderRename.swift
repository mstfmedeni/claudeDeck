import Foundation

/// Renaming a project's folder on disk along with the project (Rename… › "Rename the folder too").
/// Claude Code keeps a folder's conversations under `~/.claude/projects/<encoded path>`, so those
/// move as well, or past conversations couldn't be resumed from the new place.
public enum ProjectFolderRename {
    public enum Problem: Error, Equatable {
        /// Empty, a path separator, `.`/`..`, or too long.
        case badName
        /// Something is already there.
        case exists
        /// The project folder isn't there.
        case missing
        /// A session of the project is running (its process sits in the folder).
        case running
        case failed(String)

        public var message: String {
            switch self {
            case .badName: String(localized: "A folder name can't be empty, contain \"/\" or be \".\" or \"..\".")
            case .exists: String(localized: "A file or folder with that name is already there.")
            case .missing: String(localized: "The project's folder isn't there any more.")
            case .running: String(localized: "Stop the project's sessions and terminals first: they're running in that folder.")
            case .failed(let reason): reason
            }
        }
    }

    /// The new folder's path: `name` next to the current folder.
    public static func newPath(for path: String, name: String) throws(Problem) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name.utf8.count <= 255 else { throw .badName }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().appending(path: name).path
    }

    /// `path` with `old` swapped for `new` when it is `old` or inside it; nil otherwise.
    public static func moved(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        return path.hasPrefix(prefix) ? new + "/" + path.dropFirst(prefix.count) : nil
    }

    /// Moves the folder, then the conversations of it and of `insideDirectories` (worktrees and
    /// other working directories inside it). Returns the transcript folders moved (old → new).
    @discardableResult
    public static func move(_ old: String, to new: String, insideDirectories: [String] = [],
                            claudeRoot: URL = TranscriptIndex.defaultRoot()) throws(Problem) -> [String: String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old, isDirectory: &isDirectory), isDirectory.boolValue else { throw .missing }
        // Case-only renames on a case-insensitive volume: the "existing" item is the folder itself.
        let sameItem = old.lowercased() == new.lowercased()
        guard sameItem || !fm.fileExists(atPath: new) else { throw .exists }
        do {
            try fm.moveItem(atPath: old, toPath: new)
        } catch {
            throw .failed(error.localizedDescription)
        }
        var movedTranscripts: [String: String] = [:]
        for directory in Set([old] + insideDirectories) {
            guard let target = moved(directory, from: old, to: new) else { continue }
            let from = claudeRoot.appending(path: Transcript.projectDirectoryName(for: directory))
            let to = claudeRoot.appending(path: Transcript.projectDirectoryName(for: target))
            guard from.path != to.path, fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                // Both exist (the new path was used before): bring the conversations over one by one.
                for file in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !fm.fileExists(atPath: to.appending(path: file).path) {
                    try? fm.moveItem(at: from.appending(path: file), to: to.appending(path: file))
                }
            } else {
                try? fm.moveItem(at: from, to: to)
            }
            movedTranscripts[from.path] = to.path
        }
        return movedTranscripts
    }
}
