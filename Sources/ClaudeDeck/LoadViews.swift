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

    /// Why the brake is on, in plain words: "memory is critical", "too many builds".
    static func reason(_ state: LoadTriggerState) -> String {
        switch state.trigger {
        case .pressure: state.current >= 2 ? String(localized: "memory is critical") : String(localized: "memory is tight")
        case .swapGrowth: String(localized: "the swap file grows fast")
        case .swapSize: String(localized: "the swap file is very large")
        case .compilers: String(localized: "too many builds")
        case .load: String(localized: "extreme system load")
        case .processes: String(localized: "too many programs")
        }
    }

    static func pressureName(_ value: Double) -> String {
        value >= 2 ? LoadDetails.pressure(.critical) : value >= 1 ? LoadDetails.pressure(.warning) : LoadDetails.pressure(.normal)
    }

    /// "too many builds, memory is critical" for the triggers firing now.
    static func firedText(_ triggers: [LoadTriggerState]) -> String {
        triggers.filter(\.firing).map(reason).joined(separator: ", ")
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
                if !load.monitor.fired.isEmpty {
                    Label(String(localized: "Overloaded: \(LoadStyle.firedText(load.monitor.triggers))"), systemImage: "flame.fill")
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

/// Settings › Resources, written for the owner rather than for engineers: a status line in plain
/// words, then "when to brake" (the overload triggers, each with its switch, limit and live value,
/// orange when close and red when it is the reason), "what braking does", the limits and the
/// notifications. Load is shown as the plain number macOS reports, not as a factor of the cores.
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

    /// A load-average factor edited as the plain load number (factor × cores), in steps of half the cores.
    private func loadNumber(_ path: WritableKeyPath<LoadSettings, Double>, cores: Int) -> Binding<Double> {
        Binding(get: { model.deck.settings.load[keyPath: path] * Double(cores) },
                set: { value in
                    model.mutate(userInitiated: false) { $0.settings.load[keyPath: path] = value / Double(max(1, cores)) }
                    model.drainCLIQueueSoon()
                })
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
        let sample = load.latest
        let cores = Double(t.cores)
        let loadRange = (LoadSettings.overloadRange.lowerBound * cores)...(LoadSettings.overloadRange.upperBound * cores)
        let busyRange = (LoadSettings.busyRange.lowerBound * cores)...(LoadSettings.busyRange.upperBound * cores)
        Section {
            LoadStatusLine()
        }
        Section {
            TriggerRow(title: String(localized: "Memory is about to run out"), state: states[.pressure], isOn: enabled(.pressure),
                       now: states[.pressure].map { LoadStyle.pressureName($0.current) }) {
                Picker("Brake when memory pressure is", selection: binding(\.pressureLevel)) {
                    Text("critical").tag(MemoryPressure.critical)
                    Text("high").tag(MemoryPressure.warning)
                }
                .fixedSize()
            }
            TriggerRow(title: String(localized: "The swap file grows fast"), state: states[.swapGrowth], isOn: enabled(.swapGrowth),
                       now: states[.swapGrowth].map { String(localized: "+\(String(format: "%.1f", $0.current)) GB") }) {
                Stepper(value: binding(\.swapGrowthGB), in: LoadSettings.swapGBRange, step: 0.5) {
                    Text("more than \(String(format: "%.1f", settings.swapGrowthGB)) GB")
                }
                Stepper(value: binding(\.swapGrowthMinutes), in: LoadSettings.swapMinutesRange) {
                    Text("within \(settings.swapGrowthMinutes) minutes")
                }
            } caption: {
                Text("Only while memory is tight: the Mac is writing memory to disk faster and faster.")
            }
            TriggerRow(title: String(localized: "The swap file is very large"), state: states[.swapSize], isOn: enabled(.swapSize),
                       now: sample.map { String(localized: "\(String(format: "%.1f", Double($0.swapUsedBytes) / 1_073_741_824)) GB") }) {
                Stepper(value: binding(\.swapSizeGB), in: LoadSettings.swapGBRange, step: 4) {
                    Text("above \(String(format: "%.0f", settings.swapSizeGB)) GB")
                }
            } caption: {
                Text("Off by default: a large swap file on its own doesn't freeze the Mac.")
            }
            TriggerRow(title: String(localized: "Too many builds at once"), state: states[.compilers], isOn: enabled(.compilers),
                       now: sample.map { "\($0.compilers)" }) {
                Stepper(value: count(\.maxCompilers, current: t.overloadCompilers, range: LoadSettings.compilerRange), in: LoadSettings.compilerRange) {
                    Text("more than \(t.overloadCompilers) build processes")
                }
            } caption: {
                Text("Every app build runs several of these (compiler, linker).")
            }
            TriggerRow(title: String(localized: "System load stays extreme"), state: states[.load], isOn: enabled(.load),
                       now: sample.map { String(format: "%.0f", $0.load1) }) {
                Stepper(value: loadNumber(\.overloadFactor, cores: t.cores), in: loadRange, step: cores / 2) {
                    Text("above \(Int(t.overloadLoad.rounded()))")
                }
                Stepper(value: binding(\.overloadMinutes), in: LoadSettings.overloadMinutesRange, step: 0.5) {
                    Text("for \(String(format: "%g", settings.overloadMinutes)) minutes")
                }
            } caption: {
                Text("The number macOS reports as the load: how many tasks want to run at once. This Mac has \(t.cores) cores, so \(Int(t.overloadLoad.rounded())) is \(String(format: "%g", settings.overloadFactor)) per core. A high load alone rarely freezes it.")
            }
            TriggerRow(title: String(localized: "Too many programs running"), state: states[.processes], isOn: enabled(.processes),
                       now: sample.map { "\($0.processes)" }) {
                Stepper(value: binding(\.maxProcesses), in: LoadSettings.processRange, step: 250) {
                    Text("more than \(settings.maxProcesses) processes")
                }
            }
        } header: {
            Text("When should ClaudeDeck brake?")
        } footer: {
            Text("Only when the Mac risks freezing. Any switched-on row is enough; the brake comes off by itself once every row has stayed clear for a minute.")
        }
        Section {
            Toggle("Brake agents", isOn: binding(\.throttle))
            Text("While braking, new agent sessions wait in line, agents can't open simulators, and fewer apps are built at once. Each agent session gets one message to put heavy work off. Your own sessions are never held.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: binding(\.overloadedBuildSlots), in: LoadSettings.slotRange) {
                Text("Builds at once while braking: \(t.overloadedBuildSlots)")
            }
            Stepper(value: loadNumber(\.busyFactor, cores: t.cores), in: busyRange, step: cores / 4) {
                Text("Busy when the system load stays above \(Int(t.busyLoad.rounded())) for a minute (now: \(sample.map { String(format: "%.0f", $0.load1) } ?? "–"))")
            }
            Picker("While busy", selection: binding(\.busyAction)) {
                Text("Do nothing (only show it)").tag(LoadBusyAction.nothing)
                Text("Hold new agent sessions").tag(LoadBusyAction.holdStarts)
            }
            Text("Busy means the Mac is working hard but isn't at risk. By default it is only shown in the sidebar.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("What happens when braking?")
        }
        Section("Limits") {
            Stepper(value: count(\.buildSlots, current: t.buildSlots, range: LoadSettings.slotRange), in: LoadSettings.slotRange) {
                Text("Builds at once: \(t.buildSlots)")
            }
            Text("At most \(t.buildSlots) apps are built at the same time; the rest wait in line.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: binding(\.maxSlotHoldMinutes), in: LoadSettings.holdRange, step: 5) {
                Text("A build keeps its place for at most \(settings.maxSlotHoldMinutes) minutes")
            }
            Stepper(value: count(\.maxSimulators, current: t.maxSimulators, range: LoadSettings.simulatorRange), in: LoadSettings.simulatorRange) {
                Text("Simulators: \(t.maxSimulators)")
            }
            Text("Agents can open at most \(t.maxSimulators) iPhone simulators; the ones you opened count too. Reaching it doesn't brake anything else.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: binding(\.simulatorPruneDays), in: SimulatorPrune.dayRange) {
                Text(settings.simulatorPruneDays == 0
                     ? "Delete unused pool simulators: never"
                     : "Delete unused pool simulators after \(settings.simulatorPruneDays) days")
            }
            Text("At launch and once a day, ClaudeDeck deletes the simulators it created for agents that are shut down and haven't been used this long, and keeps at most \(t.maxSimulators + SimulatorPrune.spare) of each device type. Booted and reserved ones, and your own simulators, are never deleted.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { model.deck.settings.maxStartedSessions },
                                   set: { value in
                                       model.mutate(userInitiated: false) { $0.settings.maxStartedSessions = min(max(value, 1), 40) }
                                       model.drainCLIQueueSoon()
                                   }),
                    in: 1...40) {
                Text("Agent sessions at once: \(model.deck.settings.maxStartedSessions) (now \(model.cliRunningStarted))")
            }
            Text("Sessions that agents start; more wait in line. Your own sessions don't count.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Notifications") {
            Toggle("Notify me when the brake comes on", isOn: binding(\.notify))
            Text("Once each time, on this Mac and on your phone, with what's behind it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Always show the load in the sidebar", isOn: binding(\.alwaysShowInSidebar))
            Text("Otherwise it shows only while the Mac is busy or braking.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Restore Default Limits") {
                        model.mutate(userInitiated: false) { deck in
                            deck.settings.load = deck.settings.load.restoringDefaults()
                            deck.settings.maxStartedSessions = SessionCLI.maxRunningStarted
                        }
                        model.drainCLIQueueSoon()
                    }
                    Text("Flexible settings that only brake to keep the Mac from freezing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("What Is Using the Mac?") { model.showMacLoad() }
            }
        }
    }
}

/// "Durum: Normal — fren yok" / "Durum: Aşırı yüklü — yeni ajan oturumları bekletiliyor (sebep: bellek kritik)".
struct LoadStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let load = LoadController.shared
        HStack(spacing: 8) {
            Circle().fill(LoadStyle.color(load.level)).frame(width: 10, height: 10)
            Text(Self.text(load)).font(.callout.weight(.medium))
        }
    }

    static func text(_ load: LoadController) -> String {
        guard load.latest != nil else { return String(localized: "Status: measuring…") }
        switch load.level {
        case .ok:
            return String(localized: "Status: Normal, no brake")
        case .busy:
            return load.holdsStarts ? String(localized: "Status: Busy, new agent sessions wait")
                : String(localized: "Status: Busy, no brake (only shown)")
        case .overloaded:
            let why = load.monitor.triggers.filter(\.firing).map(LoadStyle.reason).joined(separator: ", ")
            if !load.settings.throttle { return String(localized: "Status: Overloaded, brake switched off (reason: \(why))") }
            return String(localized: "Status: Overloaded, new agent sessions wait (reason: \(why))")
        }
    }
}

