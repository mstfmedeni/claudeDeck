import ClaudeDeckCore
import SwiftUI

// MARK: - Settings › ServerPlan

/// The panel's address and an API token (created in ServerPlan's settings; kept in the keychain).
struct ServerPlanSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var token = ""
    @State private var status: String?
    @State private var failed = false
    @State private var working = false

    var body: some View {
        let controller = ServerPlanController.shared
        Section {
            TextField("Panel address", text: $address, prompt: Text(verbatim: ServerPlanContract.defaultURL))
                .onSubmit { connect() }
            SecureField("API token", text: $token,
                        prompt: ServerPlanController.token == nil ? Text(verbatim: "spk_…") : Text("Saved in the keychain"))
                .onSubmit { connect() }
            HStack {
                Button(controller.isConfigured ? String(localized: "Reconnect") : String(localized: "Connect")) { connect() }
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty
                              || (token.isEmpty && ServerPlanController.token == nil))
                if controller.isConfigured {
                    Button("Disconnect", role: .destructive) {
                        controller.disconnect()
                        address = ""
                        token = ""
                        status = nil
                    }
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(failed ? .red : .secondary)
            } else if let me = controller.me {
                Text(Self.describe(me)).font(.caption).foregroundStyle(.secondary)
            }
            if controller.isConfigured {
                Toggle("Show matching server projects under their project", isOn: Binding(
                    get: { model.deck.settings.serverPlanProjectRows },
                    set: { value in model.mutate { $0.settings.serverPlanProjectRows = value } }
                ))
                if controller.offersRegistrarBalance { ServerPlanBalanceSettings() }
            }
        } header: {
            Text("ServerPlan")
        } footer: {
            Text("Your servers, projects and deploys from a ServerPlan panel, in the sidebar: health, deploy status and notifications when a deploy fails, terminals on the servers (the panel does the SSH; no SSH key is stored here), and Fix with Claude for a failed deploy. Create the token in ServerPlan › Settings › API tokens.")
        }
        .onAppear { address = controller.address }
        // A 1.4 panel: the Namecheap balance when Settings opens (unless read a minute ago).
        .task(id: controller.me?.offersRegistrarBalance == true) { await controller.refreshBalance(maxAge: 60) }
    }

    private func connect() {
        working = true
        status = nil
        let typed = token
        Task {
            let result = await ServerPlanController.shared.connect(address: address, token: typed.isEmpty ? nil : typed)
            working = false
            switch result {
            case .success(let me):
                failed = false
                status = Self.describe(me)
                token = ""
            case .failure(let error):
                failed = true
                status = error.localizedDescription
            }
        }
    }

    static func describe(_ me: ServerPlanMe) -> String {
        let scopes = me.scopes.joined(separator: ", ")
        return String(localized: "Connected as \(me.user) (\(me.role ?? "user")) · \(scopes)")
    }
}

