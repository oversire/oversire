import Foundation

/// The dates of the open nodes and the critical path. Calendar days, no resource limits.
public struct PlanSchedule: Equatable, Sendable {
    /// `end` is the first day after the work.
    public struct Slot: Equatable, Sendable {
        public let start: PlanDay
        public let end: PlanDay
        public let slack: Int

        public init(start: PlanDay, end: PlanDay, slack: Int) {
            self.start = start
            self.end = end
            self.slack = slack
        }

        public var critical: Bool { slack <= 0 }
        public var days: Int { end - start }
    }

    /// Open nodes only.
    public let slots: [String: Slot]
    /// The first day after all open work. At least 1.
    public let end: PlanDay

    public init(slots: [String: Slot], end: PlanDay) {
        self.slots = slots
        self.end = end
    }

    /// A started node keeps its start. Other nodes start when their last blocker ends. An external blocker ends today.
    public static func build(_ graph: PlanGraph) -> PlanSchedule {
        var span: [String: (start: PlanDay, end: PlanDay)] = [:]
        for k in graph.order {
            guard let n = graph.nodes[k], n.isOpen else { continue }
            if n.started {
                let s = n.startDay ?? 0
                span[k] = (s, max(1, s + n.days))
            } else {
                let s = max(0, n.blockers.compactMap { span[$0]?.end }.max() ?? 0)
                span[k] = (s, s + n.days)
            }
        }
        let end = max(1, span.values.map(\.end).max() ?? 1)
        var late: [String: PlanDay] = [:]
        for k in graph.order.reversed() where span[k] != nil {
            let deps = graph.dependents(of: k).filter { span[$0] != nil }
            late[k] = deps.isEmpty ? end : deps.map { late[$0]! - (span[$0]!.end - span[$0]!.start) }.min()!
        }
        let slots = span.reduce(into: [String: Slot]()) { $0[$1.key] = Slot(start: $1.value.start, end: $1.value.end, slack: late[$1.key]! - $1.value.end) }
        return PlanSchedule(slots: slots, end: end)
    }

    /// Both nodes are critical and `key` starts on the day that `blocker` ends.
    public func criticalEdge(from blocker: String, to key: String) -> Bool {
        guard let a = slots[blocker.uppercased()], let b = slots[key.uppercased()] else { return false }
        return a.critical && b.critical && a.end == b.start
    }

    public func forecast(_ epic: Epic, in graph: PlanGraph, today: Date, calendar: Calendar = .current) -> EpicForecast {
        let open = graph.members(of: epic.id).compactMap { slots[$0] }
        let end = open.map(\.end).max()
        let start = epic.startDate.map { PlanGraph.day($0, from: today, calendar: calendar) } ?? open.map(\.start).min() ?? 0
        var lateBy: Int?
        if let end, let due = epic.targetDate {
            lateBy = end - (PlanGraph.day(due, from: today, calendar: calendar) + 1)
        }
        return EpicForecast(start: start, end: end, lateBy: lateBy)
    }
}

public struct EpicForecast: Equatable, Sendable {
    public let start: PlanDay
    /// The first day after the open work. Nil when no item is open.
    public let end: PlanDay?
    /// Days after the target date. Negative is early. Nil with no target date or no open item.
    public let lateBy: Int?

    public init(start: PlanDay, end: PlanDay?, lateBy: Int?) {
        self.start = start
        self.end = end
        self.lateBy = lateBy
    }

    public var isLate: Bool { (lateBy ?? 0) > 0 }
}
