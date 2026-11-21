import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// Counts the polls. `delay` makes a slow adapter. `peak` is the most requests in flight.
private final class CountingCI: CommitPolling, @unchecked Sendable {
    let base = FakeCI()
    var id: ProviderID { base.id }
    var account: AccountID { base.account }
    var capabilities: Set<Capability> { base.capabilities }
    var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(1), requestsPerHour: 5000) }
    let interests = Locked<[CIInterest]>([])
    let flight = Locked<(now: Int, peak: Int)>((0, 0))
    let delay = Locked<Duration>(.zero)
    let fail = Locked<ProviderError?>(nil)

    func probe() async throws -> Identity { try await base.probe() }
    func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }
    func pipelines(_ r: RepoRef) async throws -> [Pipeline] { [] }
    func runs(_ q: RunQuery) async throws -> [Run] { [] }
    func run(_ r: RunRef) async throws -> Run { try await base.run(r) }
    func jobs(_ r: RunRef) async throws -> [Job] { [] }
    func failures(_ r: RunRef) async throws -> [Failure] { [] }
    func perform(_ a: RunAction, on r: RunRef) async throws {}

    func pollCommit(_ i: CIInterest, since: Cursor?) async throws -> EventPage {
        interests.with { $0.append(i) }
        flight.with { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { flight.with { $0.now -= 1 } }
        let d = delay.get()
        if d > .zero { try await Task.sleep(for: d) }
        if let e = fail.get() { throw e }
        return EventPage(events: [], cursor: Cursor(rawValue: "c"))
    }
}

final class InterestPollerTests: XCTestCase {
    private func watch(_ repo: String = "acme/app", sha: String = "abc", expires: Date? = nil) -> CIWatch {
        CIWatch(repo: repo, ref: sha, ttl: 600, expiresAt: expires, sha: sha)
    }

    private func make(_ ci: CountingCI, _ clock: ManualClock, degraded: Locked<Bool> = Locked(false),
                      now: @escaping @Sendable () -> Date = Date.init) -> InterestPoller {
        InterestPoller(providers: { _ in ci }, clock: clock, now: now, degraded: { degraded.get() })
    }

    func testPollsWatchAtTheActiveInterval() async throws {
        let (ci, clock) = (CountingCI(), ManualClock())
        let p = make(ci, clock)
        _ = p.events()
        await p.setWatches([watch()])
        await eventually("poll at 0 s") { ci.interests.get().count == 1 }
        try await clock.waitForSleepers()
        XCTAssertEqual(clock.sleeps.last, .seconds(10))
        clock.advance(by: .seconds(10))
        await eventually("poll at 10 s") { ci.interests.get().count == 2 }
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(10))
        await eventually("poll at 20 s") { ci.interests.get().count == 3 }
        XCTAssertEqual(ci.interests.get().first, CIInterest(repo: "acme/app", sha: "abc"))
        await p.stop()
    }

    func testHookedRepoUsesGuardInterval() async throws {
        let (ci, clock) = (CountingCI(), ManualClock())
        let p = make(ci, clock)
        await p.setHooked(["Acme/App"])
        _ = p.events()
        await p.setWatches([watch()])
        await eventually("poll at 0 s") { ci.interests.get().count == 1 }
        try await clock.waitForSleepers()
        XCTAssertEqual(clock.sleeps.last, .seconds(60))
        clock.advance(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(ci.interests.get().count, 1, "no poll before 60 s")
        clock.advance(by: .seconds(50))
        await eventually("poll at 60 s") { ci.interests.get().count == 2 }
        await p.stop()
    }

    func testDegradedStops() async throws {
        let (ci, clock, degraded) = (CountingCI(), ManualClock(), Locked(true))
        let p = make(ci, clock, degraded: degraded)
        _ = p.events()
        await p.setWatches([watch()])
        try await clock.waitForSleepers()
        XCTAssertTrue(ci.interests.get().isEmpty, "no poll while the quota is low")
        degraded.with { $0 = false }
        clock.advance(by: .seconds(10))
        await eventually("poll after the quota came back") { ci.interests.get().count == 1 }
        await p.stop()
    }

    func testExpiredWatchDrops() async throws {
        let (ci, clock) = (CountingCI(), ManualClock())
        let p = make(ci, clock, now: { Date(timeIntervalSince1970: 1000) })
        _ = p.events()
        await p.setWatches([watch(expires: Date(timeIntervalSince1970: 900))])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(ci.interests.get().isEmpty)
        XCTAssertEqual(clock.sleeperCount, 0, "no loop for an empty set")
        await p.stop()
    }

    func testSingleFlightForARepo() async throws {
        let (ci, clock) = (CountingCI(), ManualClock())
        ci.delay.with { $0 = .milliseconds(20) }
        let p = make(ci, clock)
        _ = p.events()
        await p.setWatches([watch(sha: "aaa"), watch(sha: "bbb")])
        await eventually("both polled") { ci.interests.get().count == 2 }
        XCTAssertEqual(ci.flight.get().peak, 1)
        await p.stop()
    }

    func testRateLimitPausesUntilTheNextTick() async throws {
        let (ci, clock) = (CountingCI(), ManualClock())
        ci.fail.with { $0 = .rateLimited(retryAfter: nil) }
        let p = make(ci, clock)
        _ = p.events()
        await p.setWatches([watch(sha: "aaa"), watch(sha: "bbb")])
        await eventually("first poll") { ci.interests.get().count >= 1 }
        try await clock.waitForSleepers()
        XCTAssertEqual(ci.interests.get().count, 1, "a rate limit stops the other polls of the pass")
        let h = await p.health()
        guard case .failed = h else { return XCTFail("health is \(h)") }
        await p.stop()
    }

    func testEventsOfAPollAreYielded() async throws {
        let ci = FakeCI()
        let ev = ProviderEvent(id: "e1", provider: "fake-ci", account: ci.account, kind: .run, action: "completed",
                               subject: .run(RunRef(account: ci.account, repo: ci.repo, id: "1")), at: Date())
        ci.queueCommitPages([.success(EventPage(events: [ev], cursor: Cursor(rawValue: "1")))])
        let p = InterestPoller(providers: { _ in ci }, clock: ManualClock(), degraded: { false })
        let stream = p.events()
        await p.setWatches([watch()])
        let got = await take(1, from: stream)
        XCTAssertEqual(got.map(\.id), ["e1"])
        XCTAssertEqual(ci.commitPolls.first?.since, nil)
        await p.stop()
    }
}
