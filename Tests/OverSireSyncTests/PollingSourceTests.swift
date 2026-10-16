import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// Each poll gives one event and moves the cursor by one.
private final class CountingProvider: Provider, @unchecked Sendable {
    let id: ProviderID = "github-actions"
    let account: AccountID
    var capabilities: Set<Capability> { [] }
    var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(5), requestsPerHour: 5000) }
    let cursorsSeen = Locked<[String?]>([])
    let fail = Locked(false)

    init(account: AccountID) { self.account = account }

    func probe() async throws -> Identity { Identity(person: PersonRef(id: "1", name: "Ada")) }

    func poll(since: Cursor?) async throws -> EventPage {
        let n = cursorsSeen.with { s -> Int in s.append(since?.rawValue); return s.count }
        if fail.get() { throw ProviderError.transport("down") }
        return EventPage(events: [event("\(account.id)-\(n)", account: account)], cursor: Cursor(rawValue: String(n)))
    }
}

final class PollingSourceTests: XCTestCase {
    func testPollsOnTheClockAndKeepsTheCursor() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cursors-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ManualClock()
        let p = CountingProvider(account: acme)
        let source = PollingSource(providers: [p], cursors: CursorStore(url: file), clock: clock)
        let stream = source.events()

        let first = await take(1, from: stream)
        XCTAssertEqual(first.map(\.id), ["acme-1"])
        try await clock.waitForSleepers()
        XCTAssertEqual(clock.sleeps.last, .seconds(30))
        clock.advance(by: .seconds(30))
        await eventually("second poll") { clock.sleeps.count == 2 }
        XCTAssertEqual(p.cursorsSeen.get(), [nil, "1"])
        XCTAssertEqual(CursorStore(url: file)[acme]?.rawValue, "2", "the cursor is on disk")
        let h = await source.health()
        XCTAssertEqual(h, .live)

        // A run starts: poll now, then at the active interval.
        await source.setActive([acme])
        await eventually("poll now") { clock.sleeps.count == 3 }
        XCTAssertEqual(p.cursorsSeen.get().count, 3)
        XCTAssertEqual(clock.sleeps.last, .seconds(10))

        // The cloud is live: the safety interval.
        await source.setCloudLive(true)
        clock.advance(by: .seconds(10))
        await eventually("next poll") { clock.sleeps.count == 4 }
        XCTAssertEqual(clock.sleeps.last, .seconds(600))

        // The cloud drops: poll now to catch up.
        await source.setCloudLive(false)
        await eventually("catch-up poll") { p.cursorsSeen.get().count == 5 }
        await source.stop()
    }

    func testErrorsBackOffAndShowInHealth() async throws {
        let clock = ManualClock()
        let p = CountingProvider(account: acme)
        p.fail.with { $0 = true }
        let source = PollingSource(providers: [p], cursors: CursorStore(url: nil), clock: clock)
        let stream = source.events()
        try await clock.waitForSleepers()
        XCTAssertEqual(clock.sleeps, [.seconds(60)])
        let h = await source.health()
        XCTAssertEqual(h, .failed("down"))
        clock.advance(by: .seconds(60))
        await eventually("second poll") { clock.sleeps.count == 2 }
        XCTAssertEqual(clock.sleeps.last, .seconds(120))
        p.fail.with { $0 = false }
        clock.advance(by: .seconds(120))
        await eventually("recovered") { clock.sleeps.count == 3 }
        XCTAssertEqual(clock.sleeps.last, .seconds(30))
        await source.stop()
        _ = stream
    }

    func testOneLoopForEachAccount() async throws {
        let clock = ManualClock()
        let a = CountingProvider(account: acme), b = CountingProvider(account: AccountID(provider: "github-actions", id: "beta"))
        let source = PollingSource(providers: [a, b], cursors: CursorStore(url: nil), clock: clock)
        let got = await take(2, from: source.events())
        XCTAssertEqual(Set(got.map(\.id)), ["acme-1", "beta-1"])
        await source.stop()
    }
}
