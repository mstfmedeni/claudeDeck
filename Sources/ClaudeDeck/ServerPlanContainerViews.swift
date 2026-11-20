import AppKit
import ClaudeDeckCore
import SwiftUI

// Containers in the sidebar and their detail sheet (overview, live logs with search and
// "Claude ile düzelt", stats with sparklines, the project env), and a server's sheet (health,
// its containers' use, Docker's disk and clean-up). What a 1.4 panel can't do is shown only
// when `/me` names the feature (docs/serverplan-containers.md).

enum ServerPlanContainerText {
    static func color(_ condition: ServerPlanContainerCondition) -> Color {
        switch condition {
        case .running: .green
        case .starting: .yellow
        case .unhealthy, .restarting: .orange
        case .failed: .red
        case .paused, .stopped: .secondary
        }
    }

    static func label(_ condition: ServerPlanContainerCondition) -> String {
        switch condition {
        case .running: String(localized: "Running")
        case .starting: String(localized: "Starting")
        case .unhealthy: String(localized: "Unhealthy")
        case .restarting: String(localized: "Restarting")
        case .paused: String(localized: "Paused")
        case .stopped: String(localized: "Stopped")
        case .failed: String(localized: "Crashed")
        }
    }

    /// "Up 2 hours · 205 · shop.example.com" for the row's second line.
    static func detail(_ container: ServerPlanContainer, domains: [String]) -> String {
        var parts: [String] = []
        if let uptime = container.uptime {
            parts.append(String(localized: "up \(uptime)"))
        } else if let code = container.exitCode {
            parts.append(String(localized: "exited (\(code))"))
        } else if let status = container.status {
            parts.append(status)
        }
        if let tag = container.imageTag { parts.append(tag) }
        if let domain = domains.first { parts.append(domain) } else if let port = container.portList.first { parts.append(port) }
        return parts.joined(separator: " · ")
    }

    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "–" }
    static func rate(_ value: Double?) -> String { value.map { ByteSize.format($0) + "/s" } ?? "–" }
}

// MARK: - Sidebar row

