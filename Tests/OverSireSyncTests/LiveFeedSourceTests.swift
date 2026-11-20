import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

private struct Rig {
    let feed = FakeLiveFeed()
    let clock = ManualClock()
    let cursors = CursorStore(url: nil)
    let resyncs = Locked<[AccountID]>([])
    let online = Locked(true)
    let source: LiveFeedSource

    init(feed: FakeLiveFeed? = nil) {
        let f = feed ?? self.feed
        source = LiveFeedSource(feed: f, cursors: cursors, clock: clock, isOnline: { [online] in online.get() },
                                onResync: { [resyncs] a in resyncs.with { $0.append(a) } })
    }

    var key: String { LiveFeedSource.cursorKey(feed.account) }

    /// The stream is open, so a push reaches it.
    func connected(_ n: Int = 1) async { await eventually("connect \(n)") { feed.connects.count >= n && feed.isOpen } }

    func state(_ s: LiveFeedState) async { await eventually("state \(s)") { await source.state() == s } }

    /// Lets the source handle the signals that are in flight.
    func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    func inRange(_ d: Duration, _ lo: Double, _ hi: Double) -> Bool { d >= .seconds(lo) && d <= .seconds(hi) }
}

final class LiveFeedSourceTests: XCTestCase {
    func testFirstConnectSetsABaselineAndGivesNoEvents() async {
        let r = Rig()
        let stream = r.source.events()
        await r.connected()
        await eventually("pull") { r.cursors[r.key] != nil }
        XCTAssertEqual(r.feed.pulls, [nil])
        XCTAssertEqual(r.cursors[r.key]?.rawValue, "0")
        let s = await r.source.state()
        XCTAssertEqual(s, .connecting)
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        let none = await take(1, from: stream, timeout: 0.2, failOnTimeout: false)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(r.resyncs.get().isEmpty)
        XCTAssertNil(r.cursors[r.feed.account], "the feed keeps its own key")
        await r.source.stop()
    }

    func testChangedPullsAndYieldsEvents() async {
        let r = Rig()
        let stream = r.source.events()
        await r.connected()
        await eventually("baseline") { r.cursors[r.key] != nil }
        r.feed.addItemEvent(project: "p1", item: "i1")
        r.feed.addItemEvent(project: "p1", item: "i2")
        r.feed.push(LiveSignal(.changed, id: "b-1"))
        let got = await take(2, from: stream)
        XCTAssertEqual(got.map(\.id), ["fake-feed-1", "fake-feed-2"])
        await eventually("cursor") { r.cursors[r.key]?.rawValue == "2" }
        await r.source.stop()
    }

    func testSignalsDuringAPullGiveOneMorePull() async {
        let r = Rig()
        _ = r.source.events()
        await r.connected()
        await eventually("baseline") { r.cursors[r.key] != nil }
        let open = Locked(false)
        r.feed.gatePolls { while !open.get() { try? await Task.sleep(nanoseconds: 2_000_000) } }
        for i in 1...3 { r.feed.push(LiveSignal(.changed, id: "b-\(i)")) }
        await eventually("slow pull starts") { r.feed.pulls.count == 2 }
        await r.settle()
        open.with { $0 = true }
        await eventually("one more pull") { r.feed.pulls.count == 3 }
        await r.settle()
        XCTAssertEqual(r.feed.pulls.count, 3, "the catch-up pull, the slow pull and one more")
        await r.source.stop()
    }

    func testReconnectSendsLastEventID() async throws {
        let r = Rig()
        _ = r.source.events()
        await r.connected()
        r.feed.push(LiveSignal(.changed, id: "x-1"))
        r.feed.push(LiveSignal(.alive, id: "x-2"))
        await r.state(.live)
        await eventually("id") { await r.source.lastEventID == "x-2" }
        r.feed.drop()
        await eventually("backoff") { r.inRange(r.clock.sleeps.last ?? .zero, 1, 1.2) }
        r.clock.advance(by: .seconds(2))
        await r.connected(2)
        XCTAssertEqual(r.feed.connects, [nil, "x-2"])
        await eventually("catch-up pull") { r.feed.pulls.count >= 3 }
        await r.source.stop()
    }

    func testBackoffGrowsAndResetsAfterASignal() async {
        let r = Rig()
        for _ in 0..<3 { r.feed.refuseNextConnect(.transport("down")) }
        _ = r.source.events()
        for (i, base) in [1.0, 2.0, 4.0].enumerated() {
            await eventually("sleep \(i)") { r.clock.sleeps.count == i + 1 }
            XCTAssertTrue(r.inRange(r.clock.sleeps[i], base, base * 1.2), "sleep \(i) is \(r.clock.sleeps[i])")
            r.clock.advance(by: .seconds(6))
        }
        await r.connected(4)
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        r.feed.drop()
        await r.state(.retrying(.transport("The stream ended")))
        await eventually("reset backoff") { r.inRange(r.clock.sleeps.last ?? .zero, 1, 1.2) }
        await r.source.stop()
    }

    func testRateLimitWaitsRetryAfter() async {
        let r = Rig()
        r.feed.refuseNextConnect(.rateLimited(retryAfter: .seconds(30)))
        _ = r.source.events()
        await eventually("sleep") { r.clock.sleeps.count == 1 }
        XCTAssertGreaterThanOrEqual(r.clock.sleeps[0], .seconds(30))
        await r.state(.retrying(.rateLimited(retryAfter: .seconds(30))))
        await r.source.stop()
    }

