import AppKit
import ClaudeDeckCore

/// Approvals sessions ask for (Approvals.swift): the ServerPlan gates and domain purchases a
/// `claudedeck server` call needs the owner for. They're cards in the Approvals tab, a sidebar
/// tray, a notification and a row on the phone, never a modal dialog. They wait up to Settings >
/// Agents > Approval wait time (24 hours by default). The `claudedeck server` call runs here apart
/// from its HTTP request (`ApprovalCallJob`): the request answers "pending approval a_…" (exit 75)
/// as soon as an approval is asked for, the script long-polls `approval wait`, and the gated action
/// is sent with the panel's confirm once the owner says yes, whether or not anyone still waits.
/// The result is queued for the asking session as a one-line message. Pending ones are kept in
/// approvals.json; after a relaunch an approved one replays its call.

/// A `claudedeck server` call running in the app apart from the HTTP request that started it.
@MainActor
final class ApprovalCallJob {
    /// Approvals the call asked for, in order.
    private(set) var approvalIDs: [String] = []
    /// The call's answer once it's done.
    private(set) var response: AgentHTTPResponse?
    /// After a relaunch: the approval the owner gave before it; the first gate that matches it
    /// (same command and target, and for a purchase the same price summary) goes through once.
    var preApproved: OwnerApproval?
    private var handler: CheckedContinuation<Void, Never>?

    /// Until the call is done or asks for an approval, whichever comes first.
    func waitForAnswerOrApproval() async {
        if response != nil || !approvalIDs.isEmpty { return }
        await withCheckedContinuation { handler = $0 }
    }

    func approvalAdded(_ id: String) {
        approvalIDs.append(id)
        wake()
    }

    func finish(_ response: AgentHTTPResponse) {
        self.response = response
        wake()
    }

    private func wake() {
        handler?.resume()
        handler = nil
    }
}

/// Approvals' long polls and who already got a result.
@MainActor
final class ApprovalCalls {
    /// Approvals a running call (this launch) waits on.
    var live: Set<String> = []
    /// Results an `approval wait` (or the first answer) handed over: no message for those.
    var delivered: Set<String> = []
    private var pollers: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Until `wake(id)` or `seconds` pass.
    func poll(_ id: String, seconds: TimeInterval) async {
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pollers[id, default: [:]][token] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.pollers[id]?.removeValue(forKey: token)?.resume()
            }
        }
    }

    func wake(_ id: String) {
        for continuation in (pollers.removeValue(forKey: id) ?? [:]).values { continuation.resume() }
    }
}

extension AppModel {
    func makeApproval(_ caller: UUID, kind: OwnerApproval.Kind, command: String, target: String, summary: String?,
                      title: String) -> OwnerApproval {
        let session = deck.session(caller)
        var id = Approvals.newID()
        while approvals.book.approval(id) != nil || approvals.book.resolved(id) != nil { id = Approvals.newID() }
        let now = approvals.now()
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OwnerApproval(id: id, kind: kind, title: title, summary: text, command: command, target: target,
                             sessionID: session == nil ? nil : caller, session: session?.name ?? "claudedeck",
                             project: session.flatMap { deck.project($0.projectID)?.name } ?? "",
                             createdAt: now, expiresAt: deck.settings.approvalWait.expiry(from: now))
    }

    /// Queues the approval, waits for the owner (or the expiry), logs how it ended. `replay` is
    /// the `claudedeck server` call behind it (kept on disk for a relaunch); `job` hears about it
    /// at once so the asking request can answer "pending".
    func awaitApproval(_ approval: OwnerApproval, replay: ApprovalReplay? = nil, job: ApprovalCallJob? = nil) async -> Bool {
        if approvals.pendingCount >= Approvals.maxPending {
            logAgent(approval.session, inbound: true, "approval \(approval.command) \(approval.target): too many waiting, refused", ok: false)
            return false
        }
        // A bounce, not a dialog: nothing takes the window over.
        NSApp.requestUserAttention(.criticalRequest)
        approvalCalls.live.insert(approval.id)
        job?.approvalAdded(approval.id)
        let outcome = await approvals.request(approval, replay: replay)
        logApprovalOutcome(approval, outcome)
        return outcome.isApproved
    }

