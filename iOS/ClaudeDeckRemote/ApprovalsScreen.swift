import SwiftUI

// Approvals a session on the Mac waits on (ServerPlan gates, domain purchases), from a Mac with
// `Feature.approvals`, and the week's resolved ones (`Feature.approvalHistory`). The phone mostly
// approves or refuses them (`phoneMayApprove` / `phoneMayRefuse`): a purchase and a refusal each
// ask once more before they're sent. A refused or expired one the Mac still keeps the call of
// (24 h, `ResolvedApproval.reapprovableUntil`) can be approved anyway (`Feature.reapproveApproval`).

extension RemoteStore {
    /// Pending approvals, the one expiring first on top (nil: the Mac doesn't send them).
    var approvals: [OwnerApproval]? {
        snapshot?.supports(RemoteSnapshot.Feature.approvals) == true ? snapshot?.approvals ?? [] : nil
    }

    /// Approvals resolved in the last 7 days, newest first (nil: the Mac doesn't send them).
    var approvalHistory: [ResolvedApproval]? {
        snapshot?.supports(RemoteSnapshot.Feature.approvalHistory) == true ? snapshot?.approvalHistory ?? [] : nil
    }

    /// The owner's answer from the phone; the Mac takes only what the approval allows.
    @discardableResult
    func answerApproval(_ id: String, approve: Bool) -> Bool {
        guard snapshot?.supports(RemoteSnapshot.Feature.approvals) == true,
              let approval = approvals?.first(where: { $0.id == id }),
              approve ? approval.phoneMayApprove : approval.phoneMayRefuse else { return false }
        return send(.answerApproval(id: id, approve: approve))
    }

    /// Whether "Approve anyway" is offered for a resolved one: the Mac takes it, still keeps its
    /// call, and the phone may approve it.
    func mayReapprove(_ resolved: ResolvedApproval, now: Date = .now) -> Bool {
        guard snapshot?.supports(RemoteSnapshot.Feature.reapproveApproval) == true,
              let until = resolved.reapprovableUntil else { return false }
        return now < until && resolved.approval.phoneMayApprove
    }

    /// "Approve anyway": the Mac runs the call it kept (it checks the window again).
    @discardableResult
    func reapproveApproval(_ resolved: ResolvedApproval) -> Bool {
        guard mayReapprove(resolved) else { return false }
        return send(.reapproveApproval(id: resolved.id))
    }
}

/// History split by day for the Approvals and Decisions screens: the last week, newest day first.
enum HistoryDays {
    static let window: TimeInterval = 7 * 24 * 3600

    static func group<Item>(_ items: [Item], now: Date = .now, calendar: Calendar = .current,
                            date: (Item) -> Date) -> [(day: Date, items: [Item])] {
        let recent = items.filter { now.timeIntervalSince(date($0)) <= window }
            .sorted { date($0) > date($1) }
        let days = Dictionary(grouping: recent) { calendar.startOfDay(for: date($0)) }
        return days.keys.sorted(by: >).map { (day: $0, items: days[$0] ?? []) }
    }
}

/// A day's section header: Today, Yesterday, else the weekday and date.
struct HistoryDayHeader: View {
    let day: Date

    var body: some View {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            Text("Today")
        } else if calendar.isDateInYesterday(day) {
            Text("Yesterday")
        } else {
            Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
        }
    }
}

/// The session list's row (always, from a Mac that sends approvals): the pending count, or "None waiting".
struct ApprovalsRow: View {
    let approvals: [OwnerApproval]

    var body: some View {
        NavigationLink(value: MacScreen.approvals) {
            Label {
                HStack {
                    Text("Approvals").listFont(.body)
                    Spacer(minLength: 4)
                    if approvals.isEmpty {
                        Text("None waiting").listFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(approvals.count)").listFont(.caption, weight: .bold, monospacedDigit: true)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(approvals.contains(where: \.isPurchase) ? Color.red : Color.orange, in: Capsule())
                    }
                }
            } icon: {
                Image(systemName: "checkmark.shield").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(approvals.isEmpty ? Color.secondary : Color.orange)
            }
        }
        .tag(MacScreen.approvals)
    }
}

