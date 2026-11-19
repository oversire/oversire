import Foundation

/// The open epics in three lanes.
public struct PlanLanes: Equatable, Sendable {
    /// Active epics with open items, late first.
    public let now: [EpicID]
    public let readyToClose: [EpicID]
    /// The other open epics, in graph order.
    public let next: [EpicID]

    public init(now: [EpicID], readyToClose: [EpicID], next: [EpicID]) {
        self.now = now
        self.readyToClose = readyToClose
        self.next = next
    }

    public static func build(_ snap: ProjectSnapshot, graph: PlanGraph, schedule: PlanSchedule, today: Date,
                             calendar: Calendar = .current) -> PlanLanes {
        var now: [(epic: EpicID, late: Int, index: Int)] = [], ready: [EpicID] = [], next: [EpicID] = []
        for (index, e) in graph.epics.enumerated() {
            let r = snap.rollup(e, now: today)
            if r.readyToClose {
                ready.append(e.id)
            } else if e.state == .active && r.open > 0 {
                now.append((e.id, schedule.forecast(e, in: graph, today: today, calendar: calendar).lateBy ?? 0, index))
            } else {
                next.append(e.id)
            }
        }
        now.sort { $0.late != $1.late ? $0.late > $1.late : $0.index < $1.index }
        return PlanLanes(now: now.map(\.epic), readyToClose: ready, next: next)
    }
}

public struct PlanSummary: Equatable, Sendable {
    public struct NowCard: Equatable, Sendable {
        public let epic: EpicID
        public let forecast: EpicForecast
        /// The first 3 steps.
        public let steps: [String]
        public let more: Int
        /// The first ready step with no open blocker.
        public let startKey: String?
    }

    public struct NextEpic: Equatable, Sendable {
        public let epic: EpicID
        public let forecast: EpicForecast
    }

    public enum Next: Equatable, Sendable {
        case answer(String), close(EpicID), start(String, critical: Bool, slack: Int), plan(String)
    }

    public static let upNextLimit = 6

    public let now: [NowCard]
    public let readyToClose: [EpicID]
    public let next: [NextEpic]
    public let upNext: [Next]
    public let focusEpic: EpicID?
    /// The key of the first item that waits on an answer.
    public let focusQuestion: String?
    public let end: PlanDay

    public static func build(_ snap: ProjectSnapshot, graph: PlanGraph, schedule: PlanSchedule, lanes: PlanLanes, today: Date,
                             calendar: Calendar = .current) -> PlanSummary {
        func forecast(_ id: EpicID) -> EpicForecast {
            graph.epics.first { $0.id == id }.map { schedule.forecast($0, in: graph, today: today, calendar: calendar) }
                ?? EpicForecast(start: 0, end: nil, lateBy: nil)
        }
        let now = lanes.now.map { id -> NowCard in
            let s = steps(of: id, graph: graph, schedule: schedule)
            let start = s.first { graph.nodes[$0]?.state == .ready && graph.nodes[$0]?.hasOpenBlocker == false }
            return NowCard(epic: id, forecast: forecast(id), steps: Array(s.prefix(3)), more: max(0, s.count - 3), startKey: start)
        }
        let open = graph.order.compactMap { graph.nodes[$0] }.filter(\.isOpen)
        let inputs = open.filter { $0.state == .input }.map(\.key)
        let active = Set(graph.epics.filter { $0.state == .active }.map(\.id))
        let ready = open.filter { $0.state == .ready && !$0.hasOpenBlocker }.map(\.key).sorted { a, b in
            let (sa, sb) = (schedule.slots[a]?.slack ?? 0, schedule.slots[b]?.slack ?? 0)
            if sa != sb { return sa < sb }
            let (da, db) = (graph.dependents(of: a).count, graph.dependents(of: b).count)
            return da != db ? da > db : PlanGraph.keyOrder(a, b)
        }
        var up: [Next] = inputs.map { .answer($0) }
        up += lanes.readyToClose.map { .close($0) }
        up += ready.map { k in
            let slot = schedule.slots[k]
            return .start(k, critical: slot?.critical ?? false, slack: slot?.slack ?? 0)
        }
        up += open.filter { $0.state == .nospec && !$0.hasOpenBlocker && ($0.epic.map(active.contains) ?? false) }.map { .plan($0.key) }
        return PlanSummary(now: now, readyToClose: lanes.readyToClose, next: lanes.next.map { NextEpic(epic: $0, forecast: forecast($0)) },
                           upNext: Array(up.prefix(upNextLimit)), focusEpic: now.first?.epic, focusQuestion: inputs.first,
                           end: schedule.end)
    }

    /// The open nodes of the epic: slot start, then state rank, then key.
    public static func steps(of epic: EpicID, graph: PlanGraph, schedule: PlanSchedule) -> [String] {
        graph.members(of: epic).filter { schedule.slots[$0] != nil }.sorted { a, b in
            let (sa, sb) = (schedule.slots[a]!.start, schedule.slots[b]!.start)
            if sa != sb { return sa < sb }
            let (ra, rb) = (graph.nodes[a]!.state.rank, graph.nodes[b]!.state.rank)
            return ra != rb ? ra < rb : PlanGraph.keyOrder(a, b)
        }
    }
}

/// What changed since the last visit.
public struct PlanAway: Equatable, Sendable {
    public let done: [String]
    public let readyToClose: [EpicID]
    /// Active epics that end after their target date, in graph order.
    public let late: [EpicID]
    /// Keys of the items that wait on an answer.
    public let questions: [String]

