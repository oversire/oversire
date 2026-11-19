import OverSireCore
import XCTest
@testable import OverSireApp

final class PlanMapModelTests: XCTestCase {
    typealias M = PlanMapModel

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    private static let project = ProjectRef(account: AccountID(provider: "plane", id: "acme"), id: "4", key: "OVERSIRE")
    private static let todo = StatusOption(id: "todo", name: "Todo", color: "", group: "unstarted")
    private static let done = StatusOption(id: "done", name: "Done", color: "", group: "completed")

    private var items: [Item] = []
    private var epics: [Epic] = []
    private var relations: [String: [ItemRelation]] = [:]

    private static func key(_ n: Int) -> String { "OVERSIRE-\(n)" }

    private func item(_ n: Int, _ epic: String, _ status: StatusOption = todo) {
        items.append(Item(id: Self.key(n), key: Self.key(n), title: "Item \(n)", url: "", statusOptionId: status.id, fields: [:],
                          assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Self.today, activityAt: Self.today,
                          commentCount: 0, lastComment: nil, mentionsMe: false, epicId: EpicID(rawValue: epic)))
    }

    private func epic(_ id: String, _ state: EpicState = .active) {
        epics.append(Epic(id: EpicID(rawValue: id), title: id, state: state, url: "", project: Self.project))
    }

    private func block(_ n: Int, by b: Int) {
        let k = Self.key(b)
        relations[Self.key(n), default: []].append(ItemRelation(kind: .blockedBy, item: ItemRef(project: Self.project, id: k, key: k,
                                                                                               url: URL(string: "https://plane/\(k)")!)))
    }

    private func model(folded: Set<String> = [], critical: Bool = true) -> M {
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: Self.project, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [Self.todo, Self.done], items: items, fetchedAt: Self.today, epics: epics)
        let graph = PlanGraph.build(snap, epics: epics, relations: relations, signals: PlanSignals(), today: Self.today, calendar: Self.calendar)
        let schedule = PlanSchedule.build(graph)
        let lanes = PlanMap.lanes(graph, schedule: schedule, epics: graph.epics, mode: .all)
        return M.build(lanes: lanes, graph: graph, schedule: schedule, folded: Set(folded.map(EpicID.init(rawValue:))), showCritical: critical)
    }

    /// A→B→C in epic "a".
    private func chain() {
        epic("a")
        item(1, "a"); item(2, "a"); item(3, "a")
        block(2, by: 1); block(3, by: 2)
    }

    func testColumnsToX() {
        chain()
        let m = model()
        let b = m.node(Self.key(2))!
        XCTAssertEqual(b.column, 2)
        XCTAssertEqual(b.frame.minX, M.labelW + 2 * M.colW + M.inset)
        XCTAssertEqual(m.node(Self.key(1))!.frame.minX, M.labelW + M.colW + M.inset)
    }

    func testFoldedLaneHasNoNodes() {
        epic("a"); epic("b")
        item(1, "a"); item(2, "a"); item(3, "a"); item(4, "a", Self.done)
        item(10, "b")
        block(2, by: 10)
        let m = model(folded: ["a"])
        let lane = m.lanes.first { $0.epic.rawValue == "a" }!
        XCTAssertTrue(lane.folded)
        XCTAssertNil(lane.pill)
        XCTAssertEqual(lane.height, M.foldedH)
        XCTAssertTrue(m.nodes.allSatisfy { $0.key == Self.key(10) })
        XCTAssertEqual(lane.foldText, "3 open · 1 link to other epics")
    }

    func testCrossEpicEdgeDashed() {
        epic("a"); epic("b")
        item(1, "a"); item(2, "b"); item(3, "b")
        block(2, by: 1); block(3, by: 2)
        let m = model()
        XCTAssertEqual(m.edges.first { $0.from == Self.key(1) }?.crossEpic, true)
        XCTAssertEqual(m.edges.first { $0.from == Self.key(2) }?.crossEpic, false)
    }

    func testCriticalOffHidesMarks() {
        chain()
        XCTAssertTrue(model().nodes.contains(where: \.critical))
        XCTAssertTrue(model().edges.contains(where: \.critical))
        let m = model(critical: false)
        XCTAssertFalse(m.nodes.contains(where: \.critical))
        XCTAssertFalse(m.edges.contains(where: \.critical))
    }

    func testRelatedSet() {
        chain()
        item(4, "a")
        XCTAssertEqual(model().related(to: Self.key(2)), [Self.key(1), Self.key(2), Self.key(3)])
        XCTAssertEqual(model().related(to: Self.key(4)), [Self.key(4)])
    }

    func testArrowNavigation() {
        chain()
        epic("b")
        item(10, "b")
        let m = model()
        XCTAssertEqual(m.next(from: Self.key(1), .right), Self.key(2))
        XCTAssertEqual(m.next(from: Self.key(2), .left), Self.key(1))
        XCTAssertNil(m.next(from: Self.key(1), .left))
        XCTAssertEqual(m.next(from: Self.key(1), .down), Self.key(10))
        XCTAssertEqual(m.next(from: Self.key(10), .up), Self.key(1))
    }

    func testDonePillAndEdgePath() {
        chain()
        item(5, "a", Self.done)
        let m = model()
        let lane = m.lanes[0]
        XCTAssertEqual(lane.doneCount, 1)
        XCTAssertEqual(lane.pill?.minX, M.labelW + M.inset)
        let e = m.edges.first { $0.from == Self.key(1) }!
        XCTAssertEqual(e.path.first!.x, m.node(Self.key(1))!.frame.maxX)
        XCTAssertEqual(e.path.last!.x + 7, m.node(Self.key(2))!.frame.minX)
        XCTAssertEqual(m.size.width, M.labelW + 5 * M.colW)
    }
}
