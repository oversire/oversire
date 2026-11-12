import OverSireCore
import XCTest
@testable import OverSireApp

/// A daemon that gives one row. It counts its calls and fails while `failure` is set.
private final class FakeEvents: ItemEventReader, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _failure: Error?
    var calls: Int { lock.withLock { _calls } }
    var failure: Error? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    let rows: [Event]

    init(_ rows: [Event]) { self.rows = rows }

    func events(_ q: Event.Query) async throws -> Event.Page {
        lock.withLock { _calls += 1 }
        if let failure { throw failure }
        return Event.Page(events: rows, next: 1, head: 1, more: false)
    }
}

@MainActor
final class ItemJournalTests: XCTestCase {
    private let clock = ManualSchedule()
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func row(_ id: String, item: String = "K-1") -> Event {
        Event(seq: 1, seenAt: t0, draft: EventDraft(id: id, at: t0, kind: .commentCreated, item: item, actorType: .human, actor: "a", via: "v", summary: id))
    }

    private func journal(_ events: FakeEvents) -> ItemJournal {
        ItemJournal(reader: { events }, bus: ChangeBus(schedule: clock.schedule), lookPath: nil,
                    now: { self.t0.addingTimeInterval(self.clock.now) }, schedule: clock.schedule)
    }

    /// A read that the journal began, to its end.
    private func settle(_ j: ItemJournal, _ key: String = "K-1") async {
        for _ in 0..<100 where j.isLoading(key) || j.part(key).state == .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAFailedJournalReadKeepsTheRowsAndTellsThePart() async {
        let events = FakeEvents([row("a")])
        let j = journal(events)
        j.load("k-1")
        await settle(j)
        XCTAssertEqual(j.rows("K-1")?.map(\.id), ["a"])
        events.failure = ProviderError.transport("daemon down")
        j.load("K-1", force: true)
        await settle(j)
        XCTAssertEqual(j.rows("K-1")?.map(\.id), ["a"], "a failed read keeps the rows")
        guard case .stale(_, let why) = j.part("K-1").state else { return XCTFail("the state is stale") }
        XCTAssertEqual(why, "daemon down")
    }

    func testAFailedFirstReadHasNoRowsAndShowsFailed() async {
        let events = FakeEvents([])
        events.failure = ProviderError.transport("daemon down")
        let j = journal(events)
        j.load("K-1")
        await settle(j)
        XCTAssertNil(j.rows("K-1"))
        XCTAssertEqual(j.part("K-1").state, .failed("daemon down"))
        XCTAssertEqual(j.part("K-1").retry?.k, 1)
    }

    func testAFailedReadDoesNotReadOnEachLoad() async {
        let events = FakeEvents([row("a")])
        events.failure = ProviderError.transport("daemon down")
        let j = journal(events)
        j.load("K-1")
        await settle(j)
        for _ in 0..<5 { j.load("K-1") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(events.calls, 1)
        events.failure = nil
        clock.advance(5)
        await j.settled("K-1")
        XCTAssertEqual(events.calls, 2, "the retry plan reads again")
        XCTAssertEqual(j.rows("K-1")?.count, 1)
    }

    func testNoDaemonIsAFailure() async {
        let j = ItemJournal(reader: { nil }, bus: ChangeBus(schedule: clock.schedule), lookPath: nil, schedule: clock.schedule)
        j.load("K-1")
        await settle(j)
        XCTAssertEqual(j.part("K-1").state, .failed("No daemon is live."))
    }

    func testAFrameStillMergesIntoTheTree() {
        let j = journal(FakeEvents([]))
        j.reads = false
        j.seed("K-1", [row("a")])
        j.received(row("b"))
        j.received(row("c", item: "OTHER-1"))
        XCTAssertEqual(j.rows("K-1")?.map(\.id), ["a", "b"])
        XCTAssertNil(j.rows("OTHER-1"))
    }

    func testReadsOffBlocksEachRead() {
        let events = FakeEvents([row("a")])
        let j = journal(events)
        j.reads = false
        j.load("K-1", force: true)
        XCTAssertEqual(events.calls, 0)
    }
}