    private func logApprovalOutcome(_ approval: OwnerApproval, _ outcome: ApprovalOutcome, restored: Bool = false) {
        let what = "approval \(approval.id) \(approval.command) \(approval.target)"
        let after = restored ? " (asked before ClaudeDeck restarted)" : ""
        switch outcome {
        case .approved: logAgent(approval.session, inbound: true, "\(what): approved\(after)")
        case .refused: logAgent(approval.session, inbound: true, "\(what): refused by the owner\(after)", ok: false)
        case .expired:
            let wait = approval.expiresAt.timeIntervalSince(approval.createdAt)
            logAgent(approval.session, inbound: true, "\(what): no answer in \(ApprovalStatus.durationText(wait)), expired\(after)", ok: false)
        case .cancelled: logAgent(approval.session, inbound: true, "\(what): withdrawn\(after)", ok: false)
        }
    }

    /// The owner's answer. `from`: "mac" (the card), "notification" or "phone". A purchase is
    /// approved only from the card on the Mac; a phone gets only what the approval allows it.
    @discardableResult
    func answerApproval(_ id: String, approve: Bool, from: String) -> Bool {
        guard let approval = approvals.book.approval(id) else { return false }
        if approve {
            let allowed = switch from {
            case "mac": true
            case "notification": !approval.isPurchase
            case "phone": approval.phoneMayApprove
            default: false
            }
            guard allowed else {
                logAgent(approval.session, inbound: true, "approval \(id): approving from the \(from) isn't allowed, ignored", ok: false)
                return false
            }
        } else if from == "phone", !approval.phoneMayRefuse {
            logAgent(approval.session, inbound: true, "approval \(id): refusing from the phone isn't allowed, ignored", ok: false)
            return false
        }
        return approvals.resolve(id, approve ? .approved : .refused, from: from) != nil
    }

    func showApprovals() {
        tabs.open(.approvals)
        showMainWindow()
    }

    // MARK: The call behind an approval