/// Settings › ServerPlan on a 1.4 panel with Namecheap: the balance (refresh asks Namecheap
/// again) and the low-balance alert's local threshold.
private struct ServerPlanBalanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = ServerPlanController.shared
        let balance = controller.registrarBalance
        LabeledContent("Namecheap balance") {
            HStack(spacing: 6) {
                if let balance {
                    Text(verbatim: "\(ServerPlanRegistrarBalance.format(balance.available)) \(balance.currency)")
                        .monospacedDigit()
                        .foregroundStyle(controller.balanceIsLow ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                } else if controller.registrarBalanceError == nil, !controller.registrarBalanceLoading {
                    Text(verbatim: "—").foregroundStyle(.tertiary)
                }
                if controller.registrarBalanceLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await controller.refreshBalance(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Ask Namecheap for the balance now")
                }
            }
        }
        if let balance, let detail = Self.detail(balance, low: controller.balanceIsLow) {
            Text(detail).font(.caption).foregroundStyle(controller.balanceIsLow ? .orange : .secondary)
        }
        if let error = controller.registrarBalanceError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        TextField("Namecheap balance alert (USD)", value: Binding(
            get: { model.deck.settings.serverPlanBalanceAlert },
            set: { value in
                model.mutate { $0.settings.serverPlanBalanceAlert = max(0, value) }
                controller.balanceThresholdChanged()
            }
        ), format: .number.precision(.fractionLength(0...2)))
        Group {
            if let panel = balance?.lowThreshold {
                Text("ServerPlan's own threshold (\(ServerPlanRegistrarBalance.format(panel)) \(balance?.currency ?? "USD")) is used; this one applies when ServerPlan has none.")
            } else {
                Text("A notification on the Mac and the phone when the balance goes under this (once, until it's topped up). 0 turns it off.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    static func detail(_ balance: ServerPlanRegistrarBalance, low: Bool) -> String? {
        var parts: [String] = []
        if let account = balance.account {
            parts.append(String(localized: "Account balance \(ServerPlanRegistrarBalance.format(account)) \(balance.currency)"))
        }
        if let checked = balance.checkedAt {
            parts.append(String(localized: "checked \(checked.formatted(.relative(presentation: .named)))"))
        }
        if low { parts.append(String(localized: "Low: top up in Namecheap › Billing › Add Funds")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The sidebar's Servers section: the Namecheap balance as a small line (orange when low).
private struct ServerPlanBalanceLine: View {
    var body: some View {
        let controller = ServerPlanController.shared
        if let balance = controller.registrarBalance, controller.registrarConfigured == true {
            let low = controller.balanceIsLow
            let amount = "\(ServerPlanRegistrarBalance.format(balance.available)) \(balance.currency)"
            HStack(spacing: 4) {
                Image(systemName: low ? "exclamationmark.triangle.fill" : "creditcard")
                Text("Namecheap: \(amount)")
            }
            .sidebarFont(.caption)
            .foregroundStyle(low ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            .help(low
                  ? String(localized: "Namecheap balance is low. Top up for domain purchases: Namecheap › Billing › Add Funds.")
                  : String(localized: "Namecheap balance (for domain purchases)"))
            .selectionDisabled()
        }
    }
}

// MARK: - Sidebar › Servers

/// Window UI state: whether the Servers section is open (its rows, and the refresh loop).
enum ServerPlanSidebar {
    static let expandedKey = "sidebar.serversExpanded"
}

/// Servers with health dots, the projects deployed to each with their last deploy, and the
/// containers of an expanded server. The last section of the sidebar; its header opens and
/// closes it.
struct ServerPlanSidebarSection: View {
    @AppStorage(ServerPlanSidebar.expandedKey, store: .windowState) private var expanded = true

    var body: some View {
        let controller = ServerPlanController.shared
        Section(isExpanded: $expanded) {
            if controller.servers.isEmpty {
                // A cleared panel error stays as the explanation, without the alarm.
                let shown = controller.shownLastError
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(controller.lastError ?? (controller.lastRefresh == nil ? String(localized: "Loading…") : String(localized: "No servers")))
                        .sidebarFont(.callout).foregroundStyle(shown == nil ? .tertiary : .secondary)
                        .lineLimit(3)
                    if shown != nil {
                        Spacer(minLength: 4)
                        ServerPlanClearButton { controller.clearPanelError() }
                    }
                }
                .contextMenu {
                    if shown != nil { Button("Clear Error") { controller.clearPanelError() } }
                }
                .selectionDisabled()
            }
            ForEach(controller.servers) { server in
                ServerPlanServerRow(server: server).selectionDisabled()
            }
            let unassigned = controller.projects(on: nil)
            if !unassigned.isEmpty, !controller.servers.isEmpty {
                ForEach(unassigned) { ServerPlanProjectRow(project: $0, serverName: nil).selectionDisabled() }
            }
            if let error = controller.actionError {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(error).sidebarFont(.caption).foregroundStyle(.orange).lineLimit(3)
                    Spacer(minLength: 4)
                    ServerPlanClearButton { controller.actionError = nil }
                }
                .contextMenu { Button("Clear Error") { controller.actionError = nil } }
                .selectionDisabled()
            }
            ServerPlanBalanceLine()
        } header: {
            ServerPlanSidebarHeader(expanded: $expanded)
        }
    }
}

private struct ServerPlanSidebarHeader: View {
    @Binding var expanded: Bool

    var body: some View {
        let controller = ServerPlanController.shared
        HStack(spacing: 4) {
            // Always shown (the list's own chevron only appears on hover).
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: "server.rack")
            Text("Servers")
            Text("\(controller.servers.count)").foregroundStyle(.tertiary)
            Spacer()
            if expanded {
                if controller.refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await controller.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh from ServerPlan")
                }
            }
            if let error = controller.shownLastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(error)
            }
            if controller.hasClearableErrors {
                Button { controller.clearAll() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Clear All Errors (only here; nothing changes on ServerPlan)")
            }
        }
        .contextMenu {
            Button("Clear All Errors") { controller.clearAll() }.disabled(!controller.hasClearableErrors)
            Button("Refresh") { Task { await controller.refresh(force: true) } }
        }
        // The whole header opens and closes the section.
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
        .help(expanded ? Text("Hide servers") : Text("Show servers"))
    }
}

/// On the sidebar list, not on the Servers header: the header is the last row and may never be
/// drawn (a long list), and project rows higher up open the same sheets.
/// The refresh loop (lists, health, containers, capabilities) runs while the Servers section is
/// open and a window visible. Closed, the deploy watch keeps deploy statuses current; the
/// project rows under ClaudeDeck projects get the lists once, if nothing was loaded yet.
struct ServerPlanSidebarSupport: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage(ServerPlanSidebar.expandedKey, store: .windowState) private var expanded = true

    func body(content: Content) -> some View {
        let controller = ServerPlanController.shared
        @Bindable var bindable = controller
        let configured = controller.isConfigured
        let rows = model.deck.settings.serverPlanProjectRows
        content
            .task(id: "\(configured)-\(expanded)-\(rows)") {
                guard configured else { return }
                if expanded {
                    await controller.refreshLoop()
                } else if rows, controller.lastRefresh == nil {
                    await AppVisibility.shared.waitUntilVisible()
                    await controller.refresh(listsOnly: true)
                }
            }
            .sheet(item: $bindable.sheet) { sheet in
                switch sheet {
                case .deploy(let id, let title): ServerPlanDeploySheet(deploymentID: id, title: title)
                case .logs(let serverID, let server, let container): ServerPlanLogsSheet(serverID: serverID, server: server, container: container)
                }
            }
            .alert(item: $bindable.pendingConfirm) { pending in
                Alert(
                    title: Text(ServerPlanActionText.title(pending.action)),
                    message: Text(pending.preview.summary ?? ServerPlanActionText.fallbackSummary(pending.action)),
                    primaryButton: .destructive(Text(ServerPlanActionText.button(pending.action))) { controller.confirm(pending) },
                    secondaryButton: .cancel()
                )
            }
    }
}

/// View menu: open or close the sidebar's Servers section (only with ServerPlan set up).
struct ServerPlanSidebarToggle: View {
    @AppStorage(ServerPlanSidebar.expandedKey, store: .windowState) private var expanded = true

    var body: some View {
        if ServerPlanController.shared.isConfigured {
            if expanded {
                Button("Hide Servers") { expanded = false }
            } else {
                Button("Show Servers") { expanded = true }
            }
        }
    }
}

/// The ServerPlan projects in a ClaudeDeck project's folder, under the project's sessions.
struct ServerPlanProjectRows: View {
    let projects: [ServerPlanProject]

    var body: some View {
        let controller = ServerPlanController.shared
        ForEach(projects) { project in
            ServerPlanProjectRow(project: project, serverName: controller.server(project.defaultServerID)?.name, showsServer: true)
                .selectionDisabled()
        }
    }
}

/// Wording of the confirmation dialog.
enum ServerPlanActionText {
    static func title(_ action: ServerPlanAction) -> String {
        switch action {
        case .deploy(_, let name, _, _): String(localized: "Deploy \(name)?")
        case .container(_, let server, let name, let verb):
            switch verb {
            case .start: String(localized: "Start \(name) on \(server)?")
            case .stop: String(localized: "Stop \(name) on \(server)?")
            case .restart: String(localized: "Restart \(name) on \(server)?")
            }
        }
    }

    static func button(_ action: ServerPlanAction) -> String {
        switch action {
        case .deploy: String(localized: "Deploy")
        case .container(_, _, _, let verb):
            switch verb {
            case .start: String(localized: "Start")
            case .stop: String(localized: "Stop")
            case .restart: String(localized: "Restart")
            }
        }
    }

    static func fallbackSummary(_ action: ServerPlanAction) -> String {
        switch action {
        case .deploy: String(localized: "ServerPlan builds the image, transfers it and replaces the running container.")
        case .container: String(localized: "This changes a running server.")
        }
    }
}

private struct ServerDot: View {
    let status: ServerPlanServerStatus

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .online: .green
        case .offline: .red
        case .unknown: .secondary.opacity(0.5)
        }
    }
}

