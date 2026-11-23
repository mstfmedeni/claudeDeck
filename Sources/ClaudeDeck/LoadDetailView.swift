import Charts
import ClaudeDeckCore
import SwiftUI

/// The "Mac Yükü" tab: what is using the Mac. Per project and session (each Claude session with
/// its child processes), booted simulators, running builds and slot holders, idle agent sessions,
/// the last hour as charts, and the heaviest processes outside ClaudeDeck. Processes are measured
/// only while this tab is on screen (LoadController.detailVisible).
struct LoadDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let load = LoadController.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(load)
                charts(load)
                sessions(load)
                HStack(alignment: .top, spacing: 18) {
                    simulators(load)
                    builds(load)
                }
                idleAgents()
                others(load)
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            load.detailVisible(true)
            if !SimulatorsController.shared.loaded { await SimulatorsController.shared.reloadList() }
            while !Task.isCancelled {
                await SimulatorsController.shared.sampleForRemote(model: model, every: .seconds(10))
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onDisappear { load.detailVisible(false) }
    }

    // MARK: Header

    @ViewBuilder private func header(_ load: LoadController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(LoadStyle.color(load.level)).frame(width: 11, height: 11)
                Text(LoadStyle.title(load.level)).font(.title2.weight(.semibold))
                Spacer()
                Button("Settings…") {
                    UserDefaults.windowState.set(SettingsCategory.resources.rawValue, forKey: SettingsCategory.storageKey)
                    model.openSettings?()
                }
            }
            if let sample = load.latest {
                Text(LoadStyle.numbers(sample) + " · " + String(localized: "\(sample.processes) processes"))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if !load.monitor.fired.isEmpty {
                Label(String(localized: "Overloaded: \(LoadStyle.firedText(load.monitor.triggers))"), systemImage: "flame.fill")
                    .foregroundStyle(.red)
            } else if load.level == .busy {
                Text(load.holdsStarts ? "Busy: new work waits (new sessions, simulators, extra builds); running agents carry on."
                     : "Busy is informational: nothing is held back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Charts

    private struct Series: Identifiable {
        let title: String
        let unit: String
        let color: Color
        let value: (LoadSample) -> Double
        var id: String { title }
    }

    @ViewBuilder private func charts(_ load: LoadController) -> some View {
        let series = [
            Series(title: String(localized: "Load per core"), unit: "×", color: .blue) { $0.loadPerCore },
            Series(title: String(localized: "Memory used"), unit: "%", color: .purple) { $0.memoryUsedPercent },
            Series(title: String(localized: "Swap"), unit: "GB", color: .pink) { Double($0.swapUsedBytes) / 1_073_741_824 },
            Series(title: String(localized: "Simulators"), unit: "", color: .teal) { Double($0.simulators) },
            Series(title: String(localized: "Builds"), unit: "", color: .orange) { Double($0.builds) },
            Series(title: String(localized: "Compiler processes"), unit: "", color: .yellow) { Double($0.compilers) },
        ]
        let samples = load.monitor.samples
        LoadSection(title: String(localized: "Last hour"), systemImage: "chart.xyaxis.line") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(series) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.title).font(.caption.weight(.semibold))
                            Spacer()
                            if let last = samples.last {
                                Text(String(format: s.unit == "%" ? "%.0f" : "%.1f", s.value(last)) + s.unit)
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Chart {
                            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                                LineMark(x: .value("Time", sample.at), y: .value(s.title, s.value(sample)))
                                    .foregroundStyle(s.color)
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .frame(height: 64)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder private func sessions(_ load: LoadController) -> some View {
        LoadSection(title: String(localized: "Projects and sessions"), systemImage: "terminal") {
            if let usage = load.usage {
                let groups = projectGroups(usage)
                if groups.isEmpty {
                    Text("No running sessions.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.project) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.project).font(.headline)
                            Spacer()
                            UsageNumbers(cpu: group.cpu, bytes: group.bytes, processes: nil)
                        }
                        ForEach(group.sessions) { usage in
                            sessionRow(usage)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private struct ProjectGroup {
        var project: String
        var cpu: Double
        var bytes: UInt64
        var sessions: [SessionUsage]
    }

    private func projectGroups(_ usage: LoadUsageReport) -> [ProjectGroup] {
        var groups: [String: ProjectGroup] = [:]
        for session in usage.sessions {
            guard let deckSession = model.deck.session(session.session) else { continue }
            let name = model.deck.project(deckSession.projectID)?.name ?? ""
            groups[name, default: ProjectGroup(project: name, cpu: 0, bytes: 0, sessions: [])].cpu += session.cpuPercent
            groups[name, default: ProjectGroup(project: name, cpu: 0, bytes: 0, sessions: [])].bytes += session.residentBytes
            groups[name, default: ProjectGroup(project: name, cpu: 0, bytes: 0, sessions: [])].sessions.append(session)
        }
        return groups.values.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.bytes > $1.bytes }
    }

    @ViewBuilder private func sessionRow(_ usage: SessionUsage) -> some View {
        if let session = model.deck.session(usage.session) {
            let open = expanded.contains(usage.session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button {
                        if open { expanded.remove(usage.session) } else { expanded.insert(usage.session) }
                    } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    Image(systemName: session.kind == .claude ? "sparkle" : "terminal").foregroundStyle(.secondary)
                    Text(session.name).lineLimit(1)
                    if session.startedBy != nil {
                        Text("agent").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    UsageNumbers(cpu: usage.cpuPercent, bytes: usage.residentBytes, processes: usage.processes.count)
                    Button("Show") { model.revealInSidebar(session.id) }.controlSize(.small)
                    if session.startedBy != nil {
                        Button("Close…", role: .destructive) { closeAgent(session) }.controlSize(.small)
                    }
                }
                .padding(.leading, 8)
                if open {
                    ForEach(usage.processes.prefix(12)) { process in
                        HStack {
                            Text(verbatim: "\(process.name)  (\(process.pid))").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            UsageNumbers(cpu: process.cpuPercent, bytes: process.residentBytes, processes: nil).font(.caption)
                        }
                        .padding(.leading, 48)
                    }
                }
            }
        }
    }

    private func closeAgent(_ session: DeckSession) {
        guard session.startedBy != nil else { return }
        if Confirm.ask(String(localized: "End \"\(session.name)\" and remove it from the list?"),
                       detail: String(localized: "The running process is stopped. The Claude conversation history is kept and can be reopened from the project's \"Resume Previous Conversation…\" menu."),
                       action: String(localized: "End and Remove")) {
            model.removeSession(session.id)
        }
    }

    // MARK: Simulators

    @ViewBuilder private func simulators(_ load: LoadController) -> some View {
        let booted = load.bootedSimulators()
        LoadSection(title: String(localized: "Booted simulators"), systemImage: "iphone.gen3") {
            if booted.isEmpty {
                Text("None booted.").foregroundStyle(.secondary)
            }
            ForEach(booted) { sim in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sim.name).lineLimit(1)
                        Text(holderText(sim) + (sim.bootedAt.map { " · " + Self.duration(since: $0) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let slim = sim.slim {
                        Text(slim).font(.caption).foregroundStyle(.secondary)
                            .help(String(localized: "simslim: background services turned off of those it manages"))
                    }
                    if let bytes = sim.memoryBytes {
                        Text(LoadStyle.bytes(bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let holder = sim.holder {
                        Button("Shut Down…") { shutDown(sim, holder: holder) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func holderText(_ sim: LoadController.BootedSimulator) -> String {
        guard sim.holder != nil else { return String(localized: "user") }
        return String(localized: "ClaudeDeck: \(sim.holderName ?? String(localized: "a closed session"))")
    }

    private func shutDown(_ sim: LoadController.BootedSimulator, holder: UUID) {
        guard Confirm.ask(String(localized: "Shut down \"\(sim.name)\"?"),
                          detail: String(localized: "\(sim.holderName ?? String(localized: "A session")) holds it through ClaudeDeck. The hold is released and the simulator shuts down; the session gets an error if it is still using it."),
                          action: String(localized: "Shut Down")) else { return }
        model.releaseSimulators(of: holder, udid: sim.udid, reason: "shut down from the load tab")
        if let device = SimulatorsController.shared.devices.first(where: { $0.udid == sim.udid }), device.state != "Shutdown" {
            SimulatorsController.shared.shutdown(device)
        }
    }

    // MARK: Builds

    @ViewBuilder private func builds(_ load: LoadController) -> some View {
        LoadSection(title: String(localized: "Builds"), systemImage: "hammer") {
            let builds = load.usage?.builds ?? []
            if let sample = load.latest {
                let state = load.monitor.triggers.first { $0.trigger == .compilers }
                Text("\(sample.builds) builds running, \(sample.compilers) compiler processes · overloaded above \(load.thresholds.overloadBuilds) builds")
                    .font(.callout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(state?.firing == true ? .red : .primary)
            }
            if builds.isEmpty {
                Text("No compiler running.").foregroundStyle(.secondary)
            } else {
                Text("Compiler processes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(builds.prefix(15)) { build in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(build.name).lineLimit(1)
                        Text(buildOwner(build)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(build.started > 0 ? Self.duration(since: Date(timeIntervalSince1970: build.started)) : "")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if builds.count > 15 {
                Text("and \(builds.count - 15) more").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Build slots: \(load.slots.slots.count)/\(load.slotCapacity)").font(.caption.weight(.semibold))
            ForEach(load.slots.slots, id: \.id) { slot in
                Text(verbatim: "\(model.deck.session(slot.session)?.name ?? slot.id) · \(slot.label ?? slot.id) · "
                     + Self.duration(since: slot.acquiredAt))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if load.slots.waiters.count > 0 {
                Text("\(load.slots.waiters.count) waiting").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func buildOwner(_ build: BuildProcessUsage) -> String {
        guard let id = build.session, let session = model.deck.session(id) else { return String(localized: "outside ClaudeDeck") }
        let project = model.deck.project(session.projectID)?.name ?? ""
        return project.isEmpty ? session.name : "\(project) / \(session.name)"
    }

    // MARK: Idle agents

    @ViewBuilder private func idleAgents() -> some View {
        let idle = idleAgentSessions()
        LoadSection(title: String(localized: "Idle agent sessions"), systemImage: "moon.zzz") {
            if idle.isEmpty {
                Text("No agent session has been idle for \(LoadUsage.idleMinutes) minutes.").foregroundStyle(.secondary)
            } else {
                ForEach(idle) { session in
                    HStack {
                        Text(session.name).lineLimit(1)
                        Text(model.deck.project(session.projectID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let last = session.lastActivityAt {
                            Text(String(localized: "idle \(Self.duration(since: last))")).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button("Show") { model.revealInSidebar(session.id) }.controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Close Idle Ones…", role: .destructive) { closeIdle(idle) }
                }
                Text("Only sessions another session started with claudedeck new; never yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func idleAgentSessions() -> [DeckSession] {
        let candidates = model.deck.sessions.filter { $0.kind == .claude && model.terminals.isRunning($0.id) }.map {
            LoadUsage.IdleCandidate(session: $0.id, startedBy: $0.startedBy, idle: model.status(of: $0.id).display.isIdle,
                                    lastActivity: $0.lastActivityAt)
        }
        let ids = Set(LoadUsage.idleAgents(candidates, now: Date()))
        return model.deck.sessions.filter { ids.contains($0.id) }
    }

    private func closeIdle(_ sessions: [DeckSession]) {
        let agents = sessions.filter { $0.startedBy != nil }
        guard !agents.isEmpty,
              Confirm.ask(String(localized: "End and remove \(agents.count) idle agent sessions?"),
                          detail: agents.map(\.name).joined(separator: ", ") + "\n\n"
                              + String(localized: "Their Claude conversations are kept and can be reopened from each project's \"Resume Previous Conversation…\" menu."),
                          action: String(localized: "End and Remove")) else { return }
        for session in agents where model.deck.session(session.id)?.startedBy != nil {
            model.removeSession(session.id)
        }
        model.logAgent("ClaudeDeck", inbound: false, "load tab: closed \(agents.count) idle agent sessions")
    }

    // MARK: Other processes

    @ViewBuilder private func others(_ load: LoadController) -> some View {
        LoadSection(title: String(localized: "Heaviest other processes"), systemImage: "list.number") {
            if let usage = load.usage {
                Text("\(usage.processCount) processes · \(String(format: "%.0f", usage.totalCPU))% CPU in all (100% = one core)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(usage.others) { process in
                    HStack {
                        Text(verbatim: "\(process.name)  (\(process.pid))").lineLimit(1)
                        Spacer()
                        UsageNumbers(cpu: process.cpuPercent, bytes: process.residentBytes, processes: nil)
                    }
                }
                Text("Outside every session and outside ClaudeDeck. Another user's processes (root) show no CPU or memory.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    static func duration(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

private struct LoadSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

/// "34% · 1.2 GB · 14 proc".
private struct UsageNumbers: View {
    let cpu: Double
    let bytes: UInt64
    let processes: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.0f%%", cpu)).frame(minWidth: 44, alignment: .trailing)
                .foregroundStyle(cpu >= 100 ? .orange : .primary)
            Text(LoadStyle.bytes(bytes)).frame(minWidth: 64, alignment: .trailing).foregroundStyle(.secondary)
            if let processes {
                Text("\(processes) proc").frame(minWidth: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
    }
}
