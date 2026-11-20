import AppKit
import ClaudeDeckCore
import UserNotifications

/// Notifications, Dock badge and Dock bounce for session state changes.
@MainActor
final class AttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let permissionCategory = "permission"
    nonisolated static let approveAction = "approve"
    nonisolated static let denyAction = "deny"
    nonisolated static let agentCategory = "agentRegistration"
    nonisolated static let accountCategory = "accountSwitch"
    nonisolated static let switchAccountAction = "switchAccount"
    /// A ServerPlan gate a session waits on: Approve / Refuse right from the banner.
    nonisolated static let approvalCategory = "ownerApproval"
    /// A domain purchase: only Refuse from the banner; buying takes the card in the app.
    nonisolated static let purchaseCategory = "ownerApprovalPurchase"
    nonisolated static let loadCategory = "systemLoad"
    nonisolated static let showAgentsAction = "showAgents"
    /// A ServerPlan container problem: Open Logs, and Fix with Claude where its project matches.
    nonisolated static let containerCategory = "serverPlanContainer"
    nonisolated static let containerFixCategory = "serverPlanContainerFix"
    nonisolated static let openLogsAction = "openLogs"
    nonisolated static let fixWithClaudeAction = "fixWithClaude"
    private let model: AppModel
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        center?.delegate = self
        // Answered in place: the keystroke goes into the terminal, no need to bring the app up.
        center?.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.permissionCategory,
                actions: [
                    UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Allow"), options: []),
                    UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Deny"), options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.agentCategory,
                actions: [
                    UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Approve"), options: []),
                    UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Reject"), options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.approvalCategory,
                actions: [
                    UNNotificationAction(identifier: Self.approveAction, title: String(localized: "Approve"), options: [.authenticationRequired]),
                    UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Refuse"), options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.purchaseCategory,
                actions: [UNNotificationAction(identifier: Self.denyAction, title: String(localized: "Refuse"), options: [.destructive])],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.accountCategory,
                actions: [UNNotificationAction(identifier: Self.switchAccountAction, title: String(localized: "Switch Account"), options: [])],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.containerCategory,
                actions: [UNNotificationAction(identifier: Self.openLogsAction, title: String(localized: "Open Logs"), options: [.foreground])],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.containerFixCategory,
                actions: [
                    UNNotificationAction(identifier: Self.openLogsAction, title: String(localized: "Open Logs"), options: [.foreground]),
                    UNNotificationAction(identifier: Self.fixWithClaudeAction, title: String(localized: "Fix with Claude"), options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.loadCategory,
                actions: [UNNotificationAction(identifier: Self.showAgentsAction, title: String(localized: "Show Agents"), options: [.foreground])],
                intentIdentifiers: []
            ),
        ])
        LoadController.shared.onOverloaded = { [weak self] title, body in self?.loadNotice(title: title, body: body) }
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        model.onAttention = { [weak self] event in self?.handle(event) }
        model.remote.onAttention = { [weak self] session, hostName in self?.handleRemote(session, hostName: hostName) }
        model.remote.onAttentionCleared = { [weak self] ids in
            self?.center?.removeDeliveredNotifications(withIdentifiers: ids.map { "remote-\($0.uuidString)" })
        }
        model.onCountsChanged = { [weak self] in self?.updateBadge() }
        model.onAgentRegistered = { [weak self] record in self?.agentRegistered(record) }
        model.onSessionNotice = { [weak self] id, text in self?.sessionNotice(id, text) }
        model.onAccountNotice = { [weak self] notice in self?.accountNotice(notice) }
        let previousDecisions = model.onDecisionsChanged
        model.onDecisionsChanged = { [weak self] added in
            previousDecisions?(added)
            if let added { self?.decisionAsked(added) }
            self?.updateBadge()
            // Answered, cancelled or removed: its notification goes too.
            if let self, added == nil {
                let done = self.model.decisions.decisions.filter { !$0.isPending }.map { "decision-\($0.id)" }
                if !done.isEmpty { self.center?.removeDeliveredNotifications(withIdentifiers: done) }
            }
        }
        model.approvals.observe { [weak self] change in
            switch change {
            case .added(let approval): self?.approvalAsked(approval)
            case .resolved(let resolved): self?.center?.removeDeliveredNotifications(withIdentifiers: ["approval-\(resolved.id)"])
            }
        }
        ServerPlanController.shared.onNotice = { [weak self, weak model] notice in
            self?.serverPlanNotice(notice)
            model?.remote.pushNotice(title: notice.title, body: notice.body, collapseID: notice.id)
        }
        ServerPlanController.shared.onCleared = { [weak self] ids in
            self?.center?.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// `claudedeck notify` / `ask` from a session's terminal (the caller checked the setting).
    private func sessionNotice(_ sessionID: UUID, _ text: String) {
        guard let center, let session = model.deck.session(sessionID) else { return }
        let project = model.deck.project(session.projectID)?.name ?? ""
        let content = UNMutableNotificationContent()
        content.title = session.name == project || project.isEmpty ? session.name : "\(session.name) — \(project)"
        content.body = text
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString
        center.add(UNNotificationRequest(identifier: "cli-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// A session moved to another account, or could (with a "Switch Account" action), or every
    /// account is at its limit (AppModel+Accounts).
    private func accountNotice(_ notice: AccountNotice) {
        if model.deck.settings.bounceDock, notice.switchTo != nil, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard model.deck.settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.switchTo == nil ? nil : .default
        var info: [String: Any] = [:]
        if let id = notice.sessionID {
            info["sessionID"] = id.uuidString
            content.threadIdentifier = id.uuidString
        }
        if let target = notice.switchTo {
            info["switchAccount"] = target
            content.categoryIdentifier = Self.accountCategory
        }
        content.userInfo = info
        let key = notice.sessionID?.uuidString ?? UUID().uuidString
        center.add(UNNotificationRequest(identifier: "account-\(key)", content: content, trigger: nil))
    }

    /// The Mac became overloaded (once per episode; the caller checked the settings). Clicking,
    /// or "Show Agents", opens the agents overview.
    private func loadNotice(title: String, body: String) {
        if model.deck.settings.bounceDock, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.loadCategory
        content.userInfo = ["systemLoad": true]
        content.threadIdentifier = "systemLoad"
        center.add(UNNotificationRequest(identifier: "system-load", content: content, trigger: nil))
    }

    /// `claudedeck decide`: a decision waits for the owner (clicking opens Your Decisions).
    private func decisionAsked(_ decision: OwnerDecision) {
        if model.deck.settings.bounceDock, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard model.deck.settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = decision.project.isEmpty ? String(localized: "Decision needed") : String(localized: "Decision needed — \(decision.project)")
        content.body = decision.question
        content.sound = .default
        content.userInfo = ["decision": decision.id]
        content.threadIdentifier = "decisions"
        center.add(UNNotificationRequest(identifier: "decision-\(decision.id)", content: content, trigger: nil))
    }

    /// A session waits for an approval: shown whatever the notification setting (nothing else
    /// asks; the owner has 2 minutes). Clicking opens the Approvals tab.
    private func approvalAsked(_ approval: OwnerApproval) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = approval.isPurchase ? String(localized: "Purchase waiting for your approval") : String(localized: "Approval needed")
        content.subtitle = approval.title
        content.body = (approval.summary.isEmpty ? "" : approval.summary + "\n")
            + (approval.isPurchase ? String(localized: "Buy it from the card in ClaudeDeck. Without an answer in 2 minutes it's refused.")
                                   : String(localized: "Without an answer in 2 minutes it's refused."))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = approval.isPurchase ? Self.purchaseCategory : Self.approvalCategory
        content.userInfo = ["approval": approval.id]
        content.threadIdentifier = "approvals"
        center.add(UNNotificationRequest(identifier: "approval-\(approval.id)", content: content, trigger: nil))
    }

    /// A ServerPlan deploy failed or a server went away (clicking shows the deploy log).
    private func serverPlanNotice(_ notice: ServerPlanNotice) {
        if model.deck.settings.bounceDock, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard model.deck.settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.isFailure ? .default : nil
        if let id = notice.deploymentID { content.userInfo = ["serverPlanDeployment": id] }
        if let container = notice.container {
            content.userInfo = ["serverPlanContainer": container.name, "serverPlanServerID": container.serverID, "serverPlanServer": container.server]
            content.categoryIdentifier = container.canFix ? Self.containerFixCategory : Self.containerCategory
        }
        content.threadIdentifier = "serverplan"
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    /// An agent signed itself up: it waits for approval (shown whatever the notification setting,
    /// since nothing else asks the user).
    private func agentRegistered(_ record: AgentRegistration) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Agent waiting for approval")
        let needsInfo = !record.needs.isEmpty
        content.body = record.name + (record.host.isEmpty ? "" : " · \(record.host)")
            + (needsInfo ? "\n" + String(localized: "Paste its webhook URL and header to approve.") : "")
            + (record.description.isEmpty ? "" : "\n\(record.description)")
        content.sound = .default
        // Without a URL it can't be approved from the banner: clicking opens the form.
        if !needsInfo { content.categoryIdentifier = Self.agentCategory }
        content.userInfo = ["agentRegistration": record.id.uuidString]
        center.add(UNNotificationRequest(identifier: "agent-\(record.id.uuidString)", content: content, trigger: nil))
    }

    private func handle(_ event: AttentionEvent) {
        updateBadge()
        // The user is already looking at this terminal (it's in a visible pane).
        if model.isVisible(event.sessionID) { return }
        let settings = model.deck.settings

        if settings.bounceDock, !NSApp.isActive {
            NSApp.requestUserAttention(event.activity.isBlocked ? .criticalRequest : .informationalRequest)
        }
        guard settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = event.activity.isBlocked ? .default : nil
        content.userInfo = ["sessionID": event.sessionID.uuidString]
        // The stamp ties the actions to this prompt; a later one must not be answered by them.
        if event.activity == .needsPermission, let stamp = model.pendingPermissionStamp(event.sessionID) {
            content.categoryIdentifier = Self.permissionCategory
            content.userInfo["stamp"] = stamp.timeIntervalSince1970
        }
        content.threadIdentifier = event.sessionID.uuidString
        content.interruptionLevel = event.activity.isBlocked ? .timeSensitive : .active
        // One notification per session: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: event.sessionID.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// A session on the paired Mac needs the user. Answers go back over the connection.
    private func handleRemote(_ session: RemoteSession, hostName: String) {
        updateBadge()
        let settings = model.deck.settings
        if settings.bounceDock, !NSApp.isActive {
            NSApp.requestUserAttention(session.state.isBlocked ? .criticalRequest : .informationalRequest)
        }
        guard settings.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        let name = session.name == session.project || session.project.isEmpty ? session.name : "\(session.name) — \(session.project)"
        content.title = "\(name) · \(hostName)"
        content.body = switch session.state {
        case .needsPermission: String(localized: "Needs permission") + (session.detail.map { ": \($0)" } ?? "")
        case .needsAnswer: String(localized: "Asking a question") + (session.detail.map { ": \($0)" } ?? "")
        default: session.detail.map { String(localized: "Done — \($0)") } ?? String(localized: "Done — your turn")
        }
        content.sound = session.state.isBlocked ? .default : nil
        content.userInfo = ["sessionID": session.id.uuidString, "remote": true]
        if let stamp = session.permissionStamp {
            content.categoryIdentifier = Self.permissionCategory
            content.userInfo["stamp"] = stamp
        }
        content.threadIdentifier = "remote-\(session.id.uuidString)"
        content.interruptionLevel = session.state.isBlocked ? .timeSensitive : .active
        center.add(UNNotificationRequest(identifier: "remote-\(session.id.uuidString)", content: content, trigger: nil))
    }

    func updateBadge() {
        let counts = model.counts
        let waiting = counts.blocked + counts.unseen + model.remote.attentionCount
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        let seen = model.deck.visiblePanes.filter { model.isVisible($0) && !model.needsAttention($0) }
        if !seen.isEmpty { center?.removeDeliveredNotifications(withIdentifiers: seen.map(\.uuidString)) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo["agentRegistration"] as? String, let id = UUID(uuidString: raw) {
            let action = response.actionIdentifier
            await MainActor.run {
                let needsInfo = !(self.model.pendingAgents.first { $0.id == id }?.needs.isEmpty ?? true)
                if action == Self.approveAction, !needsInfo { self.model.approveAgent(id) }
                else if action == Self.denyAction { self.model.rejectAgent(id) }
                else if self.model.pendingAgents.contains(where: { $0.id == id }) {
                    self.model.openMainWindow?()
                    NSApp.activate()
                    self.model.agentSheet = .approve(id)
                }
            }
            return
        }
        if let id = userInfo["approval"] as? String {
            let action = response.actionIdentifier
            await MainActor.run {
                // Approve from the banner only for what allows it (never a purchase: answerApproval checks).
                if action == Self.approveAction || action == Self.denyAction,
                   self.model.answerApproval(id, approve: action == Self.approveAction, from: "notification") { return }
                self.model.openMainWindow?()
                NSApp.activate()
                self.model.showApprovals()
            }
            return
        }
        if userInfo["systemLoad"] is Bool {
            await MainActor.run {
                self.model.openMainWindow?()
                NSApp.activate()
                self.model.showAgentsOverview()
            }
            return
        }
        if userInfo["decision"] is String {
            await MainActor.run {
                self.model.openMainWindow?()
                NSApp.activate()
                self.model.showDecisions()
            }
            return
        }
        if let name = userInfo["serverPlanContainer"] as? String, let serverID = userInfo["serverPlanServerID"] as? Int {
            let server = userInfo["serverPlanServer"] as? String ?? ""
            let fix = response.actionIdentifier == Self.fixWithClaudeAction
            await MainActor.run {
                let controller = ServerPlanController.shared
                if fix {
                    Task { await controller.fixContainerFromNotice(serverID: serverID, server: server, name: name) }
                } else {
                    controller.showContainerLogs(serverID: serverID, server: server, name: name)
                }
            }
            return
        }
        if let deployment = userInfo["serverPlanDeployment"] as? Int {
            await MainActor.run {
                self.model.openMainWindow?()
                NSApp.activate()
                ServerPlanController.shared.showDeploy(deployment)
            }
            return
        }
        let raw = userInfo["sessionID"] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        let action = response.actionIdentifier
        if let target = userInfo["switchAccount"] as? String, action == Self.switchAccountAction {
            await MainActor.run {
                Task { await self.model.switchAccount(id, to: target, reason: .manual) }
            }
            return
        }
        let rawStamp = userInfo["stamp"] as? Double
        let stamp = rawStamp.map { Date(timeIntervalSince1970: $0) }
        let remote = userInfo["remote"] as? Bool ?? false
        await MainActor.run {
            if remote {
                let approve = action == Self.approveAction
                if action == Self.approveAction || action == Self.denyAction,
                   self.model.remote.answer(id, stamp: rawStamp, approve: approve) { return }
                self.model.openMainWindow?()
                NSApp.activate()
                return
            }
            // Only if that same prompt is still open; otherwise show the session instead.
            if action == Self.approveAction, self.model.approvePermission(id, expectedAt: stamp) { return }
            if action == Self.denyAction, self.model.denyPermission(id, expectedAt: stamp) { return }
            self.model.openMainWindow?()
            self.model.reveal(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // App in front but a different session selected: still show the banner.
        [.banner, .sound, .list]
    }
}
