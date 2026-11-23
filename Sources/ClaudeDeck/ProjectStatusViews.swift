import ClaudeDeckCore
import SwiftUI

/// A project's status line next to its name in the sidebar (`claudedeck project status set`):
/// small, in its tone's color (none: secondary), dimmed once it is older than a week. The tooltip
/// has the summary, then when and by which session it was written.
struct ProjectStatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
            let stale = status.isStale(now: context.date)
            Text(status.displayText)
                .sidebarFont(.caption)
                .foregroundStyle(Self.color(status.tone))
                .opacity(stale ? 0.45 : 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help(Self.tooltip(status, now: context.date))
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

    static func tooltip(_ status: ProjectStatus, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: min(status.updatedAt, now), relativeTo: now)
        let updated = status.updatedBy.map { String(localized: "Updated: \(when) · \($0)") } ?? String(localized: "Updated: \(when)")
        var lines: [String] = []
        // The whole text when the sidebar cuts it.
        if status.displayText != status.text { lines.append(status.text) }
        if let summary = status.summary { lines.append(summary) }
        lines.append(updated)
        return lines.joined(separator: "\n\n")
    }
}

/// The project menu's "Clear Status" (only while it has one).
struct ProjectStatusMenuItems: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if project.status != nil {
            Button("Clear Status") { model.clearProjectStatus(project.id) }
        }
    }
}
