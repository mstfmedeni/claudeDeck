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
        } header: {
            Text("ServerPlan")
        } footer: {
            Text("Your servers, projects and deploys from a ServerPlan panel, in the sidebar: health, deploy status and notifications when a deploy fails, terminals on the servers (the panel does the SSH; no SSH key is stored here), and Fix with Claude for a failed deploy. Create the token in ServerPlan › Settings › API tokens.")
        }
        .onAppear { address = controller.address }
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

// MARK: - Sidebar › Servers

/// Servers with health dots, the projects deployed to each with their last deploy, and the
/// containers of an expanded server. Fetched only while this section is on screen.
struct ServerPlanSidebarSection: View {
    @AppStorage("sidebar.serversExpanded", store: .windowState) private var expanded = true

    var body: some View {
        let controller = ServerPlanController.shared
        Section(isExpanded: $expanded) {
            if controller.servers.isEmpty {
                Text(controller.lastError ?? (controller.lastRefresh == nil ? String(localized: "Loading…") : String(localized: "No servers")))
                    .sidebarFont(.callout).foregroundStyle(controller.lastError == nil ? .tertiary : .secondary)
                    .lineLimit(3)
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
                Text(error).sidebarFont(.caption).foregroundStyle(.orange).lineLimit(3).selectionDisabled()
            }
        } header: {
            ServerPlanSidebarHeader(expanded: expanded)
        }
    }
}

private struct ServerPlanSidebarHeader: View {
    let expanded: Bool

    var body: some View {
        let controller = ServerPlanController.shared
        @Bindable var bindable = controller
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
            Text("Servers")
            Text("\(controller.servers.count)").foregroundStyle(.tertiary)
            Spacer()
            if controller.refreshing {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await controller.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh from ServerPlan")
            }
            if controller.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(controller.lastError ?? "")
            }
        }
        // Lists, health and capabilities only while the section is open and a window visible.
        .task(id: expanded) {
            guard expanded else { return }
            await controller.refreshLoop()
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
        return HStack(spacing: 6) {
            ServerDot(status: health?.reachable == false ? .offline : server.effectiveStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).lineLimit(1)
                if let health, health.reachable == false {
                    Text(health.error ?? String(localized: "Unreachable")).sidebarFont(.caption).foregroundStyle(.red).lineLimit(1)
                } else if let health {
                    Text(Self.healthLine(health)).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let host = server.host {
                    Text(host).sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if health?.reachable != false, health?.dockerOK == false {
                Image(systemName: "shippingbox").foregroundStyle(.orange).help("Docker isn't answering on this server")
            }
        }
        .help([server.host, health?.uptime, health?.loadAverage.map { String(localized: "load \($0)") }].compactMap { $0 }.joined(separator: " · "))
    }

    static func healthLine(_ health: ServerPlanHealth) -> String {
        [health.cpu.map { "CPU \($0)" }, health.memory.map { "RAM \($0)" }, health.disk.map { String(localized: "disk \($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func menu(_ controller: ServerPlanController) -> some View {
        if controller.allows(.terminal) {
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

    var body: some View {
        let controller = ServerPlanController.shared
        let deploy = controller.latestDeploy(of: project)
        HStack(spacing: 6) {
            DeployBadge(status: deploy?.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(project.name).lineLimit(1)
                    if let branch = project.branch, branch != "main", branch != "master" {
                        Text(branch).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let deploy {
                    Text(DeployBadge.label(deploy)).sidebarFont(.caption).foregroundStyle(deploy.status == .failed ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let deploy, deploy.status.isFinished { RowTime(date: deploy.finishedAt) }
            if let deploy, deploy.status == .failed { repairButton(deploy, controller) }
        }
        .contentShape(Rectangle())
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
        }
        if let deckProject = controller.deckProject(for: project) {
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

/// The last deploy's status as a small icon.
struct DeployBadge: View {
    let status: ServerPlanDeployStatus?

    var body: some View {
        Group {
            switch status {
            case .success?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
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
