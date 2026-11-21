import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class CIQuotaTests: XCTestCase {
    func testNoBudgetIsNotDegraded() {
        XCTAssertFalse(CITestQuota.make().degraded)
        XCTAssertNil(CITestQuota.make().budget)
    }

    func testDegradedBelowTenPercent() {
        XCTAssertTrue(CITestQuota.make(remaining: 499).degraded)
        XCTAssertFalse(CITestQuota.make(remaining: 500).degraded)
    }

    func testPastWindowIsIgnored() {
        let meter = RateMeter()
        meter.record(RateBudget(limit: 5000, remaining: 1, resetAt: CITestQuota.now.addingTimeInterval(-60)), key: "gh")
        let q = CITestQuota.make(meter: meter)
        XCTAssertFalse(q.degraded)
        XCTAssertNil(q.budget)
    }

    func testSourceFollowsLink() {
        var live = false
        let q = CITestQuota.make(live: { live })
        XCTAssertEqual(q.source, .poll)
        live = true
        XCTAssertEqual(q.source, .webhook)
    }

    func testEvaluateFiresOnlyOnChange() {
        var live = false
        let meter = RateMeter()
        let q = CITestQuota.make(live: { live }, meter: meter)
        var fired = 0
        q.onChange { fired += 1 }
        q.evaluate()
        XCTAssertEqual(fired, 0)
        live = true
        q.evaluate()
        q.evaluate()
        XCTAssertEqual(fired, 1)
        meter.record(RateBudget(limit: 5000, remaining: 10, resetAt: CITestQuota.now.addingTimeInterval(60)), key: "gh")
        q.evaluate()
        XCTAssertEqual(fired, 2)
    }
}