private struct ServerPlanServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerPlanServer
    @State private var hovering = false

    var body: some View {
        let controller = ServerPlanController.shared
        DisclosureGroup(isExpanded: Binding(
            get: { controller.expandedServers.contains(server.id) },
            set: { if $0 { controller.expandedServers.insert(server.id) } else { controller.expandedServers.remove(server.id) } }
        )) {
            ForEach(controller.projects(on: server.id)) { ServerPlanProjectRow(project: $0, serverName: server.name) }
            if let containers = controller.containers[server.id] {
                ForEach(containers) { ServerPlanContainerRow(server: server, container: $0) }
                if containers.isEmpty, controller.projects(on: server.id).isEmpty {
                    Text("No containers").sidebarFont(.caption).foregroundStyle(.tertiary)
                }
            } else if server.effectiveStatus == .offline {
                // Always a child row: the outline only expands rows that have children.
                Text("Unreachable").sidebarFont(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Loading containers…").sidebarFont(.caption).foregroundStyle(.tertiary)
            }
        } label: {
            // On the label only: on the DisclosureGroup it would also be every child row's menu.
            label(controller).contextMenu { menu(controller) }
        }
    }

    private func label(_ controller: ServerPlanController) -> some View {
        let health = controller.health[server.id]
        // A cleared problem: grey dot, the host instead of the error, no Docker warning.
        let alarm = controller.showsServerIssue(server)
        let down = health?.reachable == false || server.effectiveStatus == .offline
        return HStack(spacing: 6) {
            ServerDot(status: down ? (alarm ? .offline : .unknown) : server.effectiveStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).lineLimit(1)
                if !alarm, controller.serverIssue(server) != nil {
                    Text(server.host ?? String(localized: "Error cleared")).sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                } else if let health, health.reachable == false {
                    Text(health.error ?? String(localized: "Unreachable")).sidebarFont(.caption).foregroundStyle(.red).lineLimit(1)
                } else if let health {
                    Text(Self.healthLine(health)).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let host = server.host {
                    Text(host).sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if alarm, health?.reachable != false, health?.dockerOK == false {
                Image(systemName: "shippingbox").foregroundStyle(.orange).help("Docker isn't answering on this server")
            }
            if alarm, hovering { ServerPlanClearButton { controller.clearServerIssue(server) } }
        }
        .onHover { hovering = $0 }
        .help([server.host, health?.uptime, health?.loadAverage.map { String(localized: "load \($0)") }].compactMap { $0 }.joined(separator: " · "))
    }

    static func healthLine(_ health: ServerPlanHealth) -> String {
        [health.cpu.map { "CPU \($0)" }, health.memory.map { "RAM \($0)" }, health.disk.map { String(localized: "disk \($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func menu(_ controller: ServerPlanController) -> some View {
        if controller.showsServerIssue(server) {
            Button("Clear Error") { controller.clearServerIssue(server) }
            Divider()
        }
        if controller.canOpenTerminal {
            Button("Open Terminal") { model.openServerPlanTerminal(serverID: server.id, serverName: server.name, runClaude: false) }
            if controller.canRunClaude(on: server.id) {
                Button("Start Claude Code on \(server.name)") {
                    model.openServerPlanTerminal(serverID: server.id, serverName: server.name, runClaude: true)
                }
            }
        }
        Button("Refresh") { Task { await controller.refresh(force: true) } }
    }
}

private struct ServerPlanProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: ServerPlanProject
    let serverName: String?
    /// Under a ClaudeDeck project: which server it deploys to, after a server icon.
    var showsServer = false
    @State private var hovering = false

    var body: some View {
        let controller = ServerPlanController.shared
        let deploy = controller.latestDeploy(of: project)
        let failing = controller.showsFailure(deploy)
        // Failed, but cleared by the owner: no red, no Fix button.
        let cleared = deploy?.status == .failed && !failing
        HStack(spacing: 6) {
            DeployBadge(status: deploy?.status, muted: cleared)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(project.name).lineLimit(1)
                    if let branch = project.branch, branch != "main", branch != "master" {
                        Text(branch).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if showsServer {
                        HStack(spacing: 2) {
                            Image(systemName: "server.rack")
                            if let serverName { Text(serverName).lineLimit(1) }
                        }
                        .sidebarFont(.caption)
                        .foregroundStyle(.secondary)
                        .help(serverName.map { String(localized: "ServerPlan · \($0)") } ?? "ServerPlan")
                    }
                }
                if let deploy {
                    if cleared {
                        Text("Last deploy failed").sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    } else {
                        Text(DeployBadge.label(deploy)).sidebarFont(.caption).foregroundStyle(failing ? .red : .secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if let deploy, deploy.status.isFinished { RowTime(date: deploy.finishedAt) }
            if let deploy, failing {
                repairButton(deploy, controller)
                if hovering { ServerPlanClearButton { controller.clearDeploy(deploy) } }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if let deploy { controller.sheet = .deploy(id: deploy.id, title: project.name) }
        }
        .contextMenu { menu(deploy, controller) }
    }

    @ViewBuilder private func repairButton(_ deploy: ServerPlanDeployment, _ controller: ServerPlanController) -> some View {
        if controller.repairing.contains(deploy.id) {
            ProgressView().controlSize(.mini)
        } else if let key = controller.repairKey(deploy.id), let request = model.deck.deployRepairRequest(key) {
            Button {
                if let sid = request.sessionID, model.deck.session(sid) != nil {
                    model.tabs.selectSessions()
                    model.reveal(sid)
                }
            } label: { Image(systemName: "checkmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Fix requested")
        } else {
            Button { controller.fixWithClaude(deploy.id) } label: { Image(systemName: "wrench.and.screwdriver") }
                .buttonStyle(.borderless)
                .help("Fix with Claude: start a Claude session in this project with the deploy log")
        }
    }

    @ViewBuilder private func menu(_ deploy: ServerPlanDeployment?, _ controller: ServerPlanController) -> some View {
        if let deploy {
            Button("Show Deploy Log") { controller.sheet = .deploy(id: deploy.id, title: project.name) }
            if deploy.status == .failed { Button("Fix with Claude") { controller.fixWithClaude(deploy.id) } }
            if controller.showsFailure(deploy) { Button("Clear Error") { controller.clearDeploy(deploy) } }
        }
        // Under its project already: no "Show Project".
        if !showsServer, let deckProject = controller.deckProject(for: project) {
            Button("Show Project") { model.openProject(deckProject.id) }
        }
        if controller.allows(.deploy) {
            Divider()
            Button("Deploy…") {
                controller.request(.deploy(projectID: project.id, projectName: project.name, serverID: project.defaultServerID, forceRebuild: false))
            }
            Button("Deploy (Rebuild Image)…") {
                controller.request(.deploy(projectID: project.id, projectName: project.name, serverID: project.defaultServerID, forceRebuild: true))
            }
        }
    }
}

/// Clears one error from the sidebar (local: nothing changes on ServerPlan).
struct ServerPlanClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear Error")
    }
}

/// The last deploy's status as a small icon.
struct DeployBadge: View {
    let status: ServerPlanDeployStatus?
    /// A failure the owner cleared: grey instead of red.
    var muted = false

    var body: some View {
        Group {
            switch status {
            case .success?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(muted ? Color.secondary : Color.red)
            case .cancelled?: Image(systemName: "slash.circle").foregroundStyle(.secondary)
            case let s? where s.isRunning: Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.blue)
            default: Image(systemName: "shippingbox").foregroundStyle(.tertiary)
            }
        }
        .sidebarFont(.caption)
    }

    static func label(_ deploy: ServerPlanDeployment) -> String {
        switch deploy.status {
        case .pending: String(localized: "Deploy queued")
        case .building, .transferring, .deploying:
            String(localized: "Deploying") + (deploy.step.map { " · \($0)" } ?? "")
        case .success: String(localized: "Deployed")
        case .failed: deploy.errorSummary.map { String(localized: "Failed: \($0)") } ?? String(localized: "Deploy failed")
        case .cancelled: String(localized: "Deploy cancelled")
        case .unknown: deploy.status.rawValue
        }
    }
}

private struct ServerPlanContainerRow: View {
    let server: ServerPlanServer
    let container: ServerPlanContainer

    var body: some View {
        let controller = ServerPlanController.shared
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .sidebarFont(.caption)
                .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
            Text(container.name).sidebarFont(.callout).lineLimit(1)
            Spacer(minLength: 4)
            Text(container.status ?? container.state ?? "").sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .help(container.image ?? container.name)
        .contextMenu {
            if controller.allows(.logs) {
                Button("Logs") { controller.sheet = .logs(serverID: server.id, server: server.name, container: container.name) }
            }
            if controller.allows(.containers) {
                Divider()
                if container.isRunning {
                    Button("Restart…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .restart)) }
                    Button("Stop…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .stop)) }
                } else {
                    Button("Start…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .start)) }
                }
            }
        }
    }
}

// MARK: - Sheets

/// A deploy's log: replayed, then live while it runs (the stream only while the sheet is open).
private struct ServerPlanDeploySheet: View {
    let deploymentID: Int
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var lines: [String] = []
    @State private var deployment: ServerPlanDeployment?
    @State private var progress: ServerPlanDeployProgress?
    @State private var error: String?

    var body: some View {
        let controller = ServerPlanController.shared
        let status = deployment?.status ?? progress?.status
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DeployBadge(status: status)
                Text("\(title) · deploy #\(deploymentID)").font(.headline)
                Spacer()
                if let status, status.isRunning { ProgressView().controlSize(.small) }
            }
            if let deployment {
                Text(DeployBadge.label(deployment)).font(.callout).foregroundStyle(deployment.status == .failed ? .red : .secondary)
            } else if let progress {
                Text(String(localized: "Deploying") + (progress.step.map { " · \($0)" } ?? "")).font(.callout).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: lines.count) { proxy.scrollTo("end") }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if deployment?.status == .failed {
                    if let key = controller.repairKey(deploymentID), model.deck.deployRepairRequest(key) != nil {
                        Label("Fix requested", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button("Fix with Claude") { controller.fixWithClaude(deploymentID) }
                            .disabled(controller.repairing.contains(deploymentID))
                    }
                }
                if let deployment, controller.showsFailure(deployment) {
                    Button("Clear Error") { controller.clearDeploy(deployment) }
                        .help("Clears it from the sidebar and the phone; ServerPlan keeps the deploy")
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
        .task { await follow() }
    }

    private func follow() async {
        guard let client = ServerPlanController.shared.client else { return }
        await AppVisibility.shared.waitUntilVisible()
        do {
            for try await event in try await client.deployStream(id: deploymentID) {
                switch ServerPlanDeployStreamEvent(event) {
                case .log(let line)?: lines.append(line)
                case .status(let value)?: progress = value
                case .done(let value)?: deployment = value
                case nil: break
                }
            }
        } catch {
            // No stream (finished long ago, or no deploy_stream): the stored log.
            if let value = try? await client.deployment(id: deploymentID) {
                deployment = value
                if lines.isEmpty { lines = (value.log ?? "").components(separatedBy: "\n") }
            } else {
                self.error = error.localizedDescription
            }
        }
        if deployment == nil, let value = try? await client.deployment(id: deploymentID) {
            deployment = value
            if lines.isEmpty { lines = (value.log ?? "").components(separatedBy: "\n") }
        }
    }
}

/// A container's log: the tail, then followed while the sheet is open and a window visible.
private struct ServerPlanLogsSheet: View {
    let serverID: Int
    let server: String
    let container: String
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var follow = true
    @State private var error: String?

    static let maxLines = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.fill")
                Text("\(container) · \(server)").font(.headline)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: lines.count) { if follow { proxy.scrollTo("end") } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 440)
        .task(id: follow) { await load() }
    }

    private func load() async {
        guard let client = ServerPlanController.shared.client else { return }
        if !follow || ServerPlanController.shared.me?.has(feature: ServerPlanContract.Feature.logStream) == false {
            do {
                lines = try await client.containerLogs(serverID: serverID, container: container, tail: 200).components(separatedBy: "\n")
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        // Follow: reconnects when a window shows again after the stream ended.
        lines = []
        var ended = false
        while !Task.isCancelled, !ended {
            await AppVisibility.shared.waitUntilVisible()
            do {
                for try await event in try await client.containerLogStream(serverID: serverID, container: container, tail: lines.isEmpty ? 200 : 0) {
                    if let reason = ServerPlanLogLine.endReason(event) {
                        lines.append("— " + (reason.isEmpty ? String(localized: "log ended") : reason) + " —")
                        ended = true
                        break
                    }
                    guard let line = ServerPlanLogLine(event) else { continue }
                    lines.append(line.line)
                    if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
                    // Hidden: stop reading; the stream is reopened (from now) once visible.
                    if !AppVisibility.shared.windowsVisible { break }
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
                try? await Task.sleep(for: .seconds(10))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
