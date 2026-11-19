import SwiftUI

// The Mac's Agents overview on the phone: sessions that sessions started (`claudedeck new`),
// grouped by project, each under the session that started it. Only from a Mac with
// `Feature.agentTree`; read-only, a tap opens the session.

extension RemoteStore {
    /// The agent trees by project (nil: the Mac doesn't send them).
    var agentGroups: [AgentTree.Group]? {
        guard let snapshot, snapshot.supports(RemoteSnapshot.Feature.agentTree) else { return nil }
        // Only sessions the Mac marked as in a tree; the rest can't be anyone's starter here.
        let members = snapshot.sessions.compactMap { session in
            session.agent.map { AgentTree.Member(id: session.id, group: session.project, startedBy: $0.startedBy) }
        }
        let order = projects.filter(\.pinned).map(\.name) + projects.filter { !$0.pinned }.map(\.name)
        return AgentTree.build(members, groupOrder: order)
    }
}

struct AgentTreeRow: View {
    @Environment(RemoteStore.self) private var store
    let groups: [AgentTree.Group]

    var body: some View {
        let running = store.snapshot?.agentsRunning ?? 0
        NavigationLink(value: MacScreen.agents) {
            Label {
                HStack {
                    Text("Agent Sessions").listFont(.body)
                    Spacer(minLength: 4)
                    Text(running == 0 ? String(localized: "None running") : String(localized: "\(running) running"))
                        .listFont(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted").symbolRenderingMode(.hierarchical)
                    .foregroundStyle(running > 0 ? Color.purple : Color.secondary)
            }
        }
        .tag(MacScreen.agents)
    }
}

struct AgentTreeScreen: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.sceneID) private var sceneID
    @AppStorage("agents.filter") private var filter = "all"

    var body: some View {
        Group {
            if let groups = store.agentGroups {
                if groups.isEmpty {
                    ContentUnavailableView("No Agent Sessions", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Sessions start other sessions with `claudedeck new`. They show up here by project, under the session that started them."))
                } else {
                    list(groups)
                }
            } else {
                ContentUnavailableView("Update ClaudeDeck on the Mac", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("The Agents overview needs a newer ClaudeDeck on the Mac."))
            }
        }
        .navigationTitle("Agent Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func matches(_ id: UUID) -> Bool {
        guard let session = store.snapshot?.session(id) else { return false }
        switch filter {
        // Like the Mac's sidebar filter: working or blocked; blocked or an unseen "your turn".
        case "working": return session.state == .running || session.state.isBlocked
        case "waiting": return session.needsAttention
        default: return true
        }
    }

    private func list(_ groups: [AgentTree.Group]) -> some View {
        let sections = groups.compactMap { group -> (AgentTree.Group, [AgentTree.Row])? in
            let rows = group.rows(matching: matches)
            return rows.isEmpty ? nil : (group, rows)
        }
        return List {
            Section {
                summary
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    Text("Working").tag("working")
                    Text("Waiting").tag("waiting")
                }
                .pickerStyle(.segmented)
            }
            ForEach(sections, id: \.0.key) { group, rows in
                Section {
                    ForEach(rows) { row in
                        if let session = store.snapshot?.session(row.id) {
                            Button { store.open(session.id, in: sceneID) } label: {
                                AgentRowView(session: session, row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Label(group.key.isEmpty ? String(localized: "Removed project") : group.key, systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let snapshot = store.snapshot
        HStack(spacing: 12) {
            if let running = snapshot?.agentsRunning, let cap = snapshot?.agentsCap {
                Label(String(localized: "\(running) of \(cap) running"), systemImage: "bolt.fill").foregroundStyle(.green)
            }
            if let queued = snapshot?.agentsQueued, queued > 0 {
                Label(String(localized: "\(queued) queued"), systemImage: "hourglass").foregroundStyle(.blue)
            }
            let decisions = store.decisions?.filter(\.isPending).count ?? 0
            if decisions > 0 {
                Label(String(localized: "\(decisions) decisions"), systemImage: "signpost.right.and.left").foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
}

private struct AgentRowView: View {
    @Environment(RemoteStore.self) private var store
    let session: RemoteSession
    let row: AgentTree.Row

    var body: some View {
        let agent = session.agent
        HStack(alignment: .top, spacing: 6) {
            if row.depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(row.depth - 1) * 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let since = agent?.runningSince {
                        TimelineView(.everyMinute) { context in
                            Text("up \(SessionRow.age(since: since, now: context.date))")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if agent?.limitState == "limit_reached" {
                        pill(String(localized: "Limit reached"), .orange)
                    } else if agent?.limitState == "switching_account" {
                        pill(String(localized: "Switching account"), .blue)
                    } else {
                        StatusPill(state: session.state, program: store.program(of: session))
                    }
                    if let starter = row.node.crossStarter, let lead = store.snapshot?.session(starter) {
                        Text("← \(lead.project) · \(lead.name)").font(.caption).foregroundStyle(.purple).lineLimit(1)
                    } else if row.node.starterGone {
                        Text("← ended").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(row.node.crossChildren, id: \.group) { cross in
                        Text("→ \(cross.group) \(cross.count)").font(.caption).foregroundStyle(.teal).lineLimit(1)
                    }
                }
                let options = [agent?.model, agent?.effort, agent?.permissionMode, agent?.account].compactMap { $0 }
                let counts = counters(agent)
                if !options.isEmpty || !counts.isEmpty {
                    HStack(spacing: 8) {
                        if !options.isEmpty { Text(options.joined(separator: " · ")).lineLimit(1) }
                        ForEach(counts, id: \.0) { symbol, count in
                            Label("\(count)", systemImage: symbol).labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(row.matches ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func counters(_ agent: RemoteAgentInfo?) -> [(String, Int)] {
        var out: [(String, Int)] = []
        if let n = agent?.simulators, n > 0 { out.append(("iphone.gen3", n)) }
        if let n = agent?.pendingDecisions, n > 0 { out.append(("signpost.right.and.left", n)) }
        if let n = agent?.queuedStarts, n > 0 { out.append(("hourglass", n)) }
        return out
    }

    private func pill(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint, in: Capsule())
    }
}
