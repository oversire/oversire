import XCTest
@testable import OverSireCore

final class PlanScheduleTests: XCTestCase {
    typealias F = PlanFixture
    typealias Slot = PlanSchedule.Slot

    func testStartedKeepsStart() {
        var f = F()
        f.epic("e")
        f.item(1, "e", F.doing, start: -3, days: 2)
        f.item(2, "e", F.doing, start: -5, days: 1)
        f.item(3, "e", F.doing)
        let s = f.schedule
        XCTAssertEqual(s.slots[F.key(1)]?.start, -3)
        XCTAssertEqual(s.slots[F.key(1)]?.end, 1, "max(1, -3 + 2)")
        XCTAssertEqual(s.slots[F.key(2)]?.end, 1)
        XCTAssertEqual(s.slots[F.key(3)]?.start, 0, "no Start: today")
    }

    func testWaitsForBlockerEnd() {
        var f = F()
        f.epic("e")
        f.item(1, "e", days: 4)
        f.item(2, "e", days: 2)
        f.item(3, "e", F.done)
        f.item(4, "e")
        f.block(2, by: 1)
        f.block(4, by: 3, 99)
        let s = f.schedule
        XCTAssertEqual(s.slots[F.key(1)], Slot(start: 0, end: 4, slack: 0))
        XCTAssertEqual(s.slots[F.key(2)], Slot(start: 4, end: 6, slack: 0))
        XCTAssertEqual(s.slots[F.key(4)]?.start, 0, "a done and an external blocker do not move the start")
        XCTAssertNil(s.slots[F.key(3)], "no slot for a done item")
        XCTAssertEqual(s.end, 6)
    }

    func testCriticalPathAndSlack() {
        let s = F.demo.schedule
        func slot(_ n: Int) -> Slot? { s.slots[F.key(n)] }
        XCTAssertEqual(s.end, 10, "Nov 27 is the last day")
        XCTAssertEqual(slot(421), Slot(start: -2, end: 1, slack: 6))
        XCTAssertEqual(slot(426), Slot(start: 1, end: 3, slack: 6))
        XCTAssertEqual(slot(429), Slot(start: 3, end: 4, slack: 6))
        XCTAssertEqual(slot(440), Slot(start: 0, end: 2, slack: 0))
        XCTAssertEqual(slot(441), Slot(start: 2, end: 3, slack: 7))
        XCTAssertEqual(slot(425), Slot(start: -1, end: 1, slack: 9))
        XCTAssertEqual(slot(460), Slot(start: -1, end: 1, slack: 5))
        XCTAssertEqual(slot(470), Slot(start: 2, end: 5, slack: 2))
        XCTAssertEqual(slot(451), Slot(start: 1, end: 5, slack: 3))
        let critical = s.slots.filter(\.value.critical).keys.sorted(by: PlanGraph.keyOrder)
        XCTAssertEqual(critical, [431, 432, 435, 436, 440].map(F.key))
        XCTAssertTrue(s.criticalEdge(from: F.key(431), to: F.key(432)))
        XCTAssertTrue(s.criticalEdge(from: F.key(440), to: F.key(432)))
        XCTAssertFalse(s.criticalEdge(from: F.key(421), to: F.key(426)))
    }

    func testCriticalEdgeNeedsTouch() {
        let s = PlanSchedule(slots: ["A-1": Slot(start: 0, end: 2, slack: 0), "A-2": Slot(start: 3, end: 5, slack: 0)], end: 5)
        XCTAssertFalse(s.criticalEdge(from: "A-1", to: "A-2"))
        let t = PlanSchedule(slots: ["A-1": Slot(start: 0, end: 2, slack: 0), "A-2": Slot(start: 2, end: 5, slack: 0)], end: 5)
        XCTAssertTrue(t.criticalEdge(from: "A-1", to: "A-2"))
    }

    func testForecastLateBy() {
        var f = F()
        f.epic("e", due: 14)
        f.item(1, "e", days: 10)
        f.item(2, "e", days: 7)
        f.block(2, by: 1)
        let fc = f.schedule.forecast(f.epics[0], in: f.graph, today: F.today, calendar: F.calendar)
        XCTAssertEqual(fc, EpicForecast(start: 0, end: 17, lateBy: 2))
        XCTAssertTrue(fc.isLate)
    }

    func testForecastOfTheDemo() {
        let f = F.demo, g = f.graph, s = f.schedule
        func late(_ id: String) -> Int? { s.forecast(f.epics.first { $0.id.rawValue == id }!, in: g, today: F.today, calendar: F.calendar).lateBy }
        XCTAssertEqual(late("rd"), 5)
        XCTAssertEqual(late("cs"), -17)
        XCTAssertEqual(late("rb"), -12)
        XCTAssertEqual(late("c2"), -14)
        XCTAssertNil(late("pl"), "no target date")
        XCTAssertNil(late("ep"), "no open item")
    }

    func testEpicStartFallback() {
        var f = F()
        f.epic("e")
        f.epic("s", start: -4)
        f.epic("m")
        f.item(1, "m", F.doing, start: -2, days: 3)
        let g = f.graph, s = f.schedule
        XCTAssertEqual(s.forecast(f.epics[0], in: g, today: F.today, calendar: F.calendar), EpicForecast(start: 0, end: nil, lateBy: nil))
        XCTAssertEqual(s.forecast(f.epics[1], in: g, today: F.today, calendar: F.calendar).start, -4)
        XCTAssertEqual(s.forecast(f.epics[2], in: g, today: F.today, calendar: F.calendar).start, -2)
    }
}
