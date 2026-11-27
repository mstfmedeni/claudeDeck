import ClaudeDeckCore
import Foundation

/// The prompt queue: messages for a Claude session that go in one per turn, when it's the user's
/// turn ("your turn"), oldest first. Kept in the deck, so the Mac and remotes see the same queue.
extension AppModel {
    /// A message for the queue. It's the user's turn already and nothing is queued: it goes in now.
    func enqueue(_ id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, deck.session(id)?.kind == .claude else { return }
        mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.append(QueuedPrompt(text: trimmed)) } }
        drainQueues()
    }

    func queueAction(_ id: UUID, prompt: UUID, action: QueueAction) {
        guard let session = deck.session(id) else { return }
        // Not into a permission prompt or a question: it stays queued.
        if action == .sendNow, !terminals.isRunning(id) || status(of: id).display.isBlocked { return }
        let result = session.queue.applying(action, to: prompt)
        mutate(userInitiated: false) { $0.updateSession(id) { $0.queue = result.queue } }
        if let sent = result.sent, typePrompt(sent.text, into: id) == nil { queuedMessageTyped(sent.text) }
    }

    /// A queued owner's answer went into its session: the decision says "delivered" instead of
    /// staying "queued" (`claudedeck decision get`, the Decisions screen).
    func queuedMessageTyped(_ text: String) {
        guard let id = Decisions.decisionID(inMessage: text), let decision = decisions.decision(id),
              ["queued", "resumed", "resume_queued"].contains(decision.delivery ?? "") else { return }
        decisions.setDelivery(id, "delivered")
        decisionsChanged(added: nil)
    }

    /// Sends the next queued message of each session whose turn it is. Called on every status
    /// change; a message that went in holds the next one until Claude starts on it (or 45 s pass,
    /// in case it never showed as working).
    func drainQueues() {
        for session in deck.sessions where !session.queue.isEmpty && session.kind == .claude {
            let id = session.id
            guard terminals.isRunning(id) else { continue }
            // Being moved to another account: once it is back and has started up.
            if switchingAccounts.contains(id) || pendingAccountMoves.contains(id) { continue }
            if let launched = launchedAt[id], (hookStatuses[id]?.updatedAt ?? .distantPast) < launched { continue }
            let display = status(of: id).display
            if let sentAt = queueAwaiting[id] {
                if display.isRunning || display.isBlocked || Date().timeIntervalSince(sentAt) > 45 {
                    queueAwaiting[id] = nil
                } else {
                    continue
                }
            }
            guard display.isIdle, let next = session.queue.first else { continue }
            // On a used-up account while another has room: it moves first (AppModel+Accounts).
            if holdForAccountMove(id) { continue }
            mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.removeFirst() } }
            queueAwaiting[id] = Date()
            if typePrompt(next.text, into: id) == nil {
                queuedMessageTyped(next.text)
                // The first message after a move: typed again if it never shows up (retryKicks).
                if deliveryMoved.remove(id) != nil { pendingKicks[id] = PendingKick(message: next.text, sentAt: Date(), attempts: 1) }
            }
        }
    }

    /// Types a message and presses Return (Claude Code queues it itself while working). Returns
    /// why not: the session isn't running, or a permission prompt / question is on screen.
    @discardableResult
    func typePrompt(_ text: String, into id: UUID) -> String? {
        guard terminals.isRunning(id) else { return String(localized: "This session isn't running.") }
        guard !status(of: id).display.isBlocked else { return String(localized: "Answer the prompt on screen first.") }
        // Its account is used up and another has room: it moves first, the message goes into its
        // queue and in once it is back.
        if deck.session(id)?.kind == .claude, holdForAccountMove(id) {
            mutate(userInitiated: false) { $0.updateSession(id) { $0.queue.append(QueuedPrompt(text: text)) } }
            markSeen(id)
            return nil
        }
        terminals.type(text + "\r", into: id)
        markSeen(id)
        return nil
    }
}
