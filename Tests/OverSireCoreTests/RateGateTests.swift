import XCTest
import OverSireCore

/// A test clock for RateGate: a sleep moves the time at once.
final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date(timeIntervalSince1970: 1_800_000_000)
    private var slept: [TimeInterval] = []

    var now: Date { lock.withLock { at } }
    var sleeps: [TimeInterval] { lock.withLock { slept } }

    var clock: RateGate.Clock {
        RateGate.Clock(now: { self.now }, sleep: { s in
            self.lock.withLock {
                self.slept.append(s)
                self.at = self.at.addingTimeInterval(s)
            }
            await Task.yield()
        })
    }
}

final class Budget: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(_ n: Int) { self.n = n }
    var value: Int {
        get { lock.withLock { n } }
        set { lock.withLock { n = newValue } }
    }
}

final class RateGateTests: XCTestCase {
    func testBudgetSpacesTheCalls() async throws {
        let c = GateClock()
        let gate = RateGate(perMinute: { 6 }, concurrent: 10, clock: c.clock)
        let start = c.now
        for _ in 0..<6 {
            try await gate.enter()
            await gate.leave()
        }
        XCTAssertEqual(c.now, start, "a full bucket gives 6 calls at once")
        try await gate.enter()
        await gate.leave()
        XCTAssertEqual(c.now.timeIntervalSince(start), 10, accuracy: 0.01, "the 7th call waits one token: 60 s / 6")
    }

    func testBudgetFollowsTheLease() async throws {
        let c = GateClock()
        let budget = Budget(40)
        let gate = RateGate(perMinute: { budget.value }, concurrent: 10, clock: c.clock)
        budget.value = 15
        let start = c.now
        for _ in 0..<16 {
            try await gate.enter()
            await gate.leave()
        }
        XCTAssertEqual(c.now.timeIntervalSince(start), 4, accuracy: 0.01, "the bucket shrinks to 15, then 60 s / 15")
    }

    func testAtMostTwoAtATime() async throws {
        let gate = RateGate(perMinute: { 100 }, clock: GateClock().clock)
        try await gate.enter()
        try await gate.enter()
        let third = Task { try await gate.enter() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let waits = expectation(description: "third enters")
        Task {
            _ = try await third.value
            waits.fulfill()
        }
        await gate.leave()
        await fulfillment(of: [waits], timeout: 2)
    }

    func testPauseHoldsAllCallers() async throws {
        let c = GateClock()
        let gate = RateGate(perMinute: { 60 }, concurrent: 10, clock: c.clock)
        let start = c.now
        let first = await gate.pause(retryAfter: nil)
        XCTAssertEqual(first, RateGate.defaultPause)
        let again = await gate.pause(retryAfter: 5)
        XCTAssertNil(again, "a pause in a pause makes no new log line")
        try await gate.enter()
        XCTAssertGreaterThanOrEqual(c.now.timeIntervalSince(start), RateGate.defaultPause)
        let long = await gate.pause(retryAfter: 3600)
        XCTAssertEqual(long, RateGate.maxPause)
    }

    func testCancelledCallerStops() async {
        let gate = RateGate(perMinute: { 1 }, concurrent: 1, clock: .system)
        try? await gate.enter()
        await gate.leave()
        let t = Task { try await gate.enter() }
        t.cancel()
        do {
            try await t.value
            XCTFail("a cancelled caller enters")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
