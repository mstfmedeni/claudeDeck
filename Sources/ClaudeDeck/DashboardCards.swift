import AppKit
import Charts
import ClaudeDeckCore
import SwiftUI

// MARK: - Activity river

/// Every Claude session's stretches of working, waiting and your-turn over the chosen span, one
/// lane each. Hover scrubs through time (who was doing what then); a click opens the session.
struct RiverCard: View {
    enum Span: Int, CaseIterable, Identifiable {
        case hour = 1, threeHours = 3, twelveHours = 12, day = 24
        var id: Int { rawValue }
        var title: String { "\(rawValue)h" }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("dashboard.riverSpan", store: .windowState) private var span = Span.threeHours
    @State private var scrub: Date?

    var body: some View {
        DashCard("Activity river", systemImage: "water.waves") {
            Picker("Span", selection: $span) {
                ForEach(Span.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        } content: {
            VisibleTimeline(every: 10) { now in
                river(now: now)
            }
        }
    }

    static let laneHeight: CGFloat = 26

    struct Lane: Identifiable {
        var id: String
        var name: String
        var project: String
        var color: Color
    }

    @ViewBuilder private func river(now: Date) -> some View {
        let window = DateInterval(start: now.addingTimeInterval(-Double(span.rawValue) * 3600), end: now)
        let segments = DashboardRecorder.shared.ledger.segments(in: window, now: now)
            .filter { model.deck.session($0.session) != nil }
        let order = Dictionary(model.deck.projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let laneIDs = Set(segments.map(\.session))
        let lanes: [Lane] = model.deck.sessions
            .filter { laneIDs.contains($0.id) }
            .sorted { ((order[$0.projectID] ?? .max), $0.name) < ((order[$1.projectID] ?? .max), $1.name) }
            .map { session in
                Lane(id: session.id.uuidString, name: session.name, project: model.deck.project(session.projectID)?.name ?? "",
                     color: model.dashboardColor(project: session.projectID))
            }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach([LedgerActivity.running, .permission, .question, .idle], id: \.self) { activity in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(DashboardStyle.color(for: activity)).frame(width: 12, height: 8)
                        Text(DashboardStyle.label(for: activity))
                    }
                }
                Spacer(minLength: 8)
                scrubReadout(segments: segments, at: scrub ?? now, live: scrub == nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if lanes.isEmpty {
                DashEmpty(text: "No Claude session has been active in this span", systemImage: "water.waves")
            } else {
                Chart {
                    ForEach(segments) { segment in
                        RectangleMark(
                            xStart: .value("Start", segment.start),
                            xEnd: .value("End", segment.end),
                            y: .value("Session", segment.session.uuidString),
                            height: .ratio(segment.activity == .idle ? 0.34 : 0.62)
                        )
                        .foregroundStyle(DashboardStyle.color(for: segment.activity).gradient)
                        .cornerRadius(3)
                        .opacity(scrub.map { segment.start <= $0 && $0 <= segment.end } == false ? 0.45 : 1)
                    }
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let scrub {
                        RuleMark(x: .value("Scrub", scrub))
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXScale(domain: window.start...window.end)
                .chartYScale(domain: lanes.map(\.id))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in
                    plot.frame(height: CGFloat(lanes.count) * Self.laneHeight)
                        .background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if let plotAnchor = proxy.plotFrame {
                            let plot = geo[plotAnchor]
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .frame(width: plot.width, height: plot.height)
                                .offset(x: plot.minX, y: plot.minY)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let point): scrub = proxy.value(atX: point.x, as: Date.self)
                                    case .ended: scrub = nil
                                    }
                                }
                                .onTapGesture { point in
                                    if let id = proxy.value(atY: point.y, as: String.self).flatMap(UUID.init(uuidString:)) {
                                        model.showFromDashboard(id)
                                    }
                                }
                        }
                    }
                }
                .padding(.leading, 178)
                .overlay(alignment: .topLeading) {
                    // Lane names beside the plot (one row per lane, same height): a click opens the session.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lanes) { lane in
                            LaneLabel(lane: lane) { if let id = UUID(uuidString: lane.id) { model.showFromDashboard(id) } }
                                .frame(height: Self.laneHeight)
                        }
                    }
                    .frame(width: 170, alignment: .leading)
                }
                .animation(.snappy(duration: 0.35), value: segments.count)
                .help("Hover to scrub through time; click a lane to open that session")
            }
        }
    }

    /// "14:32 · 3 working · 1 waiting" at the scrubbed time (or now).
    private func scrubReadout(segments: [LedgerSegment], at date: Date, live: Bool) -> some View {
        let active = segments.filter { $0.start <= date && date <= $0.end }
        let working = active.filter { $0.activity == .running }.count
        let waiting = active.filter { $0.activity.isBlocked }.count
        let time = live ? String(localized: "Now") : date.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 6) {
            Text(time).fontWeight(.semibold).foregroundStyle(live ? Color.accentColor : .primary)
            Text("· \(working) working · \(waiting) waiting").monospacedDigit()
        }
    }
}