/// Pending approvals first, then the week's resolved ones by day.
struct ApprovalsScreen: View {
    @Environment(RemoteStore.self) private var store
    @State private var sent: Set<String> = []

    var body: some View {
        let pending = store.approvals ?? []
        let pendingIDs = Set(pending.map(\.id))
        // One that just resolved may be in both lists for a snapshot: pending wins.
        let history = HistoryDays.group((store.approvalHistory ?? []).filter { !pendingIDs.contains($0.id) }, date: \.resolvedAt)
        Group {
            if pending.isEmpty, history.isEmpty {
                ContentUnavailableView("Nothing to Approve", systemImage: "checkmark.shield",
                                       description: Text("ServerPlan actions and domain purchases a session on the Mac asks for show up here."))
            } else {
                List {
                    if !pending.isEmpty {
                        Section {
                            ForEach(pending) { approval in
                                ApprovalCardPhone(approval: approval, sending: sent.contains(approval.id)) { approve in
                                    if store.answerApproval(approval.id, approve: approve) { sent.insert(approval.id) }
                                }
                            }
                        } header: {
                            Text("Waiting · \(pending.count)")
                        } footer: {
                            if !pending.allSatisfy(\.neverExpires) {
                                Text("Without an answer in time it's refused.")
                            }
                        }
                    }
                    ForEach(history, id: \.day) { group in
                        Section {
                            ForEach(group.items) { resolved in
                                ResolvedApprovalPhoneRow(resolved: resolved, mayReapprove: store.mayReapprove(resolved),
                                                         sending: sent.contains(resolved.id)) {
                                    if store.reapproveApproval(resolved) { sent.insert(resolved.id) }
                                }
                            }
                        } header: {
                            HistoryDayHeader(day: group.day)
                        }
                    }
                }
            }
        }
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
        // A sent answer spins until its card leaves Waiting, or its history row stops offering
        // "Approve anyway" (it's approved now).
        .onChange(of: pending.map(\.id) + (store.approvalHistory ?? []).filter { store.mayReapprove($0) }.map(\.id)) { _, ids in
            sent = sent.filter { ids.contains($0) }
        }
        .disabled(store.connection != .connected)
    }
}

/// Time left on a pending approval: "23 h left" above an hour, a minutes:seconds countdown under
/// it, "No limit" for one that never expires.
struct ApprovalTimeLeft: View {
    let approval: OwnerApproval

    var body: some View {
        if approval.neverExpires {
            Text("No limit")
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(approval.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                if left >= 3600 {
                    Text("\(left / 3600) h left").monospacedDigit()
                } else {
                    Text("\(left / 60):\(String(format: "%02d", left % 60))").monospacedDigit()
                        .foregroundStyle(left <= 30 ? Color.red : Color.secondary)
                }
            }
        }
    }
}

