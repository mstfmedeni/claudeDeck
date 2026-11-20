import ClaudeDeckCore
import SwiftUI

/// "Approvals": what sessions wait for the owner to approve (AppModel+Approvals.swift). A card
/// per request, the one expiring first on top; nothing here is modal, and nothing is approved
/// without a click on a card (a purchase only with Buy, here on the Mac).
struct ApprovalsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DecisionsTextSize.key, store: .windowState) private var size = DecisionsTextSize.standard

    var body: some View {
        let pending = model.approvals.pending
        let recent = model.approvals.book.recent
        ScrollView {
            VStack(alignment: .leading, spacing: size) {
                header(pending: pending.count)
                if pending.isEmpty {
                    emptyState
                } else {
                    ForEach(pending) { approval in
                        ApprovalCard(approval: approval, size: size)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    }
                }
                if !recent.isEmpty {
                    Text("Recent").font(.system(size: size * 1.1, weight: .semibold)).padding(.top, 8)
                    VStack(spacing: 6) {
                        ForEach(recent) { ResolvedApprovalRow(resolved: $0, size: size) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: pending.map(\.id))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Approvals").font(.system(size: size * 1.5, weight: .semibold))
                if pending > 0 {
                    Text("\(pending) waiting").font(.system(size: size * 0.95, weight: .semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            Text("A session asked for each of these. Approved, ClaudeDeck runs the action and tells the session; without an answer in time it's refused.")
                .font(.system(size: size * 0.95)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield").font(.system(size: size * 2.3)).foregroundStyle(.tertiary)
            Text("Nothing to approve").font(.system(size: size * 1.1, weight: .semibold))
            Text("ServerPlan actions and domain purchases a session asks for with claudedeck server show up here.")
                .font(.system(size: size * 0.95)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// One waiting approval: who asks, what, the panel's summary, the time left, Refuse and
/// Approve (Buy for a purchase, with the plain warning).
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: OwnerApproval
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.7) {
            HStack(spacing: 6) {
                Image(systemName: approval.isPurchase ? "cart.badge.plus" : "server.rack")
                    .foregroundStyle(approval.isPurchase ? .red : .orange)
                if !approval.project.isEmpty { Text(approval.project).fontWeight(.semibold) }
                if let sessionID = approval.sessionID, model.deck.session(sessionID) != nil {
                    Text("·").foregroundStyle(.tertiary)
                    Button(approval.session) { model.reveal(sessionID); model.tabs.selectSessions() }
                        .buttonStyle(.link)
                        .help("Show this session")
                } else {
                    Text("·").foregroundStyle(.tertiary)
                    Text(approval.session)
                }
                Spacer()
                if approval.neverExpires {
                    Text("No time limit")
                } else {
                    VisibleTimeline(every: 1) { now in
                        let left = max(0, Int(approval.expiresAt.timeIntervalSince(now).rounded(.up)))
                        Group {
                            if left >= 3600 {
                                Text("Refused in \(left / 3600) h \(left % 3600 / 60) min")
                            } else {
                                Text("Refused in \(left / 60):\(String(format: "%02d", left % 60))")
                            }
                        }
                        .monospacedDigit()
                        .foregroundStyle(left <= 60 ? Color.red : Color.secondary)
                    }
                }
            }
            .font(.system(size: size * 0.9))
            .foregroundStyle(.secondary)

            Text(approval.title).font(.system(size: size * 1.25, weight: .semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !approval.summary.isEmpty {
                Text(approval.summary).font(.system(size: size)).textSelection(.enabled)
                    .lineSpacing(size * 0.3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if approval.isPurchase {
                Label("This is a real purchase: it's charged to the Namecheap balance and can't be undone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.95, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(role: .cancel) {
                    model.answerApproval(approval.id, approve: false, from: "mac")
                } label: {
                    Text("Refuse").frame(minWidth: 70)
                }
                .controlSize(.large)
                Button {
                    model.answerApproval(approval.id, approve: true, from: "mac")
                } label: {
                    Text(approval.isPurchase ? String(localized: "Buy") : String(localized: "Approve")).frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(approval.isPurchase ? .red : .accentColor)
                .controlSize(.large)
            }
        }
        .padding(size * 1.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((approval.isPurchase ? Color.red : Color.orange).opacity(0.4)))
    }
}

/// An answered / expired approval: what it was and how it ended.
struct ResolvedApprovalRow: View {
    let resolved: ResolvedApproval
    let size: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: resolved.outcome.isApproved ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(resolved.outcome.isApproved ? Color.green : Color.secondary)
            Text(resolved.approval.title).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(outcomeText).foregroundStyle(.secondary)
            Text(resolved.resolvedAt, style: .time).foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: size * 0.9))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var outcomeText: String {
        switch resolved.outcome {
        case .approved: resolved.from == "phone" ? String(localized: "Approved on the phone") : String(localized: "Approved")
        case .refused: resolved.from == "phone" ? String(localized: "Refused on the phone") : String(localized: "Refused")
        case .expired: String(localized: "No answer, refused")
        case .cancelled: String(localized: "The session stopped waiting")
        }
    }
}

/// The sidebar row above Your Decisions while something waits for approval.
struct PendingApprovalsTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.approvals.pending
        VStack(spacing: 0) {
            Divider()
            Button { model.showApprovals() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.orange)
                    Text("Approvals").sidebarFont(.callout, weight: .semibold)
                    Spacer()
                    Text("\(pending.count)").sidebarFont(.caption, weight: .bold).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(pending.contains(where: \.isPurchase) ? Color.red : Color.orange, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .sidebarRowPadding(7)
            .help(pending.first.map { String(localized: "Waiting: \($0.title)") } ?? "")
        }
        .background(.bar)
    }
}
