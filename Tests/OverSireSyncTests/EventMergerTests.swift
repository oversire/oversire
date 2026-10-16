import XCTest
import OverSireCore
@testable import OverSireSync

private struct FixedSource: EventSource {
    let list: [ProviderEvent]
    func events() -> AsyncStream<ProviderEvent> {
        AsyncStream { c in list.forEach { c.yield($0) } }
    }
    func health() async -> SourceHealth { .live }
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
}