/// One overload trigger in Settings: its switch, the live value ("now: 28"), orange when close
/// to the limit and red when it is why the brake is on; its limit controls below while on.
private struct TriggerRow<Controls: View, Caption: View>: View {
    let title: String
    let state: LoadTriggerState?
    @Binding var isOn: Bool
    let now: String?
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var caption: () -> Caption

    init(title: String, state: LoadTriggerState?, isOn: Binding<Bool>, now: String?, @ViewBuilder controls: @escaping () -> Controls,
         @ViewBuilder caption: @escaping () -> Caption = { EmptyView() }) {
        self.title = title
        self.state = state
        self._isOn = isOn
        self.now = now
        self.controls = controls
        self.caption = caption
    }

    private var tint: Color? {
        guard let state, state.enabled else { return nil }
        if state.firing { return .red }
        if state.threshold > 0, state.current >= state.threshold * 0.75, state.unit != "pressure" { return .orange }
        if state.unit == "pressure", state.current >= 1, state.current < state.threshold { return .orange }
        return nil
    }

    var body: some View {
        let tint = tint
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(title, isOn: $isOn)
                Spacer()
                if let now {
                    Text("now: \(now)")
                        .font(.callout.weight(tint == nil ? .regular : .semibold)).monospacedDigit()
                        .foregroundStyle(tint ?? .secondary)
                }
                if state?.firing == true { Image(systemName: "flame.fill").foregroundStyle(.red) }
            }
            if isOn {
                HStack(spacing: 16) { controls() }
                    .padding(.leading, 20)
            }
            caption()
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
        .padding(.vertical, 2)
        .listRowBackground(tint.map { $0.opacity(0.10) })
    }
}
