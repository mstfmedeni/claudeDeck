import SwiftUI

// Decisions sessions left for the owner (`claudedeck decide` on the Mac) and the projects'
// docs/AGENDA.md boards. Rows in the session list open them in the detail column (iPad) or push
// them (iPhone), like the Dashboard. Only from a Mac with `Feature.decisions` / `Feature.agenda`.

extension RemoteStore {
    /// Pending decisions and the recently answered ones, newest first (nil: the Mac doesn't send them).
    var decisions: [OwnerDecision]? { snapshot?.supports(RemoteSnapshot.Feature.decisions) == true ? snapshot?.decisions ?? [] : nil }
    var agendas: [RemoteAgenda]? { snapshot?.supports(RemoteSnapshot.Feature.agenda) == true ? snapshot?.agendas ?? [] : nil }

    /// The owner's answer; the Mac types it into the asking session at its next turn.
    @discardableResult
    func answerDecision(_ id: String, answer: String) -> Bool {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot?.supports(RemoteSnapshot.Feature.decisions) == true, !text.isEmpty else { return false }
        return send(.answerDecision(id: id, answer: String(text.prefix(Decisions.maxAnswer))))
    }
}

// MARK: - Decisions

struct DecisionsRow: View {
    let decisions: [OwnerDecision]