private struct LaneLabel: View {
    let lane: RiverCard.Lane
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(lane.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(lane.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(lane.project)
    }
}

// MARK: - Usage burn

/// The plan's 5-hour and weekly windows: where they are, the readings so far, and where the
/// current pace leads (the limit before or after the reset).
struct UsageBurnCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DashCard("Usage burn", systemImage: "flame") {
            EmptyView()
        } content: {
            if let usage = model.usage.state.usage, !usage.isEmpty {
                VisibleTimeline(every: 30) { now in
                    content(usage, now: now)
                }
            } else {
                DashEmpty(text: "Usage isn’t available (sign in to Claude Code)", systemImage: "gauge.with.dots.needle.0percent")
            }
        }
    }

    @ViewBuilder private func content(_ usage: ClaudeUsage, now: Date) -> some View {
        let samples = DashboardRecorder.shared.ledger.usage
        let five = usage.fiveHour.flatMap { window in
            UsageProjection.project(current: window, length: 5 * 3600,
                                    samples: samples.compactMap { s in s.fiveHour.map { (s.at, $0) } }, now: now)
        }
        let week = usage.sevenDay.flatMap { window in
            UsageProjection.project(current: window, length: 7 * 86400,
                                    samples: samples.compactMap { s in s.sevenDay.map { (s.at, $0) } }, now: now,
                                    recent: 24 * 3600, minimumSpan: 6 * 3600)
        }
        HStack(alignment: .top, spacing: 16) {
            if let window = usage.fiveHour { UsageGauge(title: "5 hours", window: window, projection: five, now: now) }
            if let window = usage.sevenDay { UsageGauge(title: "Week", window: window, projection: week, now: now) }
        }
        if let window = usage.fiveHour, let reset = window.resetsAt {
            let start = reset.addingTimeInterval(-5 * 3600)
            let points = samples.compactMap { s -> (Date, Double)? in
                guard let v = s.fiveHour, s.at >= start, s.at <= now else { return nil }
                return (s.at, v)
            } + [(now, window.usedPercent)]
            let end = five?.limitAt.map { min($0, reset) } ?? reset
            let projected = five.map { window.usedPercent + $0.ratePerHour * end.timeIntervalSince(now) / 3600 } ?? window.usedPercent
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", point.0), y: .value("Used", point.1))
                        .foregroundStyle(LinearGradient(colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.0), y: .value("Used", point.1), series: .value("Series", "used"))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if five != nil, end > now {
                    LineMark(x: .value("Time", now), y: .value("Used", window.usedPercent), series: .value("Series", "pace"))
                        .foregroundStyle(five?.hitsLimitBeforeReset == true ? Color.red : Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    LineMark(x: .value("Time", end), y: .value("Used", min(100, projected)), series: .value("Series", "pace"))
                        .foregroundStyle(five?.hitsLimitBeforeReset == true ? Color.red : Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                RuleMark(y: .value("Limit", 100))
                    .foregroundStyle(Color.red.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: start...reset)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let v = value.as(Int.self) { Text(verbatim: "\(v)%") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 120)
        }
    }
}

private struct UsageGauge: View {
    let title: LocalizedStringKey
    let window: UsageWindow
    let projection: UsageProjection?
    let now: Date

    var body: some View {
        let used = window.usedPercent / 100
        let color: Color = window.usedPercent >= 90 ? .red : window.usedPercent >= 70 ? .orange : .green
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle().trim(from: 0, to: used)
                    .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * used)),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(UsageFormat.percent(window))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 54, height: 54)
            .animation(.snappy, value: used)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if let reset = window.resetsAt {
                    Text("Resets in \(UsageFormat.countdown(to: reset, now: now))").font(.caption).foregroundStyle(.secondary)
                }
                if let projection {
                    if projection.hitsLimitBeforeReset, let limit = projection.limitAt {
                        Label("Limit at \(limit.formatted(date: limit.timeIntervalSince(now) > 86400 ? .abbreviated : .omitted, time: .shortened))",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    } else {
                        Label("Lasts until the reset", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    Text("\(projection.ratePerHour.formatted(.number.precision(.fractionLength(projection.ratePerHour < 10 ? 1 : 0))))% per hour")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .help(projection.fromRecentSamples ? "Pace of the last 90 minutes" : "Average pace since this window began")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rhythm

/// The week as a heat map (activity per hour from the transcripts) and today's token flow by project.
struct RhythmCard: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: ActivityHeatmap.Cell?

    var body: some View {
        let recorder = DashboardRecorder.shared
        let calendar = Calendar.current
        let now = Date()
        let digest = recorder.combined
        let map = ActivityHeatmap.build(days: 7, now: now, calendar: calendar) { hour in
            Double(digest.hours[hour]?.events ?? 0)
        }
        DashCard("This week’s rhythm", systemImage: "square.grid.3x3.fill") {
            if let hovered {
                Text("\(hovered.dayStart.formatted(.dateTime.weekday(.wide))) \(hovered.hour):00 · \(Int(hovered.value)) events")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("Replies, prompts and tool calls per hour").font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            if !recorder.pulsesLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HeatGrid(map: map, hovered: $hovered)
                Divider().padding(.vertical, 2)
                TokenFlow(now: now)
            }
        }
    }
}

private struct HeatGrid: View {
    let map: ActivityHeatmap
    @Binding var hovered: ActivityHeatmap.Cell?

    var body: some View {
        let rows = Dictionary(grouping: map.cells, by: \.day).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.key) { day, cells in
                HStack(spacing: 3) {
                    Text(cells[0].dayStart.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2).foregroundStyle(day == 6 ? .primary : .secondary)
                        .frame(width: 34, alignment: .leading)
                    ForEach(cells) { cell in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(fill(cell))
                            .frame(maxWidth: .infinity)
                            .frame(height: 15)
                            .overlay {
                                if hovered == cell { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.6), lineWidth: 1) }
                            }
                            .onHover { inside in
                                if inside { hovered = cell } else if hovered == cell { hovered = nil }
                            }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 34)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? "\(hour)" : "")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fill(_ cell: ActivityHeatmap.Cell) -> Color {
        guard map.maxValue > 0, cell.value > 0 else { return Color.primary.opacity(0.05) }
        // Square root: a few busy hours shouldn't wash out the rest.
        let level = (cell.value / map.maxValue).squareRoot()
        return Color.accentColor.opacity(0.18 + 0.82 * level)
    }
}

/// Output tokens per hour today, stacked by project.
private struct TokenFlow: View {
    @Environment(AppModel.self) private var model
    let now: Date

    private struct Bar: Identifiable {
        var hour: Date
        var project: String
        var tokens: Int
        var id: String { "\(hour.timeIntervalSince1970)-\(project)" }
    }

    private static func bars(_ pulses: [UUID: PulseDigest], deck: DeckData, since: Date) -> ([Bar], [UUID: Int]) {
        var bars: [Bar] = []
        var projects: [UUID: Int] = [:]
        for (session, digest) in pulses {
            guard let projectID = deck.session(session)?.projectID else { continue }
            for (hour, bucket) in digest.hours where hour >= since && bucket.outputTokens > 0 {
                projects[projectID, default: 0] += bucket.outputTokens
                bars.append(Bar(hour: hour, project: projectID.uuidString, tokens: bucket.outputTokens))
            }
        }
        return (bars, projects)
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: now)
        let recorder = DashboardRecorder.shared
        let (bars, projects) = Self.bars(recorder.pulses, deck: model.deck, since: today)
        let ordered = model.deck.projects.filter { projects[$0.id] != nil }
        let total = projects.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tokens out today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(DashboardStyle.compact(total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                ForEach(ordered.prefix(5)) { project in
                    HStack(spacing: 4) {
                        Circle().fill(model.dashboardColor(project: project.id)).frame(width: 7, height: 7)
                        Text(project.name).lineLimit(1)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if bars.isEmpty {
                Text("No replies yet today").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 50)
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value("Hour", bar.hour, unit: .hour), y: .value("Tokens", bar.tokens))
                        .foregroundStyle(by: .value("Project", bar.project))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale(domain: ordered.map(\.id.uuidString), range: ordered.map { model.dashboardColor(project: $0.id) })
                .chartLegend(.hidden)
                .chartXScale(domain: today...today.addingTimeInterval(86400))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let v = value.as(Int.self) { Text(DashboardStyle.compact(v)) } }
                    }
                }
                .frame(height: 90)
            }
        }
    }
}

