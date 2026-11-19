import OverSireCore
import XCTest
@testable import OverSireApp

final class PlanGanttModelTests: XCTestCase {
    typealias M = PlanGanttModel

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// A Monday.
    private static let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    private static let project = ProjectRef(account: AccountID(provider: "plane", id: "acme"), id: "4", key: "OVERSIRE")
    private static let todo = StatusOption(id: "todo", name: "Todo", color: "", group: "unstarted")
    private static let doing = StatusOption(id: "doing", name: "In Progress", color: "", group: "started")
    private static let done = StatusOption(id: "done", name: "Done", color: "", group: "completed")

    private var items: [Item] = []
    private var epics: [Epic] = []
    private var relations: [String: [ItemRelation]] = [:]

    private static func key(_ n: Int) -> String { "OVERSIRE-\(n)" }
    private static func date(_ d: PlanDay) -> Date { calendar.date(byAdding: .day, value: d, to: calendar.startOfDay(for: today))! }
    private static func ymd(_ d: PlanDay) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date(d))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func item(_ n: Int, _ epic: String, _ status: StatusOption = todo, start: PlanDay? = nil, days: Int? = nil) {
        var fields: [String: String] = [:]
        if let days {
            fields["Start"] = Self.ymd(start ?? 0)
            fields["Due"] = Self.ymd((start ?? 0) + days - 1)
        }
        items.append(Item(id: Self.key(n), key: Self.key(n), title: "Item \(n)", url: "", statusOptionId: status.id, fields: fields,
                          assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Self.today, activityAt: Self.today,
                          commentCount: 0, lastComment: nil, mentionsMe: false, epicId: EpicID(rawValue: epic)))
    }

    private func epic(_ id: String, _ state: EpicState = .active, start: PlanDay? = nil, due: PlanDay? = nil) {
        epics.append(Epic(id: EpicID(rawValue: id), title: id, state: state, startDate: start.map(Self.date), targetDate: due.map(Self.date),
                          url: "", project: Self.project))
    }

    private func block(_ n: Int, by b: Int) {
        let k = Self.key(b)
        relations[Self.key(n), default: []].append(ItemRelation(kind: .blockedBy, item: ItemRef(project: Self.project, id: k, key: k,
                                                                                               url: URL(string: "https://plane/\(k)")!)))
    }

    private func model(zoom: M.Zoom = .days, folded: Set<EpicID> = [], firstDay: PlanDay = 0, days: Int = 14) -> M {
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: Self.project, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [Self.todo, Self.doing, Self.done], items: items, fetchedAt: Self.today, epics: epics)
        let graph = PlanGraph.build(snap, epics: epics, relations: relations, signals: PlanSignals(), today: Self.today, calendar: Self.calendar)
        let schedule = PlanSchedule.build(graph)
        let forecasts = Dictionary(uniqueKeysWithValues: graph.epics.map { ($0.id, schedule.forecast($0, in: graph, today: Self.today, calendar: Self.calendar)) })
        return M.build(graph: graph, schedule: schedule, epics: graph.epics, forecasts: forecasts, folded: folded, zoom: zoom,
                       firstDay: firstDay, days: days, today: Self.today, calendar: Self.calendar)
    }

    func testXForDay() {
        let m = model(firstDay: -5)
        XCTAssertEqual(m.x(3), M.label + 3 * 20 - (-5) * 20)
        XCTAssertEqual(model(zoom: .weeks, firstDay: -5).x(3), M.label + 8 * 9)
    }

    func testWeekendsAndMondays() {
        let m = model(firstDay: 0, days: 14)
        XCTAssertEqual(m.weekends, [m.x(5)...m.x(7), m.x(12)...m.x(14)])
        XCTAssertEqual(m.mondays, [m.x(0), m.x(7)])
        XCTAssertEqual(m.weeks.count, 2)
        XCTAssertEqual(m.dayNumbers.count, 14)
        XCTAssertEqual(m.dayNumbers.filter(\.today).map(\.text), ["16"])
        XCTAssertTrue(model(zoom: .weeks).dayNumbers.isEmpty)
    }

    func testEpicBarFromStartToForecast() {
        epic("e", start: 2)
        item(1, "e", days: 4)
        item(2, "e", days: 5)
        block(2, by: 1)
        let m = model()
        guard let row = m.rows.first, let e = row.epic else { return XCTFail("no epic row") }
        XCTAssertEqual(row.bar, m.x(2)...m.x(9))
        XCTAssertFalse(e.planned)
        XCTAssertEqual(m.rows.count, 3)
        XCTAssertEqual(m.rows[1].y, M.head + M.epicRow)
        XCTAssertEqual(m.rows[2].bar, (m.x(4) + 1)...(m.x(4) + 1 + 5 * 20 - 2))
    }

    func testPlannedEpicDashed() {
        epic("p", .planned, due: 3)
        item(1, "p", days: 6)
        let m = model()
        guard let e = m.rows.first?.epic else { return XCTFail("no epic row") }
        XCTAssertTrue(e.planned)
        XCTAssertEqual(e.dueX, m.x(4))
        XCTAssertEqual(e.late, 2)
        XCTAssertEqual(e.sub, "0/1 · ▲ 2d late")
    }

    func testElbowArrow() {
        epic("e")
        item(1, "e", days: 4)
        item(2, "e", days: 2)
        block(2, by: 1)
        let m = model()
        XCTAssertEqual(m.arrows.count, 1)
        let a = m.arrows[0]
        XCTAssertEqual(a.from, Self.key(1))
        XCTAssertEqual(a.points.count, 3)
        XCTAssertEqual(a.points.first?.x, m.x(4))
        XCTAssertEqual(a.points.last?.y, m.row(key: Self.key(2))!.barRect!.minY)
        XCTAssertTrue(a.critical)
    }

    func testFoldedEpicHidesItems() {
        epic("a")
        epic("b")
        item(1, "a", days: 2)
        item(2, "b", days: 2)
        item(3, "b", Self.done)
        block(2, by: 1)
        let m = model(folded: [EpicID(rawValue: "b")])
        XCTAssertEqual(m.rows.map(\.label), ["a", "Item 1", "b"])
        XCTAssertEqual(m.rows.last?.epic?.folded, true)
        XCTAssertEqual(m.rows.last?.epic?.done, 1)
        XCTAssertEqual(m.rows.last?.epic?.total, 2)
        XCTAssertTrue(m.arrows.isEmpty, "no arrow to a folded item")
    }

    func testRangeStartsOnMonday() {
        epic("e", start: -20, due: 60)
        item(1, "e", days: 2)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: Self.project, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [Self.todo], items: items, fetchedAt: Self.today, epics: epics)
        let graph = PlanGraph.build(snap, epics: epics, relations: [:], signals: PlanSignals(), today: Self.today, calendar: Self.calendar)
        let s = PlanSchedule.build(graph)
        let f = [epics[0].id: s.forecast(epics[0], in: graph, today: Self.today, calendar: Self.calendar)]
        let r = M.range(schedule: s, epics: epics, forecasts: f, today: Self.today, calendar: Self.calendar)
        XCTAssertEqual(r.firstDay, -21)
        XCTAssertEqual(Self.calendar.component(.weekday, from: Self.date(r.firstDay)), 2)
        XCTAssertGreaterThanOrEqual(r.firstDay + r.days, 61 + 14)
        XCTAssertEqual(r.days % 7, 0)
    }
}