    var body: some View {
        let pending = decisions.filter(\.isPending).count
        NavigationLink(value: MacScreen.decisions) {
            Label {
                HStack {
                    Text("Your Decisions").listFont(.body)
                    Spacer(minLength: 4)
                    if pending > 0 {
                        Text("\(pending)").listFont(.caption, weight: .bold, monospacedDigit: true)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    } else {
                        Text("None waiting").listFont(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "signpost.right.and.left").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(pending > 0 ? Color.orange : Color.secondary)
            }
        }
        .tag(MacScreen.decisions)
    }
}

struct DecisionsScreen: View {
    @Environment(RemoteStore.self) private var store
    /// Answers sent and not yet in a snapshot (shown as sending; a lost one can be sent again).
    @State private var sent: [String: String] = [:]

    var body: some View {
        let all = store.decisions ?? []
        let pending = all.filter(\.isPending)
        let answered = all.filter { !$0.isPending }
        Group {
            if all.isEmpty {
                ContentUnavailableView("Nothing to Decide", systemImage: "signpost.right.and.left",
                                       description: Text("Sessions on the Mac ask with claudedeck decide and keep working; their questions show up here."))
            } else {
                List {
                    if !pending.isEmpty {
                        Section {
                            ForEach(pending) { decision in
                                DecisionCardPhone(decision: decision, sending: sent[decision.id]) { answer in
                                    if store.answerDecision(decision.id, answer: answer) { sent[decision.id] = answer }
                                }
                            }
                        } header: {
                            Text("Waiting · \(pending.count)")
                        } footer: {
                            Text("Your answer goes to the session as its next message.")
                        }
                    }
                    if !answered.isEmpty {
                        Section("Answered") {
                            ForEach(answered) { decision in answeredRow(decision) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Your Decisions")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pending.map(\.id)) { _, ids in
            sent = sent.filter { ids.contains($0.key) }
        }
        .disabled(store.connection != .connected)
    }

    private func answeredRow(_ decision: OwnerDecision) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(decision.question).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Label(decision.answer ?? "", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Text(decision.origin)
                if let at = decision.answeredAt {
                    Text("·")
                    Text(at, format: .relative(presentation: .named))
                }
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// A pending decision: who asks, the question and its context, the options (the recommended one
/// first and marked), and a field for an answer in one's own words.
struct DecisionCardPhone: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID
    let decision: OwnerDecision
    let sending: String?
    let answer: (String) -> Void
    @State private var custom = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "signpost.right.and.left").foregroundStyle(.orange)
                Text(decision.project.isEmpty ? decision.session : decision.project).fontWeight(.semibold).lineLimit(1)
                if !decision.project.isEmpty, !decision.session.isEmpty, let id = decision.sessionID, store.snapshot?.session(id) != nil {
                    Text("·").foregroundStyle(.tertiary)
                    Button(decision.session) { store.open(id, in: sceneID) }
                        .buttonStyle(.borderless)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(decision.createdAt, style: .relative).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.caption)
            Text(decision.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            if let context = decision.context {
                Text(context).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { expanded.toggle() }
            }
            if let sending {
                Label("Sending “\(sending)”…", systemImage: "paperplane").font(.subheadline).foregroundStyle(.secondary)
            } else {
                let ordered = decision.options.filter { $0 == decision.recommended } + decision.options.filter { $0 != decision.recommended }
                ForEach(ordered, id: \.self) { option in
                    if option == decision.recommended {
                        Button { answer(option) } label: {
                            HStack {
                                Image(systemName: "star.fill").font(.caption)
                                Text(option).multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                Text("Recommended").font(.caption2.weight(.semibold)).opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button { answer(option) } label: {
                            Text(option).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 8) {
                    TextField(decision.options.isEmpty ? String(localized: "Your answer") : String(localized: "Or answer in your own words"),
                              text: $custom, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        answer(custom)
                        custom = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text("Send"))
                }
            }
        }
        .padding(.vertical, 6)
        // Buttons in a list row: each its own target, not the whole row.
        .buttonStyle(.borderless)
    }
}

// MARK: - Agenda

struct AgendaRow: View {
    let agendas: [RemoteAgenda]

    var body: some View {
        let doing = agendas.reduce(0) { $0 + $1.board.count(.doing) }
        let blocked = agendas.reduce(0) { $0 + $1.board.count(.blocked) }
        NavigationLink(value: MacScreen.agenda) {
            Label {
                HStack {
                    Text("Agenda").listFont(.body)
                    Spacer(minLength: 4)
                    if blocked > 0 {
                        Text("\(blocked) blocked").listFont(.caption, weight: .semibold).foregroundStyle(.red)
                    } else {
                        Text("\(doing) doing").listFont(.caption, monospacedDigit: true).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "rectangle.split.3x1").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(blocked > 0 ? Color.red : Color.accentColor)
            }
        }
        .tag(MacScreen.agenda)
    }
}

enum AgendaPhoneStyle {
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

/// One project's board at a time (a menu picks the project), its columns as sections. Read only:
/// the agents edit docs/AGENDA.md on the Mac.
struct AgendaScreen: View {
    @Environment(RemoteStore.self) private var store
    @State private var projectID: UUID?
    @State private var showDone = false

    var body: some View {
        let agendas = store.agendas ?? []
        let agenda = agendas.first { $0.projectID == projectID } ?? agendas.first
        Group {
            if let agenda {
                board(agenda)
            } else {
                ContentUnavailableView("No Agenda", systemImage: "rectangle.split.3x1",
                                       description: Text("A project with docs/AGENDA.md (a table with id and status columns) shows its board here."))
            }
        }
        .navigationTitle(agenda?.project ?? String(localized: "Agenda"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if agendas.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Project", selection: Binding(get: { agenda?.projectID }, set: { projectID = $0 })) {
                            ForEach(agendas) { Text($0.project).tag(Optional($0.projectID)) }
                        }
                    } label: {
                        Label("Project", systemImage: "folder")
                    }
                }
            }
        }
    }

    private func board(_ agenda: RemoteAgenda) -> some View {
        let board = agenda.board
        let done = Set(board.items.filter { $0.status == .done }.map(\.id))
        return List {
            Section {
                HStack(spacing: 14) {
                    ForEach([AgendaStatus.todo, .doing, .review, .blocked, .done], id: \.self) { status in
                        VStack(spacing: 2) {
                            Text("\(board.count(status))").font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(AgendaPhoneStyle.color(status))
                            Text(AgendaPhoneStyle.title(status)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if let date = agenda.updatedAt {
                    Text("docs/AGENDA.md · changed \(date, format: .relative(presentation: .named))")
                }
            }
            ForEach(board.columns.filter { !$0.items.isEmpty }, id: \.status) { column in
                Section {
                    if column.status == .done, !showDone {
                        Button("Show \(column.items.count) Done") { showDone = true }
                    } else {
                        ForEach(column.items) { item in row(item, done: done) }
                    }
                } header: {
                    Label("\(AgendaPhoneStyle.title(column.status)) · \(column.items.count)", systemImage: AgendaPhoneStyle.symbol(column.status))
                        .foregroundStyle(AgendaPhoneStyle.color(column.status))
                }
            }
        }
    }

    private func row(_ item: AgendaItem, done: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.id).font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(AgendaPhoneStyle.color(item.status))
                if let track = item.track {
                    Text(track).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 4)
                if item.status == nil { Text(item.statusText).font(.caption2).foregroundStyle(.orange) }
                if let owner = item.owner {
                    Label(owner, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let title = item.title { Text(title).font(.body) }
            if !item.dependsOn.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                    ForEach(item.dependsOn, id: \.self) { dep in
                        Text(dep).font(.caption.monospaced()).strikethrough(done.contains(dep))
                            .foregroundStyle(done.contains(dep) ? Color.secondary : Color.primary)
                    }
                }
            }
            if let evidence = item.evidence {
                Text((try? AttributedString(markdown: evidence)) ?? AttributedString(evidence))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}
