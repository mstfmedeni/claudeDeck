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

/// "Your Decisions": what sessions asked with `claudedeck decide`. They kept working; a double
/// click on an option (or a few words of your own and Send) answers, and the answer goes into the
/// asking session as its next message (AppModel+Decisions.swift). Remove dismisses one without
/// answering; the recent answers can still be changed.
struct DecisionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DecisionsTextSize.key, store: .windowState) private var size = DecisionsTextSize.standard
    @State private var showOtherToday = false
    @State private var showCancelled = false

    var body: some View {
        let pending = model.decisions.pending.reversed() as [OwnerDecision]
        let all = model.decisions.decisions
        let (recent, otherToday) = DecisionSections.answered(all)
        let cancelled = DecisionSections.cancelledToday(all)
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
                if !recent.isEmpty {
                    Text("Recently Answered").font(.system(size: size * 1.1, weight: .semibold)).padding(.top, 8)
                    VStack(spacing: 8) {
                        ForEach(recent) { AnsweredDecisionRow(decision: $0, size: size) }
                    }
                }
                if !otherToday.isEmpty {
                    DisclosureGroup(isExpanded: $showOtherToday) {
                        VStack(spacing: 8) {
                            ForEach(otherToday) { AnsweredDecisionRow(decision: $0, size: size) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Other decisions today · \(otherToday.count)").font(.system(size: size * 1.05, weight: .semibold))
                    }
                }
                if !cancelled.isEmpty {
                    DisclosureGroup(isExpanded: $showCancelled) {
                        VStack(spacing: 6) {
                            ForEach(cancelled) { CancelledDecisionRow(decision: $0, size: size) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Cancelled · \(cancelled.count)").font(.system(size: size * 1.05, weight: .semibold))
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

    /// − 15 pt + : the text size of the whole tab (also ⌘+ / ⌘- / ⌘0).
    private var textSizeControl: some View {
        HStack(spacing: 2) {
            Button { DecisionsTextSize.zoom(by: -1) } label: { Image(systemName: "minus") }
                .disabled(size <= DecisionsTextSize.range.lowerBound)
                .help("Smaller Text (⌘-)")
            Button { DecisionsTextSize.zoom(by: nil) } label: {
                Text("\(Int(size)) pt").font(.caption.monospacedDigit()).frame(minWidth: 38)
            }
            .help("Actual Size (⌘0)")
            Button { DecisionsTextSize.zoom(by: 1) } label: { Image(systemName: "plus") }
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
            DecisionOrigin(decision: decision, size: size) {
                Button(action: dismiss) {
                    Label("Remove", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this decision without answering; the session is told")
            }
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
                DecisionChoices(decision: decision, size: size, current: nil) { model.answerDecision(decision.id, answer: $0, from: "mac") }
            }
            DecisionTextAnswer(size: size,
                               placeholder: decision.options.isEmpty ? String(localized: "Your answer") : String(localized: "Or answer in your own words")) {
                model.answerDecision(decision.id, answer: $0, from: "mac")
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

    private func dismiss() {
        model.dismissDecision(decision.id, from: "mac")
    }
}

/// Project · session (a link to it while it's in the deck) · age · id, and `trailing`.
struct DecisionOrigin<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision
    let size: Double
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "signpost.right.and.left").foregroundStyle(.orange)
            if !decision.project.isEmpty { Text(decision.project).fontWeight(.semibold) }
            if let sessionID = decision.sessionID, model.deck.session(sessionID) != nil {
                Text("·").foregroundStyle(.tertiary)
                Button(decision.session) { model.reveal(sessionID); model.tabs.selectSessions() }
                    .buttonStyle(.link)
                    .help("Show the session that asked")
            } else if !decision.session.isEmpty, decision.session != decision.project {
                Text("·").foregroundStyle(.tertiary)
                Text(decision.session).foregroundStyle(.secondary)
            }
            Spacer()
            Text(decision.createdAt, style: .relative).foregroundStyle(.tertiary).monospacedDigit()
            Text(decision.id).font(.system(size: size * 0.8, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            trailing
        }
        .font(.system(size: size * 0.9))
    }
}

/// The options as chips: a click selects one, a double click confirms it (a stray click never
/// answers). The agent's recommendation comes first and is marked; `current` (an answered
/// decision's answer) is checked.
struct DecisionChoices: View {
    let decision: OwnerDecision
    let size: Double
    let current: String?
    let confirm: (String) -> Void
    @State private var selected: String?

    var body: some View {
        // Recommended first: the likely answer is the first one the eye lands on.
        let ordered = decision.options.filter { $0 == decision.recommended } + decision.options.filter { $0 != decision.recommended }
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                ForEach(ordered, id: \.self) { option in chip(option) }
            }
            if let selected, selected != current {
                Label("Double-click to confirm", systemImage: "hand.tap")
                    .font(.system(size: size * 0.85)).foregroundStyle(.secondary)
                    .help(selected)
            }
        }
        .font(.system(size: size))
    }

    private func chip(_ option: String) -> some View {
        let isSelected = selected == option
        let isCurrent = current == option
        let isRecommended = option == decision.recommended
        return HStack(spacing: 5) {
            if isCurrent {
                Image(systemName: "checkmark").font(.system(size: size * 0.75, weight: .bold))
            } else if isRecommended {
                Image(systemName: "star.fill").font(.system(size: size * 0.7))
            }
            Text(option)
            if isRecommended, current == nil {
                Text("Recommended").font(.system(size: size * 0.72, weight: .semibold)).opacity(0.8)
            }
        }
        .padding(.horizontal, size * 0.8)
        .padding(.vertical, size * 0.45)
        .foregroundStyle(isSelected ? Color.white : (isCurrent ? Color.green : Color.primary))
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(isRecommended && current == nil ? 0.16 : 0.09),
                    in: RoundedRectangle(cornerRadius: size * 0.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.5, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : (isCurrent ? Color.green.opacity(0.6)
                : isRecommended ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)), lineWidth: isRecommended || isCurrent ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard option != current else { return }
            selected = nil
            confirm(option)
        }
        .simultaneousGesture(TapGesture().onEnded { selected = option })
        .help(isRecommended ? String(localized: "The asking session recommends this") : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if option != current { confirm(option) } }
    }
}

/// An answer in one's own words; only the Send button sends it (Return doesn't).
struct DecisionTextAnswer: View {
    let size: Double
    let placeholder: String
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: size))
                .lineLimit(1...6)
            Button("Send") {
                guard Decisions.cleanAnswer(text) != nil else { return }
                send(text)
                text = ""
            }
            .font(.system(size: size))
            .disabled(Decisions.cleanAnswer(text) == nil)
        }
    }
}

/// An answered decision, muted: the question, the answer and when. Change… shows the options
/// (double click) and a field to answer anew; the session gets the new answer as a message.
struct AnsweredDecisionRow: View {
    @Environment(AppModel.self) private var model
    let decision: OwnerDecision
    let size: Double
    @State private var changing = false

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.5) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(decision.question).font(.system(size: size * 0.95)).foregroundStyle(.secondary)
                        .lineLimit(changing ? nil : 2).textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(decision.answer ?? "").font(.system(size: size, weight: .semibold)).textSelection(.enabled)
                        if decision.isChanged {
                            Text("changed").font(.system(size: size * 0.75, weight: .semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .help(decision.answerHistory.map(\.answer).joined(separator: " → "))
                        }
                    }
                    details
                }
                Spacer()
                Button(changing ? String(localized: "Done") : String(localized: "Change…")) { changing.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: size * 0.85))
            }
            if changing {
                VStack(alignment: .leading, spacing: size * 0.5) {
                    if !decision.options.isEmpty {
                        DecisionChoices(decision: decision, size: size * 0.95, current: decision.answer) { change($0) }
                    }
                    DecisionTextAnswer(size: size * 0.95, placeholder: String(localized: "Change in your own words")) { change($0) }
                }
                .padding(.leading, size * 1.6)
            }
        }
        .padding(size * 0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(changing ? 1 : 0.72)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func change(_ answer: String) {
        model.changeDecisionAnswer(decision.id, answer: answer, from: "mac")
        changing = false
    }

    private var details: some View {
        HStack(spacing: 6) {
            Text(decision.origin)
            if let at = decision.answeredAt {
                Text("·")
                Text(at, format: .relative(presentation: .named))
            }
            Text("·")
            Text(decision.answeredFrom == "phone" ? String(localized: "on the phone") : String(localized: "on the Mac"))
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
}

/// A cancelled or removed decision, in today's collapsed list.
struct CancelledDecisionRow: View {
    let decision: OwnerDecision
    let size: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(decision.question).font(.system(size: size * 0.95)).lineLimit(2).foregroundStyle(.secondary)
                Text(reason).font(.system(size: size * 0.9)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(decision.origin)
                    if let at = decision.cancelledAt {
                        Text("·")
                        Text(at, format: .relative(presentation: .named))
                    }
                }
                .font(.system(size: size * 0.8)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(size * 0.6)
        .opacity(0.72)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var reason: String {
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
                    // Nothing waiting: a plain row, no orange and no "0" badge.
                    Image(systemName: "signpost.right.and.left").foregroundStyle(pending.isEmpty ? Color.secondary : Color.orange)
                    Text("Your Decisions").sidebarFont(.callout, weight: .semibold)
                    Spacer()
                    if !pending.isEmpty {
                        Text("\(pending.count)").sidebarFont(.caption, weight: .bold).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
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
