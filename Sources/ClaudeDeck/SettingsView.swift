import ClaudeDeckCore
import ServiceManagement
import SwiftUI

/// The Settings window's categories, listed in its sidebar.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, sidebar, sessions, accounts, terminals, notifications
    case agents, remote, serverPlan, simulators, iCloud, claudeCode

    /// The selected category (window UI state; the demo keeps its own).
    static let storageKey = "settings.category"

    /// The first group of the sidebar; integrations follow in a second group.
    static let basics: [SettingsCategory] = [.general, .sidebar, .sessions, .accounts, .terminals, .notifications]
    static let integrations: [SettingsCategory] = [.agents, .remote, .serverPlan, .simulators, .iCloud, .claudeCode]

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .sidebar: "Sidebar"
        case .sessions: "Sessions"
        case .accounts: "Accounts"
        case .terminals: "Terminals & Editor"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .remote: "Remote"
        case .serverPlan: "ServerPlan"
        case .simulators: "Simulators"
        case .iCloud: "iCloud"
        case .claudeCode: "Claude Code"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sidebar: "sidebar.left"
        case .sessions: "play.rectangle.on.rectangle"
        case .accounts: "person.2"
        case .terminals: "terminal"
        case .notifications: "bell.badge"
        case .agents: "cpu"
        case .remote: "iphone.radiowaves.left.and.right"
        case .serverPlan: "server.rack"
        case .simulators: "iphone"
        case .iCloud: "icloud"
        case .claudeCode: "hammer"
        }
    }

    var tint: Color {
        switch self {
        case .general, .terminals: .gray
        case .sidebar, .iCloud: .blue
        case .sessions: .green
        case .accounts: .orange
        case .notifications: .red
        case .agents: .purple
        case .remote: .teal
        case .serverPlan: .indigo
        case .simulators: .cyan
        case .claudeCode: .brown
        }
    }
}

