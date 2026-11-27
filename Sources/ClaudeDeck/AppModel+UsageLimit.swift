import ClaudeDeckCore
import Foundation
import os

private let limitLog = Logger(subsystem: "co.codemagnet.ClaudeDeck", category: "usage-limit")

/// A session that stopped on the plan's usage limit.
struct UsageLimitHit: Equatable {
    /// The limit entry's transcript timestamp — identifies the limit event.
    var at: Date
    /// From the limit message ("resets 3:20am (Europe/Istanbul)"); nil = use the usage API's reset.
    var resetsAt: Date?
}

/// A message a session must act on to get going again (the continue after a limit, or the one
/// after a move off a used-up account), until its transcript shows it arrived.
struct PendingKick: Equatable {
    var message: String
    var sentAt: Date
    var attempts: Int
}

/// Sessions that stop on the usage limit get the "continue" message once the limit resets
/// (Settings › Sessions), at most once per limit event; with other accounts they may move first
/// (AppModel+Accounts). One watch runs all the time: every half minute it moves what should move,
/// continues what has reset and re-sends a continue that didn't arrive.
extension AppModel {
    /// A little after the reset, so the first request doesn't race the window rolling over.
    static let usageLimitGrace: TimeInterval = 60
    /// A kick that hasn't shown up in the transcript after this is typed again.
    static let kickRetryAfter: TimeInterval = 90
    static let kickAttempts = 3
    /// Limit messages older than this aren't picked up again after a relaunch.
    static let usageLimitRescanAge: TimeInterval = 7 * 86400

    func receiveUsageLimit(_ event: UsageLimitEvent, for id: UUID) {
        switch event {
        case .hit(let at, let resetsAt):
            // It made a request: whatever it was kicked with arrived; the limit takes over.
            pendingKicks[id] = nil
            guard usageLimitHits[id]?.at != at else { return }
            // The same reset we already continued for: our continue came too early (wrong time
            // zone, clock skew). Don't trust the message again — wait for the usage API instead.
            let reset = resetsAt == continuedLimitResets[id] ? nil : resetsAt
            usageLimitHits[id] = UsageLimitHit(at: at, resetsAt: reset)
            limitLog.info("Session \(id, privacy: .public) hit the usage limit")
            if let session = deck.session(id) {
                let when = reset.map { " (resets \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
                logAgent("ClaudeDeck", inbound: false, "\(session.name): usage limit on \(accountLabel(accountID(of: session)))\(when)", ok: false)
            }
            startAccountWatch()
            accountLimitHit(id, resetsAt: reset) // other accounts (AppModel+Accounts)
        case .cleared(let at):
            if let hit = usageLimitHits[id], at > hit.at { usageLimitHits[id] = nil }
        }
    }

    /// The transcript tailer starts at the end of the file, so a limit this process stopped on
    /// before ClaudeDeck attached to it (a relaunch with sessions kept running) is read here from
    /// the file's last part. Only a limit after this process started counts.
    func rescanUsageLimit(_ id: UUID, path: String) {
        guard usageLimitHits[id] == nil, let launched = launchedAt[id] else { return }
        Task { [weak self] in
            let event = await Task.detached(priority: .utility) { Self.lastUsageLimitEvent(inTailOf: path) }.value
            guard let self, case .hit(let at, let resetsAt)? = event, at >= launched,
                  Date().timeIntervalSince(at) < Self.usageLimitRescanAge,
                  self.usageLimitHits[id] == nil, self.launchedAt[id] == launched else { return }
            self.receiveUsageLimit(.hit(at: at, resetsAt: resetsAt), for: id)
        }
    }

    nonisolated static func lastUsageLimitEvent(inTailOf path: String, bytes: UInt64 = 256 * 1024) -> UsageLimitEvent? {
        guard let chunk = tail(of: path, bytes: bytes) else { return nil }
        return Transcript.lastUsageLimitEvent(in: chunk)
    }

    /// The last `bytes` of a file, from its first complete line.
    nonisolated static func tail(of path: String, bytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    /// When the session's limit resets: the message's time, else its account's known reset
    /// (usage API, ClaudeDeck's record), else half an hour after the hit.
    func usageLimitReset(for id: UUID) -> Date? {
        guard let hit = usageLimitHits[id] else { return nil }
        return AccountPolicy.continueDue(hitAt: hit.at, messageReset: hit.resetsAt, accountReset: limitAccountReset(for: id), grace: 0)
    }

    private func limitAccountReset(for id: UUID) -> Date? {
        guard let session = deck.session(id) else { return usage.state.usage?.exhaustedUntil }
        return accountStanding(accountID(of: session)).resetsAt()
    }

    /// The usage of the account the session runs on.
    private func limitMonitor(for id: UUID) -> UsageMonitor? {
        guard let session = deck.session(id) else { return usage }
        return usageMonitor(forAccount: accountID(of: session)) ?? usage
    }

    /// The watch behind limits and accounts: every half minute while ClaudeDeck runs.
    func startAccountWatch() {
        guard accountWatchTask == nil else { return }
        accountWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { break }
                await self.accountWatchTick()
            }
        }
    }

