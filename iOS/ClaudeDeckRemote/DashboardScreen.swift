import SwiftUI

// The Mac's Dashboard on the phone. A compact card sits at the top of the session list (the
// screen people open the app to, on iPhone and iPad alike): the four "now" numbers and the usage
// windows at a glance. Tapping it opens the full card in the detail column (iPad) or pushes it
// (iPhone), the way a session opens, so it needs no tab of its own and the list stays one tap
// away. Only from a Mac with `Feature.dashboard`; older Macs keep the plain usage row.

/// Rows of the session list that open a screen about the Mac instead of a session (their
/// selection values, like `ScreenTab.id`).
enum MacScreen {
    static let dashboard = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000002")!
    static let servers = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000003")!
    static let simulators = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000004")!
    static let decisions = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000005")!
    static let agenda = UUID(uuidString: "5C4EE000-5C4E-5C4E-5C4E-5C4EE0000006")!

    /// Not a session: the Mac never has it, and it mustn't be cleared as one it lost.
    static func isScreen(_ id: UUID) -> Bool {
        id == ScreenTab.id || id == dashboard || id == servers || id == simulators || id == decisions || id == agenda
    }

    @MainActor @ViewBuilder
    static func view(for id: UUID) -> some View {
        switch id {
        case dashboard: DashboardScreen()
        case servers: ServersScreen()
        case simulators: SimulatorsScreen()
        case decisions: DecisionsScreen()
        case agenda: AgendaScreen()
        default: EmptyView()
        }
    }
}

extension RemoteStore {
    /// What the Mac sends for these screens, only from a Mac that says it does.
    var dashboard: RemoteDashboard? { snapshot?.supports(RemoteSnapshot.Feature.dashboard) == true ? snapshot?.dashboard : nil }
    var serverPlan: RemoteServerPlan? { snapshot?.supports(RemoteSnapshot.Feature.serverPlan) == true ? snapshot?.serverPlan : nil }
    var simulators: [RemoteSimulator]? { snapshot?.supports(RemoteSnapshot.Feature.simulators) == true ? snapshot?.simulators : nil }
}

enum DashStyle {
    static let working = Color.green
    static let waiting = Color.red
    static let yourTurn = Color.yellow
    static let lines = Color.blue

    static func compact(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// "42 s", "3 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "permission": String(localized: "Needs permission")
        case "question": String(localized: "Asking a question")
        case "idle": String(localized: "Your turn")
        case "blocked": String(localized: "Needs input")
        case "finished": String(localized: "Finished")
        case "failed": String(localized: "Failed")
        default: String(localized: "Waiting")
        }
    }

    static func reasonColor(_ reason: String) -> Color {
        switch reason {
        case "idle", "finished": yourTurn
        case "failed": .orange
        default: waiting
        }
    }

    static func usageTint(_ percent: Double) -> Color { percent >= 90 ? .red : percent >= 70 ? .orange : .green }
}

// MARK: - The list's card

struct DashboardRow: View {
    let dashboard: RemoteDashboard

    var body: some View {
        NavigationLink(value: MacScreen.dashboard) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    MiniTile(value: "\(dashboard.working)", label: "Working", color: DashStyle.working)
                    MiniTile(value: "\(dashboard.waiting)", label: "Waiting", color: DashStyle.waiting, emphasized: dashboard.waiting > 0)
                    MiniTile(value: "\(dashboard.yourTurn)", label: "Your turn", color: DashStyle.yourTurn)
                    MiniTile(value: dashboard.linesAdded.map { "+" + DashStyle.compact($0) } ?? "–", label: "Lines", color: DashStyle.lines)
                }
                if dashboard.fiveHour != nil || dashboard.week != nil {
                    VStack(spacing: 5) {
                        if let window = dashboard.fiveHour { UsageLine(title: String(localized: "5 hours"), window: window) }
                        if let window = dashboard.week { UsageLine(title: String(localized: "Week"), window: window) }
                    }
                }
            }
            .padding(8)
            // Its own surface: the row's selection color (iPad) rings it instead of washing out the tiles.
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.vertical, -2)
            .padding(.horizontal, -6)
        }
        .tag(MacScreen.dashboard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Dashboard"))
    }
}

