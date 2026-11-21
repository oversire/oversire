import XCTest
@testable import OverSireCore

final class RateMeterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func budget(_ remaining: Int, reset: TimeInterval = 3600, limit: Int = 5000) -> RateBudget {
        RateBudget(limit: limit, remaining: remaining, resetAt: now.addingTimeInterval(reset))
    }

    func testLowestTakesSmallestShare() {
        let m = RateMeter()
        m.record(budget(4000), key: "a")
        m.record(budget(100), key: "b")
        XCTAssertEqual(m.lowest(now: now)?.remaining, 100)
    }

    func testLowestIgnoresPastWindow() {
        let m = RateMeter()
        m.record(budget(10, reset: -5), key: "a")
        XCTAssertNil(m.lowest(now: now))
        m.record(budget(3000), key: "b")
        XCTAssertEqual(m.lowest(now: now)?.remaining, 3000)
    }

    func testSameWindowKeepsLowerRemaining() {
        let m = RateMeter()
        m.record(budget(100), key: "a")
        m.record(budget(200), key: "a")
        XCTAssertEqual(m.lowest(now: now)?.remaining, 100)
    }

    func testNewWindowReplaces() {
        let m = RateMeter()
        m.record(budget(100), key: "a")
        m.record(budget(4999, reset: 7200), key: "a")
        XCTAssertEqual(m.lowest(now: now)?.remaining, 4999)
        m.record(budget(5, reset: 10), key: "a")
        XCTAssertEqual(m.lowest(now: now)?.remaining, 4999, "an older window does not replace a newer one")
    }

    func testResourcesAreSeparate() {
        let m = RateMeter()
        m.record(budget(10), key: "a", resource: "search")
        XCTAssertNil(m.lowest(now: now))
        XCTAssertEqual(m.lowest(now: now, resource: "search")?.remaining, 10)
    }
}
