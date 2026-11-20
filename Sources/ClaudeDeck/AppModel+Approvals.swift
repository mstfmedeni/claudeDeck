import AppKit
import ClaudeDeckCore

/// Approvals sessions wait on (Approvals.swift): the ServerPlan gates and domain purchases a
/// `claudedeck server` call needs the owner for. They used to be NSAlert sheets on whatever
/// window happened to be key, which collided with other sheets and modal alerts and could leave
/// the window dimmed and dead. Now they're cards in the Approvals tab, a sidebar tray, a
/// notification and a row on the phone; the asking call waits exactly as before (2 minutes,
/// then refused, same exit codes).
extension AppModel {
    func makeApproval(_ caller: UUID, kind: OwnerApproval.Kind, command: String, target: String, summary: String?,
                      title: String) -> OwnerApproval {
        let session = deck.session(caller)
        var id = Approvals.newID()
        while approvals.book.approval(id) != nil { id = Approvals.newID() }
        let now = approvals.now()
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OwnerApproval(id: id, kind: kind, title: title, summary: text, command: command, target: target,
                             sessionID: session == nil ? nil : caller, session: session?.name ?? "claudedeck",
                             project: session.flatMap { deck.project($0.projectID)?.name } ?? "",
                             createdAt: now, expiresAt: now.addingTimeInterval(Approvals.timeout))
    }

    /// Queues the approval, waits for the owner (or the timeout), logs how it ended.
    func awaitApproval(_ approval: OwnerApproval) async -> Bool {
        if approvals.pendingCount >= Approvals.maxPending {
            logAgent(approval.session, inbound: true, "approval \(approval.command) \(approval.target): too many waiting, refused", ok: false)
            return false
        }
        // A bounce, not a dialog: nothing takes the window over.
        NSApp.requestUserAttention(.criticalRequest)
        let outcome = await approvals.request(approval)
        let what = "approval \(approval.id) \(approval.command) \(approval.target)"
        switch outcome {
        case .approved: logAgent(approval.session, inbound: true, "\(what): approved")
        case .refused: logAgent(approval.session, inbound: true, "\(what): refused", ok: false)
        case .expired: logAgent(approval.session, inbound: true, "\(what): no answer in \(Int(Approvals.timeout)) s, refused", ok: false)
        case .cancelled: logAgent(approval.session, inbound: true, "\(what): the call went away first", ok: false)
        }
        return outcome.isApproved
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
}
