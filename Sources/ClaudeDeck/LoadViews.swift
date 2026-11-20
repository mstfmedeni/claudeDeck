import Charts
import ClaudeDeckCore
import SwiftUI

// The Mac's load (LoadController) on screen: the sidebar row (shown while busy or overloaded, or
// always by the setting), the Dashboard card with a small chart, and Settings › Resources. The
// sidebar row and the card open the "Mac Yükü" tab (LoadDetailView.swift).

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

    static func triggerTitle(_ trigger: LoadTrigger) -> String {
        switch trigger {
        case .pressure: String(localized: "Memory pressure")
        case .swapGrowth: String(localized: "Swap growing fast")
        case .swapSize: String(localized: "Swap size")
        case .compilers: String(localized: "Compiler processes")
        case .load: String(localized: "Extreme load average")
        case .processes: String(localized: "Process count")
        }
    }

    /// The live value next to a trigger: "now: normal", "now: +0.3 GB", "now: 1.4× (12 s above)".
    static func triggerNow(_ state: LoadTriggerState) -> String {
        switch state.trigger {
        case .pressure:
            return String(localized: "now: \(pressureName(state.current))")
        case .swapGrowth:
            return String(localized: "now: +\(String(format: "%.1f", state.current)) GB")
        case .swapSize:
            return String(localized: "now: \(String(format: "%.1f", state.current)) GB")
        case .compilers, .processes:
            return String(localized: "now: \(Int(state.current))")
        case .load:
            let value = String(format: "%.2f×", state.current)
            guard let above = state.aboveFor else { return String(localized: "now: \(value)") }
            return String(localized: "now: \(value), above for \(Int(above / 60)) min")
        }
    }

    static func pressureName(_ value: Double) -> String {
        value >= 2 ? LoadDetails.pressure(.critical) : value >= 1 ? LoadDetails.pressure(.warning) : LoadDetails.pressure(.normal)
    }

    /// "Compiler processes, Memory pressure" for the triggers firing now.
    static func firedText(_ fired: [LoadTrigger]) -> String {
        fired.map(triggerTitle).joined(separator: ", ")
    }

    static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// Sidebar footer: a one-line load row, colored by level; clicking opens the "Mac Yükü" tab.
struct LoadTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let load = LoadController.shared
        if let sample = load.latest, load.level != .ok || model.deck.settings.load.alwaysShowInSidebar {
            VStack(spacing: 0) {
                Divider()
                Button { model.showMacLoad() } label: {
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
                .help(Text("The Mac's load: click for what is using it"))
            }
            .background(LoadStyle.color(load.level).opacity(load.level == .ok ? 0 : 0.10))
            .background(.bar)
        }
    }
}

/// Dashboard: the load card; clicking it opens the "Mac Yükü" tab.
struct LoadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let load = LoadController.shared
        DashCard("Mac Load", systemImage: "gauge.with.dots.needle.67percent") {
            Text(LoadStyle.title(load.level)).font(.caption.weight(.semibold)).foregroundStyle(LoadStyle.color(load.level))
        } content: {
            LoadDetails(showTitle: false)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showMacLoad() }
        .help(Text("Click for what is using the Mac"))
    }
}

