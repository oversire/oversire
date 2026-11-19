import XCTest
@testable import OverSireCore

final class PlanStepsTests: XCTestCase {
    typealias F = PlanFixture

    func steps(_ f: PlanFixture, _ epic: EpicID) -> PlanSteps {
        let g = f.graph
        return PlanSteps.build(epic: epic, graph: g, schedule: PlanSchedule.build(g))
    }

    func testDoneFirstThenScheduleOrder() {
        let s = steps(F.demo, "rd")
        XCTAssertEqual(s.done, (316...321).map(F.key))
        XCTAssertEqual(s.open.map(\.key), [421, 425, 426, 429].map(F.key))
        XCTAssertEqual(s.open.map(\.number), [7, 8, 9, 10])
        XCTAssertEqual(s.open.map(\.state), [.input, .working, .waits, .waits])
    }

    func testWaitsOnStepNumber() {
        let s = steps(F.demo, "rd")
        XCTAssertEqual(s.open[3].waitsOnStep, 9, "step 10 waits on step 9")
        XCTAssertNil(s.open[3].waitsOnKey)
        XCTAssertNil(s.open[0].waitsOnStep)
    }

    func testExternalBlocker() {
        let mc = steps(F.demo, "mc")
        let approve = mc.open.first { $0.key == F.key(437) }!
        XCTAssertNil(approve.waitsOnStep)
        XCTAssertEqual(approve.waitsOnKey, F.key(421), "the blocker is in another epic")

        let cs = steps(F.demo, "cs")
        let sync = cs.open.first { $0.key == F.key(432) }!
        XCTAssertEqual(sync.waitsOnStep, 3, "a blocker in the same epic wins")
        XCTAssertNil(sync.waitsOnKey)

        var f = F()
        f.epic("e")
        f.item(1, "e")
        f.block(1, by: 77)
        XCTAssertEqual(steps(f, "e").open[0].waitsOnKey, F.key(77))
    }

    func testWhereWeAreText() {
        let f = F.demo, g = f.graph, sch = PlanSchedule.build(g)
        let rd = f.epics[0]
        let text = PlanSteps.build(epic: rd.id, graph: g, schedule: sch).whereWeAre(
            rollup: f.snap.rollup(rd, now: F.today), forecast: sch.forecast(rd, in: g, today: F.today, calendar: F.calendar), title: f.title)
        XCTAssertEqual(text, "6 of 10 done. 5 days late. Next: Keyboard review.")

        let cs = f.epics[1]
        let onTime = PlanSteps.build(epic: cs.id, graph: g, schedule: sch).whereWeAre(
            rollup: f.snap.rollup(cs, now: F.today), forecast: sch.forecast(cs, in: g, today: F.today, calendar: F.calendar), title: f.title)
        XCTAssertEqual(onTime, "2 of 5 done. On time. Next: Store schema.")
    }
}