    func accountWatchTick() async {
        // Sessions move first (only with "switch accounts" on), then the rest continue in place.
        await balanceAccounts()
        if !usageLimitHits.isEmpty { await continueSessionsPastTheirLimit() }
        retryKicks()
    }

    private func continueSessionsPastTheirLimit() async {
        guard deck.settings.continueAfterUsageLimit else { return }
        let now = Date()
        let due = usageLimitHits.keys.filter { id in
            guard !switchingAccounts.contains(id), !pendingAccountMoves.contains(id), let reset = usageLimitReset(for: id) else { return false }
            return now >= reset.addingTimeInterval(Self.usageLimitGrace)
        }
        guard !due.isEmpty else { return }
        // Make sure the plan really is usable again; otherwise wait for the API's reset time.
        // (Each session's own account: with several accounts they reset at different times.)
        let monitors = Dictionary(due.compactMap { id in limitMonitor(for: id).map { (ObjectIdentifier($0), $0) } }) { a, _ in a }
        for monitor in monitors.values { await monitor.refresh() }
        for id in due {
            // Still used up (the other window, or the API says later): wait for that.
            if let until = limitAccountReset(for: id), until > Date() {
                if usageLimitHits[id]?.resetsAt != until { usageLimitHits[id]?.resetsAt = until }
                continue
            }
            guard let hit = usageLimitHits[id], let reset = usageLimitReset(for: id) else { continue }
            guard terminals.isRunning(id) else { usageLimitHits[id] = nil; continue }
            // Still sitting at the prompt (the user hasn't carried on or been asked something).
            // (StopFailure leaves it idle; a hook older than the hit means nothing happened since.)
            let display = status(of: id).display
            if display.isBlocked { continue }
            if !display.isIdle, let hook = hookStatuses[id], hook.updatedAt > hit.at {
                usageLimitHits[id] = nil // working again
                continue
            }
            usageLimitHits[id] = nil
            continuedLimitResets[id] = reset
            limitLog.info("Continuing session \(id, privacy: .public) after the usage limit reset")
            if let session = deck.session(id) {
                logAgent("ClaudeDeck", inbound: false, "\(session.name): usage limit on \(accountLabel(accountID(of: session))) reset; sent the continue message")
            }
            let message = continueMessageText()
            pendingKicks[id] = PendingKick(message: message, sentAt: Date(), attempts: 1)
            Task { await sendContinueMessage(id, message: message) }
        }
    }

    func continueMessageText() -> String {
        let custom = deck.settings.continueMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? String(localized: "Continue where you left off.") : custom
    }

    // MARK: Kicks

    /// A kick arrived when its text shows up in the transcript.
    func kickTranscriptGrew(_ id: UUID, chunk: String) {
        guard let kick = pendingKicks[id] else { return }
        if PendingKick.arrived(kick.message, in: chunk) { pendingKicks[id] = nil }
    }

    /// Kicks that didn't arrive (the text landed before the input was ready, a background task's
    /// turn swallowed it…) are typed again while the session sits idle; after three tries the
    /// owner is told.
    func retryKicks() {
        let now = Date()
        for (id, kick) in pendingKicks {
            guard terminals.isRunning(id), deck.session(id) != nil else { pendingKicks[id] = nil; continue }
            guard now.timeIntervalSince(kick.sentAt) >= Self.kickRetryAfter,
                  !switchingAccounts.contains(id), !pendingAccountMoves.contains(id), usageLimitHits[id] == nil else { continue }
            if let hook = hookStatuses[id], hook.updatedAt > kick.sentAt, hook.event == "UserPromptSubmit" {
                pendingKicks[id] = nil
                continue
            }
            let display = status(of: id).display
            guard display.isIdle, !display.isBlocked else { continue }
            let name = deck.session(id)?.name ?? id.uuidString
            guard kick.attempts < Self.kickAttempts else {
                pendingKicks[id] = nil
                logAgent("ClaudeDeck", inbound: false, "\(name): the continue message didn't arrive after \(kick.attempts) tries; it waits for you", ok: false)
                onAccountNotice?(AccountNotice(sessionID: id, title: String(localized: "\(name) didn't continue"),
                                               body: String(localized: "ClaudeDeck typed the continue message \(kick.attempts) times; it never arrived."),
                                               switchTo: nil))
                continue
            }
            pendingKicks[id] = PendingKick(message: kick.message, sentAt: now, attempts: kick.attempts + 1)
            logAgent("ClaudeDeck", inbound: false, "\(name): the continue message didn't arrive; typed it again (try \(kick.attempts + 1))")
            Task { await sendContinueMessage(id, message: kick.message) }
        }
    }
}

extension PendingKick {
    /// The message's start in a transcript chunk (JSON-escaped like Claude Code writes it).
    static func arrived(_ message: String, in chunk: String) -> Bool {
        let head = String(message.prefix(48))
        if chunk.contains(head) { return true }
        guard let data = try? JSONSerialization.data(withJSONObject: [head]),
              let escaped = String(data: data, encoding: .utf8)?.dropFirst(2).dropLast(2) else { return false }
        return chunk.contains(String(escaped))
    }
}
