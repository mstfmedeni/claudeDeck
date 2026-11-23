import Charts
import SwiftUI

// The Mac's load on the phone (hosts with `Feature.load`): a row in the session list next to
// Approvals and Decisions, and a full screen with what fired, what is using the Mac, the booted
// simulators, the builds and their slots, and an hour of charts (hosts with `Feature.loadHistory`).
// Read-only; older Macs leave the detail fields nil and the screen shows what there is.

enum MacLoadStyle {
    static func color(_ level: String) -> Color {
        switch level {
        case "ok": .green
        case "overloaded": .red
        default: .orange
        }
    }

    static func label(_ level: String) -> String {
        switch level {
        case "ok": String(localized: "Normal")
        case "overloaded": String(localized: "Overloaded")
        default: String(localized: "Busy")
        }
    }

    static func loadText(_ load: RemoteLoad) -> String { String(format: "%.1f×", load.loadPerCore) }

    /// "Normal · load 0.4× · RAM 48% · 4 sims".
    static func summary(_ load: RemoteLoad) -> String {
        [label(load.level), String(localized: "load \(loadText(load))"), String(localized: "RAM \(load.memoryPercent)%"),
         String(localized: "\(load.simulators) sims")].joined(separator: " · ")
    }

    /// A trigger as the Mac's Resources settings word it (`LoadTrigger` raw values).
    static func reason(_ trigger: String) -> String {
        switch trigger {
        case "pressure": String(localized: "memory is tight")
        case "swap_growth": String(localized: "the swap file grows fast")
        case "swap_size": String(localized: "the swap file is very large")
        case "compilers": String(localized: "too many builds")
        case "load": String(localized: "extreme system load")
        case "processes": String(localized: "too many programs")
        default: trigger
        }
    }
}

/// The session list's row: the level in its color and the numbers in one line.
struct MacLoadRow: View {
    let load: RemoteLoad

    var body: some View {
        let color = MacLoadStyle.color(load.level)
        NavigationLink(value: MacScreen.load) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Mac Load").listFont(.body)
                        Spacer(minLength: 4)
                        Text(MacLoadStyle.label(load.level)).listFont(.caption, weight: .semibold).foregroundStyle(color)
                    }
                    Text(MacLoadStyle.summary(load)).listFont(.caption, monospacedDigit: true).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: load.level == "ok" ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
            }
        }
        .tag(MacScreen.load)
    }
}

/// The full screen.
struct LoadScreen: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            if let load = store.macLoad {
                VStack(spacing: 16) {
                    StatusCard(load: load)
                    if let history = load.history, history.count >= 2 {
                        ChartsCard(history: history, wide: sizeClass == .regular)
                    }
                    if sizeClass == .regular {
                        HStack(alignment: .top, spacing: 16) {
                            UseCard(load: load)
                            VStack(spacing: 16) { BuildsCard(load: load); SimulatorsCard(load: load) }
                        }
                    } else {
                        UseCard(load: load)
                        BuildsCard(load: load)
                        SimulatorsCard(load: load)
                    }
                }
                .padding()
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: load)
            } else {
                ContentUnavailableView("No Load Figures", systemImage: "gauge.with.dots.needle.33percent",
                                       description: Text("Update ClaudeDeck on the Mac to see its load here."))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Mac Load")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LoadCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatusCard: View {
    let load: RemoteLoad

    var body: some View {
        let color = MacLoadStyle.color(load.level)
        LoadCard(title: "Status", systemImage: "gauge.with.dots.needle.67percent") {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(MacLoadStyle.label(load.level)).font(.title3.weight(.semibold)).foregroundStyle(color)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Figure(title: "Load per core", value: MacLoadStyle.loadText(load), caption: String(localized: "\(load.cores) cores"))
                    Figure(title: "Memory", value: "\(load.memoryPercent)%", caption: pressureText)
                }
                GridRow {
                    Figure(title: "Simulators", value: "\(load.simulators)", caption: nil)
                    Figure(title: "Builds", value: "\(load.builds)",
                           caption: load.maxBuilds.map { String(localized: "limit \($0) · slots \(load.slotsUsed)/\(load.slots)") }
                               ?? String(localized: "slots \(load.slotsUsed)/\(load.slots)"))
                }
                GridRow {
                    Figure(title: "Claude sessions", value: "\(load.sessions)", caption: nil)
                    Color.clear.frame(height: 1)
                }
            }
            if let fired = load.fired, !fired.isEmpty {
                Label(String(localized: "Overloaded: \(fired.map(MacLoadStyle.reason).joined(separator: ", "))"), systemImage: "flame.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.red)
            }
            if load.throttled {
                Label(load.level == "overloaded"
                      ? "Agents are held back: no new sessions or simulators and fewer builds until the Mac is no longer overloaded."
                      : "New agent sessions wait while the Mac is busy.",
                      systemImage: "tortoise.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var pressureText: String {
        switch load.memoryPressure {
        case "critical": String(localized: "pressure critical")
        case "warning": String(localized: "pressure warning")
        default: String(localized: "pressure normal")
        }
    }
}

private struct Figure: View {
    let title: LocalizedStringKey
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last hour, a point a minute: load per core, memory, simulators and builds.
private struct ChartsCard: View {
    let history: [RemoteLoad.Sample]
    let wide: Bool

    var body: some View {
        LoadCard(title: "Last hour", systemImage: "chart.xyaxis.line") {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: wide ? 2 : 1)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                chart("Load per core", color: .blue, value: \.loadPerCore, line: 1)
                chart("Memory", color: .purple, value: { Double($0.memoryPercent) }, domain: 0...100)
                chart("Simulators", color: .teal, value: { Double($0.simulators) })
                chart("Builds", color: .orange, value: { Double($0.builds) })
            }
        }
    }

    private func chart(_ title: LocalizedStringKey, color: Color, value: @escaping (RemoteLoad.Sample) -> Double,
                       domain: ClosedRange<Double>? = nil, line: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Chart {
                ForEach(history) { sample in
                    AreaMark(x: .value("Time", sample.at), y: .value(Text(title), value(sample)))
                        .foregroundStyle(color.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.at), y: .value(Text(title), value(sample)))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
                if let line {
                    RuleMark(y: .value("Every core busy", line)).foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: domain ?? 0...max(1, (history.map(value).max() ?? 1) * 1.15))
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 15)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 110)
        }
    }
}