private struct MiniTile: View {
    let value: String
    let label: LocalizedStringKey
    let color: Color
    var emphasized = false

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(emphasized ? color : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(emphasized ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(emphasized ? color.opacity(0.5) : .clear))
    }
}

/// "5 hours  ▓▓▓░░  42%  limit 14:20" (red when it comes before the reset).
private struct UsageLine: View {
    let title: String
    let window: RemoteDashboard.Window

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100).tint(DashStyle.usageTint(window.usedPercent))
            Text("\(Int(window.usedPercent.rounded()))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            Group {
                if window.hitsLimitBeforeReset, let limit = window.limitAt {
                    Label { Text(limit, format: .dateTime.hour().minute()) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.red)
                } else if let reset = window.resetsAt {
                    Text(reset, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                }
            }
            .font(.caption2.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - The full card

struct DashboardScreen: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            if let dashboard = store.dashboard {
                let wide = sizeClass == .regular
                VStack(spacing: 16) {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 4 : 2)
                    LazyVGrid(columns: columns, spacing: 12) {
                        NowTile(value: "\(dashboard.working)", label: "Working", caption: "Claude sessions", color: DashStyle.working, systemImage: "bolt.fill")
                        NowTile(value: "\(dashboard.waiting)", label: "Waiting on you", caption: dashboard.waiting == 0 ? "All clear" : "Permission or question",
                                color: DashStyle.waiting, systemImage: "hand.raised.fill", emphasized: dashboard.waiting > 0)
                        NowTile(value: "\(dashboard.yourTurn)", label: "Your turn", caption: "Finished, not yet seen", color: DashStyle.yourTurn, systemImage: "checkmark.bubble.fill")
                        NowTile(value: dashboard.linesAdded.map { "+" + DashStyle.compact($0) } ?? "–", label: "Lines today",
                                caption: dashboard.linesRemoved.map { "−\(DashStyle.compact($0)) removed" } ?? "Counting…",
                                color: DashStyle.lines, systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    let waiting = WaitingCard(dashboard: dashboard)
                    let usage = UsageCard(dashboard: dashboard)
                    if wide {
                        HStack(alignment: .top, spacing: 16) { waiting; usage }
                    } else {
                        waiting
                        usage
                    }
                    if let projects = dashboard.projects, !projects.isEmpty {
                        ProjectUsageCard(projects: projects)
                    }
                }
                .padding()
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: dashboard)
            } else {
                ContentUnavailableView("No Dashboard", systemImage: "gauge.with.dots.needle.33percent",
                                       description: Text("Update ClaudeDeck on the Mac to see its dashboard here."))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Card<Content: View>: View {
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

private struct NowTile: View {
    let value: String
    let label: LocalizedStringKey
    let caption: LocalizedStringKey
    let color: Color
    let systemImage: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(emphasized ? .white : color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(emphasized ? color : color.opacity(0.16)))
                Text(label).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(emphasized ? color : .primary)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(color.opacity(emphasized ? 0.22 : 0.10)).frame(width: 100, height: 100).blur(radius: 26).offset(x: 30, y: -36)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(emphasized ? color.opacity(0.45) : Color.primary.opacity(0.06)))
    }
}

private struct WaitingCard: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID
    let dashboard: RemoteDashboard

    var body: some View {
        Card(title: "Waiting on you", systemImage: "hourglass") {
            if dashboard.waitingList.isEmpty {
                Label("Nobody’s waiting on you", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // The waits count up on the phone (the Mac sends when each began).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let longest = max(60, dashboard.waitingList.map { context.date.timeIntervalSince($0.since) }.max() ?? 60)
                    VStack(spacing: 4) {
                        ForEach(dashboard.waitingList) { item in
                            Button { store.open(item.sessionID, in: sceneID) } label: {
                                WaitingRow(item: item, waited: context.date.timeIntervalSince(item.since), longest: longest)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.snapshot?.session(item.sessionID) == nil)
                        }
                        if dashboard.moreWaiting > 0 {
                            Text("and \(dashboard.moreWaiting) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct WaitingRow: View {
    let item: RemoteDashboard.Waiting
    let waited: TimeInterval
    let longest: TimeInterval

    var body: some View {
        let tint = DashStyle.reasonColor(item.reason)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !item.project.isEmpty, item.project != item.name, !item.name.hasPrefix(item.project) {
                        Text(item.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(item.detail.map { ProgramStyle.detail($0) ?? $0 } ?? DashStyle.reasonLabel(item.reason))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(DashStyle.duration(waited))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.isBlocked ? tint : .secondary)
                Capsule().fill(Color.primary.opacity(0.08))
                    .frame(width: 64, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.8)).frame(width: max(4, 64 * min(1, waited / longest)), height: 4)
                    }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct UsageCard: View {
    let dashboard: RemoteDashboard

    var body: some View {
        Card(title: "Usage", systemImage: "flame") {
            if dashboard.fiveHour == nil, dashboard.week == nil {
                Text("Usage isn’t available (sign in to Claude Code on the Mac)").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    if let window = dashboard.fiveHour { UsageGauge(title: "5 hours", window: window) }
                    if let window = dashboard.week { UsageGauge(title: "Week", window: window) }
                }
            }
        }
    }
}

/// Each project's part of the plan's usage (sent by Macs that know it).
private struct ProjectUsageCard: View {
    let projects: [RemoteDashboard.ProjectShare]
    @State private var week = false

    var body: some View {
        Card(title: "Usage by project", systemImage: "chart.bar.xaxis") {
            Picker("Window", selection: $week) {
                Text("5 hours").tag(false)
                Text("Week").tag(true)
            }
            .pickerStyle(.segmented)
            let rows = projects.filter { (week ? $0.weekTokens : $0.fiveHourTokens) > 0 }
            if rows.isEmpty {
                Text(week ? "Nothing this week" : "Nothing in this 5-hour window").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(rows) { project in
                        let share = week ? project.weekShare : project.fiveHourShare
                        let percent = week ? project.weekPercent : project.fiveHourPercent
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(project.name).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 8)
                                if let percent {
                                    Text(verbatim: String(format: "%.1f%%", percent)).font(.callout.weight(.semibold)).monospacedDigit()
                                }
                                Text(verbatim: "\(Int((share * 100).rounded()))%")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressView(value: min(1, max(0, share)))
                            Text("\((week ? project.weekTokens : project.fiveHourTokens).formatted(.number.notation(.compactName))) tokens")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("A project's share of the estimated cost in its transcripts, applied to the plan's percent.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct UsageGauge: View {
    let title: LocalizedStringKey
    let window: RemoteDashboard.Window

    var body: some View {
        let tint = DashStyle.usageTint(window.usedPercent)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: min(1, window.usedPercent / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(window.usedPercent.rounded()))%").font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if let reset = window.resetsAt {
                    Text("Resets \(reset, format: .dateTime.weekday(.abbreviated).hour().minute())").font(.caption).foregroundStyle(.secondary)
                }
                if let limit = window.limitAt {
                    if window.hitsLimitBeforeReset {
                        Label { Text("At this pace: limit at \(limit, format: .dateTime.hour().minute())") } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.caption.weight(.medium)).foregroundStyle(.red)
                    } else {
                        Text("At this pace: no limit before the reset").font(.caption).foregroundStyle(.secondary)
                    }
                } else if window.ratePerHour != nil {
                    Text("Not climbing").font(.caption).foregroundStyle(.secondary)
                }
                if let rate = window.ratePerHour, rate > 0.05 {
                    Text(verbatim: String(format: "%.1f %%/h", rate)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }
}
