import AppKit
import ClaudeDeckCore
import SwiftUI

/// The projects' `docs/AGENDA.md` boards (AgendaBoard.swift). Every few seconds each project's
/// file is looked at (one `stat`), and read again only when its size or modification time
/// changed, so the board follows the agents' edits without watching whole project trees.
@MainActor
@Observable
final class AgendaController {
    static let shared = AgendaController()
    static let interval: Duration = .seconds(2)

    /// Projects whose file has a table with id and status columns.
    private(set) var boards: [UUID: AgendaBoard] = [:]
    private(set) var modified: [UUID: Date] = [:]
    /// Something changed (remotes get a new snapshot).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var stamps: [UUID: Stamp] = [:]
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private struct Stamp: Equatable {
        var path: String
        var modified: Date
        var size: Int
    }

    private init() {}

    func start(model: AppModel) {
        self.model = model
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func board(_ projectID: UUID) -> AgendaBoard? { boards[projectID] }

    static func fileURL(_ project: Project) -> URL {
        URL(fileURLWithPath: project.path).appending(path: AgendaBoard.relativePath)
    }

    /// Reads the files that changed since the last look.
    func refresh() {
        guard let model else { return }
        var changed = false
        let projects = model.deck.projects
        let known = Set(projects.map(\.id))
        for id in boards.keys where !known.contains(id) {
            boards[id] = nil
            modified[id] = nil
            stamps[id] = nil
            changed = true
        }
        for project in projects {
            let url = Self.fileURL(project)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes, let size = (attributes[.size] as? NSNumber)?.intValue, size <= AgendaBoard.maxFileSize,
                  let date = attributes[.modificationDate] as? Date else {
                if boards[project.id] != nil || stamps[project.id] != nil {
                    boards[project.id] = nil
                    modified[project.id] = nil
                    stamps[project.id] = nil
                    changed = true
                }
                continue
            }
            let stamp = Stamp(path: url.path, modified: date, size: size)
            guard stamps[project.id] != stamp else { continue }
            stamps[project.id] = stamp
            let board = (try? String(contentsOf: url, encoding: .utf8)).flatMap(AgendaBoard.parse)
            if boards[project.id] != board { changed = true }
            boards[project.id] = board
            modified[project.id] = board == nil ? nil : date
        }
        if changed { onChange?() }
    }

    /// For a remote: each project's board, in the deck's order.
    var remoteAgendas: [RemoteAgenda] {
        guard let model else { return [] }
        return model.deck.projects.compactMap { project in
            boards[project.id].map { RemoteAgenda(projectID: project.id, project: project.name, items: $0.items, updatedAt: modified[project.id]) }
        }
    }

    static func tabTitle(_ projectID: UUID) -> String {
        let name = shared.model?.deck.project(projectID)?.name ?? ""
        return name.isEmpty ? String(localized: "Agenda") : String(localized: "Agenda — \(name)")
    }
}

extension AppModel {
    /// A project's agenda board.
    func showAgenda(_ projectID: UUID) {
        AgendaController.shared.refresh()
        tabs.open(.agenda(projectID))
        showMainWindow()
    }
}

// MARK: - Style

enum AgendaStyle {
    static func title(_ status: AgendaStatus?) -> String {
        switch status {
        case .todo: String(localized: "To Do")
        case .doing: String(localized: "Doing")
        case .review: String(localized: "Review")
        case .blocked: String(localized: "Blocked")
        case .done: String(localized: "Done")
        case nil: String(localized: "Other")
        }
    }

    static func color(_ status: AgendaStatus?) -> Color {
        switch status {
        case .todo: .secondary
        case .doing: .blue
        case .review: .purple
        case .blocked: .red
        case .done: .green
        case nil: .orange
        }
    }

    static func symbol(_ status: AgendaStatus?) -> String {
        switch status {
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .review: "eye.circle"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }
}

// MARK: - The board

struct AgendaBoardView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var agenda = AgendaController.shared

    var body: some View {
        let project = model.deck.project(projectID)
        VStack(spacing: 0) {
            header(project)
            Divider()
            if let board = agenda.board(projectID) {
                if board.items.isEmpty {
                    empty(String(localized: "The table in docs/AGENDA.md has no rows yet."))
                } else {
                    columns(board)
                }
            } else {
                empty(String(localized: "No board: docs/AGENDA.md is missing, or has no table with id and status columns."))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(_ project: Project?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(project?.name ?? String(localized: "Agenda")).font(.headline)
                Text(AgendaBoard.relativePath).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let board = agenda.board(projectID) {
                ForEach([AgendaStatus.doing, .review, .blocked], id: \.self) { status in
                    let count = board.count(status)
                    if count > 0 {
                        Label("\(count)", systemImage: AgendaStyle.symbol(status))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AgendaStyle.color(status))
                            .help(AgendaStyle.title(status))
                    }
                }
                Text("\(board.count(.done))/\(board.items.count) done").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let date = agenda.modified[projectID] {
                Text(date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    .help(String(localized: "Changed \(date.formatted(date: .abbreviated, time: .shortened))"))
            }
            if let project {
                Button {
                    let url = AgendaController.fileURL(project)
                    if FileManager.default.fileExists(atPath: url.path) { model.tabs.openFile(url, preview: false) }
                } label: {
                    Label("Open File", systemImage: "doc.text")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1").font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Columns: id, track, owner, status (todo, doing, review, done, blocked), depends-on, evidence.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columns(_ board: AgendaBoard) -> some View {
        let done = Set(board.items.filter { $0.status == .done }.map(\.id))
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(board.columns, id: \.status) { column in
                    AgendaColumn(status: column.status, items: column.items, done: done)
                }
            }
            .padding(16)
        }
    }
}

private struct AgendaColumn: View {
    let status: AgendaStatus?
    let items: [AgendaItem]
    let done: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: AgendaStyle.symbol(status)).foregroundStyle(AgendaStyle.color(status))
                Text(AgendaStyle.title(status)).font(.subheadline.weight(.semibold))
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in AgendaCard(item: item, done: done) }
                    if items.isEmpty {
                        Text("Nothing here").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AgendaCard: View {
    let item: AgendaItem
    let done: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(AgendaStyle.color(item.status))
                if let track = item.track {
                    Text(track).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if item.status == nil {
                    Text(item.statusText).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            if let title = item.title {
                Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let owner = item.owner {
                Label(owner, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !item.dependsOn.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                    ForEach(item.dependsOn, id: \.self) { dep in
                        Text(dep).font(.caption2.monospaced())
                            .strikethrough(done.contains(dep))
                            .foregroundStyle(done.contains(dep) ? Color.secondary : Color.primary)
                    }
                }
                .help(String(localized: "Depends on \(item.dependsOn.joined(separator: ", "))"))
            }
            if let evidence = item.evidence {
                Label {
                    Text((try? AttributedString(markdown: evidence)) ?? AttributedString(evidence)).font(.caption).lineLimit(3)
                } icon: {
                    Image(systemName: "checkmark.seal").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(AgendaStyle.color(item.status)).frame(width: 3)
        }
    }
}
