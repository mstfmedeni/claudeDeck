import SwiftUI

/// A session's Edits tab: what Claude changed in its files, as the Mac's Edits page shows it. A
/// stream of changes as they come, or file by file (with a net diff); any change, or lines picked
/// in it, can be sent back to Claude with a message.
struct EditsView: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @AppStorage("edits.tab") private var tab = EditsTab.stream
    @AppStorage(ConversationTextSize.key) private var textSize = ConversationTextSize.standard
    @State private var selectedFile: String?

    enum EditsTab: String { case stream, files }

    var body: some View {
        let state = store.edits[sessionID]
        Group {
            if !store.supportsEdits {
                ContentUnavailableView("Edits", systemImage: "pencil.line",
                                       description: Text(store.snapshot == nil ? "Waiting for the other Mac…" : "Update ClaudeDeck on the Mac to see Claude’s edits here."))
            } else if let state, !state.changes.isEmpty {
                VStack(spacing: 0) {
                    header(state)
                    Divider()
                    switch tab {
                    case .stream: EditsStream(state: state, sessionID: sessionID)
                    case .files: EditsFiles(state: state, sessionID: sessionID, selected: $selectedFile)
                    }
                }
            } else if state?.loaded == true {
                ContentUnavailableView("No Edits Yet", systemImage: "pencil.line",
                                       description: Text("Changes Claude makes with Edit and Write show up here as it works."))
            } else if store.connection == .connected {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Waiting for the other Mac…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .dynamicTypeSize(ConversationTextSize.size(textSize))
        .modifier(EditsSubscription(sessionID: sessionID, active: true))
    }

    private func header(_ state: RemoteEditsState) -> some View {
        HStack(spacing: 8) {
            Picker("Edits", selection: $tab) {
                Text("Stream").tag(EditsTab.stream)
                Text("Files").tag(EditsTab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 4)
            LineCounts(added: state.changes.reduce(0) { $0 + $1.added }, removed: state.changes.reduce(0) { $0 + $1.removed })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Keeps a session's edits coming from the Mac while `active` and on screen.
struct EditsSubscription: ViewModifier {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    let active: Bool
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .onAppear { update(active) }
            .onDisappear { update(false) }
            .onChange(of: active) { _, now in update(now) }
    }

    private func update(_ want: Bool) {
        guard want != open else { return }
        open = want
        if want { store.openEdits(sessionID) } else { store.closeEdits(sessionID) }
    }
}

// MARK: - Stream

/// Every change, oldest first; follows new ones while scrolled to the bottom.
private struct EditsStream: View {
    let state: RemoteEditsState
    let sessionID: UUID
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.changes) { change in
                        ChangeCard(sessionID: sessionID, root: state.root, path: change.path, hunks: change.diffHunks, change: change)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(10)
            }
            // Opens on the latest change.
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, bottom in
                atBottom = bottom
            }
            .onChange(of: state.changes.count) {
                guard atBottom else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
        }
    }

    private static let bottom = "bottom"
}

// MARK: - Files

/// The changed files, last touched first; one picked shows its changes in order, or its net diff.
private struct EditsFiles: View {
    let state: RemoteEditsState
    let sessionID: UUID
    @Binding var selected: String?

    var body: some View {
        let files = state.files
        if let selected, let file = files.first(where: { $0.path == selected }) {
            EditsFileDetail(state: state, sessionID: sessionID, path: file.path, changes: file.changes) { self.selected = nil }
        } else {
            List(files.reversed(), id: \.path) { file in
                Button { selected = file.path } label: {
                    HStack(spacing: 8) {
                        Image(systemName: file.changes.first?.created == true ? "doc.badge.plus" : "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1)
                            Text(verbatim: (EditsPaths.relative(file.path, root: state.root) as NSString).deletingLastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        LineCounts(added: file.changes.reduce(0) { $0 + $1.added }, removed: file.changes.reduce(0) { $0 + $1.removed })
                        Text(verbatim: "\(file.changes.count)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

private enum FileDetailMode: String {
    case changes, net
}

private struct EditsFileDetail: View {
    @Environment(RemoteStore.self) private var store
    let state: RemoteEditsState
    let sessionID: UUID
    let path: String
    let changes: [RemoteFileChange]
    let back: () -> Void
    @AppStorage("edits.fileMode") private var mode = FileDetailMode.changes

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) { Label("All Files", systemImage: "chevron.left") }
                Spacer(minLength: 4)
                Picker("Show", selection: $mode) {
                    Text("Changes").tag(FileDetailMode.changes)
                    Text("Net Diff").tag(FileDetailMode.net)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Text(verbatim: EditsPaths.relative(path, root: state.root))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .changes:
                        ForEach(changes) { change in
                            ChangeCard(sessionID: sessionID, root: state.root, path: change.path, hunks: change.diffHunks, change: change)
                        }
                    case .net:
                        netDiff
                    }
                }
                .padding(10)
            }
        }
        // Asked again whenever the file gains a change.
        .task(id: "\(mode.rawValue)-\(changes.count)") {
            guard mode == .net, state.netDiffs[path]?.changes != changes.count else { return }
            store.loadNetDiff(sessionID, path: path)
        }
    }

    @ViewBuilder
    private var netDiff: some View {
        if let net = state.netDiffs[path] {
            if let hunks = net.hunks {
                if hunks.isEmpty {
                    Text("No net change").font(.callout).foregroundStyle(.secondary).padding(8)
                } else {
                    ChangeCard(sessionID: sessionID, root: state.root, path: path, hunks: hunks.compactMap(\.hunk), change: nil, omitted: net.omitted)
                }
            } else {
                Text("The net diff isn’t available: the transcript doesn’t have this file’s full content.")
                    .font(.callout).foregroundStyle(.secondary).padding(8)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(8)
        }
    }
}

// MARK: - Card

enum EditsPaths {
    /// `path` relative to the session's folder (as it is when outside it).
    static func relative(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// One change (or a file's net diff): its file, lines and counts over a unified diff that scrolls
/// sideways for long lines. A tap picks a line, a tap on another extends the pick to it (tapping
/// the first one again clears it); "Write About This…" is about the picked lines, else all of it.
/// `inline`: the conversation's version, folded to one row until tapped.
struct ChangeCard: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    let root: String?
    let path: String
    let hunks: [DiffHunk]
    /// nil for a net diff.
    let change: RemoteFileChange?
    /// Net diff lines the Mac left out.
    var omitted = 0
    var inline = false

    @State private var picked: ClosedRange<Int>?
    @State private var anchor: Int?
    @State private var composing = false
    @State private var showAll = false
    @State private var unfolded = false
    @ScaledMetric(relativeTo: .caption) private var digitWidth: CGFloat = 7.2

    /// Long changes show this many lines until "Show All" (inline: fewer).
    private var collapsedLimit: Int { inline ? 40 : 200 }

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
        if inline {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { unfolded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: change?.created == true ? "doc.badge.plus" : "pencil")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(verbatim: change?.tool ?? "").listFont(.caption, weight: .semibold)
                        Text(verbatim: (path as NSString).lastPathComponent).listFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        LineCounts(added: added, removed: removed)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").listFont(.caption2).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(unfolded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if unfolded { card }
            }
            .padding(.vertical, 2)
        } else {
            card
        }
    }

    private var card: some View {
        let rows = rows
        let shown = showAll ? rows.count : min(rows.count, collapsedLimit)
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<shown, id: \.self) { index in
                        switch rows[index] {
                        case .gap:
                            Text(verbatim: "⋯")
                                .font(.system(.caption, design: .monospaced))
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
                .frame(minWidth: 0, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if shown < rows.count {
                Button("Show All \(rows.count) Lines") { showAll = true }
                    .font(.caption)
                    .padding(8)
            }
            if let left = notSent, left > 0 {
                Text("\(left) more lines weren’t sent from the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $composing) {
            EditComposer(reference: SessionChanges.mention(path: path, root: root ?? "/", lines: messageRange),
                         sessionID: sessionID) { text in
                let message = SessionChanges.message(path: path, root: root ?? "/", lines: messageLines, text: text)
                guard store.sendAboutChange(sessionID, text: message) else { return false }
                picked = nil
                anchor = nil
                return true
            }
        }
    }

    private var notSent: Int? { change?.omitted ?? omitted }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: change?.created == true ? "doc.badge.plus" : change == nil ? "sum" : "pencil")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let range = pickedLines.flatMap(SessionChanges.lineRange) ?? lineRange {
                        Text(verbatim: range.count == 1 ? "L\(range.lowerBound)" : "L\(range.lowerBound)–\(range.upperBound)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(picked == nil ? Color.secondary : Color.accentColor)
                    }
                    Text(verbatim: (EditsPaths.relative(path, root: root) as NSString).deletingLastPathComponent)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let date = change?.date {
                Text(date, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            LineCounts(added: added, removed: removed)
            if picked != nil {
                Button { picked = nil; anchor = nil } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel(Text("Clear Selection"))
            }
            Button { composing = true } label: { Image(systemName: "text.bubble") }
                .accessibilityLabel(picked == nil ? Text("Write About This…") : Text("Write About the Picked Lines…"))
                .disabled(store.connection != .connected)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .contextMenu {
            Button { composing = true } label: { Label("Write About This…", systemImage: "text.bubble") }
            if picked != nil { Button { picked = nil; anchor = nil } label: { Label("Clear Selection", systemImage: "xmark.circle") } }
            Button { UIPasteboard.general.string = EditsPaths.relative(path, root: root) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    private var allLines: [DiffLine] { hunks.flatMap(\.lines) }

    private var pickedLines: [DiffLine]? {
        guard let picked else { return nil }
        let rows = rows
        return picked.compactMap { index in
            guard index < rows.count, case .line(let line) = rows[index] else { return nil }
            return line
        }
    }

    /// The lines a message is about: the picked ones, else the whole change.
    private var messageLines: [DiffLine] { pickedLines ?? allLines }
    private var messageRange: ClosedRange<Int>? {
        pickedLines.flatMap(SessionChanges.lineRange) ?? (picked == nil ? lineRange : SessionChanges.lineRange(of: messageLines))
    }

    private var lineRange: ClosedRange<Int>? { change?.lineRange ?? SessionChanges.lineRange(of: allLines) }
    private var added: Int { change?.added ?? allLines.count { $0.kind == .added } }
    private var removed: Int { change?.removed ?? allLines.count { $0.kind == .removed } }

    private var gutter: CGFloat {
        let maxLine = hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return CGFloat(max(2, String(maxLine).count)) * digitWidth + 4
    }

    /// A tap picks a line; with one picked, a tap on another extends the pick from the first to
    /// it, and a tap on the first clears it.
    private func pick(_ index: Int) {
        if let anchor {
            if index == anchor {
                picked = nil
                self.anchor = nil
            } else {
                picked = min(anchor, index)...max(anchor, index)
            }
        } else {
            picked = index...index
            anchor = index
        }
    }
}

/// One diff line: its number, marker and text, monospaced.
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
                .padding(.trailing, 10)
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .padding(.vertical, 1)
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
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.14)
        default: .clear
        }
    }
}

struct LineCounts: View {
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

/// "Write About This…": a message for Claude about a change, through the session's queue (in at
/// once on Claude's turn, else when its turn comes).
private struct EditComposer: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let reference: String
    let sessionID: UUID
    /// False when it couldn't be sent (the sheet stays).
    let send: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: reference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                TextField("Your message about this change", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($focused)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Write About This…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { if send(text) { dismiss() } }
                        .disabled(store.connection != .connected)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    /// When the message won't go in right away.
    private var note: LocalizedStringKey? {
        guard let session = store.snapshot?.session(sessionID) else { return nil }
        switch session.state {
        case .notStarted, .ended: return "The session isn’t running: the message waits in its queue."
        case .idle where (session.queue ?? []).isEmpty: return nil
        default: return "Claude is busy: the message waits in the queue until its turn."
        }
    }
}
