import AppKit
import ClaudeDeckCore
import Foundation
import os

private let accountLog = Logger(subsystem: "co.codemagnet.ClaudeDeck", category: "accounts")

/// A notification about accounts; `switchTo` adds a "Switch account" action that moves the
/// session there.
struct AccountNotice {
    var sessionID: UUID?
    var title: String
    var body: String
    var switchTo: String?
}

enum AccountSwitchReason: String {
    /// The session hit its plan's usage limit.
    case limit
    /// The owner (Settings, the session's menu, a notification's action).
    case manual
    /// `claudedeck account switch` from the session itself.
    case cli
    /// It sat idle on an account that is used up.
    case idle
    /// A message was about to go into it while its account is used up.
    case delivery

    /// ClaudeDeck's own decision (cooldown, hysteresis), not the owner's or the session's.
    var isAutomatic: Bool { self == .limit || self == .idle || self == .delivery }
}

enum AccountSwitchRefusal: String, Error {
    case notClaude = "not_claude"
    case unknownAccount = "unknown_account"
    case sameAccount = "same_account"
    case switching = "switching"
    case notLoggedIn = "not_logged_in"
    case limited = "account_limited"
    case noAccount = "no_account"
    case pinned = "pinned"
    /// The conversation id isn't known yet, so it couldn't be resumed.
    case noConversation = "no_conversation"
    case worktreeMissing = "worktree_missing"
    /// The old process didn't go away (never resumed while it may still run).
    case stillRunning = "still_running"
}

/// Several Claude accounts (ClaudeAccounts.swift): which one a session runs on, each one's usage,
/// and moving a session to another account (the usage limit, or by hand) by resuming its
/// conversation there. With no account besides the default one nothing here changes anything.
extension AppModel {
    // MARK: Where

    /// `<Application Support>/ClaudeDeck/accounts/<id>` (the demo's data folder in the demo).
    var accountsFolder: URL { store.url.deletingLastPathComponent().appending(path: "accounts") }

    /// The owner's `~/.claude`, whose setup every account folder links.
    var sharedClaudeFolder: URL {
        if !Self.isDemo, let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return Self.claudeHome.appending(path: ".claude")
    }

    /// The default account's `.claude.json` (the demo's own in the demo).
    var defaultClaudeConfigFile: URL? {
        ClaudeTrust.configFile(environment: ProcessInfo.processInfo.environment,
                               home: FileManager.default.homeDirectoryForCurrentUser.path, demo: Self.isDemo)
    }

    func claudeConfigFile(forAccount id: String) -> URL? {
        guard let account = deck.settings.account(id) else { return id == ClaudeAccounts.defaultID ? defaultClaudeConfigFile : nil }
        return ClaudeAccounts.globalConfigFile(configDir: account.configDir, home: NSHomeDirectory())
    }

    var hasOtherAccounts: Bool { !deck.settings.accounts.isEmpty }

    // MARK: Which account

    /// The account a Claude session runs on (or will, when it starts): its own, if that still
    /// exists, else the default one.
    func accountID(of session: DeckSession) -> String {
        guard let id = session.account, deck.settings.account(id) != nil else { return ClaudeAccounts.defaultID }
        return id
    }

    func accountLabel(_ id: String) -> String {
        if id == ClaudeAccounts.defaultID { return String(localized: "Default account") }
        return deck.settings.account(id)?.label ?? id
    }

    /// Never moved automatically: pinned itself, or its project is.
    func isAccountPinned(_ session: DeckSession) -> Bool {
        session.accountPinned || projectAccountPin(session.projectID) != nil
    }

    /// The account a project's sessions are pinned to, if it still exists.
    func projectAccountPin(_ projectID: UUID) -> String? {
        guard let pin = deck.project(projectID)?.account else { return nil }
        return pin == ClaudeAccounts.defaultID || deck.settings.account(pin) != nil ? pin : nil
    }

    /// The account whose usage the sidebar meter and the phone show: where new sessions start
    /// now (the default account while there are no others).
    var shownUsageAccount: String { hasOtherAccounts ? effectiveNewSessionAccount() : ClaudeAccounts.defaultID }
    var shownUsageMonitor: UsageMonitor { usageMonitor(forAccount: shownUsageAccount) ?? usage }

