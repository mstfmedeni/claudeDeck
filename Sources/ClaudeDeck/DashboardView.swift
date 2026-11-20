import AppKit
import Charts
import ClaudeDeckCore
import SwiftUI

// The Dashboard tab: mission control for every session at once. Live state on top, the activity
// river (every session's working / waiting / your-turn stretches over time, scrubbable), then
// who is waiting on you, usage burn, today's edits, tools, the week's rhythm, automations, CI and
// phones. Exists only while its tab is selected; reads and ticks only while a window can be seen.

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var process: ProcessSample?
    @State private var width: CGFloat = 900

    var body: some View {
        let wide = width >= 780
        let columns = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DashboardHeader(process: process)
                NowTiles(wide: wide)
                LoadCard()
                RiverCard()
                columns {
                    WaitingCard()
                    UsageBurnCard()
                }
                ProjectUsageCard()
                columns {
                    EditsCard()
                    ToolsCard()
                }
                RhythmCard()
                columns {
                    AutomationsCard()
                    PipelineCard()
                }
            }
            .padding(20)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .background(DashboardStyle.page)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task {
            // Transcript counters and the process sample: only while a window can be seen.
            while !Task.isCancelled {
                await AppVisibility.shared.waitUntilVisible()
                guard !Task.isCancelled else { return }
                process = ProcessSample.take()
                await DashboardRecorder.shared.refreshPulses()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

// MARK: - Style

enum DashboardStyle {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let projectPalette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown, .cyan]

    static func color(for activity: LedgerActivity) -> Color {
        switch activity {
        case .running: StatusStyle.running
        case .permission: StatusStyle.blocked
        case .question: .orange
        case .idle: StatusStyle.idle.opacity(0.75)
        case .off: StatusStyle.inactive
        }
    }

    static func label(for activity: LedgerActivity) -> String {
        switch activity {
        case .running: String(localized: "Working")
        case .permission: String(localized: "Needs permission")
        case .question: String(localized: "Asking a question")
        case .idle: String(localized: "Your turn")
        case .off: String(localized: "Stopped")
        }
    }

    /// "42s", "4m 12s", "1h 5m" (localized units).
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return Duration.seconds(s).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

extension AppModel {
    /// A stable color per project (its place in the sidebar).
    func dashboardColor(project id: UUID) -> Color {
        let index = deck.projects.firstIndex { $0.id == id } ?? 0
        return DashboardStyle.projectPalette[index % DashboardStyle.projectPalette.count]
    }

    /// Shows a session from the dashboard (the Sessions tab comes forward).
    func showFromDashboard(_ id: UUID) {
        guard deck.session(id) != nil else { return }
        selectFromSidebar(id)
    }
}

/// A rounded card with a title row.
struct DashCard<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(DashLabelStyle())
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DashboardStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

private struct DashLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.tint)
            configuration.title.textCase(.uppercase).tracking(0.6)
        }
    }
}

/// Placeholder for an empty card.
struct DashEmpty: View {
    let text: LocalizedStringKey
    var systemImage = "moon.zzz"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 70)
    }
}

// MARK: - Header

private struct DashboardHeader: View {
    @Environment(AppModel.self) private var model
    let process: ProcessSample?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Mission Control")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(Date.now.formatted(date: .complete, time: .omitted))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                PhoneChip()
                if let process {
                    Chip(systemImage: "cpu", tint: .secondary) {
                        Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))% · \(ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory))")
                    }
                    .help("ClaudeDeck’s own CPU and memory")
                }
                LiveChip()
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct Chip<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content()
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(DashboardStyle.card))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct LiveChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 7, height: 7)
                .shadow(color: .green.opacity(0.8), radius: 3)
            Text("Live")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.green.opacity(0.12)))
        .help("Updates while this tab is on screen; nothing runs while it’s hidden")
    }
}

private struct PhoneChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let phones = model.remote.connectedRemotes
        if !phones.isEmpty {
            Chip(systemImage: "iphone.radiowaves.left.and.right", tint: .green) {
                Text(phones.count == 1 ? phones[0] : String(localized: "\(phones.count) devices"))
            }
            .help(phones.joined(separator: ", "))
        } else if case .listening = model.remote.hostState {
            Chip(systemImage: "iphone.slash", tint: .secondary) { Text("No phone connected") }
        }
    }
}

// MARK: - Now tiles

private struct NowTiles: View {
    @Environment(AppModel.self) private var model
    let wide: Bool

