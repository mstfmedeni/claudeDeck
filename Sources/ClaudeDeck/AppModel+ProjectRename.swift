import ClaudeDeckCore
import Foundation

extension AppModel {
    /// Renames a project; with `folder`, its folder on disk too (and Claude's conversations of it).
    /// Returns why the folder couldn't be renamed (the name is changed only when it could).
    @discardableResult
    func renameProject(_ id: UUID, to name: String, folder: Bool) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty, let project = deck.project(id) else { return nil }
        if folder {
            let sessions = deck.sessions(in: id)
            if sessions.contains(where: { terminals.isRunning($0.id) }) { return ProjectFolderRename.Problem.running.message }
            do {
                let old = project.path
                let new = try ProjectFolderRename.newPath(for: old, name: trimmed)
                if new != old {
                    let inside = sessions.compactMap(\.workingDirectory)
                    let transcripts = try ProjectFolderRename.move(old, to: new, insideDirectories: inside)
                    Git.repairWorktrees(in: URL(fileURLWithPath: new))
                    mutate { $0.relocateProject(id, from: old, to: new, transcripts: transcripts) }
                }
            } catch {
                return error.message
            }
        }
        mutate { $0.updateProject(id) { $0.name = trimmed } }
        return nil
    }
}
