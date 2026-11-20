import SwiftUI

// A ServerPlan server's containers on the phone (Macs with Feature.serverPlanContainers): state,
// use where the panel sends it, the last log lines, and start / stop / restart, which the Mac
// asks the owner to approve (a card in its Onaylar queue) before anything happens.

enum ContainerStyle {
    static func color(_ condition: String) -> Color {
        switch condition {
        case "running": .green
        case "starting": .yellow
        case "unhealthy", "restarting": .orange
        case "failed": .red
        default: .secondary
        }
    }

    static func label(_ condition: String) -> String {
        switch condition {
        case "running": String(localized: "Running")
        case "starting": String(localized: "Starting")
        case "unhealthy": String(localized: "Unhealthy")
        case "restarting": String(localized: "Restarting")
        case "paused": String(localized: "Paused")
        case "failed": String(localized: "Crashed")
        default: String(localized: "Stopped")
        }
    }
}

struct ServerContainersScreen: View {
    @Environment(RemoteStore.self) private var store
    let serverID: Int
    let serverName: String

    var body: some View {
        let state = store.serverContainers[serverID]
        List {
            if let error = state?.error {
                Section { Text(error).foregroundStyle(.orange) }
            }
            ForEach(state?.containers ?? []) { container in
                NavigationLink {
                    ContainerDetailScreen(serverID: serverID, serverName: serverName, name: container.name)
                } label: {
                    row(container)
                }
            }
            if state?.loading == false, state?.containers.isEmpty == true, state?.error == nil {
                Text("No containers").foregroundStyle(.secondary)
            }
        }
        .overlay { if state == nil || (state?.loading == true && state?.containers.isEmpty == true) { ProgressView() } }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.loadContainers(serverID) }
        .task { store.loadContainers(serverID) }
    }

    private func row(_ container: RemoteServerPlan.Container) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ContainerStyle.color(container.condition)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.body)
                Text(container.status ?? ContainerStyle.label(container.condition)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let cpu = container.cpuPercent {
                Text(verbatim: String(format: "%.1f%%", cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct ContainerDetailScreen: View {
    @Environment(RemoteStore.self) private var store
    let serverID: Int
    let serverName: String
    let name: String
    @State private var confirm: String?

    var body: some View {
        let state = store.serverContainers[serverID]
        let container = state?.containers.first { $0.name == name }
        let key = RemoteStore.containerKey(serverID, name)
        List {
            if let container {
                Section {
                    LabeledContent("State") {
                        Text(ContainerStyle.label(container.condition)).foregroundStyle(ContainerStyle.color(container.condition))
                    }
                    if let status = container.status { LabeledContent("Status", value: status) }
                    if let image = container.image { LabeledContent("Image", value: image) }
                    if !container.domains.isEmpty { LabeledContent("Domains", value: container.domains.joined(separator: ", ")) }
                    if let cpu = container.cpuPercent { LabeledContent("CPU") { Text(verbatim: String(format: "%.1f%%", cpu)) } }
                    if let memory = container.memPercent { LabeledContent("Memory") { Text(verbatim: String(format: "%.1f%%", memory)) } }
                }
                Section {
                    if let pending = store.containerActions[key] {
                        HStack {
                            ProgressView()
                            Text(pending).foregroundStyle(.secondary)
                        }
                    } else {
                        if container.isRunning {
                            Button("Restart…") { confirm = "restart" }
                            Button("Stop…", role: .destructive) { confirm = "stop" }
                        } else {
                            Button("Start…") { confirm = "start" }
                        }
                    }
                    if let result = store.containerActionResults[key] {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The Mac asks you to approve it in its Approvals before anything happens.")
                }
            }
            Section("Last Log Lines") {
                if let logs = state?.logsOf == name ? state?.logs : nil {
                    if logs.isEmpty {
                        Text("No log lines").foregroundStyle(.secondary)
                    } else {
                        Text(logs.suffix(100).joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else if state?.loading == true {
                    ProgressView()
                } else if let error = state?.error {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.loadContainers(serverID, logsOf: name) }
        .task { store.loadContainers(serverID, logsOf: name) }
        .confirmationDialog(confirm.map { Self.question($0, name: name, server: serverName) } ?? "", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } }
        ), titleVisibility: .visible) {
            if let verb = confirm {
                Button(Self.button(verb), role: verb == "stop" ? .destructive : nil) { store.containerAction(serverID, name, verb: verb) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    static func question(_ verb: String, name: String, server: String) -> String {
        switch verb {
        case "start": String(localized: "Start \(name) on \(server)?")
        case "stop": String(localized: "Stop \(name) on \(server)?")
        default: String(localized: "Restart \(name) on \(server)?")
        }
    }

    static func button(_ verb: String) -> String {
        switch verb {
        case "start": String(localized: "Ask the Mac to Start")
        case "stop": String(localized: "Ask the Mac to Stop")
        default: String(localized: "Ask the Mac to Restart")
        }
    }
}
