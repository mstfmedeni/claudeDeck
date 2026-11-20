import SwiftUI

// ServerPlan and the simulators on the Mac, read-only. Rows under the dashboard card open them
// like a session. Deploying, restarting and the simulators' actions stay on the Mac; the one
// action here is Fix with Claude for a failed deploy, which the Mac starts (its own repair flow).

enum ServerStyle {
    static func color(server status: String) -> Color {
        switch status {
        case "online": .green
        case "offline": .red
        default: .secondary
        }
    }

    static func label(server status: String) -> String {
        switch status {
        case "online": String(localized: "Online")
        case "offline": String(localized: "Offline")
        default: String(localized: "Unknown")
        }
    }

    static let running: Set<String> = ["pending", "building", "transferring", "deploying"]

    static func color(deploy status: String) -> Color {
        switch status {
        case "success": .green
        case "failed": .red
        case "cancelled": .secondary
        default: running.contains(status) ? .blue : .secondary
        }
    }

    static func label(deploy status: String) -> String {
        switch status {
        case "pending": String(localized: "Pending")
        case "building": String(localized: "Building")
        case "transferring": String(localized: "Transferring")
        case "deploying": String(localized: "Deploying")
        case "success": String(localized: "Deployed")
        case "failed": String(localized: "Failed")
        case "cancelled": String(localized: "Cancelled")
        default: status
        }
    }
}

/// The list's row for the Servers screen: how many servers, and what's wrong.
struct ServersRow: View {
    @Environment(RemoteStore.self) private var store
    let plan: RemoteServerPlan

    var body: some View {
        let offline = plan.servers.filter { $0.status == "offline" }.count
        let failed = plan.deploys.filter { $0.status == "failed" && !store.clearedDeploys.contains($0.id) }.count
        NavigationLink(value: MacScreen.servers) {
            Label {
                HStack {
                    Text("Servers").listFont(.body)
                    Spacer(minLength: 4)
                    if failed > 0 {
                        Text("\(failed) failed").listFont(.caption, weight: .semibold).foregroundStyle(.red)
                    } else if offline > 0 {
                        Text("\(offline) offline").listFont(.caption, weight: .semibold).foregroundStyle(.red)
                    } else {
                        Text("\(plan.servers.count)").listFont(.caption, monospacedDigit: true).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "server.rack").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(failed > 0 || offline > 0 ? Color.red : Color.accentColor)
            }
        }
        .tag(MacScreen.servers)
    }
}

struct ServersScreen: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID

    var body: some View {
        Group {
            if let plan = store.serverPlan {
                list(plan)
            } else {
                ContentUnavailableView("ServerPlan Isn't Set Up", systemImage: "server.rack",
                                       description: Text("Connect ServerPlan in the Mac's Settings › ServerPlan."))
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Fix with Claude didn't start", isPresented: Binding(get: { store.serverPlanError != nil }, set: { if !$0 { store.serverPlanError = nil } })) {
            Button("OK") { store.serverPlanError = nil }
        } message: {
            Text(store.serverPlanError ?? "")
        }
    }

    private func list(_ plan: RemoteServerPlan) -> some View {
        let failures = plan.deploys.filter { $0.status == "failed" && !store.clearedDeploys.contains($0.id) }
        let running = plan.deploys.filter { ServerStyle.running.contains($0.status) }
        let projects = plan.projects ?? []
        let serverIDs = Set(plan.servers.map(\.id))
        let unplaced = projects.filter { $0.serverID.map { !serverIDs.contains($0) } ?? true }
        return List {
            if !failures.isEmpty {
                Section {
                    ForEach(failures) { deploy in
                        failureRow(deploy)
                            .swipeActions(edge: .trailing) {
                                // Only Macs that take it (older ones would drop the message).
                                if store.canClearServerErrors {
                                    Button(role: .destructive) { store.clearDeploys([deploy.id]) } label: {
                                        Label("Clear", systemImage: "xmark.circle")
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Failed Deploys")
                        Spacer()
                        if store.canClearServerErrors {
                            Button("Clear All") { store.clearDeploys(failures.map(\.id), all: true) }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                                .disabled(store.connection != .connected)
                        }
                    }
                } footer: {
                    if store.canClearServerErrors {
                        Text("Swipe to clear one. Clearing only hides it here and on the Mac; ServerPlan keeps the deploy.")
                    }
                }
            }
            if !running.isEmpty {
                Section("Deploying") {
                    ForEach(running) { deploy in
                        HStack {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deploy.project).font(.body)
                                if let server = deploy.server { Text(server).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            DeployPill(status: deploy.status)
                        }
                    }
                }
            }
            ForEach(plan.servers) { server in
                Section {
                    let mine = projects.filter { $0.serverID == server.id }
                    if mine.isEmpty, plan.projects != nil {
                        Text("No projects").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(mine) { project in projectRow(project) }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(ServerStyle.color(server: server.status)).frame(width: 8, height: 8)
                        Text(server.name)
                        Spacer()
                        Text(ServerStyle.label(server: server.status)).foregroundStyle(ServerStyle.color(server: server.status))
                    }
                }
            }
            if !unplaced.isEmpty {
                Section("Other Projects") {
                    ForEach(unplaced) { project in projectRow(project) }
                }
            }
            if plan.servers.isEmpty, projects.isEmpty, failures.isEmpty {
                Text("No servers yet").foregroundStyle(.secondary)
            }
            // Macs with Feature.registrarBalance, a ServerPlan 1.4 panel with Namecheap.
            if store.snapshot?.supports(RemoteSnapshot.Feature.registrarBalance) == true, let balance = plan.registrarBalance {
                Section {
                    HStack {
                        Label("Namecheap Balance", systemImage: balance.low ? "exclamationmark.triangle.fill" : "creditcard")
                        Spacer()
                        Text(verbatim: "\(balance.available.formatted(.number.precision(.fractionLength(0...2)))) \(balance.currency)")
                            .monospacedDigit()
                            .foregroundStyle(balance.low ? Color.orange : Color.secondary)
                    }
                } footer: {
                    if balance.low {
                        Text("Under the alert threshold. Top up for domain purchases: Namecheap › Billing › Add Funds.")
                    }
                }
            }
            Section {
            } footer: {
                Text("Read only. Deploy, restart and the terminals are on the Mac.")
            }
        }
    }

    private func projectRow(_ project: RemoteServerPlan.Project) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body)
                if let at = project.lastDeployAt {
                    Text(at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                } else if project.lastDeployStatus == nil {
                    Text("Never deployed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if let status = project.lastDeployStatus { DeployPill(status: status, muted: project.lastDeployCleared == true) }
        }
    }

    private func failureRow(_ deploy: RemoteServerPlan.Deploy) -> some View {
        let canFix = store.snapshot?.supports(RemoteSnapshot.Feature.serverPlanRepair) == true
        let repairing = store.repairingDeploys.contains(deploy.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deploy.project).font(.body.weight(.semibold))
                    HStack(spacing: 4) {
                        if let server = deploy.server { Text(server) }
                        if let at = deploy.finishedAt {
                            if deploy.server != nil { Text("·") }
                            Text(at, format: .relative(presentation: .named))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let error = deploy.error, !error.isEmpty {
                Text(error).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                    .textSelection(.enabled)
            }
            // Under the error: the full label fits on an iPhone too.
            if canFix {
                Button {
                    store.fixDeploy(deploy.id, from: sceneID)
                } label: {
                    HStack(spacing: 6) {
                        if repairing { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
                        Text("Fix with Claude")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(repairing || store.connection != .connected)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DeployPill: View {
    let status: String
    /// A failure cleared on the Mac: grey.
    var muted = false

    var body: some View {
        let color = muted ? Color.secondary : ServerStyle.color(deploy: status)
        Text(ServerStyle.label(deploy: status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Simulators

struct SimulatorsRow: View {
    let simulators: [RemoteSimulator]

    var body: some View {
        let running = simulators.filter { $0.state != "Shutdown" }.count
        NavigationLink(value: MacScreen.simulators) {
            Label {
                HStack {
                    Text("Simulators").listFont(.body)
                    Spacer(minLength: 4)
                    Text(running == 0 ? String(localized: "None running") : String(localized: "\(running) running"))
                        .listFont(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone.gen3").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(running > 0 ? Color.green : Color.secondary)
            }
        }
        .tag(MacScreen.simulators)
    }
}

struct SimulatorsScreen: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID

    var body: some View {
        Group {
            if let simulators = store.simulators {
                if simulators.isEmpty {
                    ContentUnavailableView("No Running Simulators", systemImage: "iphone.gen3.slash",
                                           description: Text("Running simulators and the ones a session used show up here."))
                } else {
                    List {
                        Section {
                            ForEach(simulators) { simulator in row(simulator) }
                        } footer: {
                            Text("Read only. Boot, shut down and erase on the Mac (File › Simulators…).")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Simulators Are Off", systemImage: "iphone.gen3",
                                       description: Text("Turn them on in the Mac's Settings › Simulators."))
            }
        }
        .navigationTitle("Simulators")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ simulator: RemoteSimulator) -> some View {
        let booted = simulator.state != "Shutdown"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(simulator)).font(.title3).foregroundStyle(booted ? Color.green : Color.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(simulator.name).font(.body.weight(.medium))
                    Text(simulator.runtime).font(.caption).foregroundStyle(.secondary)
                    if let holder = simulator.heldBy {
                        Label(store.snapshot?.session(holder)?.name ?? String(localized: "Closed session"), systemImage: "lock.fill")
                            .font(.caption2).foregroundStyle(.tint).lineLimit(1)
                            .accessibilityLabel(Text("Reserved by \(store.snapshot?.session(holder)?.name ?? "")"))
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(simulator.isBooted ? String(localized: "Running") : simulator.state == "Shutdown" ? String(localized: "Shut down") : simulator.state)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(booted ? Color.green : Color.secondary)
                    if let bytes = simulator.memoryBytes {
                        Text(Int64(bytes), format: .byteCount(style: .memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            let sessions = simulator.sessionIDs.compactMap { store.snapshot?.session($0) }
            if !sessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sessions) { session in
                            Button { store.open(session.id, in: sceneID) } label: {
                                Label(session.name, systemImage: session.isTerminal ? "apple.terminal" : "bubble.left")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 2)
    }

    private static func icon(_ simulator: RemoteSimulator) -> String {
        let name = simulator.name.lowercased(), runtime = simulator.runtime.lowercased()
        if runtime.contains("watch") || name.contains("watch") { return "applewatch" }
        if runtime.contains("vision") || name.contains("vision") { return "visionpro" }
        if name.contains("ipad") { return "ipad" }
        return "iphone"
    }
}
