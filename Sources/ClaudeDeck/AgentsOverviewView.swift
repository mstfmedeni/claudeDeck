import ClaudeDeckCore
import SwiftUI

// The Agents tab (Window › Agents, the sidebar's Agents row): every agent tree — sessions that
// sessions started with `claudedeck new` — grouped by project, so it's clear which agents run
// where and who started them. Computed from the model's observed state; no polling of its own.

extension AppModel {
    /// The agent trees by project, pinned projects first (like the sidebar).
    var agentTreeGroups: [AgentTree.Group] {
        let members = deck.sessions.filter { $0.kind == .claude }
            .map { AgentTree.Member(id: $0.id, group: $0.projectID.uuidString, startedBy: $0.startedBy) }
        let order = (deck.projects.filter(\.pinned) + deck.projects.filter { !$0.pinned }).map(\.id.uuidString)
        return AgentTree.build(members, groupOrder: order)
    }
}

struct AgentsOverviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("agentsOverview.filter", store: .windowState) private var filter: SidebarFilter = .all

    var body: some View {
        let groups = model.agentTreeGroups
        VStack(spacing: 0) {
            AgentsOverviewHeader(filter: $filter)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Agent Sessions", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Sessions start other sessions with `claudedeck new`. They show up here by project, under the session that started them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sections = groups.compactMap { group -> (AgentTree.Group, [AgentTree.Row])? in
                    let rows = group.rows { id in
                        guard let session = model.deck.session(id) else { return false }
                        return filter.matches(model.sidebarSession(session))
                    }
                    return rows.isEmpty ? nil : (group, rows)
                }
                if sections.isEmpty {
                    ContentUnavailableView(filter == .waiting ? "Nothing is waiting for you" : "No agent is working",
                                           systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                            ForEach(sections, id: \.0.key) { group, rows in
                                AgentsProjectSection(group: group, rows: rows)
                            }
                        }
                        .padding(.horizontal, 24).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Running agents out of the cap, queued starts, pending decisions, and the filter.
private struct AgentsOverviewHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: SidebarFilter

    var body: some View {
        let running = model.cliRunningStarted
        let cap = model.deck.settings.maxStartedSessions
        let queued = model.deck.cliQueue.filter { $0.status == .queued }.count
        let decisions = model.decisions.pendingCount
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
            Text("Agents").font(.title3.weight(.semibold))
            SummaryChip(systemImage: "bolt.fill", text: String(localized: "\(running) of \(cap) running"),
                        tint: running >= cap ? .orange : .green)
                .help("Sessions started by sessions that are running, out of the cap in Settings › Agents")
            if queued > 0 {
                SummaryChip(systemImage: "hourglass", text: String(localized: "\(queued) queued"), tint: .blue)
                    .help("Starts waiting for a free slot under the cap")
            }
            if decisions > 0 {
                Button { model.showDecisions() } label: {
                    SummaryChip(systemImage: "signpost.right.and.left", text: String(localized: "\(decisions) decisions"), tint: .orange)
                }
                .buttonStyle(.plain)
                .help("Decisions your sessions left for you")
            }
            Spacer(minLength: 8)
            Picker("Show", selection: $filter) {
                Text("All").tag(SidebarFilter.all)
                Text("Working").tag(SidebarFilter.working)
                Text("Waiting").tag(SidebarFilter.waiting)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct SummaryChip: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// A project's header (its sidebar icon and group color) and its tree.
private struct AgentsProjectSection: View {
    @Environment(AppModel.self) private var model
    let group: AgentTree.Group
    let rows: [AgentTree.Row]

    var body: some View {
        let project = UUID(uuidString: group.key).flatMap { model.deck.project($0) }
        let deckGroup = project?.groupID.flatMap { id in model.deck.groups.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: project?.pinned == true ? "pin.fill" : "folder")
                    .foregroundStyle(deckGroup.map { GroupPalette.color($0.colorIndex) } ?? .secondary)
                    .frame(width: 16)
                Text(project?.name ?? String(localized: "Removed project")).font(.headline).lineLimit(1)
                if let deckGroup {
                    Text(deckGroup.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(group.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .help(project?.path ?? "")
            VStack(spacing: 2) {
                ForEach(rows) { AgentOverviewRow(row: $0) }
            }
        }
    }
}

/// One session: status, launch options, account, uptime, simulators, decisions, queued starts.
private struct AgentOverviewRow: View {
    @Environment(AppModel.self) private var model
    let row: AgentTree.Row
    @State private var hovering = false

    var body: some View {
        if let session = model.deck.session(row.id) {
            content(session)
        }
    }

    private func content(_ session: DeckSession) -> some View {
        let status = model.status(of: session.id)
        let unseen = model.isUnseenIdle(session.id)
        let state = model.cliState(session)
        let selected = model.selectedSessionID == session.id
        return HStack(alignment: .center, spacing: 8) {
            if row.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(row.depth - 1) * 22)
                    .frame(width: CGFloat(row.depth - 1) * 22 + 16, alignment: .trailing)
            }
            StatusDot(display: status.display, unseen: unseen)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.name).fontWeight(.semibold).lineLimit(1)
                    StarterBadge(node: row.node)
                    ForEach(row.node.crossChildren, id: \.group) { cross in
                        CrossChildrenBadge(cross: cross)
                    }
                }
                HStack(spacing: 6) {
                    if state == "limit_reached" {
                        TextPill(text: String(localized: "Limit reached"), tint: .orange)
                    } else if state == "switching_account" {
                        TextPill(text: String(localized: "Switching account"), tint: .blue)
                    } else {
                        StatusPill(display: status.display, unseen: unseen)
                    }
                    LaunchOptionsLine(session: session)
                    if let detail = status.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 8)
            AgentCounters(session: session)
            AgentTime(session: session, updatedAt: status.updatedAt)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14)
                      : status.display.isBlocked ? StatusStyle.blocked.opacity(0.08)
                      : hovering ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .opacity(row.matches ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.revealInSidebar(session.id) }
        .contextMenu {
            Button("Show") { model.revealInSidebar(session.id) }
            Divider()
            SessionMenu(session: session)
        }
        .help(session.workingDirectory ?? model.deck.project(session.projectID)?.path ?? "")
    }
}

/// "← payments-api · lead" for a lead started from another project; "← ended" when its
/// starter is gone.
private struct StarterBadge: View {
    @Environment(AppModel.self) private var model
    let node: AgentTree.Node

    var body: some View {
        if let starterID = node.crossStarter, let starter = model.deck.session(starterID) {
            let project = model.deck.project(starter.projectID)?.name ?? ""
            Button { model.revealInSidebar(starterID) } label: {
                Text("← \(project) · \(starter.name)")
                    .font(.caption).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(.purple)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Started by “\(starter.name)” in \(project)")
        } else if node.starterGone {
            Text("← ended")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .help("The session that started it was removed")
        }
    }
}

/// "→ mobile-app 2": sessions it started in another project.
private struct CrossChildrenBadge: View {
    @Environment(AppModel.self) private var model
    let cross: AgentTree.CrossCount

    var body: some View {
        let name = UUID(uuidString: cross.group).flatMap { model.deck.project($0)?.name } ?? "?"
        Text("→ \(name) \(cross.count)")
            .font(.caption).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.teal)
            .background(Color.teal.opacity(0.12), in: Capsule())
            .help("Started \(cross.count) sessions in \(name)")
    }
}

private struct TextPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(tint))
            .fixedSize()
    }
}

