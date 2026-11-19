import Cocoa
import OverSireCore

/// The geometry of the Timeline segment: one row for each epic, one row for each open item, the blocker arrows and the calendar.
/// x 0 is the left edge of the label column. y 0 is the top of the header.
struct PlanGanttModel: Equatable {
    enum Zoom: String {
        case days, weeks

        var dayW: CGFloat { self == .days ? 20 : 9 }
    }

    static let label: CGFloat = 220, head: CGFloat = 44, epicRow: CGFloat = 34, itemRow: CGFloat = 30
    /// The epic bar and the item bar, from the top of their row.
    static let epicBar: (y: CGFloat, h: CGFloat) = (12, 10)
    static let itemBar: (y: CGFloat, h: CGFloat) = (6, 18)

    struct Epic: Equatable {
        let id: EpicID
        let done: Int
        let total: Int
        let planned: Bool
        let folded: Bool
        /// The end of the due day.
        let dueX: CGFloat?
        /// Days after the target date, when late.
        let late: Int?
        /// The text after the bar: "Dec 3 · ▲ 2d late".
        let text: String

        var doneFraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        /// The text under the name: "6/9 · ▲ 2d late".
        var sub: String { "\(done)/\(total)" + (late.map { " · ▲ \($0)d late" } ?? "") }
    }

    struct Item: Equatable {
        let key: String
        let state: PlanState
        let critical: Bool
        let start: PlanDay
        let end: PlanDay
    }

    struct Row: Equatable {
        enum Kind: Equatable { case epic(Epic), item(Item) }
        let kind: Kind
        let y: CGFloat
        let bar: ClosedRange<CGFloat>?
        let label: String

        var height: CGFloat { if case .epic = kind { return PlanGanttModel.epicRow }; return PlanGanttModel.itemRow }
        var key: String? { if case .item(let i) = kind { return i.key }; return nil }
        var epic: Epic? { if case .epic(let e) = kind { return e }; return nil }

        var barRect: NSRect? {
            guard let bar else { return nil }
            let b = epic == nil ? PlanGanttModel.itemBar : PlanGanttModel.epicBar
            return NSRect(x: bar.lowerBound, y: y + b.y, width: bar.upperBound - bar.lowerBound, height: b.h)
        }
    }

    /// An elbow from the end of the blocker bar to the edge of the item bar.
    struct Arrow: Equatable {
        let from: String
        let to: String
        let points: [CGPoint]
        let critical: Bool
    }

    /// A label of the header.
    struct Tick: Equatable {
        let x: CGFloat
        let text: String
        var weekend = false
        var today = false
    }

    let zoom: Zoom
    let firstDay: PlanDay
    let rows: [Row]
    let arrows: [Arrow]
    let weekends: [ClosedRange<CGFloat>]
    let mondays: [CGFloat]
    /// The week labels at each Monday.
    let weeks: [Tick]
    /// The day numbers, only with the Days zoom.
    let dayNumbers: [Tick]
    /// The middle of today.
    let todayX: CGFloat
    let size: CGSize

    func x(_ day: PlanDay) -> CGFloat { Self.x(day, firstDay: firstDay, zoom: zoom) }

    var dayCount: Int { Int(((size.width - Self.label) / zoom.dayW).rounded()) }

    static func x(_ day: PlanDay, firstDay: PlanDay, zoom: Zoom) -> CGFloat { label + CGFloat(day - firstDay) * zoom.dayW }

    func row(key: String) -> Row? { rows.first { $0.key == key.uppercased() } }

