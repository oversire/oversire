import Foundation

/// Calendar days from today. 0 is today.
public typealias PlanDay = Int

public enum PlanState: String, Sendable, Equatable, CaseIterable {
    case done, working, input, waits, nospec, ready

    public var glyph: String {
        switch self {
        case .done: return "✓"
        case .working: return "●"
        case .input: return "▲"
        case .waits: return "⏸"
        case .nospec: return "◌"
        case .ready: return "○"
        }
    }

    /// The order of the steps that start on the same day.
    public var rank: Int {
        switch self {
        case .input: return 0
        case .working: return 1
        case .ready, .waits: return 2
        case .nospec: return 3
        case .done: return 4
        }
    }
}

/// The live state that the tracker does not hold. Keys are item keys.
public struct PlanSignals: Sendable {
    /// Key → who works on it, for example "Claude on mba".
    public var working: [String: String]
    /// Key → the question text.
    public var input: [String: String]

    public init(working: [String: String] = [:], input: [String: String] = [:]) {
        self.working = working
        self.input = input
    }
}

public struct PlanNode: Equatable, Sendable {
    public let key: String
    public let epic: EpicID?
    public let title: String
    public let state: PlanState
    public let started: Bool
    /// The "Start" field, only when the item is started.
    public let startDay: PlanDay?
    /// The "Due" field.
    public let dueDay: PlanDay?
    public let days: Int
    /// Open blockers that are nodes, in relation order.
    public let blockers: [String]
    /// Open blockers that are not nodes: other projects, or epics that are not open.
    public let external: [String]

    public init(key: String, epic: EpicID?, title: String, state: PlanState, started: Bool, startDay: PlanDay?, dueDay: PlanDay?,
                days: Int, blockers: [String], external: [String]) {
        self.key = key
        self.epic = epic
        self.title = title
        self.state = state
        self.started = started
        self.startDay = startDay
        self.dueDay = dueDay
        self.days = days
        self.blockers = blockers
        self.external = external
    }

    public var isOpen: Bool { state != .done }
    public var hasOpenBlocker: Bool { !blockers.isEmpty || !external.isEmpty }
}

/// A blocker edge: `to` waits for `from`.
public struct PlanEdge: Equatable, Hashable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// The items of the open epics and their open blocker edges. Keys are upper case.
public struct PlanGraph: Equatable, Sendable {
    public static let defaultDays = 2

    public let nodes: [String: PlanNode]
    /// Topological order. Ties go by key.
    public let order: [String]
    /// The edges that closed a cycle in the tracker data.
    public let dropped: [PlanEdge]
    /// The open epics (planned, active or paused), in the given order.
    public let epics: [Epic]
    private let depths: [String: Int]
    private let dependentsMap: [String: [String]]