    func usageMonitor(forAccount id: String) -> UsageMonitor? {
        id == ClaudeAccounts.defaultID ? usage : accountUsage[id]
    }

    /// What is known about an account: its usage (the last reading while it can't be read now),
    /// and ClaudeDeck's own record of it being used up.
    func accountStanding(_ id: String) -> AccountStanding {
        let monitor = usageMonitor(forAccount: id)
        return AccountStanding(id: id, loggedIn: id == ClaudeAccounts.defaultID || accountLogins[id] != nil,
                               usage: monitor?.state.usage ?? monitor?.lastKnownUsage, limitedUntil: accountLimits[id]?.until)
    }

    var accountStandings: [String: AccountStanding] {
        Dictionary(uniqueKeysWithValues: deck.settings.accountPriority.map { ($0, accountStanding($0)) })
    }

    /// Where a new session starts when nothing else says: the setting (`auto`: the first by
    /// priority with headroom).
    func accountForNewSession(_ choice: String? = nil) -> String {
        let choice = choice ?? deck.settings.newSessionAccount
        if choice == ClaudeAccounts.autoID {
            return AccountPolicy.pickForNew(order: deck.settings.accountPriority, standings: accountStandings,
                                            threshold: deck.settings.accountNearLimitPercent)
        }
        return choice == ClaudeAccounts.defaultID || deck.settings.account(choice) != nil ? choice : ClaudeAccounts.defaultID
    }

    /// Where a new session nobody chose an account for starts right now: `accountForNewSession`,
    /// or, when that one is at or near its limit, the first account with room (the same rule
    /// `accountEnvironment` applies).
    func effectiveNewSessionAccount() -> String {
        let chosen = accountForNewSession()
        let settings = deck.settings
        return AccountPolicy.redirectNew(from: chosen, order: settings.accountPriority, standings: accountStandings,
                                         threshold: settings.accountNearLimitPercent) ?? chosen
    }

    // MARK: Starting on an account

    /// Called by `launch` for every Claude start: decides the account (a project's pin, the
    /// session's own, or for a fresh start the one new sessions use), prepares its folder and
    /// returns the environment for it. Nothing (and no change) without other accounts.
    func accountEnvironment(forLaunch id: UUID, fresh: Bool, cwd: String) -> [String: String] {
        guard hasOtherAccounts, let session = deck.session(id), session.kind == .claude else { return [:] }
        let settings = deck.settings
        let pinned = isAccountPinned(session)
        // Its own account, when it has one that still exists (given by `new --account`, a switch…).
        let own = session.account.flatMap { $0 == ClaudeAccounts.defaultID || settings.account($0) != nil ? $0 : nil }
        var target = projectAccountPin(session.projectID) ?? own ?? (fresh ? accountForNewSession() : ClaudeAccounts.defaultID)
        // Avoid an account that's used up: with "switch accounts" on, or for a fresh start nobody
        // chose an account for (there also one that's near its limit). Never for a pinned one, or
        // one being moved on purpose.
        let unchosen = fresh && own == nil
        let limited = accountStanding(target).isLimited()
        let mayLeave = limited ? settings.accountSwitchMode == .auto || unchosen : unchosen
        if mayLeave, !pinned, !switchingAccounts.contains(id),
           let other = AccountPolicy.redirectNew(from: target, order: settings.accountPriority, standings: accountStandings,
                                                 threshold: settings.accountNearLimitPercent) {
            let why = limited ? "at its limit" : "near its limit"
            logAgent("ClaudeDeck", inbound: false, "\(session.name): starts on \(accountLabel(other)) (\(accountLabel(target)) is \(why))")
            target = other
        }
        if session.account != target { mutate(userInitiated: false) { $0.updateSession(id) { $0.account = target } } }
        guard let account = settings.account(target) else { return [:] }
        let project = deck.project(session.projectID)?.path
        prepareAccountFolder(account, folders: [cwd, project].compactMap { $0 })
        return ClaudeAccounts.environment(for: account)
    }

