import AppKit
import ClaudeDeckCore
import SwiftUI

/// The inspector's Edits page: what Claude changed in the selected session's files, read live
/// from its transcript (SessionChanges.swift). A stream of changes as they come, or file by file;
/// any change, or lines picked in it, can be sent back to Claude with a message.
struct EditsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.selectedSessionID.flatMap { model.deck.session($0) }
        if let session, session.kind == .claude {
            // The hook's path follows /clear (a new transcript); the deck's is the one it resumed.
            EditsSessionView(session: session,
                             transcriptPath: model.hookStatuses[session.id]?.transcriptPath ?? model.deck.transcriptPath(for: session.id))
                // Fresh state per session: never show the previous session's edits during a switch.
                .id(session.id)
        } else if session != nil {
            ContentUnavailableView("Not a Claude Session", systemImage: "terminal",
                                   description: Text("Shell terminals have no Claude edits."))
        } else {
            ContentUnavailableView("No Session Selected", systemImage: "pencil.line",
                                   description: Text("Select a Claude session to see its edits."))
        }
    }
}

enum EditsTab: String {
    case stream, files
}

private struct EditsSessionView: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let transcriptPath: String?

    @State private var changes: SessionChanges?
    @State private var selectedFile: String?
    @AppStorage("edits.tab", store: .windowState) private var tab = EditsTab.stream

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let changes, !changes.all.isEmpty {
                switch tab {
                case .stream: EditsStream(changes: changes, context: context)
                case .files: EditsFiles(changes: changes, context: context, selected: $selectedFile)
                }
            } else if changes != nil || transcriptPath == nil {
                ContentUnavailableView("No Edits Yet", systemImage: "pencil.line",
                                       description: Text("Changes Claude makes with Edit and Write show up here as it works."))
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: transcriptPath) {
            changes = nil
            guard let transcriptPath else { return }
            // Polls only while the page is shown; each poll reads just what the transcript gained.
            let tracker = EditsTrackers.tracker(for: transcriptPath)
            changes = await tracker.latest
            while !Task.isCancelled {
                if let next = await tracker.poll() { changes = next }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var context: EditsContext {
        EditsContext(sessionID: session.id,
                     root: session.workingDirectory ?? model.deck.project(session.projectID)?.path ?? "/")
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line").foregroundStyle(.secondary)
                Text(session.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let changes, !changes.all.isEmpty {
                    let added = changes.all.reduce(0) { $0 + $1.added }, removed = changes.all.reduce(0) { $0 + $1.removed }
                    LineCounts(added: added, removed: removed)
                }
            }
            Picker("Edits", selection: $tab) {
                Text("Stream").tag(EditsTab.stream)
                Text("Files").tag(EditsTab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Trackers of the transcripts shown lately, so coming back to a session's edits reads on from
/// where it was instead of parsing the transcript again.
@MainActor
enum EditsTrackers {
    private static var recent: [(path: String, tracker: SessionChangesTracker)] = []
    private static let limit = 6

    static func tracker(for path: String) -> SessionChangesTracker {
        let tracker = recent.first { $0.path == path }?.tracker ?? SessionChangesTracker(transcriptURL: URL(fileURLWithPath: path))
        recent.removeAll { $0.path == path }
        recent.append((path, tracker))
        if recent.count > limit { recent.removeFirst() }
        return tracker
    }
}

/// What a change card needs to know about its session.
struct EditsContext {
    let sessionID: UUID
    /// The session's folder: paths are shown and sent relative to it.
    let root: String

    func relative(_ path: String) -> String {
        FileListing.relativePath(of: URL(fileURLWithPath: path), in: URL(fileURLWithPath: root))
    }
}

// MARK: - Stream

/// Every change, oldest first; follows new ones while scrolled to the bottom.
private struct EditsStream: View {
    let changes: SessionChanges
    let context: EditsContext
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(changes.all) { change in
                        ChangeCard(path: change.path, hunks: change.hunks, context: context, change: change)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(8)
            }
            // Opens on the latest change.
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, bottom in
                atBottom = bottom
            }
            .onChange(of: changes.all.count) {
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private static let bottom = "bottom"
}

// MARK: - Files

/// The changed files; one picked shows its changes in order, or its net diff.
private struct EditsFiles: View {
    let changes: SessionChanges
    let context: EditsContext
    @Binding var selected: String?

    var body: some View {
        if let selected, let file = changes.files.first(where: { $0.path == selected }) {
            EditsFileDetail(changes: changes, file: file, context: context) { self.selected = nil }
        } else {
            List(changes.files.reversed(), selection: $selected) { file in
                let list = changes.changes(of: file.path)
                HStack(spacing: 6) {
                    Image(systemName: list.first?.kind == .created ? "doc.badge.plus" : "doc.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1)
                        Text(verbatim: (context.relative(file.path) as NSString).deletingLastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    LineCounts(added: list.reduce(0) { $0 + $1.added }, removed: list.reduce(0) { $0 + $1.removed })
                    Text(verbatim: "\(list.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
                .tag(file.path)
            }
            .listStyle(.sidebar)
        }
    }
}

private enum FileDetailMode: String {
    case changes, net
}

private struct EditsFileDetail: View {
    let changes: SessionChanges
    let file: ChangedFile
    let context: EditsContext
    let back: () -> Void
    @AppStorage("edits.fileMode", store: .windowState) private var mode = FileDetailMode.changes
    /// nil: not worked out yet; empty: no net change.
    @State private var net: [DiffHunk]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) { Label("All Files", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer(minLength: 4)
                Picker("Show", selection: $mode) {
                    Text("Changes").tag(FileDetailMode.changes)
                    Text("Net Diff").tag(FileDetailMode.net)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Text(verbatim: context.relative(file.path))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch mode {
                    case .changes:
                        ForEach(changes.changes(of: file.path)) { change in
                            ChangeCard(path: change.path, hunks: change.hunks, context: context, change: change)
                        }
                    case .net:
                        netDiff
                    }
                }
                .padding(8)
            }
        }
        // Worked out off the main actor, again whenever the file gains a change.
        .task(id: file.changes.count) {
            guard let original = file.original, let current = file.current else { net = nil; return }
            net = await Task.detached { SessionChanges.netDiff(from: original, to: current) }.value
        }
    }

    @ViewBuilder
    private var netDiff: some View {
        if file.original == nil || file.current == nil {
            Text("The net diff isn’t available: the transcript doesn’t have this file’s full content.")
                .font(.callout).foregroundStyle(.secondary).padding(8)
        } else if let net {
            if net.isEmpty {
                Text("No net change").font(.callout).foregroundStyle(.secondary).padding(8)
            } else {
                ChangeCard(path: file.path, hunks: net, context: context, change: nil)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
        }
    }
}

// MARK: - Card

/// One change (or a file's net diff): its file, lines and counts over a unified diff. Lines can
/// be picked (click, Shift-click to extend) to write to Claude about just those.
private struct ChangeCard: View {
    @Environment(AppModel.self) private var model
    let path: String
    let hunks: [DiffHunk]
    let context: EditsContext
    /// nil for a net diff.
    let change: FileChange?

    /// Picked lines, as indexes into `rows`.
    @State private var picked: ClosedRange<Int>?
    @State private var anchor: Int?
    @State private var composing = false
    @State private var expanded = false

    /// Long changes (a big new file) show this many lines until expanded.
    private static let collapsedLimit = 200

    private enum Row { case gap, line(DiffLine) }

    private var rows: [Row] {
        var rows: [Row] = []
        for (index, hunk) in hunks.enumerated() {
            if index > 0 { rows.append(.gap) }
            rows += hunk.lines.map(Row.line)
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let shown = expanded ? rows.count : min(rows.count, Self.collapsedLimit)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<shown, id: \.self) { index in
                        switch rows[index] {
                        case .gap:
                            Text(verbatim: "⋯")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, gutter + 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.06))
                        case .line(let line):
                            EditLineRow(line: line, gutter: gutter, picked: picked?.contains(index) == true)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(index) }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if shown < rows.count {
                Button("Show All \(rows.count) Lines") { expanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: change?.kind == .created ? "doc.badge.plus" : change == nil ? "sum" : "pencil")
                .foregroundStyle(.secondary)
                .help(change?.tool ?? "")
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let range = pickedLines.flatMap(SessionChanges.lineRange) ?? lineRange {
                        Text(verbatim: range.count == 1 ? "L\(range.lowerBound)" : "L\(range.lowerBound)–\(range.upperBound)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(picked == nil ? Color.secondary : Color.accentColor)
                    }
                    Text(verbatim: (context.relative(path) as NSString).deletingLastPathComponent)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let date = change?.date {
                Text(date, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            LineCounts(added: added, removed: removed)
            Button {
                composing = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.borderless)
            .help(picked == nil ? LocalizedStringKey("Write About This…") : LocalizedStringKey("Write About the Picked Lines…"))
            // Opens to the left: the button sits at the inspector's trailing edge, often the screen's too.
            .popover(isPresented: $composing, arrowEdge: .leading) {
                EditComposer(reference: SessionChanges.mention(path: path, root: context.root,
                                                               lines: SessionChanges.lineRange(of: messageLines) ?? lineRange),
                             sessionID: context.sessionID) { text in
                    let message = SessionChanges.message(path: path, root: context.root, lines: messageLines, text: text)
                    model.enqueue(context.sessionID, text: message)
                    picked = nil
                    anchor = nil
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .contextMenu {
            Button("Write About This…") { composing = true }
            if picked != nil { Button("Clear Selection") { picked = nil; anchor = nil } }
            Divider()
            Button("Open File") { EditorOpener.openDefault(URL(fileURLWithPath: path), model: model) }
            Button("Copy Path") { FileActions.copy(context.relative(path)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }

    private var allLines: [DiffLine] { hunks.flatMap(\.lines) }

    private var pickedLines: [DiffLine]? {
        guard let picked else { return nil }
        return picked.compactMap { index in
            guard index < rows.count, case .line(let line) = rows[index] else { return nil }
            return line
        }
    }

    /// The lines a message is about: the picked ones, else the whole change.
    private var messageLines: [DiffLine] { pickedLines ?? allLines }

    private var lineRange: ClosedRange<Int>? { change?.lineRange ?? SessionChanges.lineRange(of: allLines) }
    private var added: Int { change?.added ?? allLines.count { $0.kind == .added } }
    private var removed: Int { change?.removed ?? allLines.count { $0.kind == .removed } }

    private var gutter: CGFloat {
        let maxLine = hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return CGFloat(max(2, String(maxLine).count)) * 7 + 4
    }

    /// Click picks a line (again: unpicks); Shift-click extends from the last one picked.
    private func pick(_ index: Int) {
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            picked = min(anchor, index)...max(anchor, index)
        } else if picked == index...index {
            picked = nil
            anchor = nil
        } else {
            picked = index...index
            anchor = index
        }
    }
}

/// One diff line: new-side number, marker, text.
private struct EditLineRow: View {
    let line: DiffLine
    let gutter: CGFloat
    let picked: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(line.displayLine.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
                .padding(.trailing, 4)
            Text(marker)
                .frame(width: 12)
                .foregroundStyle(color)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .padding(.trailing, 8)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if picked { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context, .noNewline: " "
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        default: .secondary
        }
    }

    private var background: Color {
        if picked { return Color.accentColor.opacity(0.18) }
        return switch line.kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        default: .clear
        }
    }
}

private struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(.red) }
        }
        .font(.caption.monospacedDigit())
    }
}

// MARK: - Composer

/// "Write about this": a message for Claude about a change. It goes through the session's queue:
/// in right away on Claude's turn, else when its turn comes.
private struct EditComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reference: String
    let sessionID: UUID
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: reference)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .frame(width: 320, height: 90)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Your message about this change")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    send(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    /// When the message won't go in right away.
    private var note: LocalizedStringKey? {
        guard model.terminals.isRunning(sessionID) else { return "The session isn’t running: the message waits in its queue." }
        let display = model.status(of: sessionID).display
        let queued = !(model.deck.session(sessionID)?.queue.isEmpty ?? true)
        return display.isIdle && !queued ? nil : "Claude is busy: the message waits in the queue until its turn."
    }
}
