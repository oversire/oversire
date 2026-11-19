import Foundation
import OverSireCore

/// The geometry of the Map: lanes, nodes and edges in content points, with the top left at 0,0.
/// Column 0 is DONE (a pill), columns 1 to 4 are NOW, NEXT, THEN and LATER.
struct PlanMapModel: Equatable {
    static let labelW: CGFloat = 184, colW: CGFloat = 160, nodeW: CGFloat = 144, nodeH: CGFloat = 48, row: CGFloat = 56
    static let headH: CGFloat = 30, inset: CGFloat = 8, foldedH: CGFloat = 44, minLaneH: CGFloat = 92
    static let columns = ["DONE", "NOW", "NEXT", "THEN", "LATER"]

    struct Node: Equatable {
        let key: String
        let frame: CGRect
        let state: PlanState
        let critical: Bool
        /// The epic is planned.
        let dashed: Bool
        let text: String
        /// VoiceOver
        let label: String
        let lane: Int
        let column: Int
    }

    struct Edge: Equatable {
        let from: String
        let to: String
        let crossEpic: Bool
        let critical: Bool
        /// A cubic curve: start, two control points, end. The arrow head ends 6 points after the end.
        let path: [CGPoint]
    }

    struct Lane: Equatable {
        let epic: EpicID
        let y: CGFloat
        let height: CGFloat
        let folded: Bool
        let foldText: String?
        let doneCount: Int
        let open: Int
        /// The DONE pill. Nil when the lane is folded or has no done item.
        let pill: CGRect?
    }

    enum Direction { case left, right, up, down }

    let lanes: [Lane]
    let nodes: [Node]
    let edges: [Edge]
    let size: CGSize

