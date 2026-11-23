import ClaudeDeckCore
import Foundation
import SwiftUI

/// Claude Code's Remote Control in the sessions ClaudeDeck runs (RemoteControl.swift): which ones
/// have it on (Claude Code's session registry, read every few seconds; a badge in the sidebar and
/// a row on the phone), and turning it off the way the owner would: once the session's turn is
/// over, `/remote-control` is typed, and only once its dialog is on screen, Up Up Enter picks
/// "Disconnect this session". The registry then has to say it's off; every off, done or failed,
/// goes to the Activity Log. Settings › Sessions › "Keep Remote Control off" does this by itself
/// for a session whose Remote Control came back with a resume.
extension AppModel {
    /// How often the registry is read.
    static let remoteControlInterval: Duration = .seconds(4)

    func startRemoteControlWatch() {
        guard remoteControlTask == nil else { return }
        remoteControlTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshRemoteControl()
                try? await Task.sleep(for: Self.remoteControlInterval)
            }
        }
    }

    /// The default config dir's and every account's `sessions` folder.
    private var remoteControlFolders: [URL] {
        RemoteControl.registryFolders(defaultConfigDir: sharedClaudeFolder,
                                      accountConfigDirs: deck.settings.accounts.map(\.configDir))
    }

    /// Running Claude sessions and the Claude session id each one is on now.
    private var runningClaudeIDs: [UUID: String] {
        var out: [UUID: String] = [:]
        for session in deck.sessions where session.kind == .claude && terminals.isRunning(session.id) {
            if let sid = hookStatuses[session.id]?.sessionID ?? session.claudeSessionID, !sid.isEmpty { out[session.id] = sid }
        }
        return out
    }

    private func readRemoteControlRegistry() async -> [String: RemoteControl.RegistryEntry] {
        let folders = remoteControlFolders
        // The demo's stand-in sessions write registry files for processes that aren't theirs.
        let demo = Self.isDemo
        return await Task.detached {
            RemoteControl.readRegistry(folders, isAlive: demo ? { _ in true } : RemoteControl.processIsAlive)
        }.value
    }

    /// Reads the registry: updates `remoteControlOn` (sidebar, phones) and, with "Keep Remote
    /// Control off", turns it off where a resume just brought it back.
    func refreshRemoteControl() async {
        let registry = await readRemoteControlRegistry()
        let on = RemoteControl.sessionsOn(claudeIDs: runningClaudeIDs, registry: registry)
        if on != remoteControlOn {
            remoteControlOn = on
            onCountsChanged?()
        }
        let now = Date()
        for (id, at) in remoteControlResumedAt where now.timeIntervalSince(at) > RemoteControl.resumeWatch || !terminals.isRunning(id) {
            remoteControlResumedAt[id] = nil
        }
        guard deck.settings.keepRemoteControlOff else { return }
        for id in on where RemoteControl.autoOffDue(launchedAt: remoteControlResumedAt[id], on: true, now: now) {
            remoteControlResumedAt[id] = nil
            turnOffRemoteControl([id], by: "ClaudeDeck", why: "it came back on with the resume")
        }
    }

    /// Sessions the "all sessions" action would reach.
    var remoteControlOffTargets: [UUID] {
        deck.sessions.map(\.id).filter { remoteControlOn.contains($0) && !remoteControlOffPending.contains($0) }
    }

    /// The menu's "Turn Off Remote Control (All Sessions)" and the phone's.
    func turnOffRemoteControlEverywhere(by who: String) {
        turnOffRemoteControl(remoteControlOffTargets, by: who)
    }

    /// Turns Remote Control off in each session (where it's on), each once its turn is over.
    /// `who`: for the Activity Log ("Owner", "Phone", "ClaudeDeck", a session's name).
    func turnOffRemoteControl(_ ids: [UUID], by who: String, why: String? = nil) {
        for id in ids {
            guard let session = deck.session(id), session.kind == .claude, !remoteControlOffPending.contains(id) else { continue }
            remoteControlOffPending.insert(id)
            let name = session.name
            logAgent(who, inbound: true, "Remote Control off · \(name): requested" + (why.map { " (\($0))" } ?? ""))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let failure = await self.runRemoteControlOff(id)
                self.remoteControlOffPending.remove(id)
                if let failure {
                    self.logAgent(who, inbound: true, "Remote Control off · \(name): \(failure)", ok: false)
                } else {
                    self.logAgent(who, inbound: true, "Remote Control off · \(name): done")
                }
                await self.refreshRemoteControl()
            }
        }
    }

    /// Waits for the turn to end, then types. nil: it's off (or already was); else why not.
    private func runRemoteControlOff(_ id: UUID) async -> String? {
        let deadline = Date().addingTimeInterval(RemoteControl.waitLimit)
        while Date() < deadline {
            guard let session = deck.session(id) else { return "given up, the session is gone" }
            let registry = await readRemoteControlRegistry()
            let sid = hookStatuses[id]?.sessionID ?? session.claudeSessionID
            let step = RemoteControl.offStep(
                isClaude: session.kind == .claude, running: terminals.isRunning(id),
                readOnly: terminals.readOnlySessions.contains(id),
                on: sid.flatMap { registry[$0] }?.isOn == true,
                switching: switchingAccounts.contains(id) || accountSwitchPending(id),
                typingPending: pendingCompact.contains(id) || pendingContinue.contains(id) || resumeTyping.contains(id)
                    || cliCompactsPending.contains(id),
                progress: cliProgress(id))
            switch step {
            case .skip(.alreadyOff): return nil
            case .skip(let reason): return "skipped (\(reason.rawValue))"
            case .wait: try? await Task.sleep(for: .seconds(1))
            case .now: return await typeRemoteControlOff(id, sid: sid)
            }
        }
        return "given up, the turn didn't end in \(Int(RemoteControl.waitLimit / 60)) minutes"
    }

    /// The visible screen's lines, top to bottom.
    private func screenLines(_ id: UUID) -> (lines: [String], applicationCursor: Bool)? {
        guard let view = terminals.view(for: id) else { return nil }
        let screen = TerminalCapture.screen(of: view, scrollback: 0)
        return (screen.lines.map { $0.map(\.text).joined() }, screen.applicationCursor)
    }

    /// Types `/remote-control` into the idle session and picks "Disconnect this session" once its
    /// dialog shows; then waits for the registry to say it's off.
    private func typeRemoteControlOff(_ id: UUID, sid: String?) async -> String? {
        guard let before = screenLines(id) else { return "no terminal to type into" }
        if !RemoteControl.showsDisconnectDialog(before.lines) {
            // Ctrl+C first clears a draft in the prompt (as typeCompact does), so the command
            // isn't appended to it and sent as a message.
            terminals.type("\u{3}", into: id)
            try? await Task.sleep(for: .milliseconds(250))
            guard terminals.isRunning(id) else { return "the session stopped" }
            terminals.type(RemoteControl.command, into: id)
            // A moment for the command list to settle on it before Enter.
            try? await Task.sleep(for: .milliseconds(500))
            terminals.type("\r", into: id)
        }
        var screen: (lines: [String], applicationCursor: Bool)?
        let shownBy = Date().addingTimeInterval(RemoteControl.dialogLimit)
        while Date() < shownBy {
            try? await Task.sleep(for: .milliseconds(250))
            if let now = screenLines(id), RemoteControl.showsDisconnectDialog(now.lines) { screen = now; break }
        }
        guard let screen else {
            // Never an arrow key without the dialog: at the prompt it would recall a message.
            terminals.type(RemoteControl.escape, into: id)
            return "the Remote Control dialog didn't show up"
        }
        for key in RemoteControl.disconnectKeys(applicationCursor: screen.applicationCursor) {
            terminals.type(key, into: id)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let verifyBy = Date().addingTimeInterval(RemoteControl.verifyLimit)
        while Date() < verifyBy {
            let registry = await readRemoteControlRegistry()
            if let sid, registry[sid]?.isOn != true { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "still on after “Disconnect this session”"
    }
}

/// File › "Turn Off Remote Control (All Sessions)".
struct RemoteControlCommands: View {
    let model: AppModel

    var body: some View {
        Button("Turn Off Remote Control (All Sessions)") { model.turnOffRemoteControlEverywhere(by: "Owner") }
            .disabled(model.remoteControlOffTargets.isEmpty)
    }
}

/// The sidebar's mark on a session with Remote Control on.
struct RemoteControlBadge: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        if model.remoteControlOn.contains(sessionID) {
            Image(systemName: model.remoteControlOffPending.contains(sessionID) ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                .sidebarFont(.caption2)
                .foregroundStyle(.orange)
                .help(model.remoteControlOffPending.contains(sessionID)
                      ? String(localized: "Remote Control is on; turning it off once the turn is over")
                      : String(localized: "Remote Control is on: this session can be driven from claude.ai/code or the Claude app"))
                .accessibilityLabel(Text("Remote Control on"))
        }
    }
}

/// `claudedeck remote-control off ID|self|--all`: never done on a session's word alone. It asks
/// the owner with an approval card (Approvals tab, notification, phone); the request answers
/// "pending approval a_…" (202, exit 75) and the script long-polls `approval wait`. Approved, the
/// sessions get the same off as the menu's. Not kept across a relaunch (nothing to replay:
/// `loadApprovals` withdraws it). Contract: docs/agents.md.
extension AppModel {
    private struct CLIRemoteControlOff: Encodable {
        var remoteControl = "off"
        var sessions: [UUID]
        var pending: Bool
    }

    func cliRemoteControlOff(_ caller: UUID, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        let callerName = deck.session(caller)?.name ?? "claudedeck"
        let ref = (form["target"] ?? "").trimmingCharacters(in: .whitespaces)
        let ids: [UUID]
        let target: String
        if ref == "all" {
            ids = remoteControlOffTargets
            target = String(localized: "all sessions")
        } else {
            let session: DeckSession
            switch cliCloseTarget(ref, caller: caller) {
            case .failure(let refusal): return refusal.response
            case .success(let found): session = found
            }
            guard session.kind == .claude else { return SessionCLI.failure(400, "not_claude", exit: .usage) }
            ids = remoteControlOn.contains(session.id) ? [session.id] : []
            target = session.name
        }
        guard !ids.isEmpty else {
            return SessionCLI.answer(200, CLIRemoteControlOff(sessions: [], pending: false), text: "already off", exit: .ok, json: json)
        }
        let names = ids.compactMap { deck.session($0)?.name }
        var approval = makeApproval(caller, kind: .other, command: "remote-control off", target: target,
                                    summary: String(localized: "Claude Code's Remote Control is turned off in: \(names.joined(separator: ", ")). Each session gets /remote-control › Disconnect once its turn is over."),
                                    title: String(localized: "\(callerName) asks to turn off Remote Control in \(target)"))
        // Turning it off takes nothing away the owner can't turn on again: a phone may say yes.
        approval.phoneMayApprove = true
        let job = ApprovalCallJob()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let approved = await self.awaitApproval(approval, job: job)
            let response: AgentHTTPResponse
            if approved {
                self.turnOffRemoteControl(ids, by: callerName, why: "approved by the owner")
                response = SessionCLI.answer(200, CLIRemoteControlOff(sessions: ids, pending: true),
                                             text: "turning off Remote Control in \(names.joined(separator: ", ")) (each after its turn; see the activity log)",
                                             exit: .ok, json: json)
            } else {
                let reason = self.approvals.book.resolved(approval.id)?.outcome == .expired ? "approval_expired" : "owner_refused"
                response = SessionCLI.failure(403, reason, exit: .refused)
            }
            job.finish(response)
            for id in job.approvalIDs {
                self.approvalCallFinished(id, response, line: approved ? "turning off Remote Control in \(names.count) session(s)" : nil)
            }
        }
        await job.waitForAnswerOrApproval()
        if let response = job.response {
            approvalCalls.delivered.formUnion(job.approvalIDs)
            return response
        }
        return approvalPendingResponse(job.approvalIDs[0], json: json)
    }
}
