import ClaudeDeckCore
import Foundation

/// `claudedeck restart ID`: the owner's Restart Terminal from a session. The old process in that
/// same pane is stopped and the terminal's command re-run (`restartSession`: `stopForRestart` +
/// `launch(resume: false)`); a stopped one is just launched. Never a new terminal.
/// Allowed: the caller's own terminals (`mayClose`), and with Settings › "Sessions may restart
/// command terminals in their own project" (off by default) the terminals with a startup command
/// in its project. A Claude session only when the caller started it, under the close rules.
/// Contract: docs/agents.md.
extension AppModel {
    func cliRestart(_ caller: UUID, ref: String, json: Bool) async -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let target: DeckSession
        switch cliCloseTarget(ref, caller: caller) {
        case .failure(let refusal): return refusal.response
        case .success(let session): target = session
        }
        let id = target.id
        let check = SessionCLI.mayRestart(caller: caller, callerProject: deck.session(caller)?.projectID, target: id,
                                          targetKind: target.kind, targetProject: target.projectID,
                                          targetCommand: target.startupCommand, startedBy: startedByMap(),
                                          openedBy: openedByMap(),
                                          mayRestartProjectTerminals: deck.settings.sessionsMayRestartProjectTerminals,
                                          mayCloseSessions: deck.settings.sessionsMayCloseSessions)
        switch check {
        case .allowed:
            break
        case .isSelf:
            return SessionCLI.failure(400, "cannot_restart_self", exit: .usage)
        case .restartOff:
            logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): refused (the setting is off)", ok: false)
            return SessionCLI.failure(403, "restart_off", exit: .refused)
        case .closeOff:
            logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): refused (closing sessions is off)", ok: false)
            return SessionCLI.failure(403, "close_off", exit: .refused)
        case .notYours:
            logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): refused (not its own, nor a command terminal of its project)", ok: false)
            return SessionCLI.failure(403, "not_yours", exit: .refused)
        }
        // Watched read-only in another app's session helper: it can't be driven from here.
        if terminals.readOnlySessions.contains(id) {
            logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): refused (read-only)", ok: false)
            return SessionCLI.failure(409, "read_only", exit: .failed)
        }
        if switchingAccounts.contains(id) || accountSwitchPending(id) {
            logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): refused (switching account)", ok: false)
            return SessionCLI.failure(409, "switching_account", exit: .failed)
        }
        if restartingSessions.contains(id) {
            return SessionCLI.failure(409, "busy", exit: .failed)
        }
        let running = terminals.isRunning(id)
        if target.kind == .claude {
            // The owner's Restart Session, without dialogs: a busy one is left alone.
            guard running else { return SessionCLI.failure(409, "not_running", exit: .failed) }
            guard await restartSession(id, busy: .skip, interactive: false) else {
                logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): not restarted (Claude is working or its conversation is unknown)", ok: false)
                return SessionCLI.failure(409, "busy", exit: .failed)
            }
        } else if running {
            guard await restartSession(id, interactive: false) else {
                logAgent(callerName, inbound: true, "claudedeck restart · \(target.name): couldn't restart it", ok: false)
                return SessionCLI.failure(409, "not_restarted", exit: .failed)
            }
        } else {
            launch(id, resume: false)
        }
        // `wait` and `send` now concern the new process.
        cli.commandExits[id] = nil
        cli.sentAt[id] = nil
        let command = target.startupCommand.map { " (\($0))" } ?? ""
        logAgent(callerName, inbound: true, "claudedeck restart · \(target.name)" + command + (running ? ": restarted" : ": started (wasn't running)"))
        onCountsChanged?()
        return SessionCLI.answer(200, SessionCLIRestarted(restarted: true, id: id, running: running),
                                 text: running ? "restarted" : "started", exit: .ok, json: json)
    }
}