/// What is using the Mac: the heaviest sessions and projects.
private struct UseCard: View {
    let load: RemoteLoad

    var body: some View {
        LoadCard(title: "What is using the Mac", systemImage: "cpu") {
            let top = load.top ?? []
            let projects = load.topProjects ?? []
            if top.isEmpty, projects.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
            if !top.isEmpty {
                Text("Sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(top) { entry in
                    UseLine(name: entry.name, detail: entry.agent ? String(localized: "\(entry.project) · agent") : entry.project,
                            cpu: entry.cpuPercent, memoryMB: entry.memoryMB)
                }
            }
            if !projects.isEmpty {
                Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(projects) { project in
                    UseLine(name: project.name, detail: nil, cpu: project.cpuPercent, memoryMB: project.memoryMB)
                }
            }
        }
    }
}

private struct UseLine: View {
    let name: String
    let detail: String?
    let cpu: Int
    let memoryMB: Int

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout).lineLimit(1)
                if let detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Text(verbatim: "\(cpu)% · \(memoryMB) MB").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Build slots and the compiler processes running now.
private struct BuildsCard: View {
    let load: RemoteLoad

    var body: some View {
        LoadCard(title: "Builds", systemImage: "hammer") {
            Text("Slots in use: \(load.slotsUsed) of \(load.slots)").font(.callout)
            if let holders = load.slotHolders, !holders.isEmpty {
                ForEach(holders) { slot in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slot.name.isEmpty ? String(localized: "A closed session") : slot.name).font(.callout).lineLimit(1)
                            if let label = slot.label { Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 6)
                        Text(slot.since, style: .relative).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let builds = load.runningBuilds, !builds.isEmpty {
                Text(load.compilerProcesses.map { String(localized: "Compiler processes: \($0)") } ?? String(localized: "Compiler processes"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(builds) { build in
                    HStack(spacing: 6) {
                        Text(build.name).font(.callout.monospaced()).lineLimit(1)
                        Spacer(minLength: 6)
                        Text((build.session ?? String(localized: "outside ClaudeDeck")) + " · \(build.cpuPercent)%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if load.builds == 0 {
                Text("No builds running").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SimulatorsCard: View {
    let load: RemoteLoad

    var body: some View {
        LoadCard(title: "Booted simulators", systemImage: "iphone") {
            if let sims = load.bootedSimulators, !sims.isEmpty {
                ForEach(sims) { sim in
                    HStack(spacing: 6) {
                        Text(sim.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        Text((sim.holder ?? String(localized: "user")) + (sim.memoryMB.map { " · \($0) MB" } ?? ""))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text(load.simulators == 0 ? String(localized: "None booted") : String(localized: "\(load.simulators) sims"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
