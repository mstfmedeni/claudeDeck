import ClaudeDeckCore
import SwiftUI

/// The Decisions tab's text size: the − / + in its header and ⌘+ / ⌘- / ⌘0 while the tab is in
/// front (the zoom key monitor in ClaudeDeckApp.swift). Kept per user like the window state.
enum DecisionsTextSize {
    static let key = "decisions.fontSize"
    static let range: ClosedRange<Double> = 11...24
    static let standard: Double = 15

    /// nil resets to the standard size.
    @MainActor static func zoom(by step: Double?) {
        let defaults = UserDefaults.windowState
        let current = defaults.object(forKey: key) as? Double ?? standard
        let next = step.map { current + $0 } ?? standard
        defaults.set(min(max(next, range.lowerBound), range.upperBound), forKey: key)
    }
}

/// "Your Decisions": what sessions asked with `claudedeck decide`. They kept working; one tap on
/// an option (or a few words of your own) answers, and the answer goes into the asking session as
/// its next message (AppModel+Decisions.swift). Remove dismisses one without answering.
struct DecisionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DecisionsTextSize.key, store: .windowState) private var size = DecisionsTextSize.standard
    @State private var showAnswered = true
    @State private var showCancelled = false

    var body: some View {
        let pending = model.decisions.pending.reversed() as [OwnerDecision]
        let answered = model.decisions.newestFirst.filter(\.isAnswered)
        let cancelled = model.decisions.newestFirst.filter(\.isCancelled)
        ScrollView {
            VStack(alignment: .leading, spacing: size) {
                header(pending: pending.count)
                if pending.isEmpty {
                    emptyState
                } else {
                    ForEach(pending) { decision in
                        DecisionCard(decision: decision, size: size)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    }
                }
                if !answered.isEmpty {
                    DisclosureGroup(isExpanded: $showAnswered) {
                        VStack(spacing: 6) {
                            ForEach(answered.prefix(50)) { AnsweredDecisionRow(decision: $0, size: size) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Answered · \(answered.count)").font(.system(size: size * 1.1, weight: .semibold))
                    }
                    .padding(.top, 8)
                }
                if !cancelled.isEmpty {
                    DisclosureGroup(isExpanded: $showCancelled) {
                        VStack(spacing: 6) {
                            ForEach(cancelled.prefix(50)) { AnsweredDecisionRow(decision: $0, size: size) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Cancelled · \(cancelled.count)").font(.system(size: size * 1.1, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: pending.map(\.id))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Your Decisions").font(.system(size: size * 1.5, weight: .semibold))
                if pending > 0 {
                    Text("\(pending) waiting").font(.system(size: size * 0.95, weight: .semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                textSizeControl
            }
            Text("Sessions keep working while these wait. Your answer reaches the session as its next message.")
                .font(.system(size: size * 0.95)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// − A + : the text size of the whole tab (also ⌘+ / ⌘- / ⌘0).
    private var textSizeControl: some View {
        HStack(spacing: 2) {
            Button { DecisionsTextSize.zoom(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                .disabled(size <= DecisionsTextSize.range.lowerBound)
                .help("Smaller Text (⌘-)")
            Button { DecisionsTextSize.zoom(by: nil) } label: {
                Text("\(Int(size)) pt").font(.caption.monospacedDigit()).frame(minWidth: 38)
            }
            .help("Actual Size (⌘0)")
            Button { DecisionsTextSize.zoom(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                .disabled(size >= DecisionsTextSize.range.upperBound)
                .help("Larger Text (⌘+)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "signpost.right.and.left").font(.system(size: size * 2.3)).foregroundStyle(.tertiary)
            Text("Nothing to decide").font(.system(size: size * 1.1, weight: .semibold))
            Text("A session asks with claudedeck decide (Settings › Agents › Command-line tool for sessions).")
                .font(.system(size: size * 0.95)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// A pending decision: who asks and why, the options with the recommended one first in line, and
/// a field for an answer of one's own. Remove (the button or the context menu) dismisses it.
struct DecisionCard: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision
    let size: Double
    @State private var custom = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.75) {
            origin
            Text(decision.question).font(.system(size: size * 1.3, weight: .semibold)).textSelection(.enabled)
                .lineSpacing(size * 0.2)
                .fixedSize(horizontal: false, vertical: true)
            if let context = decision.context {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context).font(.system(size: size)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineSpacing(size * 0.35)
                        .lineLimit(expanded ? nil : 8)
                        .fixedSize(horizontal: false, vertical: true)
                    if context.count > 600 || context.filter(\.isNewline).count > 7 {
                        Button(expanded ? String(localized: "Less") : String(localized: "More")) { expanded.toggle() }
                            .buttonStyle(.link).font(.system(size: size * 0.85))
                    }
                }
            }
            if !decision.options.isEmpty {
                DecisionOptions(decision: decision, size: size) { model.answerDecision(decision.id, answer: $0, from: "mac") }
            }
            HStack(spacing: 8) {
                TextField(decision.options.isEmpty ? String(localized: "Your answer") : String(localized: "Or answer in your own words"),
                          text: $custom, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: size))
                    .lineLimit(1...6)
                    .onSubmit(sendCustom)
                Button("Send", action: sendCustom)
                    .font(.system(size: size))
                    .disabled(Decisions.cleanAnswer(custom) == nil)
            }
        }
        .padding(size * 1.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        .contextMenu {
            Button("Remove", role: .destructive, action: dismiss)
        }
    }

    private func sendCustom() {
        guard Decisions.cleanAnswer(custom) != nil else { return }
        model.answerDecision(decision.id, answer: custom, from: "mac")
        custom = ""
    }

    private func dismiss() {
        model.dismissDecision(decision.id, from: "mac")
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
            Text(decision.id).font(.system(size: size * 0.8, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            Button(action: dismiss) {
                Label("Remove", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this decision without answering; the session is told")
        }
        .font(.system(size: size * 0.9))
    }
}

/// The options as buttons; the agent's recommendation is prominent and marked.
struct DecisionOptions: View {
    let decision: OwnerDecision
    let size: Double
    let pick: (String) -> Void

    var body: some View {
        // Recommended first: the likely answer is the first one the eye lands on.
        let ordered = decision.options.filter { $0 == decision.recommended } + decision.options.filter { $0 != decision.recommended }
        FlowLayout(spacing: 8) {
            ForEach(ordered, id: \.self) { option in
                if option == decision.recommended {
                    Button { pick(option) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.system(size: size * 0.75))
                            Text(option)
                            Text("Recommended").font(.system(size: size * 0.75, weight: .semibold)).opacity(0.85)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("The asking session recommends this")
                } else {
                    Button { pick(option) } label: { Text(option).padding(.vertical, 2) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .font(.system(size: size))
        .controlSize(.large)
    }
}

/// An answered or cancelled decision in the history.
struct AnsweredDecisionRow: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision
    let size: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decision.isCancelled ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(decision.isCancelled ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.question).font(.system(size: size * 0.95)).lineLimit(2).foregroundStyle(.secondary)
                if decision.isCancelled {
                    Text(cancelText).font(.system(size: size * 0.95)).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(decision.answer ?? "").font(.system(size: size * 0.95, weight: .semibold)).textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(decision.origin)
                    if let at = decision.answeredAt ?? decision.cancelledAt {
                        Text("·")
                        Text(at, format: .relative(presentation: .named))
                    }
                    if decision.isAnswered {
                        Text("·")
                        Text(decision.answeredFrom == "phone" ? String(localized: "on the phone") : String(localized: "on the Mac"))
                    }
                    if decision.delivery == "queued" {
                        Text("·")
                        Text("sent to the session")
                    } else if decision.delivery == "terminal" {
                        Text("·")
                        Text("kept for claudedeck decision get")
                    } else if decision.delivery == "no_session" {
                        Text("·")
                        Text("the session was gone").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: size * 0.8)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cancelText: String {
        let reason = decision.cancelReason ?? ""
        if reason == Decisions.ownerDismissed { return String(localized: "Removed without an answer") }
        return reason.isEmpty ? String(localized: "Cancelled by the session") : String(localized: "Cancelled: \(reason)")
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