struct ServerPlanContainerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerPlanServer
    let container: ServerPlanContainer
    @State private var hovering = false

    var body: some View {
        let controller = ServerPlanController.shared
        let condition = container.condition
        let domains = controller.domains(for: container, serverID: server.id)
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .sidebarFont(.caption)
                .foregroundStyle(ServerPlanContainerText.color(condition))
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).sidebarFont(.callout).lineLimit(1)
                Text(ServerPlanContainerText.detail(container, domains: domains)).sidebarFont(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let stats = controller.containerStats[server.id]?[container.name], container.isRunning {
                Text(ServerPlanContainerText.percent(stats.cpuPercent)).sidebarFont(.caption, monospacedDigit: true).foregroundStyle(.secondary)
            } else if condition.isProblem {
                Text(ServerPlanContainerText.label(condition)).sidebarFont(.caption).foregroundStyle(ServerPlanContainerText.color(condition))
            }
            if hovering {
                Button { open(.overview) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("Show Details")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { open(.overview) }
        .help([container.image, container.status].compactMap { $0 }.joined(separator: " · "))
        .contextMenu { ServerPlanContainerMenu(server: server, container: container) }
    }

    private func open(_ tab: ServerPlanContainerTab) {
        ServerPlanController.shared.sheet = .container(serverID: server.id, server: server.name, container: container.name, tab: tab)
    }
}

/// The container's actions: the row's context menu and the sheet's "More" menu.
struct ServerPlanContainerMenu: View {
    @Environment(AppModel.self) private var model
    let server: ServerPlanServer
    let container: ServerPlanContainer
    var inSheet = false

    var body: some View {
        let controller = ServerPlanController.shared
        if !inSheet {
            Button("Show Details") { controller.sheet = .container(serverID: server.id, server: server.name, container: container.name, tab: .overview) }
            if controller.allows(.logs) {
                Button("Logs") { controller.sheet = .container(serverID: server.id, server: server.name, container: container.name, tab: .logs) }
            }
        }
        if controller.canOpenTerminal, controller.has(ServerPlanContract.Feature.containerExec), container.isRunning {
            Button("Open Shell in Container") {
                controller.sheet = nil
                model.openServerPlanTerminal(serverID: server.id, serverName: server.name, runClaude: false, container: container.name)
            }
        }
        if controller.allows(.containers) {
            Divider()
            if !inSheet {
                if container.isRunning {
                    Button("Restart…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .restart)) }
                    Button("Stop…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .stop)) }
                } else {
                    Button("Start…") { controller.request(.container(serverID: server.id, serverName: server.name, name: container.name, verb: .start)) }
                }
            }
            ForEach(ServerPlanAction.ContainerOp.allCases, id: \.self) { op in
                if controller.has(op.feature) {
                    Button(Self.title(op)) { controller.request(.containerOp(serverID: server.id, serverName: server.name, name: container.name, op: op)) }
                }
            }
        }
    }

    static func title(_ op: ServerPlanAction.ContainerOp) -> String {
        switch op {
        case .recreate: String(localized: "Recreate…")
        case .pull: String(localized: "Update Image…")
        case .remove: String(localized: "Remove…")
        }
    }
}

// MARK: - Container sheet

struct ServerPlanContainerSheet: View {
    let serverID: Int
    let server: String
    let name: String
    @State var tab: ServerPlanContainerTab
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = ServerPlanController.shared
        @Bindable var bindable = controller
        let container = controller.container(serverID, name) ?? ServerPlanContainer(name: name)
        let serverRow = controller.server(serverID) ?? ServerPlanServer(id: serverID, name: server)
        VStack(alignment: .leading, spacing: 10) {
            header(container, serverRow, controller)
            Picker("", selection: $tab) {
                Text("Overview").tag(ServerPlanContainerTab.overview)
                if controller.allows(.logs) { Text("Logs").tag(ServerPlanContainerTab.logs) }
                Text("Stats").tag(ServerPlanContainerTab.stats)
                Text("Env").tag(ServerPlanContainerTab.env)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch tab {
                case .overview: ServerPlanContainerOverview(serverID: serverID, server: server, container: container)
                case .logs: ServerPlanLogsPane(serverID: serverID, server: server, container: container)
                case .stats: ServerPlanContainerStatsPane(serverID: serverID, container: container)
                case .env: ServerPlanEnvPane(serverID: serverID, container: container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ServerPlanActionStatus()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 520)
        .modifier(ServerPlanConfirmAlert(binding: $bindable.pendingConfirm))
    }

    @ViewBuilder private func header(_ container: ServerPlanContainer, _ serverRow: ServerPlanServer, _ controller: ServerPlanController) -> some View {
        let condition = container.condition
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(ServerPlanContainerText.color(condition))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) · \(server)").font(.headline)
                Text([ServerPlanContainerText.label(condition), container.status].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(condition.isProblem ? ServerPlanContainerText.color(condition) : .secondary)
            }
            Spacer()
            if controller.actionRunning.contains(where: { $0.containerName == name }) { ProgressView().controlSize(.small) }
            if controller.allows(.containers) {
                if container.isRunning {
                    Button("Restart…") { controller.request(.container(serverID: serverID, serverName: server, name: name, verb: .restart)) }
                    Button("Stop…") { controller.request(.container(serverID: serverID, serverName: server, name: name, verb: .stop)) }
                } else {
                    Button("Start…") { controller.request(.container(serverID: serverID, serverName: server, name: name, verb: .start)) }
                }
            }
            if controller.canOpenTerminal {
                Button("Server Terminal") {
                    controller.sheet = nil
                    model.openServerPlanTerminal(serverID: serverID, serverName: server, runClaude: false)
                }
            }
            Menu("More") { ServerPlanContainerMenu(server: serverRow, container: container, inSheet: true) }
                .fixedSize()
        }
    }
}

/// The panel's 428 summary for a destructive action, shown where the owner clicked (a sheet
/// presents its own; the sidebar's only while no sheet is up).
struct ServerPlanConfirmAlert: ViewModifier {
    let binding: Binding<ServerPlanPendingConfirm?>

    func body(content: Content) -> some View {
        content.alert(item: binding) { pending in
            Alert(
                title: Text(ServerPlanActionText.title(pending.action)),
                message: Text(pending.preview.summary ?? ServerPlanActionText.fallbackSummary(pending.action)),
                primaryButton: .destructive(Text(ServerPlanActionText.button(pending.action))) { ServerPlanController.shared.confirm(pending) },
                secondaryButton: .cancel()
            )
        }
    }
}

/// The last action's error or result, with a clear button.
struct ServerPlanActionStatus: View {
    var body: some View {
        let controller = ServerPlanController.shared
        if let error = controller.actionError {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Spacer()
                ServerPlanClearButton { controller.actionError = nil }
            }
        } else if let notice = controller.actionNotice {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(notice).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ServerPlanClearButton { controller.actionNotice = nil }
            }
        }
    }
}

// MARK: Overview

private struct ServerPlanContainerOverview: View {
    let serverID: Int
    let server: String
    let container: ServerPlanContainer
    @Environment(AppModel.self) private var model
    @State private var inspect: ServerPlanContainerInspect?
    @State private var inspectError: String?

    var body: some View {
        let controller = ServerPlanController.shared
        let project = controller.project(for: container, serverID: serverID)
        let domains = controller.domains(for: container, serverID: serverID)
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                row("State") {
                    HStack(spacing: 6) {
                        Circle().fill(ServerPlanContainerText.color(container.condition)).frame(width: 8, height: 8)
                        Text(ServerPlanContainerText.label(container.condition))
                        if let status = container.status { Text(status).foregroundStyle(.secondary) }
                    }
                }
                if container.health != .none { row("Health") { Text(container.health.rawValue) } }
                if let uptime = container.uptime { row("Up") { Text(uptime) } }
                if let code = container.exitCode { row("Exit code") { Text(verbatim: "\(code)").foregroundStyle(code == 0 ? Color.secondary : Color.red) } }
                row("Image") { Text(container.image ?? "–").textSelection(.enabled) }
                row("Ports") { Text(container.portList.isEmpty ? "–" : container.portList.joined(separator: ", ")).textSelection(.enabled) }
                row("Domains") {
                    if domains.isEmpty {
                        Text(verbatim: "–")
                    } else {
                        HStack(spacing: 10) {
                            ForEach(domains, id: \.self) { domain in
                                if let url = URL(string: "https://\(domain)") { Link(domain, destination: url) } else { Text(domain) }
                            }
                        }
                    }
                }
                row("Project") {
                    if let project {
                        HStack(spacing: 8) {
                            Text(project.name)
                            if let deck = controller.deckProject(for: project) {
                                Text("(\(deck.name) in ClaudeDeck)").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Not a ServerPlan project's container").foregroundStyle(.secondary)
                    }
                }
                if let id = container.containerID { row("Container ID") { Text(id).textSelection(.enabled) } }
                if let created = container.created { row("Created") { Text(created) } }
                if let inspect {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    if let count = inspect.restartCount {
                        row("Restarts") { Text(verbatim: "\(count)" + (inspect.restartPolicy.map { " (\($0))" } ?? "")) }
                    }
                    if let started = inspect.startedAt { row("Started") { Text(started, format: .dateTime) } }
                    if let finished = inspect.finishedAt, !container.isRunning { row("Finished") { Text(finished, format: .dateTime) } }
                    if inspect.oomKilled == true { row("Out of memory") { Text("Killed by the kernel (OOM)").foregroundStyle(.red) } }
                    if !inspect.networks.isEmpty { row("Networks") { Text(inspect.networks.joined(separator: ", ")) } }
                    if !inspect.mounts.isEmpty {
                        row("Mounts") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(inspect.mounts, id: \.destination) { mount in
                                    Text(verbatim: "\(mount.source) → \(mount.destination)" + (mount.rw ? "" : " (ro)")).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !inspect.envKeys.isEmpty { row("Env keys") { Text(inspect.envKeys.joined(separator: ", ")).textSelection(.enabled) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            if let inspectError { Text(inspectError).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: container.name) { await loadInspect() }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    private func loadInspect() async {
        let controller = ServerPlanController.shared
        guard let client = controller.client, controller.has(ServerPlanContract.Feature.containerInspect) else { return }
        do {
            inspect = try await client.containerInspect(serverID: serverID, container: container.name)
        } catch {
            inspectError = error.localizedDescription
        }
    }
}

// MARK: Logs

/// One log line on screen.
private struct ServerPlanLogEntry: Identifiable, Equatable {
    let id: Int
    let text: String
    let stderr: Bool
    let severity: ServerPlanLogSeverity
}

/// The tail, then followed (the panel's SSE stream; polled when it has none) while the pane is
/// open and a window visible. Search, "errors only", highlighting, selection, and "Claude ile
/// düzelt" with the selected lines.
struct ServerPlanLogsPane: View {
    let serverID: Int
    let server: String
    let container: ServerPlanContainer
    @State private var entries: [ServerPlanLogEntry] = []
    @State private var nextID = 0
    @State private var follow = true
    @State private var query = ""
    @State private var errorsOnly = false
    @State private var selection: Set<Int> = []
    @State private var error: String?
    @State private var reloads = 0

    static let maxLines = 5_000
    static let initialTail = 500

    var body: some View {
        let controller = ServerPlanController.shared
        let filter = ServerPlanLogFilter(query: query, errorsOnly: errorsOnly)
        let shown = filter.isActive ? entries.filter { filter.matches($0.text) } : entries
        let errors = entries.filter { $0.severity == .error }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search (re: for a regex)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                Button { reloads += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload the log")
            }
            if filter.invalidRegex { Text("Not a valid regular expression.").font(.caption).foregroundStyle(.orange) }
            ScrollViewReader { proxy in
                List(shown, selection: $selection) { entry in
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(entry))
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .id(entry.id)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 14)
                .contextMenu(forSelectionType: Int.self) { ids in
                    Button("Copy") { copy(ids) }
                    Button("Fix with Claude") { fix(ids) }.disabled(project == nil)
                }
                .onChange(of: entries.last?.id) {
                    if follow, selection.isEmpty, let last = shown.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                Text(filter.isActive ? "\(shown.count) of \(entries.count) lines" : "\(entries.count) lines")
                    .font(.caption).foregroundStyle(.secondary)
                if errors > 0 {
                    Button { errorsOnly.toggle() } label: {
                        Label("\(errors) errors", systemImage: "exclamationmark.octagon.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
                Spacer()
                if !selection.isEmpty {
                    Button("Copy \(selection.count) Lines") { copy(selection) }
                }
                Button(selection.isEmpty ? String(localized: "Fix with Claude") : String(localized: "Fix \(selection.count) Lines with Claude")) {
                    fix(selection)
                }
                .disabled(project == nil || entries.isEmpty || controller.repairingLogs.contains(ServerPlanController.key(serverID, container.name)))
                .help(project == nil ? Text("This container doesn't belong to a ServerPlan project with a folder on this Mac.")
                      : Text("Sends the selected lines (or, with none selected, the shown errors and the last lines) to a Claude session in the project."))
            }
        }
        .task(id: "\(follow)-\(reloads)") { await load() }
    }

    private var project: ServerPlanProject? { ServerPlanController.shared.project(for: container, serverID: serverID) }

    private func color(_ entry: ServerPlanLogEntry) -> Color {
        switch entry.severity {
        case .error: .red
        case .warning: .orange
        case .normal: entry.stderr ? .secondary : .primary
        }
    }

    private func lines(_ ids: Set<Int>) -> [String] {
        entries.filter { ids.contains($0.id) }.map(\.text)
    }

    private func copy(_ ids: Set<Int>) {
        let text = lines(ids).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The selected lines; with none, the error lines (with the lines around the last ones)
    /// and the tail.
    private func fix(_ ids: Set<Int>) {
        var picked = lines(ids)
        if picked.isEmpty { picked = ContainerLogRepair.pick(entries.map(\.text)) }
        ServerPlanController.shared.fixLogsWithClaude(serverID: serverID, server: server, container: container, lines: picked)
    }

    private func append(_ text: String, stderr: Bool) {
        entries.append(ServerPlanLogEntry(id: nextID, text: text, stderr: stderr, severity: ServerPlanLogSeverity.of(text)))
        nextID += 1
        if entries.count > Self.maxLines { entries.removeFirst(entries.count - Self.maxLines) }
    }

    private func replace(with text: String) {
        entries = []
        selection = []
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        for line in lines { append(line, stderr: false) }
    }

    private func load() async {
        let controller = ServerPlanController.shared
        guard let client = controller.client else { return }
        let streams = controller.has(ServerPlanContract.Feature.logStream)
        if !follow || !streams {
            // The tail; when following without a stream, polled every 5 s.
            repeat {
                await AppVisibility.shared.waitUntilVisible()
                do {
                    replace(with: try await client.containerLogs(serverID: serverID, container: container.name, tail: Self.initialTail))
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                guard follow else { return }
                try? await Task.sleep(for: .seconds(5))
            } while !Task.isCancelled
            return
        }
        // Follow: reconnects when a window shows again after the stream ended. With `log_query`
        // the reconnect asks for what was logged since the stream stopped (`since`), so the gap
        // while hidden is filled; without it the stream restarts from now.
        entries = []
        selection = []
        var ended = false
        var stoppedAt: Date?
        let resumes = controller.has(ServerPlanContract.Feature.logQuery)
        while !Task.isCancelled, !ended {
            await AppVisibility.shared.waitUntilVisible()
            do {
                let since = resumes ? stoppedAt.map { $0.formatted(.iso8601) } : nil
                let tail = entries.isEmpty ? Self.initialTail : since != nil ? Self.initialTail : 0
                defer { stoppedAt = Date() }
                for try await event in try await client.containerLogStream(serverID: serverID, container: container.name, tail: tail,
                                                                           since: since) {
                    if let reason = ServerPlanLogLine.endReason(event) {
                        append("— " + (reason.isEmpty ? String(localized: "log ended") : reason) + " —", stderr: true)
                        ended = true
                        break
                    }
                    guard let line = ServerPlanLogLine(event) else { continue }
                    append(line.line, stderr: line.stream == "stderr")
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

// MARK: Stats

struct ServerPlanSparkline: View {
    let values: [Double]
    /// The top of the chart (100 for percentages); nil: the series' own peak.
    var ceiling: Double?
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(ceiling ?? (values.max() ?? 1), 0.000_1)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(min(value, top) / top) * (size.height - 2) - 1)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.15)))
            context.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

struct ServerPlanMetricTile: View {
    let title: LocalizedStringKey
    let value: String
    let series: MetricSeries
    var ceiling: Double?
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.callout.monospacedDigit())
            }
            if series.values.count > 1 {
                ServerPlanSparkline(values: series.values, ceiling: ceiling, color: color)
            } else {
                Text("Collecting…").font(.caption2).foregroundStyle(.tertiary).frame(height: 30)
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// CPU, memory, disk, load (and network on panels that send counters) of a server.
struct ServerPlanServerTiles: View {
    let serverID: Int

    var body: some View {
        let controller = ServerPlanController.shared
        let series = controller.serverSeries[serverID] ?? ServerPlanSeries()
        let sample = controller.health[serverID].map(ServerPlanServerSample.init)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
            ServerPlanMetricTile(title: "CPU", value: ServerPlanContainerText.percent(sample?.cpuPercent), series: series.cpu, ceiling: 100)
            ServerPlanMetricTile(title: "Memory", value: ServerPlanContainerText.percent(sample?.memPercent), series: series.memory, ceiling: 100, color: .purple)
            ServerPlanMetricTile(title: "Disk", value: ServerPlanContainerText.percent(sample?.diskPercent), series: series.disk, ceiling: 100, color: .orange)
            ServerPlanMetricTile(title: "Load (1 min)", value: sample?.load1.map { String(format: "%.2f", $0) } ?? "–", series: series.load, color: .teal)
            if sample?.netRxBytes != nil {
                ServerPlanMetricTile(title: "Network in", value: ServerPlanContainerText.rate(series.netIn.last), series: series.netIn, color: .green)
                ServerPlanMetricTile(title: "Network out", value: ServerPlanContainerText.rate(series.netOut.last), series: series.netOut, color: .blue)
            }
        }
    }
}

private struct ServerPlanContainerStatsPane: View {
    let serverID: Int
    let container: ServerPlanContainer

    var body: some View {
        let controller = ServerPlanController.shared
        let perContainer = controller.has(ServerPlanContract.Feature.containerStats)
        let stats = controller.containerStats[serverID]?[container.name]
        let series = controller.containerSeries[ServerPlanController.key(serverID, container.name)] ?? ServerPlanSeries()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("This container").font(.headline)
                if !perContainer {
                    Text("Per-container CPU, memory and network need ServerPlan's container_stats; this panel doesn't offer it yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !container.isRunning {
                    Text("Not running.").font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                        ServerPlanMetricTile(title: "CPU", value: ServerPlanContainerText.percent(stats?.cpuPercent), series: series.cpu)
                        ServerPlanMetricTile(title: "Memory", value: memory(stats), series: series.memory, ceiling: 100, color: .purple)
                        ServerPlanMetricTile(title: "Network in", value: ServerPlanContainerText.rate(series.netIn.last), series: series.netIn, color: .green)
                        ServerPlanMetricTile(title: "Network out", value: ServerPlanContainerText.rate(series.netOut.last), series: series.netOut, color: .blue)
                    }
                    if let pids = stats?.pids { Text("Processes: \(pids)").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Server").font(.headline)
                ServerPlanServerTiles(serverID: serverID)
                Text("Sampled every 10 seconds while this is open.").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: serverID) { await controller.sampleLoop(serverID, containers: perContainer) }
    }

    private func memory(_ stats: ServerPlanContainerStats?) -> String {
        guard let stats else { return "–" }
        let percent = ServerPlanContainerText.percent(stats.memPercent)
        guard let used = stats.memUsedBytes else { return percent }
        return "\(percent) · \(ByteSize.format(used))"
    }
}

// MARK: Env

/// The deploy env of the container's ServerPlan project: secrets never come back from the panel;
/// a change applies at the next deploy (or a recreate, on panels that offer it).
private struct ServerPlanEnvPane: View {
    let serverID: Int
    let container: ServerPlanContainer
    @State private var rows: [ServerPlanEnvVar] = []
    @State private var loading = false
    @State private var error: String?
    @State private var key = ""
    @State private var value = ""
    @State private var secret = false
    @State private var confirmSave = false
    @State private var saved: String?

    var body: some View {
        let controller = ServerPlanController.shared
        let project = controller.project(for: container, serverID: serverID)
        VStack(alignment: .leading, spacing: 10) {
            if let project {
                HStack {
                    Text("Deploy env of \(project.name)").font(.headline)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { Task { await load(project) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                List(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.key).font(.system(.callout, design: .monospaced)).frame(minWidth: 180, alignment: .leading)
                        if row.isSecret {
                            Label("secret", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(row.value ?? "").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        }
                        Spacer()
                        if let source = row.source { Text(source).font(.caption).foregroundStyle(.tertiary) }
                        Button { key = row.key; value = row.value ?? ""; secret = row.isSecret } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit")
                        if controller.has(ServerPlanContract.Feature.envDelete), let envID = row.envID {
                            Button { controller.request(.envDelete(projectID: project.id, projectName: project.name, envID: envID, key: row.key)) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete…")
                        }
                    }
                }
                .frame(minHeight: 160)
                HStack(spacing: 8) {
                    TextField("KEY", text: $key).textFieldStyle(.roundedBorder).frame(width: 200).font(.system(.body, design: .monospaced))
                    if secret {
                        SecureField("Value", text: $value).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Value", text: $value).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Secret", isOn: $secret).toggleStyle(.checkbox)
                    Button("Save…") { confirmSave = true }
                        .disabled(!Self.validKey(key) || !controller.allows(.read))
                }
                HStack(spacing: 8) {
                    Text("Changes apply at the next deploy.").font(.caption).foregroundStyle(.secondary)
                    if let saved { Text(saved).font(.caption).foregroundStyle(.green) }
                    Spacer()
                    if controller.has(ServerPlanContract.Feature.containerRecreate), controller.allows(.containers) {
                        Button("Recreate Now…") {
                            controller.request(.containerOp(serverID: serverID, serverName: controller.server(serverID)?.name ?? "#\(serverID)",
                                                            name: container.name, op: .recreate))
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("This container doesn't belong to a ServerPlan project, so it has no env here.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: project?.id) { if let project { await load(project) } }
        .alert("Save \(key) to the deploy env of \(project?.name ?? "")?", isPresented: $confirmSave) {
            Button("Save") { if let project { Task { await save(project) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(secret ? "The value is stored as a secret; it can't be read back." : "The running container keeps its env until the next deploy.")
        }
    }

    static func validKey(_ key: String) -> Bool { key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil }

    private func load(_ project: ServerPlanProject) async {
        guard let client = ServerPlanController.shared.client else { return }
        loading = true
        defer { loading = false }
        do {
            rows = try await client.projectEnv(projectID: project.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ project: ServerPlanProject) async {
        guard let client = ServerPlanController.shared.client else { return }
        do {
            try await client.setProjectEnv(projectID: project.id, key: key, value: value, secret: secret)
            saved = String(localized: "\(key) saved.")
            key = ""
            value = ""
            secret = false
            await load(project)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Server sheet

/// A server: health sparklines, its containers (with their use on panels that send it), and
/// Docker's disk with a clean-up on panels with `docker_prune`.
struct ServerPlanServerSheet: View {
    let serverID: Int
    let server: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var disk: ServerPlanDockerDisk?
    @State private var diskError: String?
    @State private var images: ServerPlanPruneOptions.Images = .dangling
    @State private var pruneContainers = true
    @State private var buildCache = true
    @State private var volumes = false

    var body: some View {
        let controller = ServerPlanController.shared
        @Bindable var bindable = controller
        let serverRow = controller.server(serverID) ?? ServerPlanServer(id: serverID, name: server)
        let health = controller.health[serverID]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "server.rack")
                VStack(alignment: .leading, spacing: 2) {
                    Text(server).font(.headline)
                    Text([serverRow.host, health?.uptime, health?.loadAverage.map { String(localized: "load \($0)") }].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if health?.dockerOK == false { Label("Docker isn't answering", systemImage: "shippingbox").foregroundStyle(.orange) }
                if controller.canOpenTerminal {
                    Button("Open Terminal") {
                        controller.sheet = nil
                        model.openServerPlanTerminal(serverID: serverID, serverName: server, runClaude: false)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ServerPlanServerTiles(serverID: serverID)
                    containers(controller)
                    docker(controller)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ServerPlanActionStatus()
            HStack {
                Text("Sampled every 10 seconds while this is open.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 540)
        .task(id: serverID) {
            await loadDisk()
            await controller.sampleLoop(serverID, containers: controller.has(ServerPlanContract.Feature.containerStats))
        }
        // A clean-up finished: what's left.
        .onChange(of: controller.actionNotice) { Task { await loadDisk() } }
        .modifier(ServerPlanConfirmAlert(binding: $bindable.pendingConfirm))
    }

    @ViewBuilder private func containers(_ controller: ServerPlanController) -> some View {
        let list = controller.containers[serverID] ?? []
        let stats = controller.containerStats[serverID] ?? [:]
        Text("Containers").font(.headline)
        if list.isEmpty {
            Text("No containers loaded yet.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Name"); Text("State"); Text("CPU"); Text("Memory"); Text("Image")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(list) { container in
                    GridRow {
                        Button(container.name) {
                            controller.sheet = .container(serverID: serverID, server: server, container: container.name, tab: .overview)
                        }
                        .buttonStyle(.link)
                        HStack(spacing: 4) {
                            Circle().fill(ServerPlanContainerText.color(container.condition)).frame(width: 7, height: 7)
                            Text(ServerPlanContainerText.label(container.condition))
                        }
                        Text(ServerPlanContainerText.percent(stats[container.name]?.cpuPercent)).monospacedDigit()
                        Text(stats[container.name]?.memUsedBytes.map(ByteSize.format) ?? "–").monospacedDigit()
                        Text(container.image ?? "–").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if !controller.has(ServerPlanContract.Feature.containerStats) {
                Text("Per-container CPU and memory need ServerPlan's container_stats; this panel doesn't offer it yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func docker(_ controller: ServerPlanController) -> some View {
        Text("Docker disk").font(.headline)
        if !controller.has(ServerPlanContract.Feature.dockerPrune) {
            Text("Disk usage and clean-up need ServerPlan's docker_prune; this panel doesn't offer it yet. ServerPlan removes dangling images after every deploy.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let disk {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text(verbatim: ""); Text("Total"); Text("In use"); Text("Size"); Text("Reclaimable") }.font(.caption).foregroundStyle(.secondary)
                usage("Images", disk.images)
                usage("Containers", disk.containers)
                usage("Volumes", disk.volumes)
                usage("Build cache", disk.buildCache)
            }
            HStack(spacing: 12) {
                Picker("Images", selection: $images) {
                    Text("Dangling").tag(ServerPlanPruneOptions.Images.dangling)
                    Text("All unused").tag(ServerPlanPruneOptions.Images.unused)
                    Text("Keep").tag(ServerPlanPruneOptions.Images.none)
                }
                .fixedSize()
                Toggle("Stopped containers", isOn: $pruneContainers).toggleStyle(.checkbox)
                Toggle("Build cache", isOn: $buildCache).toggleStyle(.checkbox)
                Toggle("Unused volumes (their data too)", isOn: $volumes).toggleStyle(.checkbox)
            }
            HStack {
                let options = ServerPlanPruneOptions(images: images, containers: pruneContainers, volumes: volumes, buildCache: buildCache)
                Text("Up to \(ByteSize.format(disk.reclaimable(options))) can be freed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clean Up…") { controller.request(.prune(serverID: serverID, serverName: server, options: options)) }
                    .disabled(!controller.allows(.containers))
            }
        } else if let diskError {
            Text(diskError).font(.caption).foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func usage(_ title: LocalizedStringKey, _ usage: ServerPlanDockerDisk.Usage) -> some View {
        GridRow {
            Text(title)
            Text(verbatim: "\(usage.count)").monospacedDigit()
            Text(verbatim: "\(usage.active)").monospacedDigit()
            Text(ByteSize.format(usage.sizeBytes)).monospacedDigit()
            Text(ByteSize.format(usage.reclaimableBytes)).monospacedDigit()
        }
    }

    private func loadDisk() async {
        let controller = ServerPlanController.shared
        guard let client = controller.client, controller.has(ServerPlanContract.Feature.dockerPrune) else { return }
        do {
            disk = try await client.dockerDisk(serverID: serverID)
        } catch {
            diskError = error.localizedDescription
        }
    }
}
