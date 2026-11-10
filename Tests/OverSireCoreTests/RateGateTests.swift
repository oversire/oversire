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

    // MARK: Priority (OVERSIRE-456)

    func testUserCallPassesWaitingBackgroundCalls() async throws {
        let gate = RateGate(perMinute: { 1000 }, concurrent: 1, clock: GateClock().clock)
        let order = Order()
        try await gate.enter(priority: .background)
        for (name, p) in [("bg1", CallPriority.background), ("bg2", .background), ("user", .user)] {
            Task {
                try await gate.enter(priority: p)
                await order.add(name)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        for _ in 0..<3 {
            await gate.leave()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let seen = await order.list
        XCTAssertEqual(seen, ["user", "bg1", "bg2"])
    }

    func testUserCallPassesBackgroundInTheTokenWait() async throws {
        let c = SleepGateClock()
        let gate = RateGate(perMinute: { 6 }, concurrent: 2, clock: c.clock)
        for _ in 0..<6 {
            try await gate.enter()
            await gate.leave()
        }
        let order = Order()
        Task {
            try await gate.enter(priority: .background)
            await order.add("bg")
        }
        try await c.waitForSleepers(1)
        Task {
            try await gate.enter(priority: .user)
            await order.add("user")
        }
        try await c.waitForSleepers(2)
        c.advance(10)
        try await Task.sleep(nanoseconds: 50_000_000)
        var seen = await order.list
        XCTAssertEqual(seen, ["user"], "the user call takes the token")
        try await c.waitForSleepers(1)
        c.advance(10)
        try await Task.sleep(nanoseconds: 50_000_000)
        seen = await order.list
        XCTAssertEqual(seen, ["user", "bg"])
    }

    func testReservedSlotStaysFreeForUserCalls() async throws {
        let gate = RateGate(perMinute: { 1000 }, concurrent: 2, reserved: 1, clock: GateClock().clock)
        try await gate.enter(priority: .background)
        let order = Order()
        let second = Task {
            try await gate.enter(priority: .background)
            await order.add("bg2")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        var seen = await order.list
        XCTAssertEqual(seen, [], "the second background call waits")
        try await gate.enter(priority: .user)
        await gate.leave()
        await gate.leave()
        _ = try await second.value
        seen = await order.list
        XCTAssertEqual(seen, ["bg2"], "a background call enters when a slot is free")
    }

    func testEnterReturnsTheWait() async throws {
        let gate = RateGate(perMinute: { 6 }, concurrent: 10, clock: GateClock().clock)
        for _ in 0..<6 {
            let waited = try await gate.enter()
            XCTAssertEqual(waited, 0)
            await gate.leave()
        }
        let waited = try await gate.enter()
        XCTAssertEqual(waited, 10, accuracy: 0.01)
    }

    func testUserWaitingIsCountedOnCancel() async throws {
        let gate = RateGate(perMinute: { 1000 }, concurrent: 1, clock: GateClock().clock)
        try await gate.enter(priority: .background)
        let user = Task { try await gate.enter(priority: .user) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let order = Order()
        let bg = Task {
            try await gate.enter(priority: .background)
            await order.add("bg")
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        user.cancel()
        do {
            _ = try await user.value
            XCTFail("a cancelled caller enters")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await gate.leave()
        _ = try await bg.value
        let seen = await order.list
        XCTAssertEqual(seen, ["bg"])
    }

    func testMixedAndCancelledCallsAllEnd() async throws {
        let gate = RateGate(perMinute: { 100_000 }, concurrent: 2, reserved: 1, clock: GateClock().clock)
        let ended = expectation(description: "all callers end")
        ended.expectedFulfillmentCount = 300
        for n in 0..<300 {
            let t = Task {
                defer { ended.fulfill() }
                do {
                    try await gate.enter(priority: n % 3 == 0 ? .user : .background)
                    await Task.yield()
                    await gate.leave()
                } catch {}
            }
            if n % 5 == 0 { t.cancel() }
        }
        await fulfillment(of: [ended], timeout: 10)
    }

    func testPriorityIsATaskLocal() async {
        XCTAssertEqual(CallPriority.current, .background)
        await CallPriority.user {
            XCTAssertEqual(CallPriority.current, .user)
            let child = await Task { CallPriority.current }.value
            XCTAssertEqual(child, .user)
            let detached = await Task.detached { CallPriority.current }.value
            XCTAssertEqual(detached, .background)
        }
        XCTAssertEqual(CallPriority.current, .background)
    }

    func testPauseHoldsBothLanes() async throws {
        let c = GateClock()
        let gate = RateGate(perMinute: { 60 }, concurrent: 10, clock: c.clock)
        let start = c.now
        _ = await gate.pause(retryAfter: nil)
        try await gate.enter(priority: .user)
        XCTAssertGreaterThanOrEqual(c.now.timeIntervalSince(start), RateGate.defaultPause)
    }

    func testGatedTransportGivesTheWaitToTheBase() async throws {
        let c = GateClock()
        let gate = RateGate(perMinute: { 6 }, concurrent: 10, clock: c.clock)
        for _ in 0..<6 {
            try await gate.enter()
            await gate.leave()
        }
        let base = WaitProbe(statuses: [200])
        let t = GatedTransport(base, gate: gate, host: "acme")
        _ = try await CallPriority.user { try await t.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
        XCTAssertEqual(base.waits, [GateWait(ms: 10_000, priority: .user)])
    }

    func testRetryAfter429GivesEachAttemptItsOwnWait() async throws {
        let c = GateClock()
        let gate = RateGate(perMinute: { 60 }, concurrent: 10, clock: c.clock)
        let base = WaitProbe(statuses: [429, 200])
        let t = GatedTransport(base, gate: gate, host: "acme")
        _ = try await t.send(URLRequest(url: URL(string: "https://x.test/a")!))
        XCTAssertEqual(base.waits.count, 2)
        XCTAssertEqual(base.waits[0], GateWait(ms: 0, priority: .background))
        XCTAssertGreaterThanOrEqual(base.waits[1].ms, 15_000, "the retry waits for the pause")
    }
}

actor Order {
    private(set) var list: [String] = []
    func add(_ s: String) { list.append(s) }
}

/// A clock whose sleep waits for `advance`.
final class SleepGateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [CheckedContinuation<Void, Error>] = []

    var clock: RateGate.Clock {
        RateGate.Clock(now: { self.lock.withLock { self.at } }, sleep: { _ in
            try await withCheckedThrowingContinuation { c in self.lock.withLock { self.sleepers.append(c) } }
        })
    }

    func waitForSleepers(_ n: Int) async throws {
        for _ in 0..<200 {
            if lock.withLock({ sleepers.count }) == n { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("expected \(n) sleepers")
    }

    func advance(_ s: TimeInterval) {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            at = at.addingTimeInterval(s)
            defer { sleepers = [] }
            return sleepers
        }
        woken.forEach { $0.resume() }
    }
}

/// Answers with the given statuses and keeps the gate wait that it sees.
final class WaitProbe: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private var seen: [GateWait] = []
    var waits: [GateWait] { lock.withLock { seen } }

    init(statuses: [Int]) { self.statuses = statuses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status = lock.withLock { () -> Int in
            if let w = GateWait.current { seen.append(w) }
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        let headers = status == 429 ? ["Retry-After": "20"] : [:]
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