    func testNoDataForTheTimeoutReconnects() async throws {
        let r = Rig()
        _ = r.source.events()
        await r.connected()
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        try await r.clock.waitForSleepers()
        r.clock.advance(by: .seconds(61))
        await r.state(.retrying(.transport("No data for 60 s")))
        await eventually("backoff") { r.inRange(r.clock.sleeps.last ?? .zero, 1, 1.2) }
        r.clock.advance(by: .seconds(2))
        await r.connected(2)
        await r.source.stop()
    }

    func testKeepAliveKeepsTheStream() async {
        let r = Rig()
        _ = r.source.events()
        await r.connected()
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        for _ in 0..<12 {
            await r.settle()
            r.clock.advance(by: .seconds(25))
            r.feed.push(LiveSignal(.alive))
        }
        await r.settle()
        XCTAssertEqual(r.feed.connects.count, 1)
        let s = await r.source.state()
        XCTAssertEqual(s, .live)
        await r.source.stop()
    }

    func testResyncDropsTheCursorAndAsksForAResync() async {
        let r = Rig()
        r.cursors[r.key] = Cursor(rawValue: "0")
        r.feed.addItemEvent(project: "p1", item: "i1")
        _ = r.source.events()
        await r.connected()
        await eventually("catch-up") { r.cursors[r.key]?.rawValue == "1" }
        r.feed.push(LiveSignal(.resync, id: "b-9"))
        await eventually("resync") { r.resyncs.get() == [r.feed.account] }
        XCTAssertEqual(r.feed.pulls, [Cursor(rawValue: "0"), nil])
        XCTAssertEqual(r.cursors[r.key]?.rawValue, "1")
        await r.settle()
        XCTAssertEqual(r.resyncs.get().count, 1)
        await r.source.stop()
    }

    func testExpiredCursorAsksForAResync() async {
        let r = Rig()
        r.cursors[r.key] = Cursor(rawValue: "0")
        _ = r.source.events()
        await r.connected()
        await eventually("catch-up") { r.feed.pulls.count == 1 }
        await r.settle()
        XCTAssertTrue(r.resyncs.get().isEmpty)
        r.feed.expireCursor()
        r.feed.push(LiveSignal(.changed))
        await eventually("resync") { r.resyncs.get() == [r.feed.account] }
        await r.source.stop()
    }

    func testUnauthorizedStops() async {
        let r = Rig()
        r.feed.refuseNextConnect(.unauthorized)
        _ = r.source.events()
        await r.state(.stopped(.unauthorized))
        r.clock.advance(by: .seconds(3600))
        await r.settle()
        XCTAssertEqual(r.feed.connects.count, 1)
        await r.source.wake()
        await r.connected(2)
        await r.source.stop()
    }

    func testNotFoundStops() async {
        let r = Rig()
        r.feed.refuseNextConnect(.notFound)
        _ = r.source.events()
        await r.state(.stopped(.notFound))
        r.clock.advance(by: .seconds(3600))
        await r.settle()
        XCTAssertEqual(r.feed.connects.count, 1)
        await r.source.stop()
    }

    func testPullUnauthorizedStops() async {
        let r = Rig()
        r.feed.failPolls(.unauthorized)
        _ = r.source.events()
        await r.state(.stopped(.unauthorized))
        r.clock.advance(by: .seconds(3600))
        await r.settle()
        XCTAssertEqual(r.feed.connects.count, 1)
        await r.source.stop()
    }

    func testFailedPullKeepsTheStreamAndTriesAtTheNextSignal() async {
        let r = Rig()
        r.feed.failPolls(.transport("down"))
        _ = r.source.events()
        await r.connected()
        await eventually("failed pull") { r.feed.pulls.count == 1 }
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        await eventually("retry at the signal") { r.feed.pulls.count >= 2 }
        r.feed.failPolls(nil)
        r.feed.push(LiveSignal(.alive))
        await eventually("pull ok") { r.cursors[r.key] != nil }
        XCTAssertEqual(r.feed.connects.count, 1)
        await r.source.stop()
    }

    func testOfflineWaitsForWake() async {
        let r = Rig()
        r.online.with { $0 = false }
        _ = r.source.events()
        await r.state(.retrying(.transport("This Mac is offline")))
        await r.settle()
        XCTAssertTrue(r.feed.connects.isEmpty)
        r.online.with { $0 = true }
        await r.source.wake()
        await r.connected()
        await r.source.stop()
    }

    func testHealthFollowsTheState() async {
        let r = Rig()
        let idle = await r.source.health()
        XCTAssertEqual(idle, .off)
        _ = r.source.events()
        await r.connected()
        await r.state(.connecting)
        let connecting = await r.source.health()
        XCTAssertEqual(connecting, .connecting)
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        let live = await r.source.health()
        XCTAssertEqual(live, .live)
        r.feed.refuseNextConnect(.transport("down"))
        r.feed.drop(ProviderError.transport("reset"))
        await r.state(.retrying(.transport("reset")))
        let failed = await r.source.health()
        XCTAssertEqual(failed, .failed("reset"))
        await r.source.stop()
    }

    func testStateUpdatesStartWithTheCurrentState() async {
        let r = Rig()
        let updates = await r.source.stateUpdates()
        _ = r.source.events()
        let got = await take(2, from: updates)
        XCTAssertEqual(got, [.off, .connecting])
        await r.source.stop()
    }

    func testStopEndsTheStream() async {
        let r = Rig()
        let stream = r.source.events()
        let ended = Locked(false)
        Task { for await _ in stream {}; ended.with { $0 = true } }
        await r.connected()
        r.feed.push(LiveSignal(.alive))
        await r.state(.live)
        await r.source.stop()
        let s = await r.source.state()
        XCTAssertEqual(s, .off)
        await eventually("events end") { ended.get() }
        await eventually("request ends") { !r.feed.isOpen }
    }
}