    /// The days to show: from a Monday at least 2 weeks before today, to 2 weeks after the last end or due date. At least 9 weeks.
    static func range(schedule: PlanSchedule, epics: [OverSireCore.Epic], forecasts: [EpicID: EpicForecast], today: Date,
                      calendar: Calendar) -> (firstDay: PlanDay, days: Int) {
        var first = min(-14, forecasts.values.map(\.start).min() ?? 0, schedule.slots.values.map(\.start).min() ?? 0)
        let day0 = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: calendar.date(byAdding: .day, value: first, to: day0) ?? day0)
        first -= (weekday + 5) % 7
        var last = max(schedule.end, forecasts.values.compactMap(\.end).max() ?? 0)
        for e in epics { if let t = e.targetDate { last = max(last, PlanGraph.day(t, from: today, calendar: calendar) + 1) } }
        let days = max(63, last + 14 - first)
        return (first, (days + 6) / 7 * 7)
    }

    static func build(graph: PlanGraph, schedule: PlanSchedule, epics: [OverSireCore.Epic], forecasts: [EpicID: EpicForecast],
                      folded: Set<EpicID>, zoom: Zoom, firstDay: PlanDay, days: Int, today: Date, calendar: Calendar) -> PlanGanttModel {
        let dw = zoom.dayW
        func x(_ d: PlanDay) -> CGFloat { Self.x(d, firstDay: firstDay, zoom: zoom) }
        let day0 = calendar.startOfDay(for: today)
        func date(_ d: PlanDay) -> Date { calendar.date(byAdding: .day, value: d, to: day0) ?? day0 }
        func text(_ d: PlanDay) -> String { EpicBoard.day(date(d)) }

        var rows: [Row] = []
        var y = head
        for e in epics {
            let f = forecasts[e.id] ?? schedule.forecast(e, in: graph, today: today, calendar: calendar)
            let members = graph.members(of: e.id)
            let done = members.filter { graph.nodes[$0]?.state == .done }.count
            let late = (f.lateBy ?? 0) > 0 ? f.lateBy : nil
            let x0 = x(f.start)
            let tail = (f.end.map { text($0 - 1) } ?? "") + (late.map { (f.end == nil ? "" : " · ") + "▲ \($0)d late" } ?? "")
            let due = e.targetDate.map { x(PlanGraph.day($0, from: today, calendar: calendar) + 1) }
            let isFolded = folded.contains(e.id)
            rows.append(Row(kind: .epic(Epic(id: e.id, done: done, total: members.count, planned: e.state == .planned, folded: isFolded,
                                             dueX: due, late: late, text: tail)),
                            y: y, bar: x0...max(x0 + 8, x(f.end ?? 0)), label: e.title))
            y += epicRow
            guard !isFolded else { continue }
            let open = PlanSummary.steps(of: e.id, graph: graph, schedule: schedule)
            for k in open {
                guard let n = graph.nodes[k], let s = schedule.slots[k] else { continue }
                let bx = x(s.start) + 1
                rows.append(Row(kind: .item(Item(key: k, state: n.state, critical: s.critical, start: s.start, end: s.end)),
                                y: y, bar: bx...(bx + max(dw - 2, CGFloat(s.days) * dw - 2)), label: n.title))
                y += itemRow
            }
        }

        var arrows: [Arrow] = []
        let byKey = Dictionary(rows.compactMap { r in r.key.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        for e in graph.edges {
            guard let a = byKey[e.from], let b = byKey[e.to], let ab = a.barRect, let bb = b.barRect,
                  case .item(let ai) = a.kind, case .item(let bi) = b.kind else { continue }
            arrows.append(Arrow(from: e.from, to: e.to, points: elbow(from: ab, endX: x(ai.end), to: bb, startX: x(bi.start)),
                                critical: schedule.criticalEdge(from: e.from, to: e.to)))
        }

        var weekends: [ClosedRange<CGFloat>] = [], mondays: [CGFloat] = [], weeks: [Tick] = [], numbers: [Tick] = []
        for d in firstDay..<(firstDay + days) {
            let date = date(d)
            let wd = calendar.component(.weekday, from: date)
            let weekend = wd == 1 || wd == 7
            if weekend {
                if let last = weekends.last, last.upperBound == x(d) { weekends[weekends.count - 1] = last.lowerBound...x(d + 1) }
                else { weekends.append(x(d)...x(d + 1)) }
            }
            if wd == 2 {
                mondays.append(x(d))
                weeks.append(Tick(x: x(d), text: text(d)))
            }
            if zoom == .days {
                numbers.append(Tick(x: x(d), text: String(calendar.component(.day, from: date)), weekend: weekend, today: d == 0))
            }
        }
        return PlanGanttModel(zoom: zoom, firstDay: firstDay, rows: rows, arrows: arrows, weekends: weekends, mondays: mondays,
                              weeks: weeks, dayNumbers: numbers, todayX: x(0) + floor(dw / 2) - 1,
                              size: CGSize(width: x(firstDay + days), height: y + 8))
    }

    /// Right from the end of the blocker, then down or up into the item bar, near its start.
    /// An item that starts before its blocker ends goes around: 5 points.
    static func elbow(from a: NSRect, endX: CGFloat, to b: NSRect, startX: CGFloat) -> [CGPoint] {
        let down = b.minY > a.minY
        let y0 = a.midY, y1 = down ? b.minY : b.maxY
        let ix = startX + 6
        if ix >= endX + 4 {
            return [CGPoint(x: endX, y: y0), CGPoint(x: ix, y: y0), CGPoint(x: ix, y: y1)]
        }
        let gap = down ? b.minY - 4 : b.maxY + 4
        return [CGPoint(x: endX, y: y0), CGPoint(x: endX + 6, y: y0), CGPoint(x: endX + 6, y: gap), CGPoint(x: ix, y: gap), CGPoint(x: ix, y: y1)]
    }
}