    /// A gated call finished (or can't run any more): keep its answer for `approval wait`, wake
    /// the polls, and tell the asking session in one line unless a poll handed the answer over.
    func approvalCallFinished(_ id: String, _ response: AgentHTTPResponse, line: String?) {
        approvalCalls.live.remove(id)
        let approved = approvals.book.resolved(id)?.outcome == .approved
        approvals.setResult(id, ApprovalCallResult(response), line: approved ? line : nil)
        approvalCalls.wake(id)
        guard let resolved = approvals.book.resolved(id), resolved.outcome != .cancelled else { return }
        // A poll between two rounds picks it up within a moment: only then is the message needed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.approvalCalls.delivered.contains(id), let resolved = self.approvals.book.resolved(id) else { return }
            guard let sessionID = resolved.approval.sessionID, self.deck.session(sessionID)?.kind == .claude else { return }
            self.enqueue(sessionID, text: Approvals.message(for: resolved))
            self.logAgent(resolved.approval.session, inbound: false, "approval \(id): the result was queued for the session")
        }
    }

    /// The asking request's answer while the approval waits (202, exit 75).
    func approvalPendingResponse(_ id: String, json: Bool) -> AgentHTTPResponse {
        guard let status = approvals.book.status(id) else { return SessionCLI.failure(404, "unknown_approval", exit: .unknown) }
        var running = status
        if running.status != "pending" { running.status = "running" }
        return SessionCLI.answer(202, running, text: running.text(now: approvals.now()), exit: .pendingApproval, json: json)
    }

    /// `GET /v1/cli/approvals/{id}`.
    func cliApprovalStatus(_ id: String, json: Bool) -> AgentHTTPResponse {
        guard OwnerApproval.isValidID(id), let status = approvals.book.status(id) else {
            return SessionCLI.failure(404, "unknown_approval", exit: .unknown)
        }
        return SessionCLI.answer(200, status, text: status.text(now: approvals.now()), exit: .ok, json: json)
    }

    /// `GET /v1/cli/approvals/{id}/wait?timeout=S` (at most 25 s a round): the gated call's own
    /// answer once it's done (its status, body and exit code), else 202 with exit 75.
    func cliApprovalWait(_ id: String, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard OwnerApproval.isValidID(id), approvals.book.status(id) != nil else {
            return SessionCLI.failure(404, "unknown_approval", exit: .unknown)
        }
        func done() -> AgentHTTPResponse? {
            if let result = approvals.book.results[id] {
                approvalCalls.delivered.insert(id)
                return result.response
            }
            // Ended with nothing that will run (a phone's own approval from before a relaunch).
            if let resolved = approvals.book.resolved(id), !approvalCalls.live.contains(id), approvals.book.replays[id] == nil {
                let status = ApprovalStatus(resolved: resolved)
                return SessionCLI.answer(200, status, text: status.text(), exit: resolved.outcome.isApproved ? .ok : .refused, json: json)
            }
            return nil
        }
        if let answer = done() { return answer }
        let window = min(Approvals.pollWindow, max(0, TimeInterval(form["timeout"] ?? "") ?? Approvals.pollWindow))
        if window > 0 { await approvalCalls.poll(id, seconds: window) }
        return done() ?? approvalPendingResponse(id, json: json)
    }

    /// `POST /v1/cli/approvals/{id}/cancel`: the asking session withdraws a pending one.
    func cliApprovalCancel(_ caller: UUID, id: String, json: Bool) -> AgentHTTPResponse {
        guard OwnerApproval.isValidID(id), approvals.book.status(id) != nil else {
            return SessionCLI.failure(404, "unknown_approval", exit: .unknown)
        }
        guard let approval = approvals.book.approval(id) else { return SessionCLI.failure(409, "not_pending", exit: .refused) }
        guard approval.sessionID == caller else { return SessionCLI.failure(403, "not_yours", exit: .refused) }
        approvals.cancel(id)
        let status = approvals.book.status(id) ?? ApprovalStatus(pending: approval)
        return SessionCLI.answer(200, status, text: "cancelled \(id)", exit: .ok, json: json)
    }

    // MARK: Kept on disk (Application Support/approvals.json)

    private var approvalsURL: URL {
        DeckDataStore.default().url.deletingLastPathComponent().appending(path: "approvals.json")
    }

    /// At launch: saves on every change from now on, reads the pending ones back (they wait
    /// again, now with nothing running behind them), expires the ones whose time ran out, and
    /// withdraws the ones nothing can replay (a phone's own container actions).
    func loadApprovals() {
        approvals.observe { [weak self] change in
            guard let self else { return }
            self.saveApprovals()
            if case .resolved(let resolved) = change { self.resolvedWithoutCall(resolved) }
        }
        if let data = try? Data(contentsOf: approvalsURL) {
            do {
                approvals.restore(try JSONDecoder().decode(ApprovalBook.self, from: data))
            } catch {
                logAgent("ClaudeDeck", inbound: false, "couldn't read approvals.json: \(error.localizedDescription)", ok: false)
            }
        }
        for approval in approvals.pending where approvals.book.replays[approval.id] == nil {
            approvals.cancel(approval.id, from: "relaunch")
        }
    }

    private func saveApprovals() {
        do {
            try JSONEncoder().encode(approvals.book).write(to: approvalsURL, options: .atomic)
        } catch {
            logAgent("ClaudeDeck", inbound: false, "couldn't save approvals: \(error.localizedDescription)", ok: false)
        }
    }

    /// An approval ended that no running call waits on (asked before a relaunch): approved, the
    /// app replays the call (the panel asks again and gets the confirm); otherwise the asking
    /// session is told it was refused or expired.
    private func resolvedWithoutCall(_ resolved: ResolvedApproval) {
        guard !approvalCalls.live.contains(resolved.id), let replay = approvals.book.replays[resolved.id] else { return }
        logApprovalOutcome(resolved.approval, resolved.outcome, restored: true)
        let id = resolved.id
        switch resolved.outcome {
        case .approved:
            approvalCalls.live.insert(id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let job = ApprovalCallJob()
                job.preApproved = resolved.approval
                let (response, line) = await self.runServerCall(replay, job: job)
                self.approvalCallFinished(id, response, line: line)
                for other in job.approvalIDs { self.approvalCallFinished(other, response, line: line) }
            }
        case .refused:
            approvalCallFinished(id, SessionCLI.failure(403, "owner_refused", exit: .refused), line: nil)
        case .expired:
            approvalCallFinished(id, SessionCLI.failure(403, "approval_expired", exit: .refused), line: nil)
        case .cancelled:
            approvalCallFinished(id, SessionCLI.failure(409, "approval_cancelled", exit: .refused), line: nil)
        }
    }
}
