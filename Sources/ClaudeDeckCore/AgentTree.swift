import Foundation

/// The Agents overview: sessions grouped by project, each project's sessions as the tree
/// `claudedeck new` built (`DeckSession.startedBy`). Pure, so the Mac's tab and the phone's
/// screen share it. A session is in it only when it is part of an agent tree: it started a
/// session, or a session started it.
///
/// Nesting stays inside a project: a session started by one in another project is a lead of
/// its own project (`crossStarter` says who started it), and its starter counts it in
/// `crossChildren`.
public enum AgentTree {
    /// One session as the tree needs it. `group` is the project's key (its id on the Mac, its
    /// name on the phone).
    public struct Member: Sendable, Equatable {
        public var id: UUID
        public var group: String
        public var startedBy: UUID?

        public init(id: UUID, group: String, startedBy: UUID?) {
            self.id = id
            self.group = group
            self.startedBy = startedBy
        }
    }

    /// Sessions a node started in another project, per project.
    public struct CrossCount: Sendable, Equatable {
        public var group: String
        public var count: Int
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public var id: UUID
        /// Started by a session in another project (that session's id).
        public var crossStarter: UUID?
        /// Started by a session that is no longer there.
        public var starterGone: Bool
        /// The sessions it started in this project, in the order given.
        public var children: [Node]
        /// The sessions it started in other projects.
        public var crossChildren: [CrossCount]
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var key: String
        public var roots: [Node]
        public var id: String { key }

        /// Every session in the group, depth first.
        public var count: Int { rows { _ in true }.count }

        /// The tree flattened depth first, for a list. With a filter, only the sessions that match
        /// and their starters (`matches` false: shown for context, so no child loses its place).
        public func rows(matching keep: (UUID) -> Bool) -> [Row] {
            var out: [Row] = []
            func visit(_ node: Node, depth: Int) -> Bool {
                let index = out.count
                out.append(Row(node: node, depth: depth, matches: keep(node.id)))
                var any = out[index].matches
                for child in node.children where visit(child, depth: depth + 1) { any = true }
                if !any { out.removeSubrange(index...) }
                return any
            }
            for root in roots { _ = visit(root, depth: 0) }
            return out
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var node: Node
        public var depth: Int
        public var matches: Bool
        public var id: UUID { node.id }
    }

    /// The groups in `groupOrder` (then any other, in the order their sessions come), each with
    /// its leads and what they started. Sessions keep the order they are given in.
    public static func build(_ members: [Member], groupOrder: [String]) -> [Group] {
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var started: [UUID: [Member]] = [:]
        for member in members {
            if let starter = member.startedBy, starter != member.id { started[starter, default: []].append(member) }
        }
        let inTree = members.filter { ($0.startedBy != nil && $0.startedBy != $0.id) || started[$0.id] != nil }
        guard !inTree.isEmpty else { return [] }

        var order = groupOrder
        var known = Set(groupOrder)
        for member in inTree where !known.contains(member.group) {
            order.append(member.group)
            known.insert(member.group)
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        var visited = Set<UUID>()
        func node(_ member: Member) -> Node {
            visited.insert(member.id)
            let mine = started[member.id] ?? []
            let children = mine.filter { $0.group == member.group && !visited.contains($0.id) }.map(node)
            var cross: [String: Int] = [:]
            for child in mine where child.group != member.group { cross[child.group, default: 0] += 1 }
            let crossChildren = cross.map { CrossCount(group: $0.key, count: $0.value) }
                .sorted { (rank[$0.group] ?? .max, $0.group) < (rank[$1.group] ?? .max, $1.group) }
            let starter = member.startedBy.flatMap { $0 == member.id ? nil : byID[$0] }
            return Node(id: member.id,
                        crossStarter: starter.flatMap { $0.group == member.group ? nil : $0.id },
                        starterGone: member.startedBy != nil && member.startedBy != member.id && starter == nil,
                        children: children, crossChildren: crossChildren)
        }

        var groups: [Group] = []
        for key in order {
            let here = inTree.filter { $0.group == key }
            guard !here.isEmpty else { continue }
            // A lead: started by the owner, by a session that's gone, or by one in another project.
            var roots = here.filter { member in
                guard let starter = member.startedBy, starter != member.id, let parent = byID[starter] else { return true }
                return parent.group != member.group
            }.map(node)
            // A startedBy loop has no lead: its first session stands in for one.
            for member in here where !visited.contains(member.id) { roots.append(node(member)) }
            groups.append(Group(key: key, roots: roots))
        }
        return groups
    }
}