    var body: some View {
        let recorder = DashboardRecorder.shared
        let claude = model.deck.sessions.filter { $0.kind == .claude }
        let states = claude.map { model.status(of: $0.id).display }
        let working = states.filter(\.isRunning).count
        let blocked = states.filter(\.isBlocked).count
        let yourTurn = claude.filter { model.isUnseenIdle($0.id) }.count
        let open = claude.filter { model.terminals.isRunning($0.id) }.count
        let today = Calendar.current.startOfDay(for: Date())
        let lines = recorder.combined.total(in: DateInterval(start: today, duration: 86400))
        let grid = wide ? [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        LazyVGrid(columns: grid, spacing: 14) {
            NowTile(value: "\(working)", label: "Working", caption: "of \(open) open sessions", color: StatusStyle.running, systemImage: "bolt.fill")
            NowTile(value: "\(blocked)", label: "Waiting on you", caption: blocked == 0 ? "All clear" : "Permission or question", color: StatusStyle.blocked,
                    systemImage: "hand.raised.fill", emphasized: blocked > 0)
            NowTile(value: "\(yourTurn)", label: "Your turn", caption: "Finished, not yet seen", color: .yellow, systemImage: "checkmark.bubble.fill")
            NowTile(value: "+\(DashboardStyle.compact(lines.added))", label: "Lines today",
                    caption: "−\(DashboardStyle.compact(lines.removed)) removed · \(DashboardStyle.compact(lines.outputTokens)) tokens out",
                    color: .blue, systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .animation(.snappy, value: [working, blocked, yourTurn, lines.added])
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(emphasized ? .white : color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(emphasized ? color : color.opacity(0.16)))
                Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(emphasized ? color : .primary)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DashboardStyle.card)
                .overlay(alignment: .topTrailing) {
                    // A soft wash of the tile's color in the corner.
                    Circle().fill(color.opacity(emphasized ? 0.22 : 0.10)).frame(width: 120, height: 120).blur(radius: 30).offset(x: 30, y: -40)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(emphasized ? color.opacity(0.45) : Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - Waiting on you

private struct WaitingCard: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        var id: UUID
        var name: String
        var project: String
        var projectID: UUID
        var detail: String?
        var activity: LedgerActivity
        var since: Date
    }

    var body: some View {
        let ledger = DashboardRecorder.shared.ledger
        let rows: [Row] = model.deck.sessions.compactMap { session in
            let status = model.status(of: session.id)
            guard status.display.isBlocked || model.isUnseenIdle(session.id) else { return nil }
            let activity = LedgerActivity(status.display.activityValue)
            let recorded = ledger.current(session.id)
            let since = recorded?.activity == activity ? recorded!.at : status.updatedAt ?? Date()
            return Row(id: session.id, name: session.name, project: model.deck.project(session.projectID)?.name ?? "",
                       projectID: session.projectID, detail: status.detail, activity: activity, since: since)
        }
        .sorted { ($0.activity.isBlocked ? 0 : 1, $0.since) < ($1.activity.isBlocked ? 0 : 1, $1.since) }
        let today = Calendar.current.startOfDay(for: Date())
        let responses = ledger.responses(since: today).map(\.waited).sorted()
        DashCard("Waiting on you", systemImage: "hourglass") {
            if !responses.isEmpty {
                Text("\(responses.count) answered today · median \(DashboardStyle.duration(responses[responses.count / 2]))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } content: {
            if rows.isEmpty {
                DashEmpty(text: "Nobody’s waiting on you", systemImage: "checkmark.seal")
            } else {
                VisibleTimeline(every: 1) { now in
                    let longest = max(60, rows.map { now.timeIntervalSince($0.since) }.max() ?? 60)
                    VStack(spacing: 6) {
                        ForEach(rows.prefix(6)) { row in
                            DashWaitingRow(name: row.name, project: row.project, color: model.dashboardColor(project: row.projectID),
                                       detail: row.detail, activity: row.activity, waited: now.timeIntervalSince(row.since), longest: longest)
                                .contentShape(Rectangle())
                                .onTapGesture { model.showFromDashboard(row.id) }
                                .help("Show this session")
                        }
                        if rows.count > 6 {
                            Text("and \(rows.count - 6) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct DashWaitingRow: View {
    let name: String
    let project: String
    let color: Color
    let detail: String?
    let activity: LedgerActivity
    let waited: TimeInterval
    let longest: TimeInterval
    @State private var hovering = false

    var body: some View {
        let tint = DashboardStyle.color(for: activity)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                    if project != name, !project.isEmpty {
                        Text(project).font(.caption).foregroundStyle(color).lineLimit(1)
                    }
                }
                Text(detail ?? DashboardStyle.label(for: activity))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(DashboardStyle.duration(waited))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(activity.isBlocked ? tint : .secondary)
                GeometryReader { geo in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.8)).frame(width: max(4, geo.size.width * min(1, waited / longest)))
                        }
                }
                .frame(width: 70, height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - Edits

private struct EditsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = DashboardRecorder.shared
        let today = Calendar.current.startOfDay(for: Date())
        let digest = recorder.combined
        let files = Self.files(recorder.pulses, day: today)
        let top = files.values.sorted { ($0.file.added + $0.file.removed, $0.file.edits) > ($1.file.added + $1.file.removed, $1.file.edits) }
        let total = digest.total(in: DateInterval(start: today, duration: 86400))
        let editingSessions = Set(files.values.map(\.session)).count
        let hourly = (0..<24).compactMap { h -> (Date, Int, Int)? in
            guard let hour = Calendar.current.date(byAdding: .hour, value: h, to: today), hour <= Date() else { return nil }
            let b = digest.hours[hour] ?? PulseBucket()
            return (hour, b.added, b.removed)
        }
        DashCard("Today’s edits", systemImage: "pencil.and.list.clipboard") {
            Text("\(files.count) files · \(editingSessions) sessions").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } content: {
            if !recorder.pulsesLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 70)
            } else if top.isEmpty {
                DashEmpty(text: "No edits by Claude yet today", systemImage: "pencil.slash")
            } else {
                HStack(alignment: .bottom, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "+\(total.added.formatted())").foregroundStyle(.green)
                        Text(verbatim: "−\(total.removed.formatted())").foregroundStyle(.red)
                    }
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Chart {
                        ForEach(hourly, id: \.0) { hour, added, removed in
                            BarMark(x: .value("Hour", hour, unit: .hour), y: .value("Lines", added)).foregroundStyle(.green.opacity(0.8))
                            BarMark(x: .value("Hour", hour, unit: .hour), y: .value("Lines", -removed)).foregroundStyle(.red.opacity(0.7))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartXScale(domain: today...today.addingTimeInterval(86400))
                    .frame(width: 150, height: 36)
                    .help("Lines added and removed per hour today")
                }
                VStack(spacing: 2) {
                    let longest = max(1, top.first.map { $0.file.added + $0.file.removed } ?? 1)
                    ForEach(top.prefix(6), id: \.file.path) { entry in
                        FileRow(file: entry.file, root: model.deck.session(entry.session).flatMap { model.deck.project($0.projectID)?.path },
                                longest: longest)
                    }
                }
            }
        }
    }
}

extension EditsCard {
    /// The day's edited files across sessions, each with the session that edited it first.
    static func files(_ pulses: [UUID: PulseDigest], day: Date) -> [String: (file: PulseFile, session: UUID)] {
        var files: [String: (file: PulseFile, session: UUID)] = [:]
        for (session, pulse) in pulses {
            for (path, file) in pulse.files[day] ?? [:] {
                if var existing = files[path] {
                    existing.file.edits += file.edits
                    existing.file.added += file.added
                    existing.file.removed += file.removed
                    files[path] = existing
                } else {
                    files[path] = (file, session)
                }
            }
        }
        return files
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: PulseFile
    let root: String?
    let longest: Int
    @State private var hovering = false

    var body: some View {
        let relative = root.flatMap { file.path.hasPrefix($0 + "/") ? String(file.path.dropFirst($0.count + 1)) : nil } ?? (file.path as NSString).abbreviatingWithTildeInPath
        let name = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.callout).lineLimit(1)
                if !folder.isEmpty { Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(file.edits)×").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            GeometryReader { geo in
                let scale = geo.size.width / CGFloat(longest)
                HStack(spacing: 1) {
                    Capsule().fill(.green.opacity(0.85)).frame(width: max(2, CGFloat(file.added) * scale))
                    if file.removed > 0 { Capsule().fill(.red.opacity(0.75)).frame(width: max(2, CGFloat(file.removed) * scale)) }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 80, height: 5)
            Text(verbatim: "+\(file.added) −\(file.removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showFileTab(URL(fileURLWithPath: file.path), preview: true) }
        .help(file.path)
    }
}

// MARK: - Tools

private struct ToolsCard: View {
    var body: some View {
        let recorder = DashboardRecorder.shared
        let today = Calendar.current.startOfDay(for: Date())
        let counts = recorder.combined.tools[today] ?? [:]
        let sorted = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = Array(sorted.prefix(8))
        let rest = sorted.dropFirst(8).reduce(0) { $0 + $1.value }
        let total = counts.values.reduce(0, +)
        let agents = (counts["Agent"] ?? 0) + (counts["Task"] ?? 0)
        DashCard("Tool calls today", systemImage: "hammer") {
            Text("\(total.formatted()) calls · \(agents) agents").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } content: {
            if top.isEmpty {
                DashEmpty(text: recorder.pulsesLoaded ? "No tool calls yet today" : "Reading transcripts…", systemImage: "hammer")
            } else {
                let rows = top.map { ($0.key, $0.value) } + (rest > 0 ? [(String(localized: "Other"), rest)] : [])
                let most = max(1, rows.map(\.1).max() ?? 1)
                VStack(spacing: 7) {
                    ForEach(rows, id: \.0) { tool, count in
                        HStack(spacing: 10) {
                            Text(tool).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 120, alignment: .trailing)
                            GeometryReader { geo in
                                Capsule().fill(ToolsCard.color(for: tool).gradient)
                                    .frame(width: max(6, geo.size.width * CGFloat(count) / CGFloat(most)))
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 9)
                            Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        }
                    }
                }
                .animation(.snappy, value: total)
            }
        }
    }

    /// Reading, changing, running, delegating, the web: one hue each.
    static func color(for tool: String) -> Color {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "NotebookRead": .teal
        case "Edit", "Write", "MultiEdit", "NotebookEdit": .blue
        case "Bash", "BashOutput", "KillShell": .orange
        case "Agent", "Task": .purple
        case "WebFetch", "WebSearch": .pink
        case "TodoWrite", "AskUserQuestion", "ExitPlanMode": .indigo
        default: tool.contains(": ") ? .mint : .gray
        }
    }
}