    public init(done: [String], readyToClose: [EpicID], late: [EpicID], questions: [String]) {
        self.done = done
        self.readyToClose = readyToClose
        self.late = late
        self.questions = questions
    }

    /// `done` uses `updatedAt`: the last change, not the time of the close.
    public static func build(_ snap: ProjectSnapshot, summary: PlanSummary, schedule: PlanSchedule, graph: PlanGraph,
                             since: Date) -> PlanAway {
        let late = Set(summary.now.filter { $0.forecast.isLate }.map(\.epic))
        return PlanAway(done: snap.items.filter { snap.isFinished($0) && $0.updatedAt > since }.map(\.key),
                        readyToClose: summary.readyToClose,
                        late: graph.epics.map(\.id).filter(late.contains),
                        questions: graph.order.filter { graph.nodes[$0]?.state == .input })
    }

    /// "Epics shipped. Review desk slipped. An agent waits on your answer on approval checks."
    public func sentence(name: (EpicID) -> String, title: (String) -> String) -> String {
        var parts: [String] = []
        if !readyToClose.isEmpty { parts.append(readyToClose.map(name).joined(separator: ", ") + " shipped.") }
        if !late.isEmpty { parts.append(late.map(name).joined(separator: ", ") + " slipped.") }
        if let q = questions.first {
            parts.append("An agent waits on your answer on " + Self.inline(title(q)) + ".")
        } else {
            parts.append("No agent waits on you.")
        }
        return parts.joined(separator: " ")
    }

    /// A title inside a sentence: the first letter in lower case, but "CI checks" stays.
    static func inline(_ title: String) -> String {
        let word = title.prefix { $0 != " " }
        guard let first = word.first, word.count < 2 || !word.dropFirst().first!.isUppercase else { return title }
        return first.lowercased() + title.dropFirst()
    }
}

public enum PlanMapMode: String, Sendable {
    case all, activeAndLinked
}

/// One epic row of the Map. No geometry.
public struct PlanMapLane: Equatable, Sendable {
    public let epic: EpicID
    /// Columns 1 to 4. Each column goes by slot start, then key.
    public let columns: [[String]]
    public let done: [String]
    public let open: Int
    /// The open edges between this epic and another epic.
    public let crossLinks: Int
}

public enum PlanMap {
    public static func lanes(_ graph: PlanGraph, schedule: PlanSchedule, epics: [Epic], mode: PlanMapMode) -> [PlanMapLane] {
        let edges = graph.edges.compactMap { e -> (from: EpicID, to: EpicID)? in
            guard let a = graph.nodes[e.from]?.epic, let b = graph.nodes[e.to]?.epic else { return nil }
            return (a, b)
        }
        let active = Set(epics.filter { $0.state == .active }.map(\.id))
        var linked = active
        for e in edges {
            if active.contains(e.from) { linked.insert(e.to) }
            if active.contains(e.to) { linked.insert(e.from) }
        }
        return epics.filter { mode == .all || linked.contains($0.id) }.map { epic in
            let members = graph.members(of: epic.id)
            var columns: [[String]] = Array(repeating: [], count: 4)
            for k in members where graph.column(k) > 0 { columns[graph.column(k) - 1].append(k) }
            columns = columns.map { col in
                col.sorted { a, b in
                    let (sa, sb) = (schedule.slots[a]?.start ?? 0, schedule.slots[b]?.start ?? 0)
                    return sa != sb ? sa < sb : PlanGraph.keyOrder(a, b)
                }
            }
            let done = members.filter { graph.nodes[$0]?.state == .done }
            return PlanMapLane(epic: epic.id, columns: columns, done: done, open: members.count - done.count,
                               crossLinks: edges.filter { ($0.from == epic.id) != ($0.to == epic.id) }.count)
        }
    }
}

/// The numbered steps of one epic: the done steps first, then the open steps in `PlanSummary.steps` order.
public struct PlanSteps: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let number: Int
        public let key: String
        public let state: PlanState
        /// The number of the first open blocker in the same epic.
        public let waitsOnStep: Int?
        /// The first open blocker outside the epic, when no blocker is in the epic.
        public let waitsOnKey: String?
    }

    public let done: [String]
    public let open: [Step]

    public static func build(epic: EpicID, graph: PlanGraph, schedule: PlanSchedule) -> PlanSteps {
        let done = graph.members(of: epic).filter { graph.nodes[$0]?.state == .done }
        let keys = PlanSummary.steps(of: epic, graph: graph, schedule: schedule)
        let number = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, done.count + $0 + 1) })
        let open = keys.map { k -> Step in
            let n = graph.nodes[k]!
            let inside = n.blockers.first { number[$0] != nil }
            let outside = inside == nil ? (n.blockers.first { graph.nodes[$0]?.epic != epic } ?? n.external.first) : nil
            return Step(number: number[k]!, key: k, state: n.state, waitsOnStep: inside.flatMap { number[$0] }, waitsOnKey: outside)
        }
        return PlanSteps(done: done, open: open)
    }

    /// The first open step that is not in work and does not wait on an answer.
    public var next: Step? { open.first { $0.state != .working && $0.state != .input } }

    /// "6 of 9 done. 2 days late. Next: Keyboard review."
    public func whereWeAre(rollup: EpicRollup, forecast: EpicForecast, title: (String) -> String) -> String {
        var parts = ["\(rollup.done) of \(rollup.total) done."]
        if let late = forecast.lateBy {
            parts.append(late > 0 ? "\(late) \(late == 1 ? "day" : "days") late." : "On time.")
        }
        if let next { parts.append("Next: \(title(next.key)).") }
        return parts.joined(separator: " ")
    }
}