    static func build(lanes src: [PlanMapLane], graph: PlanGraph, schedule: PlanSchedule, folded: Set<EpicID>, showCritical: Bool) -> PlanMapModel {
        let planned = Set(graph.epics.filter { $0.state == .planned }.map(\.id))
        var lanes: [Lane] = [], nodes: [Node] = []
        var y = headH
        for (li, l) in src.enumerated() {
            let isFolded = folded.contains(l.epic)
            let cells = [l.done.isEmpty ? 0 : 1] + l.columns.map(\.count)
            let rows = max(1, cells.max() ?? 1)
            let h = isFolded ? foldedH : max(minLaneH, 12 + CGFloat(rows) * row)
            func top(_ count: Int) -> CGFloat { y + (h - (CGFloat(count) * row - 8)) / 2 }
            var fold: String?
            if isFolded {
                let total = l.open + l.done.count
                fold = l.open == 0 && total > 0 ? "All \(total) done. Close the epic."
                    : "\(l.open) open · \(l.crossLinks) link\(l.crossLinks == 1 ? "" : "s") to other epics"
            }
            var pill: CGRect?
            if !isFolded {
                if !l.done.isEmpty { pill = CGRect(x: labelW + inset, y: top(1).rounded(), width: nodeW, height: nodeH) }
                for (ci, col) in l.columns.enumerated() {
                    let t = top(col.count)
                    for (k, key) in col.enumerated() {
                        guard let n = graph.nodes[key] else { continue }
                        let frame = CGRect(x: labelW + CGFloat(ci + 1) * colW + inset, y: (t + CGFloat(k) * row).rounded(), width: nodeW, height: nodeH)
                        let crit = showCritical && (schedule.slots[key]?.critical ?? false)
                        nodes.append(Node(key: key, frame: frame, state: n.state, critical: crit, dashed: planned.contains(l.epic), text: n.title,
                                          label: "\(key), \(n.title), \(stateWord(n))" + (crit ? ", on the critical path" : ""), lane: li, column: ci + 1))
                    }
                }
            }
            lanes.append(Lane(epic: l.epic, y: y, height: h, folded: isFolded, foldText: fold, doneCount: l.done.count, open: l.open, pill: pill))
            y += h
        }
        let at = Dictionary(nodes.map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let edges = graph.edges.compactMap { e -> Edge? in
            guard let a = at[e.from], let c = at[e.to] else { return nil }
            let x1 = a.maxX, y1 = a.midY, x2 = c.minX - 1 - 6, y2 = c.midY
            let dx = max(10, min(40, (x2 + 6 - x1) / 2))
            return Edge(from: e.from, to: e.to, crossEpic: graph.nodes[e.from]?.epic != graph.nodes[e.to]?.epic,
                        critical: showCritical && schedule.criticalEdge(from: e.from, to: e.to),
                        path: [CGPoint(x: x1, y: y1), CGPoint(x: x1 + dx, y: y1), CGPoint(x: x2 - dx, y: y2), CGPoint(x: x2, y: y2)])
        }
        return PlanMapModel(lanes: lanes, nodes: nodes, edges: edges, size: CGSize(width: labelW + 5 * colW, height: y))
    }

    private static func stateWord(_ n: PlanNode) -> String {
        switch n.state {
        case .done: return "done"
        case .working: return "working"
        case .input: return "needs your answer"
        case .waits: return "waits for " + (n.blockers + n.external).joined(separator: ", ")
        case .nospec: return n.hasOpenBlocker ? "no spec, waits for " + (n.blockers + n.external).joined(separator: ", ") : "no spec"
        case .ready: return "ready"
        }
    }

    func node(_ key: String) -> Node? { nodes.first { $0.key == key.uppercased() } }

    /// The key, its blockers and its dependents on the map.
    func related(to key: String) -> Set<String> {
        let k = key.uppercased()
        guard node(k) != nil else { return [] }
        var out: Set<String> = [k]
        for e in edges {
            if e.from == k { out.insert(e.to) }
            if e.to == k { out.insert(e.from) }
        }
        return out
    }

    /// Left and right: the nearest node in the next column of the lane that has one. Up and down: the next node
    /// in the same column, else the nearest node of the next lane that has nodes.
    func next(from key: String, _ dir: Direction) -> String? {
        guard let n = node(key) else { return nodes.first?.key }
        func nearest(_ list: [Node], to p: CGPoint) -> Node? {
            list.min { hypot($0.frame.midX - p.x, $0.frame.midY - p.y) < hypot($1.frame.midX - p.x, $1.frame.midY - p.y) }
        }
        let c = CGPoint(x: n.frame.midX, y: n.frame.midY)
        switch dir {
        case .left, .right:
            let step = dir == .right ? 1 : -1
            var col = n.column + step
            while (1...4).contains(col) {
                let list = nodes.filter { $0.lane == n.lane && $0.column == col }
                if let f = nearest(list, to: c) { return f.key }
                col += step
            }
            return nil
        case .up, .down:
            let same = nodes.filter { $0.lane == n.lane && $0.column == n.column }
            let down = dir == .down
            if let f = same.filter({ down ? $0.frame.minY > n.frame.minY : $0.frame.minY < n.frame.minY })
                .min(by: { abs($0.frame.minY - n.frame.minY) < abs($1.frame.minY - n.frame.minY) }) { return f.key }
            var lane = n.lane + (down ? 1 : -1)
            while lane >= 0 && lane < lanes.count {
                let list = nodes.filter { $0.lane == lane }
                if let f = nearest(list, to: CGPoint(x: c.x, y: down ? list.map(\.frame.midY).min() ?? 0 : list.map(\.frame.midY).max() ?? 0)) {
                    return f.key
                }
                lane += down ? 1 : -1
            }
            return nil
        }
    }

    /// Tab order: lane by lane, column by column, top to bottom.
    var order: [String] {
        nodes.sorted { ($0.lane, $0.column, $0.frame.minY) < ($1.lane, $1.column, $1.frame.minY) }.map(\.key)
    }
}
