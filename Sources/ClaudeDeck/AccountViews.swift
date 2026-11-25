import AppKit
import ClaudeDeckCore
import SwiftUI

// Several Claude accounts (AppModel+Accounts): Settings › Accounts, a session's "Account" menu,
// a project's pin, "New Claude Session on Account", and the other accounts' usage in the usage
// popover. Nothing here shows until there is an account besides the default one (except the
// settings section, where accounts are added).

/// "5h 62% · week 18%", "limited · 1h 20m", "not logged in".
private struct AccountUsageText: View {
    @Environment(AppModel.self) private var model
    let id: String
    let now: Date

    var body: some View {
        let standing = model.accountStanding(id)
        if !standing.loggedIn {
            Text("Not logged in").foregroundStyle(.orange)
        } else if standing.isLimited(now: now) {
            Text(standing.resetsAt(now: now).map { String(localized: "Limit reached · resets in \(UsageFormat.countdown(to: $0, now: now))") }
                 ?? String(localized: "Limit reached"))
                .foregroundStyle(.red)
        } else if let usage = standing.usage {
            let parts = [usage.fiveHour.map { String(localized: "5h \(UsageFormat.percent($0))") },
                         usage.sevenDay.map { String(localized: "week \(UsageFormat.percent($0))") }].compactMap { $0 }
            Text(verbatim: parts.joined(separator: " · "))
                .foregroundStyle(standing.isNearLimit(threshold: model.deck.settings.accountNearLimitPercent) ? .orange : .secondary)
        } else if let monitor = model.usageMonitor(forAccount: id) {
            UsageUnavailableText(monitor: monitor)
        } else {
            Text("Usage unknown").foregroundStyle(.secondary)
        }
    }
}

/// Why an account's usage isn't shown, and for an unreadable login an "Allow Access" button that
/// gives macOS's Keychain question time to be answered (Always Allow).
private struct UsageUnavailableText: View {
    let monitor: UsageMonitor
    @State private var asking = false

