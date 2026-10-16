import XCTest
import OverSireCore
@testable import OverSireSync

final class PollSchedulerTests: XCTestCase {
    let policy = PollPolicy(minInterval: .seconds(15), requestsPerHour: 5000)

    func testModeIntervalsAndFloor() {
        let s = PollScheduler(policy: policy)
        XCTAssertEqual(s.delay(mode: .normal), .seconds(30))
        XCTAssertEqual(s.delay(mode: .active), .seconds(15), "the vendor floor wins over 10 s")
        XCTAssertEqual(s.delay(mode: .safety), .seconds(600))
    }

    func testBackoffGrowsAndResets() {
        var s = PollScheduler(policy: policy)
        s.failed(ProviderError.transport("down"))
        XCTAssertEqual(s.delay(mode: .normal), .seconds(60))
        s.failed(ProviderError.transport("down"))
        XCTAssertEqual(s.delay(mode: .normal), .seconds(120))
        for _ in 0..<10 { s.failed(ProviderError.transport("down")) }
        XCTAssertEqual(s.delay(mode: .normal), .seconds(600), "capped")
        s.succeeded()
        XCTAssertEqual(s.delay(mode: .normal), .seconds(30))
    }

    func testRateLimitRetryAfter() {
        var s = PollScheduler(policy: policy)
        s.failed(ProviderError.rateLimited(retryAfter: .seconds(900)))
        XCTAssertEqual(s.delay(mode: .active), .seconds(900))
        s.succeeded(retryAfter: .seconds(45))
        XCTAssertEqual(s.delay(mode: .normal), .seconds(45), "a page can ask for a pause too")
    }

    func testBudget() {
        let s = PollScheduler(policy: policy)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let low = RateBudget(limit: 5000, remaining: 400, resetAt: now.addingTimeInterval(1200))
        XCTAssertEqual(s.delay(mode: .active, budget: low, now: now), .seconds(1200), "the reserve waits for the reset")
        let tight = RateBudget(limit: 5000, remaining: 520, resetAt: now.addingTimeInterval(1200))
        XCTAssertEqual(s.delay(mode: .normal, budget: tight, now: now), .seconds(60), "1200 s over 20 calls")
        let plenty = RateBudget(limit: 5000, remaining: 4900, resetAt: now.addingTimeInterval(1200))
        XCTAssertEqual(s.delay(mode: .normal, budget: plenty, now: now), .seconds(30))
    }

    func testBackoffAndRecentIDs() {
        var b = Backoff()
        XCTAssertEqual([b.next(jitter: 0), b.next(jitter: 0), b.next(jitter: 0)], [.seconds(1), .seconds(2), .seconds(4)])
        for _ in 0..<10 { _ = b.next(jitter: 0) }
        XCTAssertEqual(b.next(jitter: 0), .seconds(60))
        b.reset()
        XCTAssertEqual(b.next(jitter: 0.2).timeInterval, 1.2, accuracy: 1e-9)

        var ids = RecentIDs(capacity: 2)
        XCTAssertTrue(ids.insert("a"))
        XCTAssertFalse(ids.insert("a"))
        ids.insert("b")
        ids.insert("c")
        XCTAssertFalse(ids.contains("a"), "the oldest id leaves")
        XCTAssertTrue(ids.contains("c"))
    }
}
