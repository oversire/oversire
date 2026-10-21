import Foundation

/// The start order of a queue lane. Relations hold an item. Inside the items with no open blocker, priority sets the order.
public enum LaneOrder {
    /// Urgent is 0. None and an unknown name come last.
    public static func rank(_ priority: String?) -> Int {
        StatusOption.priorities.firstIndex { $0.id == priority?.lowercased() || $0.name == priority } ?? StatusOption.priorities.count
    }

    /// The index for a new entry: after the last entry with the same or a higher priority.
    public static func insert(_ priority: String?, into keys: [String], priority of: (String) -> String?) -> Int {
        let r = rank(priority)
        return (keys.lastIndex { rank(of($0)) <= r }).map { $0 + 1 } ?? 0
    }
}

/// The blockedBy edges between items: a key to the keys of its blockers. The hub of the cloud has the same rules.
public struct BlockGraph: Sendable {
    private var edges: [String: Set<String>] = [:]

    /// `relations`: the relations of each key. A relatesTo relation is no edge.
    public init(_ relations: [String: [ItemRelation]] = [:]) {
        for (key, rels) in relations {
            for r in rels { _ = add(key, r) }
        }
    }

    public func has(_ key: String, _ r: ItemRelation) -> Bool {
        guard let (from, to) = Self.edge(key, r) else { return false }
        return edges[from]?.contains(to) ?? false
    }

    /// Adds a relation of `key`. False, and no change, when it makes a cycle.
    @discardableResult
    public mutating func add(_ key: String, _ r: ItemRelation) -> Bool {
        guard let (from, to) = Self.edge(key, r) else { return true }
        if from == to || reaches(to, from) { return false }
        edges[from, default: []].insert(to)
        return true
    }

    private static func edge(_ key: String, _ r: ItemRelation) -> (String, String)? {
        let other = r.item.key.uppercased(), me = key.uppercased()
        switch r.kind {
        case .blockedBy: return (me, other)
        case .blocks: return (other, me)
        default: return nil
        }
    }

    private func reaches(_ a: String, _ b: String) -> Bool {
        var seen: Set<String> = []
        var stack = [a]
        while let n = stack.popLast() {
            if n == b { return true }
            guard seen.insert(n).inserted else { continue }
            stack += edges[n] ?? []
        }
        return false
    }
}
