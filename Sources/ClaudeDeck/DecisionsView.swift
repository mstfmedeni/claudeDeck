import ClaudeDeckCore
import SwiftUI

/// "Your Decisions": what sessions asked with `claudedeck decide`. They kept working; one tap on
/// an option (or a few words of your own) answers, and the answer goes into the asking session as
/// its next message (AppModel+Decisions.swift).
struct DecisionsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAnswered = true

    var body: some View {
        let pending = model.decisions.pending.reversed() as [OwnerDecision]
        let answered = model.decisions.newestFirst.filter { !$0.isPending }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(pending: pending.count)
                if pending.isEmpty {
                    emptyState
                } else {
                    ForEach(pending) { decision in
                        DecisionCard(decision: decision)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    }
                }
                if !answered.isEmpty {
                    DisclosureGroup(isExpanded: $showAnswered) {
                        VStack(spacing: 6) {
                            ForEach(answered.prefix(50)) { AnsweredDecisionRow(decision: $0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Answered · \(answered.count)").font(.headline)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: pending.map(\.id))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Your Decisions").font(.title2.weight(.semibold))
                if pending > 0 {
                    Text("\(pending) waiting").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            Text("Sessions keep working while these wait. Your answer reaches the session as its next message.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "signpost.right.and.left").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Nothing to decide").font(.headline)
            Text("A session asks with claudedeck decide (Settings › Agents › Command-line tool for sessions).")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// A pending decision: who asks and why, the options with the recommended one first in line, and
/// a field for an answer of one's own.
struct DecisionCard: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision
    @State private var custom = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            origin
            Text(decision.question).font(.title3.weight(.semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let context = decision.context {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(expanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                    if context.count > 320 || context.filter(\.isNewline).count > 4 {
                        Button(expanded ? String(localized: "Less") : String(localized: "More")) { expanded.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            if !decision.options.isEmpty {
                DecisionOptions(decision: decision) { model.answerDecision(decision.id, answer: $0, from: "mac") }
            }
            HStack(spacing: 8) {
                TextField(decision.options.isEmpty ? String(localized: "Your answer") : String(localized: "Or answer in your own words"),
                          text: $custom, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendCustom)
                Button("Send", action: sendCustom)
                    .disabled(Decisions.cleanAnswer(custom) == nil)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func sendCustom() {
        guard Decisions.cleanAnswer(custom) != nil else { return }
        model.answerDecision(decision.id, answer: custom, from: "mac")
        custom = ""
    }

    private var origin: some View {
        HStack(spacing: 6) {
            Image(systemName: "signpost.right.and.left").foregroundStyle(.orange)
            if !decision.project.isEmpty { Text(decision.project).fontWeight(.semibold) }
            if let sessionID = decision.sessionID, model.deck.session(sessionID) != nil {
                Text("·").foregroundStyle(.tertiary)
                Button(decision.session) { model.reveal(sessionID); model.tabs.selectSessions() }
                    .buttonStyle(.link)
                    .help("Show the session that asked")
            } else if !decision.session.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(decision.session).foregroundStyle(.secondary)
            }
            Spacer()
            Text(decision.createdAt, style: .relative).foregroundStyle(.tertiary).monospacedDigit()
            Text(decision.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// The options as buttons; the agent's recommendation is prominent and marked.
struct DecisionOptions: View {
    let decision: OwnerDecision
    let pick: (String) -> Void

    var body: some View {
        // Recommended first: the likely answer is the first one the eye lands on.
        let ordered = decision.options.filter { $0 == decision.recommended } + decision.options.filter { $0 != decision.recommended }
        FlowLayout(spacing: 8) {
            ForEach(ordered, id: \.self) { option in
                if option == decision.recommended {
                    Button { pick(option) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.caption2)
                            Text(option)
                            Text("Recommended").font(.caption2.weight(.semibold)).opacity(0.85)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("The asking session recommends this")
                } else {
                    Button(option) { pick(option) }.buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.large)
    }
}

struct AnsweredDecisionRow: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.question).font(.callout).lineLimit(2).foregroundStyle(.secondary)
                Text(decision.answer ?? "").font(.callout.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text([decision.project, decision.session].filter { !$0.isEmpty }.joined(separator: " · "))
                    if let at = decision.answeredAt {
                        Text("·")
                        Text(at, format: .relative(presentation: .named))
                    }
                    Text("·")
                    Text(decision.answeredFrom == "phone" ? String(localized: "on the phone") : String(localized: "on the Mac"))
                    if decision.delivery == "queued" {
                        Text("·")
                        Text("sent to the session")
                    } else if decision.delivery == "no_session" {
                        Text("·")
                        Text("the session was gone").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Above the sidebar's waiting tray while decisions wait: their count, a click opens the tab.
struct PendingDecisionsTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.decisions.pending
        VStack(spacing: 0) {
            Divider()
            Button { model.showDecisions() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "signpost.right.and.left").foregroundStyle(.orange)
                    Text("Your Decisions").sidebarFont(.callout, weight: .semibold)
                    Spacer()
                    Text("\(pending.count)").sidebarFont(.caption, weight: .bold).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .sidebarRowPadding(7)
            .help(pending.first.map { String(localized: "Latest: \($0.question)") } ?? "")
        }
        .background(.bar)
    }
}

/// Lays its subviews out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