/// System Settings–style: categories on the left, the selected one's grouped form on the right.
/// The state lives here (not in the panes) so switching categories keeps it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsCategory.storageKey, store: .windowState) private var category = SettingsCategory.general
    @State private var installed = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        // A plain HStack: a NavigationSplitView in the Settings scene ignores its column width
        // and squeezes the category names.
        HStack(spacing: 0) {
            List(selection: Binding<SettingsCategory?>(
                get: { category },
                set: { if let new = $0 { category = new } }
            )) {
                Section {
                    ForEach(SettingsCategory.basics) { row($0) }
                }
                Section {
                    ForEach(SettingsCategory.integrations) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 225)
            Divider()
            Form { pane(category) }
                .formStyle(.grouped)
                .id(category) // each category opens at its top
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(category.title)
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        .onAppear { installed = model.hooksInstalled }
    }

    private func row(_ category: SettingsCategory) -> some View {
        Label {
            Text(category.title)
        } icon: {
            Image(systemName: category.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .tag(category)
    }

    @ViewBuilder
    private func pane(_ category: SettingsCategory) -> some View {
        switch category {
        case .general: generalPane
        case .sidebar: SidebarSettingsSection()
        case .sessions: sessionsPane
        case .accounts: AccountsSettingsSection()
        case .terminals: terminalsPane
        case .notifications: notificationsPane
        case .agents: AgentsSettingsSection()
        case .remote: RemoteSettingsSection()
        case .serverPlan: ServerPlanSettingsSection()
        case .simulators: SimulatorSettingsSection()
        case .iCloud: iCloudPane
        case .claudeCode: claudeCodePane
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalPane: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { model.deck.settings.theme },
                set: { model.setTheme($0) }
            )) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Language", selection: Binding(
                get: { language },
                set: { language = $0; $0.apply(); languageChanged = true }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if languageChanged {
                HStack {
                    Text("The new language shows after ClaudeDeck restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                }
            }
        }
        Section("Startup and Quit") {
            Toggle("Launch ClaudeDeck at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if SMAppService.mainApp.status == .requiresApproval {
                Text("Waiting for approval in System Settings › General › Login Items.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                Text("The app is running outside /Applications (\(Bundle.main.bundlePath)). Move it to /Applications for a lasting login item.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Ask before quitting (⌘Q while terminals are open)", isOn: setting(\.confirmQuit))
            Toggle("Hide from the Dock when the window is closed (menu bar only)", isOn: setting(\.hideDockWhenClosed))
            Text("Closing the window (X) doesn't stop any session; the app keeps running in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if AppUpdater.shared.isAvailable {
            Section("Updates") {
                UpdateSettingsRows()
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsPane: some View {
        Section("When ClaudeDeck Quits") {
            PtydSettingsRows()
        }
        Section("At Launch") {
            Toggle("Resume open sessions at launch", isOn: setting(\.resumeOnLaunch))
            Toggle("Run /compact on large resumed sessions", isOn: setting(\.compactOnResume))
            Stepper(value: setting(\.compactThresholdTokens), in: 50_000...1_000_000, step: 25_000) {
                Text("Compact threshold: context above \(model.deck.settings.compactThresholdTokens / 1000)K tokens")
            }
            .disabled(!model.deck.settings.compactOnResume)
        }
        Section("Continue Message") {
            TextField("Message", text: setting(\.continueMessage), prompt: Text("Continue where you left off."))
            Picker("Send it to", selection: setting(\.continueAllOnResume)) {
                Text("Interrupted sessions only").tag(false)
                Text("All resumed sessions").tag(true)
            }
            Text(model.deck.settings.continueAllOnResume
                 ? "Every session that comes back at launch gets this message, also one that was waiting on you (your turn, a question, a permission)."
                 : "Only sessions that were working when ClaudeDeck quit (or crashed) get this message. Sessions waiting on you (your turn, a question, a permission) are left as they were.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Continue sessions when the usage limit resets", isOn: setting(\.continueAfterUsageLimit))
            Text("A session that stopped on the Claude plan's usage limit gets this message once, when the limit resets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Terminals & Editor

    @ViewBuilder
    private var terminalsPane: some View {
        Section("Terminals") {
            Toggle("Show Program Status in terminals", isOn: Binding(
                get: { model.deck.settings.terminalProgramStatus },
                set: { model.setTerminalProgramStatusDefault($0) }
            ))
            Text("Plain terminals show whether their command is running, needs input, finished or failed, and land in \"Waiting for you\" when they need you. Programs can report it themselves (OSC 7501); zsh and bash also mark each command (applies when a terminal starts). Each terminal can override this from its menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Editor") {
            Toggle("Open text files in the built-in editor (double-click in the Files panel)", isOn: setting(\.openFilesInBuiltInEditor))
            Stepper(value: setting(\.editorFontSize), in: DeckSettings.fontSizeRange, step: 1) {
                Text("Font size: \(Int(model.deck.settings.editorFontSize)) pt")
            }
            Toggle("Wrap Lines", isOn: setting(\.editorWrapLines))
            Toggle("Open files in separate windows instead of tabs", isOn: setting(\.openFilesInSeparateWindow))
        }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsPane: some View {
        Section("Alerts") {
            Toggle("Show notifications (permission / question / done)", isOn: setting(\.notifications))
            Toggle("Bounce the Dock icon", isOn: setting(\.bounceDock))
        }
    }

    // MARK: iCloud

    @ViewBuilder
    private var iCloudPane: some View {
        Section("iCloud") {
            Toggle("Sync projects and groups with iCloud Drive", isOn: Binding(
                get: { model.deck.settings.iCloudSync },
                set: { on in
                    model.mutate { $0.settings.iCloudSync = on }
                    model.sync.refresh()
                }
            ))
            .disabled(!DeckSyncController.isAvailable && !model.deck.settings.iCloudSync)
            if DeckSyncController.isAvailable {
                Text("The project list and groups (name, color, pinning, group membership) are merged with your other Macs through iCloud Drive › ClaudeDeck › projects.json. Sessions, panes, selection and settings are not synced. Deletions don't propagate to other Macs.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("iCloud Drive is off on this Mac (~/Library/Mobile Documents/com~apple~CloudDocs is missing). Turn it on in System Settings › Apple Account › iCloud › iCloud Drive.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.deck.settings.iCloudSync {
                if let error = model.sync.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let at = model.sync.lastSyncAt {
                    Text("Last sync: \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Claude Code

    @ViewBuilder
    private var claudeCodePane: some View {
        Section("Claude Code Hooks") {
            LabeledContent("Status") {
                (installed ? Text("Installed") : Text("Not Installed"))
                    .foregroundStyle(installed ? .green : .red)
            }
            Text("ClaudeDeck adds only its own status hook to ~/.claude/settings.json; it leaves other hooks alone and makes a backup before every change. The hook only runs in ClaudeDeck terminals.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Reinstall") { model.installHooks(); installed = model.hooksInstalled }
                Button("Uninstall", role: .destructive) { model.uninstallHooks(); installed = model.hooksInstalled }
            }
            if let path = model.claudePath {
                LabeledContent("claude", value: path).font(.caption)
            } else {
                Text("`claude` was not found in your login shell.").foregroundStyle(.red)
            }
        }
        PencilSettingsSection()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setting<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(
            get: { model.deck.settings[keyPath: keyPath] },
            set: { value in model.mutate { $0.settings[keyPath: keyPath] = value } }
        )
    }
}

/// The app's own language (Settings › General), independent of the system's: stored as the
/// app's `AppleLanguages` default, which macOS reads at launch.
enum AppLanguage: String, CaseIterable {
    case system, english = "en", turkish = "tr"

    static var current: AppLanguage {
        guard let first = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first
        else { return .system }
        return first.hasPrefix("tr") ? .turkish : first.hasPrefix("en") ? .english : .system
    }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Quits and opens the app again. Sessions in the session helper keep running; the others
    /// resume next launch, as with any quit.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