/// The numbers, the build slots and the last hour.
struct LoadDetails: View {
    @Environment(AppModel.self) private var model
    var showTitle = true
    var showButtons = true

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
                let fired = load.monitor.fired
                if !fired.isEmpty {
                    Label(String(localized: "Overloaded by: \(LoadStyle.firedText(fired))"), systemImage: "flame.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if load.isThrottling {
                    Label("Agents are held back: no new sessions or simulators and fewer build slots until the Mac is no longer overloaded.",
                          systemImage: "tortoise.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if load.level == .busy {
                    Text(load.holdsStarts ? "Busy: new agent sessions wait; everything else goes on."
                         : "Busy is informational: nothing is held back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !load.slots.slots.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(load.slots.slots, id: \.id) { slot in
                            Text(verbatim: "\(model.deck.session(slot.session)?.name ?? slot.id) · \(slot.label ?? slot.id)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                LoadChart(samples: load.monitor.samples, cores: sample.cores)
                    .frame(height: 70)
                if showButtons {
                    HStack {
                        Spacer()
                        Button("Show Agents") { model.showAgentsOverview() }.controlSize(.small)
                        Button("Details") { model.showMacLoad() }.controlSize(.small)
                    }
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

/// The load per core over the kept samples.
struct LoadChart: View {
    let samples: [LoadSample]
    let cores: Int

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(x: .value("Time", sample.at), y: .value("Load", sample.loadPerCore))
                    .foregroundStyle(.blue.opacity(0.25))
                LineMark(x: .value("Time", sample.at), y: .value("Load", sample.loadPerCore))
                    .foregroundStyle(.blue)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
    }
}

/// Settings › Resources: every overload trigger with its switch, value and live reading, what
/// busy does, and the limits.
struct ResourcesSettingsSection: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ path: WritableKeyPath<LoadSettings, T>) -> Binding<T> {
        Binding(get: { model.deck.settings.load[keyPath: path] },
                set: { value in
                    model.mutate(userInitiated: false) { $0.settings.load[keyPath: path] = value }
                    model.drainCLIQueueSoon()
                })
    }

    /// A count that follows the cores until it's set (nil: the default).
    private func count(_ path: WritableKeyPath<LoadSettings, Int?>, current: Int, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { current },
                set: { value in model.mutate(userInitiated: false) { $0.settings.load[keyPath: path] = min(max(value, range.lowerBound), range.upperBound) } })
    }

    private func enabled(_ trigger: LoadTrigger) -> Binding<Bool> {
        Binding(get: { model.deck.settings.load.isEnabled(trigger) },
                set: { on in
                    model.mutate(userInitiated: false) { $0.settings.load.setEnabled(trigger, on) }
                    model.drainCLIQueueSoon()
                })
    }

    var body: some View {
        let load = LoadController.shared
        let t = load.thresholds
        let settings = model.deck.settings.load
        let states = Dictionary(uniqueKeysWithValues: load.monitor.triggers.map { ($0.trigger, $0) })
        Section("Now") {
            LoadDetails()
        }
        Section {
            TriggerRow(trigger: .pressure, state: states[.pressure], isOn: enabled(.pressure)) {
                Picker("At", selection: binding(\.pressureLevel)) {
                    Text("high (warning)").tag(MemoryPressure.warning)
                    Text("critical").tag(MemoryPressure.critical)
                }
                .labelsHidden()
                .fixedSize()
            }
            TriggerRow(trigger: .swapGrowth, state: states[.swapGrowth], isOn: enabled(.swapGrowth)) {
                Stepper(value: binding(\.swapGrowthGB), in: LoadSettings.swapGBRange, step: 0.5) {
                    Text("+\(String(format: "%.1f", settings.swapGrowthGB)) GB")
                }
                Stepper(value: binding(\.swapGrowthMinutes), in: LoadSettings.swapMinutesRange) {
                    Text("in \(settings.swapGrowthMinutes) min")
                }
            }
            TriggerRow(trigger: .swapSize, state: states[.swapSize], isOn: enabled(.swapSize)) {
                Stepper(value: binding(\.swapSizeGB), in: LoadSettings.swapGBRange, step: 4) {
                    Text("above \(String(format: "%.0f", settings.swapSizeGB)) GB")
                }
            }
            TriggerRow(trigger: .compilers, state: states[.compilers], isOn: enabled(.compilers)) {
                Stepper(value: count(\.maxCompilers, current: t.overloadCompilers, range: LoadSettings.compilerRange), in: LoadSettings.compilerRange) {
                    Text("more than \(t.overloadCompilers)")
                }
            }
            TriggerRow(trigger: .load, state: states[.load], isOn: enabled(.load)) {
                Stepper(value: binding(\.overloadFactor), in: LoadSettings.overloadRange, step: 0.5) {
                    Text("above \(String(format: "%.1f", settings.overloadFactor))× the cores (\(Int(t.overloadLoad)))")
                }
                Stepper(value: binding(\.overloadMinutes), in: LoadSettings.overloadMinutesRange, step: 0.5) {
                    Text("for \(String(format: "%.1f", settings.overloadMinutes)) min")
                }
            }
            TriggerRow(trigger: .processes, state: states[.processes], isOn: enabled(.processes)) {
                Stepper(value: binding(\.maxProcesses), in: LoadSettings.processRange, step: 250) {
                    Text("more than \(settings.maxProcesses)")
                }
            }
        } header: {
            Text("When is the Mac overloaded?")
        } footer: {
            Text("Only real freeze risks count: any switched-on trigger makes the Mac overloaded. Swap growth counts only while memory pressure is high or critical. Back to normal once every trigger stays well clear for a minute. The live value is next to each; a red one is firing now.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Busy") {
            Stepper(value: binding(\.busyFactor), in: LoadSettings.busyRange, step: 0.25) {
                Text("Busy above \(String(format: "%.2f", settings.busyFactor))× the cores for a minute (\(Int(t.busyLoad)))")
            }
            Picker("While busy", selection: binding(\.busyAction)) {
                Text("Nothing").tag(LoadBusyAction.nothing)
                Text("Hold new starts").tag(LoadBusyAction.holdStarts)
            }
            Text("Busy (a high load average, high memory pressure, or half the compiler limit) is shown in the sidebar. With \"Hold new starts\", claudedeck new and the start queue wait while busy; simulators and builds go on.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Limits") {
            Toggle("Slow down agents while the Mac is overloaded", isOn: binding(\.throttle))
            Text("While overloaded: claudedeck new is refused (with --queue it waits in the queue), the queue holds, claudedeck sim acquire is refused, fewer build slots are handed out, and agent sessions get a message (once per episode, when idle) to postpone heavy work. It all resumes as soon as the Mac is no longer overloaded.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: count(\.buildSlots, current: t.buildSlots, range: LoadSettings.slotRange), in: LoadSettings.slotRange) {
                Text("Most builds at once: \(t.buildSlots)")
            }
            Stepper(value: binding(\.overloadedBuildSlots), in: LoadSettings.slotRange) {
                Text("Builds at once while overloaded: \(t.overloadedBuildSlots)")
            }
            Stepper(value: binding(\.maxSlotHoldMinutes), in: LoadSettings.holdRange, step: 5) {
                Text("A build slot goes back after \(settings.maxSlotHoldMinutes) minutes at most")
            }
            Text("Agents run builds with claudedeck heavy -- COMMAND (or claudedeck slot acquire build): they wait for one of these slots. A slot also goes back when its session ends.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: count(\.maxSimulators, current: t.maxSimulators, range: LoadSettings.simulatorRange), in: LoadSettings.simulatorRange) {
                Text("Most booted simulators: \(t.maxSimulators)")
            }
            Text("claudedeck sim acquire is refused once this many simulators are booted (yours count too). Reaching it doesn't make the Mac busy.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { model.deck.settings.maxStartedSessions },
                                   set: { value in
                                       model.mutate(userInitiated: false) { $0.settings.maxStartedSessions = min(max(value, 1), 40) }
                                       model.drainCLIQueueSoon()
                                   }),
                    in: 1...40) {
                Text("Most agent-started sessions running at once: \(model.deck.settings.maxStartedSessions) (now \(model.cliRunningStarted))")
            }
            Text("Also in Settings › Agents.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restore Default Limits") {
                model.mutate(userInitiated: false) { deck in
                    deck.settings.load = deck.settings.load.restoringDefaults()
                    deck.settings.maxStartedSessions = SessionCLI.maxRunningStarted
                }
                model.drainCLIQueueSoon()
            }
            Text("Every trigger, value and limit on this page goes back to its default (the defaults follow this Mac's \(t.cores) cores).")
                .font(.caption).foregroundStyle(.secondary)
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

/// One overload trigger in Settings: switch, value controls, the live value (red while firing).
private struct TriggerRow<Controls: View>: View {
    let trigger: LoadTrigger
    let state: LoadTriggerState?
    @Binding var isOn: Bool
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        let firing = state?.firing == true
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(LoadStyle.triggerTitle(trigger), isOn: $isOn)
                Spacer()
                if let state {
                    Text(LoadStyle.triggerNow(state))
                        .font(.caption.weight(firing ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(firing ? .red : .secondary)
                    if firing { Image(systemName: "flame.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            if isOn {
                HStack(spacing: 16) { controls() }
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(firing ? Color.red.opacity(0.10) : nil)
    }
}