// MARK: - Automations

struct AutomationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let automations = model.deck.automations
        let runs = model.deck.automationRuns
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let recent = runs.filter { $0.startedAt >= weekAgo && $0.status.isFinished && $0.status != .cancelled }
        let succeeded = recent.filter { $0.status == .succeeded }.count
        DashCard("Automations", systemImage: "clock.arrow.circlepath") {
            if !recent.isEmpty {
                Text("\(succeeded)/\(recent.count) succeeded this week").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } content: {
            if automations.isEmpty {
                DashEmpty(text: "No automations yet", systemImage: "clock.badge.questionmark")
            } else {
                VisibleTimeline(every: 60) { now in
                    VStack(spacing: 4) {
                        ForEach(automations.prefix(6)) { automation in
                            DashAutomationRow(automation: automation,
                                          runs: runs.filter { $0.automationID == automation.id }.sorted { $0.startedAt < $1.startedAt }.suffix(10),
                                          now: now)
                        }
                    }
                }
            }
        }
    }
}

private struct DashAutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let runs: ArraySlice<AutomationRun>
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor(automation.lastRunStatus)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(automation.name).font(.callout.weight(.medium)).lineLimit(1)
                Group {
                    if !automation.enabled {
                        Text("Off")
                    } else if let next = automation.nextRunAt {
                        Text("Next in \(UsageFormat.countdown(to: next, now: now))")
                    } else {
                        Text("On demand")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach(runs) { run in
                    Capsule().fill(statusColor(run.status)).frame(width: 7, height: 16)
                        .help("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.status.rawValue)")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .opacity(automation.enabled ? 1 : 0.55)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showAutomations() }
    }

    private func statusColor(_ status: AutomationRunStatus?) -> Color {
        switch status {
        case .succeeded: .green
        case .failed: .red
        case .running, .pending: .blue
        case .skipped, .cancelled: .gray.opacity(0.6)
        case nil: .gray.opacity(0.3)
        }
    }
}

