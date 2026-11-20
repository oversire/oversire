import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

private struct FixedSource: EventSource {
    let list: [ProviderEvent]
    func events() -> AsyncStream<ProviderEvent> {
        AsyncStream { c in list.forEach { c.yield($0) } }
    }
    func health() async -> SourceHealth { .live }
}

/// Gives the event of a feed again, as a poll does.
private struct RepeatingProvider: Provider {
    let id: ProviderID = "fake-feed"
    let account: AccountID
    var capabilities: Set<Capability> { [] }
    var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(5), requestsPerHour: 5000) }
    func probe() async throws -> Identity { Identity(person: PersonRef(id: "1", name: "Ada")) }
    func poll(since: Cursor?) async throws -> EventPage {
        EventPage(events: [event("fake-feed-1", account: account)], cursor: Cursor(rawValue: "1"))
    }
}

final class EventMergerTests: XCTestCase {
    func testRepeatsAcrossSourcesComeOnce() async {
        let a = FixedSource(list: [event("1"), event("2"), event("3")])
        let b = FixedSource(list: [event("2"), event("3"), event("4"), event("1")])
        let merger = EventMerger(polling: nil, others: [a, b])
        let stream = merger.events()
        let got = await take(4, from: stream)
        XCTAssertEqual(got.map(\.id).sorted(), ["1", "2", "3", "4"])
        let more = await take(1, from: stream, timeout: 0.2, failOnTimeout: false)
        XCTAssertTrue(more.isEmpty, "no repeat comes later")
        await merger.stop()
    }

    func testFeedAndPollRepeatsComeOnce() async {
        let feed = FakeLiveFeed()
        let source = LiveFeedSource(feed: feed, cursors: CursorStore(url: nil))
        let polling = PollingSource(providers: [RepeatingProvider(account: feed.account)], cursors: CursorStore(url: nil))
        let merger = EventMerger(polling: polling, others: [source])
        let stream = merger.events()
        await eventually("connect") { feed.connects.count == 1 }
        await eventually("baseline") { feed.pulls.count == 1 }
        feed.addItemEvent(project: "p1", item: "i1")
        feed.push(LiveSignal(.changed))
        let got = await take(1, from: stream)
        XCTAssertEqual(got.map(\.id), ["fake-feed-1"])
        let more = await take(1, from: stream, timeout: 0.3, failOnTimeout: false)
        XCTAssertTrue(more.isEmpty, "the feed and the poll give the id once")
        await merger.stop()
    }
}
