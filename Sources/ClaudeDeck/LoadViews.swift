import Charts
import ClaudeDeckCore
import SwiftUI

// The Mac's load (LoadController) on screen: the sidebar row (shown while busy or overloaded, or
// always by the setting), the Dashboard card with a small chart, and Settings › Resources.

enum LoadStyle {
    static func color(_ level: LoadLevel) -> Color {
        switch level {
        case .ok: .green
        case .busy: .orange
        case .overloaded: .red
        }
    }

    static func title(_ level: LoadLevel) -> String {
        switch level {
        case .ok: String(localized: "Mac load: OK")
        case .busy: String(localized: "Mac load: Busy")
        case .overloaded: String(localized: "Mac load: Overloaded")
        }
    }

    /// "1.4× · RAM 81% · 11 sims · 30 builds · 37 sessions".
    static func numbers(_ sample: LoadSample) -> String {
        var parts = [String(format: "%.1f×", sample.loadPerCore), String(localized: "RAM \(Int(sample.memoryUsedPercent.rounded()))%")]
        if sample.simulators > 0 { parts.append(String(localized: "\(sample.simulators) sims")) }
        if sample.compilers > 0 { parts.append(String(localized: "\(sample.compilers) builds")) }
        parts.append(String(localized: "\(sample.sessions) sessions"))
        return parts.joined(separator: " · ")
    }
}

/// Sidebar footer: a one-line load row, colored by level; clicking shows the details.
struct LoadTray: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        let load = LoadController.shared
        if let sample = load.latest, load.level != .ok || model.deck.settings.load.alwaysShowInSidebar {
            VStack(spacing: 0) {
                Divider()
                Button { showDetails.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: load.level == .overloaded ? "flame.fill" : "gauge.with.dots.needle.67percent")
                            .foregroundStyle(LoadStyle.color(load.level))
                        Text(LoadStyle.title(load.level)).sidebarFont(.callout, weight: .semibold)
                        Spacer(minLength: 4)
                        Text(LoadStyle.numbers(sample)).sidebarFont(.caption).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .sidebarRowPadding(7)
                .help(Text("The Mac's load (Settings › Resources)"))
                .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                    LoadDetails().padding(14).frame(width: 360)
                }
            }
            .background(LoadStyle.color(load.level).opacity(load.level == .ok ? 0 : 0.10))
            .background(.bar)
        }
    }
}

/// Dashboard: the load card.
struct LoadCard: View {
    var body: some View {
        let load = LoadController.shared
        DashCard("Mac Load", systemImage: "gauge.with.dots.needle.67percent") {
            Text(LoadStyle.title(load.level)).font(.caption.weight(.semibold)).foregroundStyle(LoadStyle.color(load.level))
        } content: {
            LoadDetails(showTitle: false)
        }
    }
}

/// The numbers, the build slots and the last 30 minutes.
struct LoadDetails: View {
    @Environment(AppModel.self) private var model
    var showTitle = true

    var body: some View {
        let load = LoadController.shared
        VStack(alignment: .leading, spacing: 10) {
            if showTitle {
                HStack {
                    Circle().fill(LoadStyle.color(load.level)).frame(width: 9, height: 9)
                    Text(LoadStyle.title(load.level)).font(.headline)
                }
            }
            if let sample = load.latest {
                let t = load.thresholds
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Load")
                        Text(String(format: "%.1f / %d (%.1f×)", sample.load1, sample.cores, sample.loadPerCore)).monospacedDigit()
                    }
                    GridRow {
                        Text("Memory")
                        Text("\(Int(sample.memoryUsedPercent.rounded()))% · pressure \(Self.pressure(sample.pressure)) · swap \(Int(sample.swapUsedBytes / 1_048_576)) MB")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Simulators")
                        Text("\(sample.simulators) booted (agents up to \(t.maxSimulators))").monospacedDigit()
                    }
                    GridRow {
                        Text("Builds")
                        Text("\(sample.compilers) compiler processes · slots \(load.slots.slots.count)/\(load.slotCapacity)").monospacedDigit()
                    }
                    GridRow {
                        Text("Sessions")
                        Text("\(sample.sessions) Claude sessions · \(sample.processes) processes").monospacedDigit()
                    }
                }
                .font(.callout)
                if load.isThrottling {
                    Label("Agents are held back: no new sessions, simulators or extra builds until the Mac is back to normal.",
                          systemImage: "tortoise.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !load.slots.slots.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(load.slots.slots, id: \.id) { slot in
                            Text(verbatim: "\(model.deck.session(slot.session)?.name ?? slot.id) · \(slot.label ?? slot.id)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                LoadChart(samples: load.monitor.samples, overload: t.overloadLoad)
                    .frame(height: 70)
                HStack {
                    Spacer()
                    Button("Show Agents") { model.showAgentsOverview() }.controlSize(.small)
                }
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
        }
    }

    static func pressure(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "normal")
        case .warning: String(localized: "high")
        case .critical: String(localized: "critical")
        }
    }
}

