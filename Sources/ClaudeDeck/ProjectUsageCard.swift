import ClaudeDeckCore
import SwiftUI

/// The Dashboard's "Usage by project": each project's share of the 5-hour and weekly windows
/// (ProjectUsageMonitor), as bars of the window's percent.
struct ProjectUsageCard: View {
    @Environment(AppModel.self) private var model
    @State private var monitor = ProjectUsageMonitor.shared
    @State private var window = Window.fiveHours

    enum Window: Hashable { case fiveHours, week }

    var body: some View {
        DashCard("Usage by project", systemImage: "chart.bar.xaxis") {
            Picker("", selection: $window) {
                Text("5 hours").tag(Window.fiveHours)
                Text("Week").tag(Window.week)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            let rows = monitor.shares.filter { (window == .fiveHours ? $0.fiveHour : $0.week).messages > 0 }
            if !monitor.loaded {
                DashEmpty(text: "Reading the transcripts…", systemImage: "hourglass")
            } else if rows.isEmpty {
                DashEmpty(text: window == .fiveHours ? "Nothing in this 5-hour window" : "Nothing this week")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows.prefix(10)) { row(for: $0) }
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await AppVisibility.shared.waitUntilVisible()
                guard !Task.isCancelled else { return }
                await monitor.refresh(model: model)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var footnote: String {
        model.usage.state.usage == nil
            ? String(localized: "Shares of the estimated cost in the transcripts of the deck's projects (API prices). The plan's usage isn't available.")
            : String(localized: "Each project's share of the estimated cost in its transcripts (API prices), applied to the plan's percent. Sessions outside the deck's projects aren't counted.")
    }

    private func row(for share: ProjectUsageShare) -> some View {
        let five = window == .fiveHours
        let totals = five ? share.fiveHour : share.week
        let fraction = five ? share.fiveHourShare : share.weekShare
        let percent = five ? share.fiveHourPercent : share.weekPercent
        let color = model.dashboardColor(project: share.projectID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(share.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                if let percent {
                    Text(verbatim: String(format: "%.1f%%", percent))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color.opacity(0.85)).frame(width: max(3, proxy.size.width * min(1, fraction)))
                }
            }
            .frame(height: 5)
            Text("\(ProjectUsageReport.compact(totals.tokens)) tokens · \(ProjectUsageReport.compact(totals.output)) output · ≈ \(totals.cost, format: .currency(code: "USD"))")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(String(localized: "Input \(totals.input), output \(totals.output), cache writes \(totals.cacheWrite), cache reads \(totals.cacheRead) tokens in \(totals.messages) replies"))
    }
}