    /// Links the shared setup into the account's folder and brings its `.claude.json` up to
    /// date for `folders` (trust, MCP servers) from the default config and `extraSources`.
    @discardableResult
    func prepareAccountFolder(_ account: ClaudeAccount, folders: [String], extraSources: [URL] = []) -> ClaudeAccounts.SyncOutcome {
        let dir = URL(fileURLWithPath: account.configDir)
        do {
            let blocked = try ClaudeAccounts.prepareFolder(dir, source: sharedClaudeFolder)
            if !blocked.isEmpty {
                accountLog.info("Account \(account.id, privacy: .public): not linked (in the way): \(blocked.joined(separator: ", "), privacy: .public)")
            }
        } catch {
            accountLog.error("Account \(account.id, privacy: .public): folder: \(error.localizedDescription, privacy: .public)")
        }
        let sources = [defaultClaudeConfigFile].compactMap { $0 } + extraSources
        let outcome = ClaudeAccounts.syncConfig(ClaudeAccounts.globalConfigFile(configDir: account.configDir, home: NSHomeDirectory()),
                                                sources: sources, folders: Array(Set(folders)), lockWait: 1)
        if case .failed(let why) = outcome {
            accountLog.error("Account \(account.id, privacy: .public): .claude.json not updated: \(why, privacy: .public)")
        }
        return outcome
    }

    // MARK: Usage and logins

    /// One usage monitor per account besides the default one; logins re-read.
    func syncAccountMonitors() {
        let accounts = deck.settings.accounts
        for (index, account) in accounts.enumerated() where accountUsage[account.id] == nil {
            let monitor = UsageMonitor(configDir: account.configDir, demoIndex: index + 1)
            accountUsage[account.id] = monitor
            let id = account.id
            monitor.onUpdate = { [weak self] in self?.accountUsageUpdated(id) }
            monitor.start()
        }
        for id in accountUsage.keys where !accounts.contains(where: { $0.id == id }) {
            accountUsage[id]?.stop()
            accountUsage[id] = nil
        }
        refreshAccountLogins()
    }

    /// Who is logged in on each account, from its `.claude.json` (Claude Code writes the
    /// address there at login; no secret is read). The demo counts every account as logged in.
    func refreshAccountLogins() {
        var logins: [String: String] = [:]
        for account in deck.settings.accounts {
            if Self.isDemo {
                logins[account.id] = "\(account.id)@example.com"
                continue
            }
            let file = ClaudeAccounts.globalConfigFile(configDir: account.configDir, home: NSHomeDirectory())
            if let email = ClaudeAccounts.loggedInEmail(ClaudeAccounts.readConfig(file)) { logins[account.id] = email }
        }
        if logins != accountLogins { accountLogins = logins }
    }

    /// The default account's address, for Settings (nil when not known).
    var defaultAccountEmail: String? {
        if Self.isDemo { return "owner@example.com" }
        return defaultClaudeConfigFile.flatMap { ClaudeAccounts.loggedInEmail(ClaudeAccounts.readConfig($0)) }
    }

    // MARK: Managing accounts