/// The load average over the kept samples, with the overload line.
struct LoadChart: View {
    let samples: [LoadSample]
    let overload: Double

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(x: .value("Time", sample.at), y: .value("Load", sample.load1))
                    .foregroundStyle(.blue.opacity(0.25))
                LineMark(x: .value("Time", sample.at), y: .value("Load", sample.load1))
                    .foregroundStyle(.blue)
            }
            RuleMark(y: .value("Overloaded", overload))
                .foregroundStyle(.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
    }
}

/// Settings › Resources.
struct ResourcesSettingsSection: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ path: WritableKeyPath<LoadSettings, T>) -> Binding<T> {
        Binding(get: { model.deck.settings.load[keyPath: path] },
                set: { value in model.mutate(userInitiated: false) { $0.settings.load[keyPath: path] = value } })
    }

    /// A count that follows the cores until it's set (nil: the default).
    private func count(_ path: WritableKeyPath<LoadSettings, Int?>, current: Int, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { current },
                set: { value in model.mutate(userInitiated: false) { $0.settings.load[keyPath: path] = min(max(value, range.lowerBound), range.upperBound) } })
    }

    var body: some View {
        let load = LoadController.shared
        let t = load.thresholds
        let settings = model.deck.settings.load
        Section("Now") {
            LoadDetails()
        }
        Section("Agents") {
            Toggle("Slow down agents while the Mac is overloaded", isOn: Binding(
                get: { settings.throttle },
                set: { on in
                    model.mutate(userInitiated: false) { $0.settings.load.throttle = on }
                    model.drainCLIQueueSoon()
                }
            ))
            Text("While overloaded (until the Mac is back to normal): claudedeck new is refused (with --queue it waits in the queue), the queue holds, claudedeck sim acquire is refused, only one build slot is handed out, and agents get a note to postpone heavy work.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: count(\.maxSimulators, current: t.maxSimulators, range: LoadSettings.simulatorRange), in: LoadSettings.simulatorRange) {
                Text("Most booted simulators: \(t.maxSimulators)")
            }
            Text("claudedeck sim acquire is refused once this many simulators are booted (yours count too).")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: count(\.buildSlots, current: t.buildSlots, range: LoadSettings.slotRange), in: LoadSettings.slotRange) {
                Text("Most builds at once: \(t.buildSlots)")
            }
            Stepper(value: binding(\.maxSlotHoldMinutes), in: LoadSettings.holdRange, step: 5) {
                Text("A build slot goes back after \(settings.maxSlotHoldMinutes) minutes at most")
            }
            Text("Agents run builds with claudedeck heavy -- COMMAND (or claudedeck slot acquire build): they wait for one of these slots. A slot also goes back when its session ends.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("When is the Mac overloaded?") {
            Stepper(value: binding(\.overloadFactor), in: LoadSettings.overloadRange, step: 0.5) {
                Text("Load above \(String(format: "%.1f", settings.overloadFactor))× the cores for a minute (\(Int(t.overloadLoad)))")
            }
            Stepper(value: binding(\.busyFactor), in: LoadSettings.busyRange, step: 0.25) {
                Text("Busy above \(String(format: "%.2f", settings.busyFactor))× the cores (\(Int(t.busyLoad)))")
            }
            Stepper(value: count(\.maxCompilers, current: t.overloadCompilers, range: LoadSettings.compilerRange), in: LoadSettings.compilerRange) {
                Text("More than \(t.overloadCompilers) compiler processes")
            }
            Text("Also when macOS reports critical memory pressure. Back to normal once the numbers stay well below these for a minute. The defaults follow this Mac's \(t.cores) cores.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore Defaults") {
                model.mutate(userInitiated: false) { deck in
                    let keep = deck.settings.load
                    var fresh = LoadSettings()
                    fresh.throttle = keep.throttle
                    fresh.notify = keep.notify
                    fresh.alwaysShowInSidebar = keep.alwaysShowInSidebar
                    deck.settings.load = fresh
                }
            }
        }
        Section("Showing") {
            Toggle("Notify when the Mac becomes overloaded", isOn: binding(\.notify))
            Text("Once per episode, on this Mac and on paired phones, with what's behind it (simulators, builds, sessions).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Always show the load in the sidebar", isOn: binding(\.alwaysShowInSidebar))
            Text("Otherwise it shows only while the Mac is busy or overloaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
