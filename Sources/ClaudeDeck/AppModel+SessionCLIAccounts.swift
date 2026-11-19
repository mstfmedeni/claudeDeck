import ClaudeDeckCore
import Foundation

/// `claudedeck account list|current|switch` (AppModel+Accounts): the accounts and their usage,
/// the caller's account, and moving the caller itself to another one.
extension AppModel {
    func cliAccountInfos(caller: UUID) -> [SessionCLIAccountInfo] {
        let settings = deck.settings
        let active = settings.newSessionAccount == ClaudeAccounts.autoID ? accountForNewSession() : accountForNewSession(settings.newSessionAccount)
        let current = deck.session(caller).map(accountID(of:))
        return settings.accountPriority.enumerated().map { index, id in
            let standing = accountStanding(id)
            let usage = standing.usage
            let running = deck.sessions.filter { $0.kind == .claude && terminals.isRunning($0.id) && accountID(of: $0) == id }.count
            return SessionCLIAccountInfo(name: id, label: accountLabel(id), priority: index + 1, active: id == active, current: id == current,
                                         loggedIn: standing.loggedIn, fiveHour: usage?.fiveHour?.usedPercent, weekly: usage?.sevenDay?.usedPercent,
                                         limited: standing.isLimited(), nearLimit: standing.isNearLimit(threshold: settings.accountNearLimitPercent),
                                         resetAt: standing.resetsAt(), sessions: running)
        }
    }

    func cliAccounts(_ caller: UUID, json: Bool) -> AgentHTTPResponse {
        let infos = cliAccountInfos(caller: caller)
        return SessionCLI.answer(200, infos, text: ClaudeAccounts.listText(infos), exit: .ok, json: json)
    }

    func cliCurrentAccount(_ caller: UUID, json: Bool) -> AgentHTTPResponse {
        guard let info = cliAccountInfos(caller: caller).first(where: \.current) else {
            return SessionCLI.failure(404, "unknown_session", exit: .unknown)
        }
        return SessionCLI.answer(200, info, text: info.name, exit: .ok, json: json)
    }

    /// The caller moves itself: answered first, then (a moment later, once the command has
    /// printed) its `claude` ends and resumes on the other account.
    func cliSwitchAccount(_ caller: UUID, form: [String: String], json: Bool) async -> AgentHTTPResponse {
        guard let session = deck.session(caller), session.kind == .claude else { return SessionCLI.failure(400, "not_claude", exit: .usage) }
        guard hasOtherAccounts else { return SessionCLI.failure(409, "no_account", exit: .failed) }
        guard !isAccountPinned(session) else { return SessionCLI.failure(409, "pinned", exit: .refused) }
        let from = accountID(of: session)
        let wanted = (form["to"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String
        if wanted.isEmpty || wanted == ClaudeAccounts.autoID {
            for id in deck.settings.accountPriority where id != from { await usageMonitor(forAccount: id)?.refresh() }
            refreshAccountLogins()
            guard let pick = accountSwitchCandidate(for: caller) else { return SessionCLI.failure(409, "no_account", exit: .failed) }
            target = pick
        } else {
            guard wanted == ClaudeAccounts.defaultID || deck.settings.account(wanted) != nil else {
                return SessionCLI.failure(404, "unknown_account", exit: .unknown)
            }
            target = wanted
        }
        guard target != from else { return SessionCLI.failure(409, "same_account", exit: .failed) }
        refreshAccountLogins()
        let standing = accountStanding(target)
        guard standing.loggedIn else { return SessionCLI.failure(409, "not_logged_in", exit: .failed) }
        guard !standing.isLimited() else { return SessionCLI.failure(409, "account_limited", exit: .failed) }
        guard !switchingAccounts.contains(caller), !restartingSessions.contains(caller) else {
            return SessionCLI.failure(409, "switching", exit: .failed)
        }
        logAgent(session.name, inbound: true, "claudedeck account switch · \(accountLabel(from)) → \(accountLabel(target))")
        Task { @MainActor [weak self] in
            // The command prints and Claude's tool call returns before the process ends.
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            if case .failure(let refusal) = await self.switchAccount(caller, to: target, reason: .cli) {
                self.logAgent(session.name, inbound: true, "claudedeck account switch: not moved (\(refusal.rawValue))", ok: false)
            }
        }
        let answer = SessionCLIAccountSwitch(from: from, to: target)
        return SessionCLI.answer(200, answer, text: "switching \(from) → \(target): this session ends and resumes there in a moment",
                                 exit: .ok, json: json)
    }

    /// `new --account NAME|auto`: nil when not given; an error for an unknown name.
    func cliAccountChoice(_ form: [String: String]) -> Result<String?, AgentHTTPRequestRefusal> {
        let raw = (form["account"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .success(nil) }
        if raw == ClaudeAccounts.autoID || raw == ClaudeAccounts.defaultID || deck.settings.account(raw) != nil { return .success(raw) }
        return .failure(.init(SessionCLI.failure(404, "unknown_account", exit: .unknown)))
    }
}