/// Model · effort, permission mode (`claudedeck new` options) and the account when there are several.
private struct LaunchOptionsLine: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        let options = session.launchOptions
        let modelEffort = [options?.model, options?.effort].compactMap { $0 }.joined(separator: " · ")
        if !modelEffort.isEmpty {
            Label(modelEffort, systemImage: "cpu").labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .help("Model and effort it was started with")
        }
        if let mode = options?.permissionMode {
            Label(mode, systemImage: "lock.shield").labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .help("Permission mode it was started with")
        }
        if !model.deck.settings.accounts.isEmpty {
            Label(model.accountLabel(model.accountID(of: session)), systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .help("Claude account")
        }
    }
}

/// Held simulators, pending decisions and queued starts, each only when there are any.
private struct AgentCounters: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession

    var body: some View {
        let sims = model.simHolds.held(by: session.id).count
        let decisions = model.decisions.pending.filter { $0.sessionID == session.id }.count
        let queued = model.deck.cliQueue.filter { $0.caller == session.id && $0.status == .queued }.count
        HStack(spacing: 8) {
            if sims > 0 {
                Label("\(sims)", systemImage: "iphone.gen3")
                    .help("Simulators it holds")
            }
            if decisions > 0 {
                Button { model.showDecisions() } label: {
                    Label("\(decisions)", systemImage: "signpost.right.and.left").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Decisions it left for you")
            }
            if queued > 0 {
                Label("\(queued)", systemImage: "hourglass").foregroundStyle(.blue)
                    .help("Its starts waiting under the cap")
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
    }
}

/// Running: how long it has been up; stopped: its last activity.
private struct AgentTime: View {
    @Environment(AppModel.self) private var model
    let session: DeckSession
    let updatedAt: Date?

    var body: some View {
        let since = model.runningSince(session.id)
        let last = updatedAt ?? session.lastActivityAt
        VisibleTimeline(every: 15) { now in
            VStack(alignment: .trailing, spacing: 1) {
                if let since {
                    Text("up \(RelativeTime.short(since, now: now))")
                        .help("Running since \(since.formatted(date: .omitted, time: .shortened))")
                }
                if let last {
                    Text(RelativeTime.short(last, now: now)).foregroundStyle(.tertiary)
                        .help("Last activity")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 44, alignment: .trailing)
    }
}

/// Under the sidebar's decisions row while agent trees exist: how many sessions started by
/// sessions run (the tab header's count);
/// a click opens the Agents tab.
struct AgentsOverviewTray: View {
    @Environment(AppModel.self) private var model
    let running: Int

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button { model.showAgentsOverview() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
                    Text("Agents").sidebarFont(.callout, weight: .semibold)
                    Spacer()
                    Text("\(running)").sidebarFont(.caption, weight: .bold).monospacedDigit()
                        .foregroundStyle(running > 0 ? .white : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(running > 0 ? Color.purple : Color.secondary.opacity(0.15), in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .sidebarRowPadding(7)
            .help("Which agents run in which project (Window › Agents)")
        }
        .background(.bar)
    }
}