    /// Adds an account (its folder, linked to the shared setup) and returns it; the owner logs in
    /// with `openAccountLogin`.
    @discardableResult
    func addAccount(label raw: String) -> ClaudeAccount? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = ClaudeAccounts.newID(for: label, taken: Set(deck.settings.accounts.map(\.id))) else { return nil }
        let account = ClaudeAccount(id: id, label: String(label.prefix(60)),
                                    configDir: accountsFolder.appending(path: id).standardizedFileURL.path)
        prepareAccountFolder(account, folders: [])
        mutate { deck in
            deck.settings.accounts.append(account)
            deck.settings.accountOrder = deck.settings.accountPriority
        }
        syncAccountMonitors()
        logAgent("ClaudeDeck", inbound: false, "account added: \(account.label) (\(account.id))")
        return account
    }

    /// A terminal running `claude auth login` on the account, in the selected project: the owner
    /// logs in there (ClaudeDeck never sees the password or the token).
    func openAccountLogin(_ id: String) {
        guard let account = deck.settings.account(id) else { return }
        guard let projectID = selectedProjectID ?? deck.projects.first?.id else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Add a project first")
            alert.informativeText = String(localized: "The login runs in a terminal, and terminals belong to a project.")
            alert.runAsSheet()
            return
        }
        let claude = claudePath.map(ShellEnvironment.escapedPath) ?? "claude"
        var created: DeckSession?
        mutate { deck in
            created = deck.addCommandShell(to: projectID, command: "\(claude) auth login")
            if let id = created?.id {
                deck.updateSession(id) {
                    $0.autoStart = false
                    $0.account = account.id
                    $0.name = String(localized: "Login · \(account.label)")
                }
            }
        }
        guard let session = created else { return }
        launch(session.id, resume: false)
        selectedSessionID = session.id
    }

    /// Removes an account (not while a session runs on it). Its folder goes to the Trash; the
    /// login stays in the Keychain until `claude auth logout` (run in its login terminal first).
    func removeAccount(_ id: String) {
        guard let account = deck.settings.account(id) else { return }
        let running = deck.sessions.filter { $0.kind == .claude && accountID(of: $0) == id && terminals.isRunning($0.id) }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(account.label) is in use")
            alert.informativeText = String(localized: "Move or stop its sessions first: \(running.map(\.name).joined(separator: ", "))")
            alert.runAsSheet()
            return
        }
        guard Confirm.ask(String(localized: "Remove the account \(account.label)?"),
                          detail: String(localized: "Its sessions move to the default account. Its folder goes to the Trash; conversations stay (they're shared). The login stays in the Keychain: run `claude auth logout` in its login terminal first to remove it."),
                          action: String(localized: "Remove")) else { return }
        let prefix = account.configDir + "/"
        mutate { deck in
            deck.settings.accounts.removeAll { $0.id == id }
            deck.settings.accountOrder.removeAll { $0 == id }
            if deck.settings.newSessionAccount == id { deck.settings.newSessionAccount = ClaudeAccounts.defaultID }
            for index in deck.projects.indices where deck.projects[index].account == id { deck.projects[index].account = nil }
            for index in deck.sessions.indices where deck.sessions[index].account == id {
                deck.sessions[index].account = nil
                deck.sessions[index].accountPinned = false
            }
            // Transcripts are found again under the default folder (the same files).
            for index in deck.sessions.indices where deck.sessions[index].transcriptPath?.hasPrefix(prefix) == true {
                deck.sessions[index].transcriptPath = nil
            }
        }
        if accountLimits.removeValue(forKey: id) != nil { saveAccountLimits() }
        syncAccountMonitors()
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: account.configDir), resultingItemURL: nil)
        logAgent("ClaudeDeck", inbound: false, "account removed: \(account.label) (\(account.id))")
    }

    /// Moves an account up (-1) or down (+1) in the priority order.
    func moveAccount(_ id: String, by offset: Int) {
        var order = deck.settings.accountPriority
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        mutate { $0.settings.accountOrder = order }
    }

    func setProjectAccount(_ projectID: UUID, to id: String?) {
        mutate { deck in
            guard let index = deck.projects.firstIndex(where: { $0.id == projectID }) else { return }
            deck.projects[index].account = id
        }
    }

    func setAccountPinned(_ pinned: Bool, for id: UUID) {
        mutate { $0.updateSession(id) { $0.accountPinned = pinned } }
    }

    // MARK: Moving a session

    /// Ends the session's `claude` (after it has exited, never while it may still run) and
    /// resumes the same conversation on `target`: same ClaudeDeck session (id, pane, name,
    /// options, who started it), same Claude session id. Typed "continue" message only when it
    /// was in the middle of something.
    @discardableResult
    func switchAccount(_ id: UUID, to target: String, reason: AccountSwitchReason) async -> Result<String, AccountSwitchRefusal> {
        guard let session = deck.session(id), session.kind == .claude, let project = deck.project(session.projectID) else {
            return .failure(.notClaude)
        }
        guard target == ClaudeAccounts.defaultID || deck.settings.account(target) != nil else { return .failure(.unknownAccount) }
        let from = accountID(of: session)
        guard target != from else { return .failure(.sameAccount) }
        guard !switchingAccounts.contains(id), !restartingSessions.contains(id) else { return .failure(.switching) }
        refreshAccountLogins()
        guard accountStanding(target).loggedIn else { return .failure(.notLoggedIn) }
        let plan = SessionRestart.plan(
            claudeSessionID: session.claudeSessionID,
            resumableID: deck.resumableID(for: id),
            worktreeName: session.worktreeName,
            workingDirectoryExists: session.workingDirectory.map { FileManager.default.fileExists(atPath: $0) }
        )
        switch plan {
        case .resume, .fresh: break
        case .continueLatest: return .failure(.noConversation)
        case .unavailable: return .failure(.worktreeMissing)
        }
        switchingAccounts.insert(id)
        restartingSessions.insert(id)
        defer {
            switchingAccounts.remove(id)
            restartingSessions.remove(id)
        }
        let display = status(of: id).display
        // In the middle of something: it stopped on the limit, or it is working right now.
        let atLimit = usageLimitHits[id] != nil
        let midTask = atLimit || display.isRunning
        // The folder's trust (and MCP servers) follow the session to the other account.
        let folders = Array(Set([session.workingDirectory ?? project.path, project.path]))
        await carryFolderSetup(folders, from: from, to: target)
        if terminals.isRunning(id) {
            await stopForRestart(id, graceful: SessionRestart.exitsGracefully(status(of: id).display.activityValue))
        }
        guard await waitUntilStopped(id), deck.session(id) != nil else { return .failure(.stillRunning) }
        mutate(userInitiated: false) { $0.updateSession(id) {
            $0.account = target
            $0.busyAtQuit = false // the message below is the one it gets
        } }
        usageLimitHits[id] = nil
        continuedLimitResets[id] = nil
        accountSwitchOffered[id] = nil
        switch plan {
        case .resume(let sid): launch(id, resume: true, resumeID: sid)
        default: launch(id, resume: false)
        }
        if reason.isAutomatic { lastAccountMove[id] = Date() }
        let line = "\(session.name): account \(accountLabel(from)) → \(accountLabel(target)) (\(moveReasonText(reason, from: from)))"
        accountLog.info("\(line, privacy: .public)")
        logAgent("ClaudeDeck", inbound: false, line)
        // A silent move (an idle session) isn't worth a notification; the log has it.
        if reason != .idle && reason != .delivery { notifyAccountSwitch(id, from: from, to: target, reason: reason) }
        if midTask {
            let message = atLimit ? AccountSwitchMessage.afterLimit : AccountSwitchMessage.manual
            // Kept until the transcript shows it arrived; typed again otherwise (retryKicks).
            pendingKicks[id] = PendingKick(message: message, sentAt: Date(), attempts: 1)
            Task { await sendContinueMessage(id, message: message) }
        }
        return .success(target)
    }

    /// Why a session moved, for the activity log.
    private func moveReasonText(_ reason: AccountSwitchReason, from: String) -> String {
        let until = accountStanding(from).resetsAt().map { " until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        switch reason {
        case .limit: return "stopped on the usage limit; \(accountLabel(from)) is used up\(until)"
        case .idle: return "idle on \(accountLabel(from)), which is used up\(until); moved before its next use"
        case .delivery: return "a message for it while \(accountLabel(from)) is used up\(until)"
        case .manual: return "by the owner"
        case .cli: return "claudedeck account switch"
        }
    }

    /// Trust and MCP servers for `folders` on `target`, from the default config and `from`'s.
    private func carryFolderSetup(_ folders: [String], from: String, to target: String) async {
        let sources = [claudeConfigFile(forAccount: from)].compactMap { $0 }
        if let account = deck.settings.account(target) {
            prepareAccountFolder(account, folders: folders, extraSources: sources)
            return
        }
        // Back to the default account: only the trust answer, the way ClaudeTrust adds it.
        guard let file = defaultClaudeConfigFile else { return }
        let configs = sources.compactMap(ClaudeAccounts.readConfig)
        for folder in folders where ClaudeAccounts.isTrusted(folder, in: configs) {
            let outcome = await Task.detached { ClaudeTrust.trust(folder, in: file) }.value
            if outcome == .trusted { logAgent("ClaudeDeck", inbound: false, "trusted \(folder) for the default account (it was trusted on \(accountLabel(from)))") }
        }
    }

    private func notifyAccountSwitch(_ id: UUID, from: String, to: String, reason: AccountSwitchReason) {
        guard let session = deck.session(id) else { return }
        let title = String(localized: "\(session.name): account switched")
        let body = reason == .limit
            ? String(localized: "\(accountLabel(from)) hit its usage limit; continuing on \(accountLabel(to)).")
            : String(localized: "Now running on \(accountLabel(to)) (was \(accountLabel(from))).")
        onAccountNotice?(AccountNotice(sessionID: id, title: title, body: body, switchTo: nil))
        remote.pushNotice(title: title, body: body, collapseID: "account-\(id.uuidString)", threadID: "accounts")
    }

    // MARK: The usage limit

    /// A session hit its plan's usage limit (AppModel+UsageLimit): its account counts as used up
    /// until the reset; with "switch accounts" on, the session moves (or the owner is asked).
    func accountLimitHit(_ id: UUID, resetsAt: Date?) {
        guard let session = deck.session(id), session.kind == .claude else { return }
        let account = accountID(of: session)
        let until = resetsAt ?? accountStanding(account).usage?.exhaustedUntil ?? Date().addingTimeInterval(30 * 60)
        recordAccountLimit(account, until: until)
        guard hasOtherAccounts, deck.settings.accountSwitchMode != .off, !isAccountPinned(session) else { return }
        Task { await moveAfterLimit(id) }
    }

    /// The account a session that hit its limit would move to now (nil: none has room).
    func accountSwitchCandidate(for id: UUID) -> String? {
        guard let session = deck.session(id) else { return nil }
        let pick = AccountPolicy.pickForSwitch(order: deck.settings.accountPriority, standings: accountStandings,
                                               excluding: [accountID(of: session)], threshold: deck.settings.accountNearLimitPercent)
        if case .account(let id) = pick { return id }
        return nil
    }

    /// `wait` and `list`: a session at its limit that is about to move keeps counting as running.
    func accountSwitchPending(_ id: UUID) -> Bool {
        if switchingAccounts.contains(id) || pendingAccountMoves.contains(id) { return true }
        guard hasOtherAccounts, deck.settings.accountSwitchMode == .auto, usageLimitHits[id] != nil,
              let session = deck.session(id), !isAccountPinned(session) else { return false }
        return accountSwitchCandidate(for: id) != nil
    }

    /// The facts `AccountPolicy.decideMove` goes by (background tasks: false; see `hasBackgroundTasks`).
    func accountMoveFacts(_ id: UUID) -> AccountPolicy.SessionFacts? {
        guard let session = deck.session(id), session.kind == .claude else { return nil }
        let display = status(of: id).display
        return AccountPolicy.SessionFacts(account: accountID(of: session), pinned: isAccountPinned(session), working: display.isRunning,
                                          blocked: display.isBlocked, atLimit: usageLimitHits[id] != nil, lastMovedAt: lastAccountMove[id])
    }

    func decideAccountMove(_ facts: AccountPolicy.SessionFacts, trigger: AccountPolicy.MoveTrigger) -> AccountPolicy.MoveDecision {
        AccountPolicy.decideMove(facts, trigger: trigger, order: deck.settings.accountPriority, standings: accountStandings,
                                 threshold: deck.settings.accountNearLimitPercent)
    }

    /// Moves (auto) or offers to move (notify) a session that hit its limit; with no account to
    /// move to it waits: it moves as soon as another account has room (`balanceAccounts`), or gets
    /// the usual "continue" when its own limit resets.
    func moveAfterLimit(_ id: UUID) async {
        guard let hit = usageLimitHits[id], let session = deck.session(id), !isAccountPinned(session) else { return }
        let ids = Set(deck.settings.accountPriority).subtracting([accountID(of: session)])
        for account in ids { await usageMonitor(forAccount: account)?.refresh() }
        refreshAccountLogins()
        guard usageLimitHits[id] == hit, terminals.isRunning(id), let facts = accountMoveFacts(id) else { return }
        let decision = decideAccountMove(facts, trigger: .limit)
        guard case .move(let target) = decision else {
            // Said once per limit event; the watch keeps trying every half minute.
            guard accountSwitchOffered[id] != hit.at else { return }
            accountSwitchOffered[id] = hit.at
            switch decision {
            case .stay(.noRoom(let earliest)):
                let when = earliest.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
                logAgent("ClaudeDeck", inbound: false, "\(session.name): every account is at its limit; waiting" + (when.isEmpty ? "" : " (first reset \(when))"), ok: false)
                onAccountNotice?(AccountNotice(sessionID: id, title: String(localized: "\(session.name): every account is at its limit"),
                                               body: when.isEmpty ? String(localized: "It continues when a limit resets.")
                                                                  : String(localized: "It continues when a limit resets (first at \(when))."),
                                               switchTo: nil))
            case .stay(.cooldown(let until)):
                logAgent("ClaudeDeck", inbound: false, "\(session.name): at its limit; moved a moment ago, may move again at \(until.formatted(date: .omitted, time: .shortened))", ok: false)
            default:
                break
            }
            return
        }
        switch deck.settings.accountSwitchMode {
        case .off: return
        case .auto:
            if case .failure(let refusal) = await switchAccount(id, to: target, reason: .limit) {
                automaticMoveFailed(id, to: target, refusal)
            }
        case .notify:
            guard accountSwitchOffered[id] != hit.at else { return }
            accountSwitchOffered[id] = hit.at
            let title = String(localized: "\(session.name): usage limit reached")
            let body = String(localized: "\(accountLabel(accountID(of: session))) is at its limit. Switch to \(accountLabel(target))?")
            logAgent("ClaudeDeck", inbound: false, "\(session.name): usage limit; offered a move to \(accountLabel(target))")
            onAccountNotice?(AccountNotice(sessionID: id, title: title, body: body, switchTo: target))
            remote.pushNotice(title: title, body: body, collapseID: "account-\(id.uuidString)", threadID: "accounts")
        }
    }

    // MARK: Keeping sessions on accounts with room

    /// Every half minute and after every usage reading (with "switch accounts" on): a session
    /// stopped on its limit moves as soon as another account has room; an idle one sitting on a
    /// used-up account moves (silently) before it is next used. One at a time.
    func balanceAccounts() async {
        guard hasOtherAccounts, deck.settings.accountSwitchMode == .auto, !balancingAccounts else { return }
        balancingAccounts = true
        defer { balancingAccounts = false }
        for session in deck.sessions where session.kind == .claude {
            let id = session.id
            guard terminals.isRunning(id), !switchingAccounts.contains(id), !restartingSessions.contains(id),
                  !pendingAccountMoves.contains(id), let facts = accountMoveFacts(id) else { continue }
            if facts.atLimit {
                guard case .move = decideAccountMove(facts, trigger: .limit) else { continue }
                await moveAfterLimit(id)
                continue
            }
            guard readyForInput(id), case .move = decideAccountMove(facts, trigger: .idle) else { continue }
            // Only now read the transcript: a move would end its background tasks.
            var withTasks = facts
            withTasks.backgroundTasks = await hasBackgroundTasks(id)
            guard readyForInput(id), case .move(let target) = decideAccountMove(withTasks, trigger: .idle) else { continue }
            if case .failure(let refusal) = await switchAccount(id, to: target, reason: .idle) {
                automaticMoveFailed(id, to: target, refusal)
            }
        }
    }

    /// Not tried again for `moveCooldown` (no retry every half minute); a move already under
    /// way (another path got there first) isn't a failure.
    private func automaticMoveFailed(_ id: UUID, to target: String, _ refusal: AccountSwitchRefusal, detail: String = "") {
        guard refusal != .switching else { return }
        lastAccountMove[id] = Date()
        let name = deck.session(id)?.name ?? id.uuidString
        logAgent("ClaudeDeck", inbound: false, "\(name): couldn't move to \(accountLabel(target)) (\(refusal.rawValue))\(detail)", ok: false)
    }

    /// Idle at its prompt, started up, nothing typed into it that hasn't begun.
    func readyForInput(_ id: UUID) -> Bool {
        guard terminals.isRunning(id), status(of: id).display.isIdle,
              let hook = hookStatuses[id], hook.updatedAt >= (launchedAt[id] ?? .distantPast) else { return false }
        return queueAwaiting[id] == nil && !pendingContinue.contains(id) && !pendingCompact.contains(id) && pendingKicks[id] == nil
    }

    /// Background shells or agents still running in the session (its transcript's last part).
    /// Read again only when the transcript has grown.
    func hasBackgroundTasks(_ id: UUID) async -> Bool {
        guard let path = tailers[id]?.url.path ?? deck.session(id)?.transcriptPath else { return false }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
        if let cached = backgroundTaskCheck[id], cached.size == size { return cached.running }
        let running = await Task.detached(priority: .utility) {
            guard let tail = AppModel.tail(of: path, bytes: 4 * 1024 * 1024) else { return false }
            return !Transcript.runningBackgroundTasks(in: tail).isEmpty
        }.value
        backgroundTaskCheck[id] = (size, running)
        return running
    }

    /// Called before a message goes into a Claude session (a queued prompt, `send`, a decision's
    /// answer, the phone): when it sits on a used-up account and another has room, it moves first
    /// and the message waits in its queue until it is back. True: hold the message.
    func holdForAccountMove(_ id: UUID) -> Bool {
        if pendingAccountMoves.contains(id) || switchingAccounts.contains(id) { return true }
        guard hasOtherAccounts, deck.settings.accountSwitchMode == .auto, terminals.isRunning(id),
              !restartingSessions.contains(id), let facts = accountMoveFacts(id),
              case .move(let target) = decideAccountMove(facts, trigger: .delivery) else { return false }
        pendingAccountMoves.insert(id)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.switchAccount(id, to: target, reason: .delivery)
            self.pendingAccountMoves.remove(id)
            if case .failure(let refusal) = result {
                self.automaticMoveFailed(id, to: target, refusal, detail: "; its message goes in here")
            }
            self.drainQueues()
        }
        return true
    }

    // MARK: What is known about each account

    /// Every usage reading: a full window marks the account used up until its reset (kept across
    /// relaunches); then sessions may move.
    func accountUsageUpdated(_ account: String) {
        if let usage = usageMonitor(forAccount: account)?.state.usage {
            let next = AccountPolicy.limitRecord(accountLimits[account], after: usage)
            if next != accountLimits[account] {
                if let next, (accountLimits[account]?.until ?? .distantPast) < Date() {
                    logAgent("ClaudeDeck", inbound: false, "\(accountLabel(account)) is used up until \(next.until.formatted(date: .abbreviated, time: .shortened)) (usage)")
                } else if next == nil {
                    logAgent("ClaudeDeck", inbound: false, "\(accountLabel(account)) has room again (usage)")
                }
                accountLimits[account] = next
                saveAccountLimits()
            }
        }
        scheduleAccountBalance()
    }

    func recordAccountLimit(_ account: String, until: Date) {
        let now = Date()
        let old = accountLimits[account]
        guard (old?.until ?? .distantPast) < until else { return }
        accountLimits[account] = AccountLimitRecord(until: until, recordedAt: now)
        saveAccountLimits()
    }

    private func scheduleAccountBalance() {
        guard hasOtherAccounts, !accountBalanceScheduled else { return }
        accountBalanceScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.accountBalanceScheduled = false
            await self.balanceAccounts()
        }
    }

    private var accountLimitsFile: URL { store.url.deletingLastPathComponent().appending(path: "account-limits.json") }

    func loadAccountLimits() {
        guard let data = try? Data(contentsOf: accountLimitsFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([String: AccountLimitRecord].self, from: data) else { return }
        let now = Date()
        accountLimits = records.filter { $0.value.until > now }
    }

    func saveAccountLimits() {
        let now = Date()
        let live = accountLimits.filter { $0.value.until > now }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(live) else { return }
        try? data.write(to: accountLimitsFile, options: .atomic)
    }
}
