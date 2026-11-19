import XCTest
@testable import OverSireCore

final class PlanGraphTests: XCTestCase {
    typealias F = PlanFixture

    func testStateOrder() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, "e", F.backlog)
        f.item(3, "e")
        f.item(4, "e", F.backlog)
        f.item(5, "e", F.done)
        f.block(2, by: 3)
        f.signals = PlanSignals(working: [F.key(1): "Claude on mba"], input: [F.key(1): "Why?"])
        XCTAssertEqual(f.node(1)?.state, .working, "working wins over input")
        XCTAssertEqual(f.node(2)?.state, .waits, "an open blocker wins over no spec")
        XCTAssertEqual(f.node(3)?.state, .ready)
        XCTAssertEqual(f.node(4)?.state, .nospec)
        XCTAssertEqual(f.node(5)?.state, .done)
        XCTAssertEqual(f.node(1)?.started, true)
        XCTAssertEqual(f.node(3)?.started, false)
    }

    func testOnlyOpenEpics() {
        var f = F()
        f.epic("a")
        f.epic("p", .none, .planned)
        f.epic("x", .none, .done)
        f.item(1, "a")
        f.item(2, "p")
        f.item(3, "x")
        f.item(4, nil)
        XCTAssertEqual(Set(f.graph.nodes.keys), [F.key(1), F.key(2)])
        XCTAssertEqual(f.graph.epics.map(\.id), ["a", "p"])
    }

    func testDoneBlockerIsNotOpen() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, "e", F.done)
        f.item(3, nil, F.done)
        f.block(1, by: 2, 3)
        XCTAssertEqual(f.node(1)?.blockers, [])
        XCTAssertEqual(f.node(1)?.external, [])
        XCTAssertEqual(f.node(1)?.state, .ready)
    }

    func testUnknownBlockerStaysOpen() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, nil)
        f.block(1, by: 99, 2)
        XCTAssertEqual(f.node(1)?.blockers, [])
        XCTAssertEqual(f.node(1)?.external, [F.key(99), F.key(2)])
        XCTAssertEqual(f.node(1)?.state, .waits)
    }

    func testBlocksRelationOfTheOtherItem() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, "e")
        f.relations[F.key(2)] = [ItemRelation(kind: .blocks, item: F.ref(F.key(1)))]
        f.block(1, by: 2)
        XCTAssertEqual(f.node(1)?.blockers, [F.key(2)], "one edge, also when both sides tell it")
    }

    func testCycleDropsOneEdge() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, "e")
        f.block(1, by: 2)
        f.block(2, by: 1)
        let g = f.graph
        XCTAssertEqual(g.dropped, [PlanEdge(from: F.key(1), to: F.key(2))])
        XCTAssertEqual(g.order, [F.key(2), F.key(1)])
        XCTAssertEqual(g.nodes[F.key(1)]?.blockers, [F.key(2)])
    }

    func testOrderIsTopologicalWithKeyTies() {
        var f = F()
        f.epic("e")
        for n in [10, 9, 2, 1] { f.item(n, "e") }
        f.block(1, by: 10)
        XCTAssertEqual(f.graph.order, [F.key(2), F.key(9), F.key(10), F.key(1)])
        XCTAssertEqual(f.graph.dependents(of: F.key(10)), [F.key(1)])
    }

    func testDepthColumns() {
        var f = F()
        f.epic("e")
        for n in 1...6 { f.item(n, "e", n == 6 ? F.done : F.todo) }
        for n in 2...5 { f.block(n, by: n - 1) }
        let g = f.graph
        XCTAssertEqual((1...5).map { g.depth(F.key($0)) }, [1, 2, 3, 4, 5])
        XCTAssertEqual((1...5).map { g.column(F.key($0)) }, [1, 2, 3, 4, 4])
        XCTAssertEqual(g.column(F.key(6)), 0)
        XCTAssertEqual(g.members(of: "e"), (1...6).map(F.key))
    }

    func testDurationFromStartDue() {
        var f = F()
        f.item(1, nil)
        f.items[0] = Item(id: "1", key: "K-1", title: "", url: "", statusOptionId: nil, fields: ["Start": "2026-11-02", "Due": "2026-11-04"],
                          assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: F.today, activityAt: F.today, commentCount: 0,
                          lastComment: nil, mentionsMe: false)
        XCTAssertEqual(PlanGraph.duration(f.items[0], calendar: F.calendar, defaultDays: 2), 3)
        f.item(2, nil, start: 0)
        XCTAssertEqual(PlanGraph.duration(f.items[1], calendar: F.calendar, defaultDays: 2), 2, "no Due")
        XCTAssertEqual(PlanGraph.duration(f.items[1], calendar: F.calendar, defaultDays: 5), 5)
    }

    func testStartDayOnlyWhenStarted() {
        var f = F()
        f.epic("e")
        f.item(1, "e", F.doing, start: -3, days: 2)
        f.item(2, "e", F.todo, start: 4, days: 2)
        XCTAssertEqual(f.node(1)?.startDay, -3)
        XCTAssertNil(f.node(2)?.startDay)
        XCTAssertEqual(f.node(2)?.dueDay, 5)
    }

    func testKeyOrderIsNumeric() {
        XCTAssertEqual(["ENG-10", "ENG-9", "ABC-100"].sorted(by: PlanGraph.keyOrder), ["ABC-100", "ENG-9", "ENG-10"])
    }
}