struct ApprovalCardPhone: View {
    let approval: OwnerApproval
    let sending: Bool
    let answer: (Bool) -> Void
    /// Refusing asks once: a tap meant for Approve shouldn't refuse it for good.
    @State private var confirmRefuse = false
    /// A purchase is real money: approving it asks once more.
    @State private var confirmPurchase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: approval.isPurchase ? "cart.badge.plus" : "server.rack")
                    .foregroundStyle(approval.isPurchase ? .red : .orange)
                Text([approval.project, approval.session].filter { !$0.isEmpty }.joined(separator: " · "))
                Spacer()
                ApprovalTimeLeft(approval: approval)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(approval.title).font(.headline)
            if !approval.summary.isEmpty {
                Text(approval.summary).font(.subheadline)
            }
            if approval.isPurchase {
                Text("This is a real purchase: it's charged to the Namecheap balance and can't be undone.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.red)
            }
            HStack {
                if !approval.phoneMayApprove {
                    Label("Approve on the Mac", systemImage: "desktopcomputer")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if sending {
                    ProgressView()
                } else {
                    if approval.phoneMayRefuse {
                        Button("Refuse", role: .destructive) { confirmRefuse = true }
                            .buttonStyle(.bordered)
                            .confirmationDialog("Refuse this request?", isPresented: $confirmRefuse, titleVisibility: .visible) {
                                Button("Refuse", role: .destructive) { answer(false) }
                            } message: {
                                Text("The session is told no; it would have to ask again.")
                            }
                    }
                    if approval.phoneMayApprove {
                        Button(approval.isPurchase ? String(localized: "Buy") : String(localized: "Approve")) {
                            if approval.isPurchase { confirmPurchase = true } else { answer(true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog("Make this purchase?", isPresented: $confirmPurchase, titleVisibility: .visible) {
                            Button("Buy") { answer(true) }
                        } message: {
                            Text(approval.summary.isEmpty ? approval.title : approval.summary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A resolved approval: how it ended and when, what it was, who asked, and what the action did;
/// "Approve anyway" while the Mac still keeps a refused or expired one's call (asks once more).
struct ResolvedApprovalPhoneRow: View {
    let resolved: ResolvedApproval
    var mayReapprove = false
    var sending = false
    var reapprove: () -> Void = {}
    @State private var confirm = false

    var body: some View {
        let approval = resolved.approval
        let origin = [approval.project, approval.session].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(outcomeText).fontWeight(.semibold).foregroundStyle(color)
                Spacer(minLength: 4)
                Text(resolved.resolvedAt, style: .time).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.caption)
            Text(approval.title).font(.subheadline).lineLimit(3)
            if !origin.isEmpty {
                Label(origin, systemImage: approval.isPurchase ? "cart" : "server.rack")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let result = resolved.result, !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if mayReapprove || sending {
                HStack {
                    if let until = resolved.reapprovableUntil {
                        Text("Changeable until \(until.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if sending {
                        ProgressView()
                    } else {
                        Button(approval.isPurchase ? String(localized: "Buy anyway") : String(localized: "Approve anyway")) { confirm = true }
                            .buttonStyle(.bordered)
                            .tint(approval.isPurchase ? .red : .accentColor)
                            .confirmationDialog(approval.isPurchase ? String(localized: "Buy anyway?") : String(localized: "Approve anyway?"),
                                                isPresented: $confirm, titleVisibility: .visible) {
                                Button(approval.isPurchase ? String(localized: "Buy") : String(localized: "Approve and Run"),
                                       role: approval.isPurchase ? .destructive : nil) { reapprove() }
                            } message: {
                                Text(confirmMessage)
                            }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var confirmMessage: String {
        let approval = resolved.approval
        let run = String(localized: "ClaudeDeck runs “\(approval.title)” now, as the session asked, and tells the session the result.")
        guard approval.isPurchase else { return run }
        let summary = approval.summary.isEmpty ? "" : approval.summary + "\n\n"
        return summary + run + "\n\n"
            + String(localized: "This is a real purchase: it's charged to the Namecheap balance and can't be undone.")
    }

    private var outcomeText: String {
        let phone = resolved.from == "phone"
        switch resolved.outcome {
        case .approved where resolved.changedFrom != nil:
            return phone ? String(localized: "Approved anyway on the phone") : String(localized: "Approved anyway")
        case .approved: return phone ? String(localized: "Approved on the phone") : String(localized: "Approved")
        case .refused: return phone ? String(localized: "Refused on the phone") : String(localized: "Refused")
        case .expired: return String(localized: "No answer, refused")
        case .cancelled: return String(localized: "The session stopped waiting")
        }
    }

    private var symbol: String {
        switch resolved.outcome {
        case .approved: "checkmark.circle.fill"
        case .refused: "xmark.circle.fill"
        case .expired: "clock.badge.xmark"
        case .cancelled: "minus.circle"
        }
    }

    private var color: Color {
        switch resolved.outcome {
        case .approved: .green
        case .refused: .red
        case .expired, .cancelled: .secondary
        }
    }
}
