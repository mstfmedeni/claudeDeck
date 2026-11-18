import AppKit
import ClaudeDeckCore
import Foundation

/// Persistent sessions (Settings › Sessions › "Keep sessions running when ClaudeDeck quits"):
/// what AppModel does with the session helper's answers. See PtydController and PtydLaunchPlan.
extension AppModel {
    /// Right after the launch-time check: attach every session still alive in the helper, mark
    /// those that ended there, and hold those that can't be told apart from a running process.
    /// Everything else waits for the usual launch path (resume on launch).
    func attachHelperSessions() {
        var changed = false
        for session in deck.sessions where !terminals.isRunning(session.id) {
            switch ptyd.gate(for: session) {
            case .attach(let info):
                attachFromHelper(session.id, info, readOnly: false)
            case .attachReadOnly(let info):
                attachFromHelper(session.id, info, readOnly: true)
            case .ended:
                // It ended while the app was away (like `/exit`): not resumed.
                mutate(userInitiated: false) { $0.updateSession(session.id) { $0.isOpen = false; $0.busyAtQuit = false; $0.helperHost = nil } }
                ptyd.client.map { if $0.isFull { $0.forget(session.id.uuidString) } }
                changed = true
            case .hold(let reason):
                ptyd.held[session.id] = reason
            case .proceed:
                if session.helperHost != nil {
                    mutate(userInitiated: false) { $0.updateSession(session.id) { $0.helperHost = nil } }
                    changed = true
                }
            }
        }
        if changed { saveNow() }
    }

    /// A session started in (or was attached to) the helper: remember where it runs, so the
    /// next launch reattaches instead of resuming.
    func helperSessionStarted(_ id: UUID, _ info: PtydSessionInfo, instance: String) {
        ptyd.noteSession(info)
        let host = PtydHost(instance: instance, pid: info.pid, startedAt: info.startedAt)
        guard deck.session(id)?.helperHost != host else { return }
        mutate(userInitiated: false) { $0.updateSession(id) { $0.helperHost = host } }
        // Saved at once: a crash right now must still know the process lives on.
        saveNow()
    }

    /// The helper went away (crash, restart) while these sessions ran in it. Each one comes back
    /// the way it would at launch: attached if it is somehow still alive in a helper, resumed
    /// once its old process is gone, left alone if that process still runs.
    func recoverHelperSessions(_ ids: [UUID]) async {
        // The children got SIGHUP: give them all together a moment to exit.
        let hosts = ids.compactMap { deck.session($0)?.helperHost }
        let deadline = ContinuousClock.now + .seconds(5)
        while hosts.contains(where: PtydLaunchPlan.processAlive), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for id in ids {
            guard deck.session(id) != nil, !terminals.isRunning(id) else { continue }
            guard let current = deck.session(id) else { continue }
            if case .ended = ptyd.gate(for: current) {
                mutate(userInitiated: false) { $0.updateSession(id) { $0.isOpen = false; $0.helperHost = nil } }
                continue
            }
            launch(id, resume: true, automatic: current.kind == .claude)
        }
    }

    /// Settings › Sessions toggle.
    func setKeepSessionsRunning(_ on: Bool) {
        if on {
            Task { await ptyd.enable() }
            return
        }
        let live = terminals.helperSessionIDs.count + ptyd.orphans.count
        guard live > 0 else {
            Task { await ptyd.disable(endSessions: false) }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sessions are running in the background helper")
        alert.informativeText = String(localized: "\(live) sessions run in the session helper. Keep them running until they end, or end them now? Sessions you start from now on run inside ClaudeDeck and end when it quits.")
        alert.addButton(withTitle: String(localized: "Keep Until They End"))
        alert.addButton(withTitle: String(localized: "End Them Now"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await ptyd.disable(endSessions: false) }
        case .alertSecondButtonReturn:
            Task { await ptyd.disable(endSessions: true) }
        default:
            break
        }
    }

    /// "Restart helper (restarts sessions)", after a confirmation.
    func confirmRestartHelper() {
        let count = terminals.helperSessionIDs.count + ptyd.held.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Restart the session helper?")
        alert.informativeText = String(localized: "This ends the \(count) sessions running in the helper and starts them again (Claude sessions resume their conversation). Anything they are doing right now is interrupted.")
        alert.addButton(withTitle: String(localized: "Restart Helper"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await ptyd.restartHelper() }
    }

}
