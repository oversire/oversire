import XCTest
@testable import OverSireCore

final class PlanSummaryTests: XCTestCase {
    typealias F = PlanFixture

    func summary(_ f: PlanFixture) -> (PlanLanes, PlanSummary) {
        let g = f.graph, s = PlanSchedule.build(g), snap = f.snap
        let lanes = PlanLanes.build(snap, graph: g, schedule: s, today: F.today, calendar: F.calendar)
        return (lanes, PlanSummary.build(snap, graph: g, schedule: s, lanes: lanes, today: F.today, calendar: F.calendar))
    }

    func testNowLateFirst() {
        var f = F()
        f.epic("ontime", due: 10)
        f.epic("late", due: 0)
        f.item(1, "ontime", days: 11)
        f.item(2, "late", days: 6)
        let (lanes, sum) = summary(f)
        XCTAssertEqual(lanes.now, ["late", "ontime"])
        XCTAssertEqual(sum.now.map(\.forecast.lateBy), [5, 0])
        XCTAssertEqual(sum.focusEpic, "late")
    }

    func testLanesOfTheDemo() {
        let (lanes, sum) = summary(F.demo)
        XCTAssertEqual(lanes.now, ["rd", "rb", "cs"])
        XCTAssertEqual(lanes.readyToClose, ["ep"])
        XCTAssertEqual(lanes.next, ["mc", "c2", "pl", "ln", "gl"])
        XCTAssertEqual(sum.next.map(\.epic), lanes.next)
        XCTAssertEqual(sum.next.first?.forecast.lateBy, -31)
        XCTAssertEqual(sum.end, 10)
        XCTAssertEqual(sum.focusQuestion, F.key(421))
        let rd = sum.now[0]
        XCTAssertEqual(rd.steps, [421, 425, 426].map(F.key))
        XCTAssertEqual(rd.more, 1)
        XCTAssertNil(rd.startKey, "426 waits for 421")
        XCTAssertEqual(sum.now[2].startKey, F.key(431))
    }

    func testStepsOrderAndStartKey() {
        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.item(2, "e")
        f.item(3, "e")
        f.block(2, by: 99)
        f.signals = PlanSignals(input: [F.key(1): "Why?"])
        let (_, sum) = summary(f)
        XCTAssertEqual(sum.now[0].steps, [1, 2, 3].map(F.key), "equal start: input first, then key")
        XCTAssertEqual(sum.now[0].startKey, F.key(3), "2 has an open blocker")
    }

    func testUpNextOrderAndCap() {
        var f = F()
        f.epic("a")
        f.epic("z")
        f.item(9, "z", F.done)
        for n in 1...3 { f.item(n, "a") }
        f.signals = PlanSignals(input: Dictionary(uniqueKeysWithValues: (1...3).map { (F.key($0), "Q") }))
        f.item(11, "a", days: 1)
        f.item(12, "a", days: 1)
        f.item(13, "a", days: 3)
        f.item(14, "a", days: 2)
        f.item(20, "a", days: 5)
        f.block(20, by: 11)
        let (_, sum) = summary(f)
        XCTAssertEqual(sum.upNext, [.answer(F.key(1)), .answer(F.key(2)), .answer(F.key(3)), .close("z"),
                                    .start(F.key(11), critical: true, slack: 0), .start(F.key(13), critical: false, slack: 3)])
    }

    func testUpNextOfTheDemo() {
        let (_, sum) = summary(F.demo)
        XCTAssertEqual(sum.upNext, [.answer(F.key(421)), .close("ep"), .start(F.key(431), critical: true, slack: 0),
                                    .start(F.key(440), critical: true, slack: 0), .start(F.key(450), critical: false, slack: 3)])
    }

    func testPlanOnlyActiveNospec() {
        var f = F()
        f.epic("a")
        f.epic("p", .none, .planned)
        f.item(1, "a", F.backlog)
        f.item(2, "p", F.backlog)
        f.item(3, "a", F.backlog)
        f.block(3, by: 1)
        let (_, sum) = summary(f)
        XCTAssertEqual(sum.upNext, [.plan(F.key(1))])
    }

    func testAwayCountsAndSentence() {
        var f = F.demo
        let since = F.today.addingTimeInterval(-86400)
        f.item(500, "rd", F.done, updatedAt: F.today.addingTimeInterval(-3600))
        f.item(501, nil, F.done, updatedAt: F.today.addingTimeInterval(-7200))
        let g = f.graph, s = f.schedule
        let (_, sum) = summary(f)
        let away = PlanAway.build(f.snap, summary: sum, schedule: s, graph: g, since: since)
        XCTAssertEqual(away.done, [F.key(500), F.key(501)])
        XCTAssertEqual(away.readyToClose, ["ep"])
        XCTAssertEqual(away.late, ["rd"])
        XCTAssertEqual(away.questions, [F.key(421)])
        XCTAssertEqual(away.sentence(name: f.name, title: f.title),
                       "Epics shipped. Review desk slipped. An agent waits on your answer on approval checks.")
        XCTAssertEqual(PlanAway(done: [], readyToClose: [], late: [], questions: []).sentence(name: f.name, title: f.title),
                       "No agent waits on you.")
        XCTAssertEqual(PlanAway.inline("CI checks"), "CI checks")
    }

    func testMapActiveAndLinked() {
        var f = F()
        f.epic("a")
        f.epic("p", .none, .planned)
        f.epic("q", .none, .planned)
        f.item(1, "a")
        f.item(2, "p")
        f.item(3, "q")
        f.block(1, by: 2)
        let g = f.graph, s = f.schedule
        XCTAssertEqual(PlanMap.lanes(g, schedule: s, epics: g.epics, mode: .activeAndLinked).map(\.epic), ["a", "p"])
        XCTAssertEqual(PlanMap.lanes(g, schedule: s, epics: g.epics, mode: .all).map(\.epic), ["a", "p", "q"])

        let d = F.demo, dg = d.graph
        XCTAssertEqual(PlanMap.lanes(dg, schedule: d.schedule, epics: dg.epics, mode: .activeAndLinked).map(\.epic),
                       ["rd", "cs", "rb", "ep", "mc", "c2", "pl"])
    }

    func testMapColumns() {
        let d = F.demo, g = d.graph
        let cs = PlanMap.lanes(g, schedule: d.schedule, epics: g.epics, mode: .all).first { $0.epic == "cs" }!
        XCTAssertEqual(cs.columns, [[F.key(431)], [F.key(432)], [F.key(433)], []])
        XCTAssertEqual(cs.done, [300, 301].map(F.key))
        XCTAssertEqual(cs.open, 3)
        XCTAssertEqual(cs.crossLinks, 3)
        let rd = PlanMap.lanes(g, schedule: d.schedule, epics: g.epics, mode: .all).first { $0.epic == "rd" }!
        XCTAssertEqual(rd.columns, [[F.key(421), F.key(425)], [F.key(426)], [F.key(429)], []], "slot start, then key")
    }

    func testFoldedCrossLinks() {
        var f = F()
        f.epic("a")
        f.epic("b")
        f.item(1, "a")
        f.item(2, "a")
        f.item(3, "b")
        f.item(4, "b")
        f.block(3, by: 1)
        f.block(2, by: 4)
        f.block(2, by: 1)
        let g = f.graph
        XCTAssertEqual(PlanMap.lanes(g, schedule: f.schedule, epics: g.epics, mode: .all).map(\.crossLinks), [2, 2])
    }
}