    var body: some View {
        switch monitor.unavailableReason {
        case .noToken:
            HStack(spacing: 6) {
                Text("Login not readable").foregroundStyle(.orange)
                if asking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Allow Access") {
                        asking = true
                        Task { await monitor.allowKeychainAccess(); asking = false }
                    }
                    .controlSize(.mini)
                    .help("macOS asks whether ClaudeDeck may read this account's Claude Code login in the Keychain: choose Always Allow. ClaudeDeck only reads it to show the usage.")
                }
            }
        case .expired:
            Text("Login expired: run claude in this account once").foregroundStyle(.orange)
        case .noPlanUsage:
            Text("No plan usage for this account").foregroundStyle(.secondary)
        case nil:
            Text("Usage unknown").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

struct AccountsSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Accounts") {
            Text("Each Claude account is its own Claude Code login. Sessions on another account share your settings, skills, plugins, MCP servers and conversations; when an account hits its usage limit, a session can move to another one and continue the same conversation. ClaudeDeck never sees your password or token: you log in yourself in a terminal.")
                .font(.caption).foregroundStyle(.secondary)
            let order = model.deck.settings.accountPriority
            VisibleTimeline(every: 30) { now in
                VStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, id in
                        row(id, index: index, count: order.count, now: now)
                    }
                }
            }
            Button("Add Account…") { addAccount() }
            if model.hasOtherAccounts {
                Picker("New sessions start on", selection: setting(\.newSessionAccount)) {
                    ForEach(order, id: \.self) { id in Text(model.accountLabel(id)).tag(id) }
                    Divider()
                    Text("Automatic (first with room)").tag(ClaudeAccounts.autoID)
                }
                Picker("When a session hits the usage limit", selection: setting(\.accountSwitchMode)) {
                    Text("Wait for the reset").tag(AccountSwitchMode.off)
                    Text("Notify me (switch with one click)").tag(AccountSwitchMode.notify)
                    Text("Switch to another account").tag(AccountSwitchMode.auto)
                }
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                Stepper(value: setting(\.accountNearLimitPercent), in: 50...100, step: 5) {
                    Text("Near the limit at \(Int(model.deck.settings.accountNearLimitPercent))%")
                }
                Text("An account at or above this (5-hour or weekly) is skipped for new sessions and switches while another has room. Pin a project to an account from its menu; pin a session from its Account menu. Pinned sessions never move.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            // A login finishing in its terminal shows up here within a few seconds.
            while !Task.isCancelled {
                model.refreshAccountLogins()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var modeExplanation: String {
        switch model.deck.settings.accountSwitchMode {
        case .off: String(localized: "The session waits for its own limit to reset (and gets the continue message then, if that's on).")
        case .notify: String(localized: "You get a notification with a Switch Account button; the session waits until you choose.")
        case .auto: String(localized: "The session ends and resumes the same conversation on the first account with room, in the same pane. If it was working, it's told to continue. When every account is at its limit it waits for the first reset.")
        }
    }

    private func row(_ id: String, index: Int, count: Int, now: Date) -> some View {
        let isDefault = id == ClaudeAccounts.defaultID
        let email = isDefault ? model.defaultAccountEmail : model.accountLogins[id]
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountLabel(id)).fontWeight(.medium)
                HStack(spacing: 6) {
                    if let email { Text(verbatim: email).foregroundStyle(.secondary) }
                    AccountUsageText(id: id, now: now)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer()
            if !isDefault {
                Button(email == nil ? String(localized: "Log In…") : String(localized: "Log In Again…")) { model.openAccountLogin(id) }
                    .controlSize(.small)
                    .fixedSize()
            }
            ControlGroup {
                Button { model.moveAccount(id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Try this account earlier")
                Button { model.moveAccount(id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .help("Try this account later")
            }
            .controlSize(.small)
            .fixedSize()
            if !isDefault {
                Button(role: .destructive) { model.removeAccount(id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove Account…")
            }
        }
    }

    private func addAccount() {
        guard let label = TextPrompt.ask(title: String(localized: "New Claude Account"),
                                         placeholder: String(localized: "Name (e.g. Work, Second Max)")) else { return }
        guard let account = model.addAccount(label: label) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Use letters or digits in the name.")
            alert.runAsSheet()
            return
        }
        // Straight to the login: a terminal running `claude auth login` on the new account.
        model.openAccountLogin(account.id)
    }

    private func setting<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(
            get: { model.deck.settings[keyPath: keyPath] },
            set: { value in model.mutate { $0.settings[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Menus

/// A Claude session's "Account" submenu: move it to another account, or pin it.
struct SessionAccountMenu: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        if session.kind == .claude, model.hasOtherAccounts {
            let current = model.accountID(of: session)
            Menu(String(localized: "Account: \(model.accountLabel(current))")) {
                ForEach(model.deck.settings.accountPriority, id: \.self) { id in
                    Button {
                        Task { await AccountActions.switchSession(session.id, to: id, model: model) }
                    } label: {
                        Text(verbatim: model.accountLabel(id) + AccountActions.suffix(id, model: model))
                    }
                    .disabled(id == current || model.switchingAccounts.contains(session.id))
                }
                Divider()
                Toggle("Keep on This Account", isOn: Binding(
                    get: { session.accountPinned },
                    set: { model.setAccountPinned($0, for: session.id) }
                ))
                .disabled(model.projectAccountPin(session.projectID) != nil)
            }
        }
    }
}

/// A project's "Account" submenu: pin every session in it to one account.
struct ProjectAccountMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if model.hasOtherAccounts {
            let pin = model.projectAccountPin(project.id)
            Menu(pin.map { String(localized: "Account: \(model.accountLabel($0))") } ?? String(localized: "Account")) {
                Toggle("Any Account (Not Pinned)", isOn: Binding(get: { pin == nil }, set: { if $0 { model.setProjectAccount(project.id, to: nil) } }))
                Divider()
                ForEach(model.deck.settings.accountPriority, id: \.self) { id in
                    Toggle(model.accountLabel(id), isOn: Binding(get: { pin == id }, set: { if $0 { model.setProjectAccount(project.id, to: id) } }))
                }
            }
        }
    }
}

/// "New Claude Session on Account ▸" in a project's menus.
struct NewSessionOnAccountMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if model.hasOtherAccounts, model.projectAccountPin(project.id) == nil {
            Menu {
                ForEach(model.deck.settings.accountPriority, id: \.self) { id in
                    Button {
                        model.newSession(in: project.id, account: id)
                    } label: {
                        Text(verbatim: model.accountLabel(id) + AccountActions.suffix(id, model: model))
                    }
                }
            } label: {
                Label("New Claude Session on Account", systemImage: "person.2")
            }
        }
    }
}

@MainActor
enum AccountActions {
    /// " — 5h 62%" / " — limit reached" / " — not logged in".
    static func suffix(_ id: String, model: AppModel) -> String {
        let standing = model.accountStanding(id)
        if !standing.loggedIn { return " — " + String(localized: "not logged in") }
        if standing.isLimited() { return " — " + String(localized: "limit reached") }
        if let window = standing.usage?.fiveHour { return " — " + String(localized: "5h \(UsageFormat.percent(window))") }
        return ""
    }

    static func switchSession(_ id: UUID, to target: String, model: AppModel) async {
        if case .failure(let refusal) = await model.switchAccount(id, to: target, reason: .manual) {
            let alert = NSAlert()
            alert.messageText = String(localized: "The session wasn't moved")
            alert.informativeText = message(refusal)
            alert.runAsSheet()
        }
    }

    static func message(_ refusal: AccountSwitchRefusal) -> String {
        switch refusal {
        case .notLoggedIn: String(localized: "Nobody is logged in on that account yet: Settings › Accounts › Log In…")
        case .noConversation: String(localized: "ClaudeDeck doesn't know this session's conversation yet, so it can't be resumed on another account.")
        case .worktreeMissing: String(localized: "The session's worktree folder no longer exists.")
        case .switching: String(localized: "It is already being moved.")
        case .stillRunning: String(localized: "Its Claude process didn't end, so it wasn't resumed elsewhere.")
        default: refusal.rawValue
        }
    }
}

// MARK: - Usage popover

/// The other accounts' usage, under the default one's in the usage popover.
struct OtherAccountsUsage: View {
    @Environment(AppModel.self) private var model
    let now: Date

    var body: some View {
        if model.hasOtherAccounts {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts").font(.subheadline)
                ForEach(model.deck.settings.accountPriority, id: \.self) { id in
                    HStack {
                        Text(model.accountLabel(id)).lineLimit(1)
                        Spacer()
                        AccountUsageText(id: id, now: now).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