// MARK: - Pull requests, CI and devices

struct PipelineCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let monitor = GitHubMonitor.shared
        let linked = model.deck.sessions.compactMap { session -> (DeckSession, GitHubItemDetails)? in
            guard session.linkedWorkItem != nil, let details = monitor.details[session.id] else { return nil }
            return (session, details)
        }
        let failing = linked.filter { $0.1.checks?.outcome == .failed }.count
        // Linked but not fetched yet (gh polls while the app is in front).
        let pending = model.deck.sessions.filter { $0.linkedWorkItem != nil && monitor.details[$0.id] == nil }
        DashCard("Pull requests & CI", systemImage: "arrow.triangle.pull") {
            if failing > 0 {
                Text("\(failing) failing").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
        } content: {
            if linked.isEmpty && pending.isEmpty {
                DashEmpty(text: "Link a session to an issue or pull request to follow it here", systemImage: "link")
            } else {
                VStack(spacing: 4) {
                    ForEach(linked.prefix(6), id: \.0.id) { session, details in
                        PullRequestRow(session: session, details: details)
                    }
                    ForEach(pending.prefix(max(0, 6 - linked.count))) { session in
                        if let item = session.linkedWorkItem {
                            HStack(spacing: 10) {
                                Image(systemName: item.kind == .pr ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                                    .foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: "\(item.repo) \(item.shortLabel)").font(.callout.weight(.medium)).lineLimit(1)
                                    Text(session.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("Not checked yet").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
                            .help(item.url)
                        }
                    }
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let details: GitHubItemDetails
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: details.kind == .pr ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                .foregroundStyle(stateColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: "#\(details.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(details.title).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(session.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let review = details.reviewDecision {
                Text(reviewText(review))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(reviewColor(review).opacity(0.15)))
                    .foregroundStyle(reviewColor(review))
            }
            if let checks = details.checks, checks.total > 0 {
                HStack(spacing: 4) {
                    Image(systemName: checks.outcome == .failed ? "xmark.circle.fill" : checks.outcome == .pending ? "clock.fill" : "checkmark.circle.fill")
                    Text("\(checks.passed)/\(checks.total)").monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(checks.outcome == .failed ? .red : checks.outcome == .pending ? .orange : .green)
                .help(checks.failedNames.joined(separator: ", "))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let url = URL(string: details.url) { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("Open on GitHub") { if let url = URL(string: details.url) { NSWorkspace.shared.open(url) } }
            Button("Show Session") { model.showFromDashboard(session.id) }
        }
        .help(details.url)
    }

    private var stateColor: Color {
        switch details.displayState {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    private func reviewText(_ decision: String) -> String {
        switch decision {
        case "APPROVED": String(localized: "Approved")
        case "CHANGES_REQUESTED": String(localized: "Changes requested")
        default: String(localized: "Review required")
        }
    }

    private func reviewColor(_ decision: String) -> Color {
        switch decision {
        case "APPROVED": .green
        case "CHANGES_REQUESTED": .orange
        default: .secondary
        }
    }
}
