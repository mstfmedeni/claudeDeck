import AppKit
import ClaudeDeckCore
import Foundation

/// ServerPlan terminals: shell sessions whose process is ClaudeDeck bridging the pty to the
/// panel's terminal WebSocket (ServerPlanTerminalBridge). The panel does the SSH with its own
/// keys; this Mac only ever holds a single-use, 60-second ticket.
extension AppModel {
    /// A terminal on `server` (or Claude Code there), reusing a closed one of the same kind.
    func openServerPlanTerminal(serverID: Int, serverName: String, runClaude: Bool) {
        let existing = deck.sessions.first {
            $0.serverPlanTerminal?.serverID == serverID && $0.serverPlanTerminal?.runClaude == runClaude
        }
        if let existing {
            if !terminals.isRunning(existing.id) { launch(existing.id, resume: false) }
            tabs.selectSessions()
            selectedSessionID = existing.id
            return
        }
        guard let projectID = serverPlanHomeProject(serverID: serverID) else { NSSound.beep(); return }
        let name = runClaude ? "claude@\(serverName)" : serverName
        var created: DeckSession?
        mutate {
            created = $0.addSession(to: projectID, kind: .shell, name: name)
            if let id = created?.id {
                $0.updateSession(id) { $0.serverPlanTerminal = ServerPlanTerminalTarget(serverID: serverID, serverName: serverName, runClaude: runClaude) }
            }
        }
        guard let id = created?.id else { return }
        launch(id, resume: false)
        tabs.selectSessions()
        selectedSessionID = id
    }

    /// Where a server's terminal goes: the ClaudeDeck project of a ServerPlan project deployed
    /// there, else the selected project, else the first.
    private func serverPlanHomeProject(serverID: Int) -> UUID? {
        let controller = ServerPlanController.shared
        for project in controller.projects(on: serverID) {
            if let match = controller.deckProject(for: project) { return match.id }
        }
        return selectedProjectID ?? deck.projects.first?.id
    }

    /// Gets a ticket, then runs the bridge in the session's pty. Without one (not configured, no
    /// permission, panel down) the bridge just prints why and exits.
    func launchServerPlanTerminal(_ id: UUID, target: ServerPlanTerminalTarget, cwd: String) {
        guard let executable = Bundle.main.executablePath else { return }
        let client = ServerPlanController.shared.client
        let grid = terminals.gridSize(id)
        Task { @MainActor in
            var environment: [String: String] = [:]
            if let client {
                do {
                    let url = try await client.terminalURL(serverID: target.serverID, cols: grid.cols, rows: grid.rows,
                                                           command: target.runClaude ? .claude : .shell)
                    environment[ServerPlanTerminalBridge.urlVariable] = url.absoluteString
                } catch {
                    environment[ServerPlanTerminalBridge.errorVariable] = error.localizedDescription
                }
            } else {
                environment[ServerPlanTerminalBridge.errorVariable] = String(localized: "ServerPlan isn't set up (Settings › ServerPlan).")
            }
            guard !terminals.isRunning(id), deck.session(id) != nil else { return }
            // Program Status when it applies: OSC 7501 from programs on the server (our shell
            // integration can't reach the remote shell).
            terminals.startProcess(id: id, cwd: cwd, executable: executable, args: [ServerPlanTerminalBridge.argument], environment: environment,
                                   programStatus: deck.showsProgramStatus(id))
            mutate(userInitiated: false) { $0.updateSession(id) { $0.isOpen = true } }
            onCountsChanged?()
        }
    }
}
