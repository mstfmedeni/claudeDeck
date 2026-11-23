import SwiftUI

/// A project's status line on the Mac (`claudedeck project status set`; hosts with
/// `Feature.projectStatus`): small, in its tone's color, dimmed after a week, like the Mac's sidebar.
struct ProjectStatusLabel: View {
    let status: ProjectStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
            Text(status.displayText)
                .listFont(.caption)
                .foregroundStyle(Self.color(status.tone))
                .opacity(status.isStale(now: context.date) ? 0.45 : 1)
                .lineLimit(1)
                .layoutPriority(-1)
                .accessibilityLabel(Text(status.text))
        }
    }

    static func color(_ tone: ProjectStatus.Tone?) -> Color {
        switch tone {
        case .ok: .green
        case .wait: .orange
        case .warn: .red
        case nil: .secondary
        }
    }

    /// "Updated: 2 hours ago · lead".
    static func updatedLine(_ status: ProjectStatus, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: min(status.updatedAt, now), relativeTo: now)
        return status.updatedBy.map { String(localized: "Updated: \(when) · \($0)") } ?? String(localized: "Updated: \(when)")
    }
}

/// The top of a project's long-press menu: the whole status, its summary and when it was written.
struct ProjectStatusMenuSection: View {
    let status: ProjectStatus

    var body: some View {
        Section {
            Text(status.text)
            if let summary = status.summary { Text(summary) }
            Text(ProjectStatusLabel.updatedLine(status))
        }
    }
}