    public static func build(_ snap: ProjectSnapshot, epics: [Epic], relations: [String: [ItemRelation]], signals: PlanSignals,
                             today: Date, calendar: Calendar = .current, defaultDays: Int = PlanGraph.defaultDays) -> PlanGraph {
        let open = epics.filter { !$0.state.isClosed }
        let ids = Set(open.map(\.id))
        var items: [String: Item] = [:]
        for i in snap.items where i.epicId.map(ids.contains) ?? false { items[i.key.uppercased()] = i }
        let keys = items.keys.sorted(by: keyOrder)

        var finished: [String: Bool] = [:]
        for s in snap.index ?? [] { if let k = s.key { finished[k.uppercased()] = snap.isClosed(s.stateId) } }
        for i in snap.items { finished[i.key.uppercased()] = snap.isFinished(i) }
        let working = Dictionary(signals.working.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let input = Dictionary(signals.input.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { a, _ in a })

        // blockedBy of the item first, then the blocks relations of the other items.
        var raw: [String: [String]] = [:]
        let sortedRelations = relations.sorted { keyOrder($0.key.uppercased(), $1.key.uppercased()) }
        for (k, rels) in sortedRelations {
            for r in rels where r.kind == .blockedBy { raw[k.uppercased(), default: []].append(r.item.key.uppercased()) }
        }
        for (k, rels) in sortedRelations {
            for r in rels where r.kind == .blocks { raw[r.item.key.uppercased(), default: []].append(k.uppercased()) }
        }

        var blockers: [String: [String]] = [:]
        var external: [String: [String]] = [:]
        var dropped: [PlanEdge] = []
        func reaches(_ a: String, _ b: String) -> Bool {
            var seen: Set<String> = []
            var stack = [a]
            while let n = stack.popLast() {
                if n == b { return true }
                guard seen.insert(n).inserted else { continue }
                stack += blockers[n] ?? []
            }
            return false
        }
        for k in keys where !finished[k, default: false] {
            var seen: Set<String> = []
            for b in raw[k] ?? [] where seen.insert(b).inserted {
                if items[b] != nil {
                    guard !finished[b, default: false] else { continue }
                    if b == k || reaches(b, k) {
                        dropped.append(PlanEdge(from: b, to: k))
                    } else {
                        blockers[k, default: []].append(b)
                    }
                } else if !(finished[b] ?? false) {
                    external[k, default: []].append(b)
                }
            }
        }

        let day0 = calendar.startOfDay(for: today)
        func dayOf(_ text: String?) -> PlanDay? { parse(text, calendar: calendar).map { day($0, from: day0, calendar: calendar) } }
        var nodes: [String: PlanNode] = [:]
        for k in keys {
            let i = items[k]!
            let b = blockers[k] ?? [], x = external[k] ?? []
            let state: PlanState
            if finished[k, default: false] { state = .done }
            else if working[k] != nil { state = .working }
            else if input[k] != nil { state = .input }
            else if !b.isEmpty || !x.isEmpty { state = .waits }
            else if snap.unplanned(i) != nil { state = .nospec }
            else { state = .ready }
            let started = state != .done
                && (state == .working || state == .input || [.progress, .review].contains(snap.option(i.statusOptionId)?.category))
            nodes[k] = PlanNode(key: k, epic: i.epicId, title: i.title, state: state, started: started,
                                startDay: started ? dayOf(i.fields["Start"]) : nil, dueDay: dayOf(i.fields["Due"]),
                                days: duration(i, calendar: calendar, defaultDays: defaultDays), blockers: b, external: x)
        }
        return PlanGraph(nodes: nodes, epics: open, dropped: dropped)
    }

    init(nodes: [String: PlanNode], epics: [Epic], dropped: [PlanEdge] = []) {
        self.nodes = nodes
        self.epics = epics
        self.dropped = dropped
        var deps: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        for k in nodes.keys.sorted(by: Self.keyOrder) {
            indegree[k] = nodes[k]!.blockers.count
            for b in nodes[k]!.blockers { deps[b, default: []].append(k) }
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted(by: Self.keyOrder)
        var order: [String] = []
        var depths: [String: Int] = [:]
        while !ready.isEmpty {
            let k = ready.removeFirst()
            order.append(k)
            depths[k] = 1 + (nodes[k]!.blockers.compactMap { depths[$0] }.max() ?? 0)
            for d in deps[k] ?? [] {
                indegree[d]! -= 1
                if indegree[d] == 0 {
                    ready.insert(d, at: ready.firstIndex { Self.keyOrder(d, $0) } ?? ready.endIndex)
                }
            }
        }
        self.order = order
        self.depths = depths
        self.dependentsMap = deps
    }

    /// `max(1, days(Start…Due) + 1)` when the item has both dates, else `defaultDays`.
    public static func duration(_ item: Item, calendar: Calendar, defaultDays: Int) -> Int {
        guard let s = parse(item.fields["Start"], calendar: calendar), let e = parse(item.fields["Due"], calendar: calendar) else {
            return defaultDays
        }
        return max(1, day(e, from: s, calendar: calendar) + 1)
    }

    /// The calendar days from the day of `today` to the day of `date`.
    public static func day(_ date: Date, from today: Date, calendar: Calendar) -> PlanDay {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// A "YYYY-MM-DD" field, at the start of that day in the calendar.
    static func parse(_ text: String?, calendar: Calendar) -> Date? {
        guard let text else { return nil }
        let n = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard n.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: n[0], month: n[1], day: n[2]))
    }

    /// The prefix A to Z, then the number: ENG-9 comes before ENG-10.
    public static func keyOrder(_ a: String, _ b: String) -> Bool {
        func split(_ k: String) -> (String, Int?) {
            guard let dash = k.lastIndex(of: "-") else { return (k, nil) }
            return (String(k[..<dash]), Int(k[k.index(after: dash)...]))
        }
        let (pa, na) = split(a), (pb, nb) = split(b)
        if pa != pb { return pa < pb }
        if let na, let nb, na != nb { return na < nb }
        return a < b
    }

    /// The open nodes that `key` blocks, in key order.
    public func dependents(of key: String) -> [String] { dependentsMap[key.uppercased()] ?? [] }

    /// 1 for a node with no open blocker, else 1 + the largest depth of its blockers.
    public func depth(_ key: String) -> Int { depths[key.uppercased()] ?? 1 }

    /// The Map column: 0 for done, else the depth, at most 4.
    public func column(_ key: String) -> Int {
        nodes[key.uppercased()]?.state == .done ? 0 : min(depth(key), 4)
    }

    /// The nodes of the epic, in graph order.
    public func members(of epic: EpicID) -> [String] { order.filter { nodes[$0]?.epic == epic } }

    /// All open edges, in graph order.
    public var edges: [PlanEdge] {
        order.flatMap { k in (nodes[k]?.blockers ?? []).map { PlanEdge(from: $0, to: k) } }
    }
}
