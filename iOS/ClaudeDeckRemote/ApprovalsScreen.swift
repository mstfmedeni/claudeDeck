import SwiftUI

// Approvals a session on the Mac waits on (ServerPlan gates, domain purchases), from a Mac with
// `Feature.approvals`. The phone mostly shows them: a purchase is approved on the Mac only, and so
// is every ServerPlan gate for now (`phoneMayApprove`); what may be refused from here has a Refuse
// button (refusing never changes anything on the servers).

extension RemoteStore {
    /// Pending approvals, the one expiring first on top (nil: the Mac doesn't send them).
    var approvals: [OwnerApproval]? {
        snapshot?.supports(RemoteSnapshot.Feature.approvals) == true ? snapshot?.approvals ?? [] : nil
    }

    /// The owner's answer from the phone; the Mac takes only what the approval allows.
    @discardableResult
    func answerApproval(_ id: String, approve: Bool) -> Bool {
        guard snapshot?.supports(RemoteSnapshot.Feature.approvals) == true,
              let approval = approvals?.first(where: { $0.id == id }),
              approve ? approval.phoneMayApprove : approval.phoneMayRefuse else { return false }
        return send(.answerApproval(id: id, approve: approve))
    }
}

/// The session list's row while something waits for approval on the Mac.
struct ApprovalsRow: View {
    let approvals: [OwnerApproval]

    var body: some View {
        NavigationLink(value: MacScreen.approvals) {
            Label {
                HStack {
                    Text("Approvals").listFont(.body)
                    Spacer(minLength: 4)
                    Text("\(approvals.count)").listFont(.caption, weight: .bold, monospacedDigit: true)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(approvals.contains(where: \.isPurchase) ? Color.red : Color.orange, in: Capsule())
                }
            } icon: {
                Image(systemName: "checkmark.shield").symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
            }
        }
        .tag(MacScreen.approvals)
    }
}

struct ApprovalsScreen: View {
    @Environment(RemoteStore.self) private var store
    @State private var sent: Set<String> = []

    var body: some View {
        let pending = store.approvals ?? []
        Group {
            if pending.isEmpty {
                ContentUnavailableView("Nothing to Approve", systemImage: "checkmark.shield",
                                       description: Text("ServerPlan actions and domain purchases a session on the Mac asks for show up here."))
            } else {
                List {
                    Section {
                        ForEach(pending) { approval in
                            ApprovalCardPhone(approval: approval, sending: sent.contains(approval.id)) { approve in
                                if store.answerApproval(approval.id, approve: approve) { sent.insert(approval.id) }
                            }
                        }
                    } footer: {
                        Text("Without an answer in 2 minutes it's refused.")
                    }
                }
            }
        }
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pending.map(\.id)) { _, ids in sent = sent.filter { ids.contains($0) } }
        .disabled(store.connection != .connected)
    }
}

struct ApprovalCardPhone: View {
    let approval: OwnerApproval
    let sending: Bool
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: approval.isPurchase ? "cart.badge.plus" : "server.rack")
                    .foregroundStyle(approval.isPurchase ? .red : .orange)
                Text([approval.project, approval.session].filter { !$0.isEmpty }.joined(separator: " · "))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(approval.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(left / 60):\(String(format: "%02d", left % 60))").monospacedDigit()
                        .foregroundStyle(left <= 30 ? Color.red : Color.secondary)
                }
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
                        Button("Refuse", role: .destructive) { answer(false) }
                            .buttonStyle(.bordered)
                    }
                    if approval.phoneMayApprove {
                        Button("Approve") { answer(true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
