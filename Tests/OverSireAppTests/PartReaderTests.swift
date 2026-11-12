import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

/// A fetch that counts its calls and fails while `failure` is set.
private final class Script: @unchecked Sendable {
    var calls = 0
    var failure: Error?
    var value = 1
    func fetch() async throws -> Int {
        calls += 1
        if let failure { throw failure }
        return value
    }
}

private let down = ProviderError.transport("down")

final class PartReaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let clock = ManualSchedule()
    private var now: Date { t0.addingTimeInterval(clock.now) }

    private func reader(_ s: Script, merge: @escaping (Int?, Int) -> Int = { $1 }, final: @escaping (Error) -> Bool = { _ in false },
                        maxAge: TimeInterval? = nil) -> PartReader<Int> {
        PartReader(fetch: s.fetch, merge: merge, final: final, maxAge: maxAge, now: { [unowned self] in now },
                   schedule: clock.schedule, changed: {})
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: The reader

    func testAFailedReadKeepsTheOldValue() async {
        let s = Script()
        let r = reader(s)
        await r.load()
        let at = now
        s.failure = down
        clock.advance(60)
        await r.load(force: true)
        XCTAssertEqual(r.value, 1)
        XCTAssertEqual(r.state, .stale(at, error: "down"))
    }

    func testTheRetryPlanIs5Then30Then120ThenStops() async {
        let s = Script()
        s.failure = down
        let r = reader(s)
        await r.load()
        XCTAssertEqual(r.last.retry(now: now)?.k, 1)
        for t in [5.0, 30, 120] {
            clock.advance(t)
            await r.settled()
        }
        XCTAssertEqual(s.calls, 4)
        XCTAssertTrue(r.last.stopped)
        XCTAssertNil(r.last.retry(now: now))
        clock.advance(600)
        await r.settled()
        XCTAssertEqual(s.calls, 4, "no timer after the plan stops")
    }

    func testAManualReadRestartsThePlan() async {
        let s = Script()
        s.failure = down
        let r = reader(s)
        await r.load()
        clock.advance(5)
        await r.settled()
        XCTAssertEqual(r.last.tries, 2)
        await r.load(force: true)
        XCTAssertEqual(r.last.retry(now: now)?.k, 1)
        let calls = s.calls
        clock.advance(5)
        await r.settled()
        XCTAssertEqual(s.calls, calls + 1, "only the new plan reads: the old timer is gone")
    }

    func testANonForcedReadDoesNotLoopOnAFailure() async {
        let s = Script()
        s.failure = down
        let r = reader(s)
        await r.load()
        for _ in 0..<10 { await r.load(force: false) }
        XCTAssertEqual(s.calls, 1)
    }

    func testAStoppedReadReadsAgainAfterTheRest() async {
        var v = Read<Int>()
        v.begin(manual: true)
        v.fail("x", at: t0, final: true)
        XCTAssertTrue(v.stopped)
        XCTAssertFalse(v.wants(force: false, now: t0.addingTimeInterval(Read<Int>.rest - 1), maxAge: nil))
        XCTAssertTrue(v.wants(force: false, now: t0.addingTimeInterval(Read<Int>.rest + 1), maxAge: nil))
        XCTAssertTrue(v.wants(force: true, now: t0, maxAge: nil))

        let s = Script()
        s.failure = down
        let r = reader(s)
        await r.load()
        for t in [5.0, 30, 120] { clock.advance(t); await r.settled() }
        clock.advance(Read<Int>.rest + 1)
        await r.load()
        XCTAssertEqual(s.calls, 5)
    }

    func testAMaxAgeReadsAgainOnlyWhenOld() async {
        let s = Script()
        let r = reader(s, maxAge: 30)
        await r.load()
        clock.advance(10)
        await r.load()
        XCTAssertEqual(s.calls, 1)
        clock.advance(25)
        await r.load()
        XCTAssertEqual(s.calls, 2)
    }

    func testAFinalErrorDoesNotRetry() async {
        let s = Script()
        s.failure = ProviderError.notFound
        let r = reader(s, final: { ($0 as? ProviderError) == .notFound })
        await r.load()
        XCTAssertEqual(r.state, .failed("Not found"))
        XCTAssertNil(r.last.retry(now: now))
        clock.advance(1000)
        await r.settled()
        XCTAssertEqual(s.calls, 1)
    }

    func testTheMergeJoinsTheValues() async {
        let s = Script()
        let r = reader(s, merge: { ($0 ?? 0) + $1 })
        await r.load()
        s.value = 5
        await r.load(force: true)
        XCTAssertEqual(r.value, 6)
    }

    func testAReadCallsTheChangeCallbackForEachStateChange() async {
        let s = Script()
        var states: [ReadState] = []
        var r: PartReader<Int>!
        r = PartReader(fetch: s.fetch, now: { [unowned self] in now }, schedule: clock.schedule, changed: { states.append(r.state) })
        await r.load()
        XCTAssertEqual(states, [.busy(shows: nil), .fresh(t0)])
    }

    // MARK: Words and views

    func testEachStateHasWords() {
        let zone = TimeZone(identifier: "UTC")!
        let today = utc(2026, 11, 12, 14, 6), now = utc(2026, 11, 12, 18, 0)
        func word(_ s: ReadState) -> String { s.word(now: now, zone: zone) }
        XCTAssertEqual(word(.idle), "Not read yet")
        XCTAssertEqual(word(.busy(shows: nil)), "Reading…")
        XCTAssertEqual(word(.fresh(today)), "Read 14:06")
        XCTAssertEqual(word(.stale(today, error: "x")), "Read failed · shows 14:06")
        XCTAssertEqual(word(.failed("x")), "Did not load")
        XCTAssertEqual(word(.fresh(utc(2026, 11, 11, 9, 30))), "Read Nov 11")
        XCTAssertTrue(ReadState.failed("x").didFail)
        XCTAssertTrue(ReadState.stale(today, error: "x").didFail)
        XCTAssertFalse(ReadState.fresh(today).didFail)
    }

    private func texts(_ v: NSView) -> [String] {
        (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts)
    }

    private func buttons(_ v: NSView) -> [NSButton] {
        (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons)
    }

    private func part(_ state: ReadState, retry: ReadRetry? = nil, title: String = "Diff of a.go", refresh: @escaping () -> Void = {}) -> PagePart {
        PagePart(id: "diff", title: title, state: state, retry: retry, refresh: refresh)
    }

    func testTheAccessoryOfEachStateHasAGlyphAndWords() {
        let at = Date()
        let fresh = ReadAccessory(part(.fresh(at)))
        XCTAssertEqual(texts(fresh), [ReadState.fresh(at).word])
        XCTAssertTrue(buttons(fresh).contains { $0.accessibilityLabel() == "Refresh Diff of a.go" })
        XCTAssertEqual(fresh.accessibilityLabel(), "Diff of a.go: " + ReadState.fresh(at).word)

        let compact = ReadAccessory(part(.fresh(at)), compact: true)
        XCTAssertTrue(texts(compact).isEmpty)
        XCTAssertEqual(buttons(compact).count, 1, "the icon stays")

        let busy = ReadAccessory(part(.busy(shows: nil)))
        XCTAssertEqual(texts(busy), ["Reading…"])
        XCTAssertTrue(busy.arrangedSubviews.first is Glyph)

        var tried = 0
        let stale = ReadAccessory(part(.stale(at, error: "timed out"), refresh: { tried += 1 }))
        XCTAssertEqual(texts(stale), [ReadState.stale(at, error: "").word])
        XCTAssertTrue(stale.arrangedSubviews.first is Glyph)
        let again = buttons(stale).first { $0.title == "Try again" }
        XCTAssertEqual(again?.toolTip, "timed out")
        again?.performClick(nil)
        XCTAssertEqual(tried, 1)

        XCTAssertTrue(ReadAccessory(part(.failed("x"))).arrangedSubviews.isEmpty)
        XCTAssertTrue(ReadAccessory(part(.idle)).arrangedSubviews.isEmpty)
    }

    func testTheNoteTellsTheTryAndStops() {
        let at = t0.addingTimeInterval(25)
        let two = ReadNote("The diff did not load.", part: part(.failed("down"), retry: ReadRetry(at: at, k: 2, of: 3)), now: { self.t0 })
        XCTAssertTrue(texts(two).contains("The diff did not load."))
        XCTAssertTrue(texts(two).contains("down"))
        XCTAssertTrue(texts(two).contains("Tries again by itself in 25 s · try 2 of 3"))
        XCTAssertTrue(buttons(two).contains { $0.title == "Try again" })

        let stopped = ReadNote("The diff did not load.", part: part(.failed("down")), now: { self.t0 })
        XCTAssertTrue(texts(stopped).contains("OverSire stopped trying. Click Try again."))

        let plane = PagePart(id: "p", title: "Plane", state: .failed("x"), retry: nil, refresh: {}, auto: false)
        XCTAssertFalse(texts(ReadNote("Plane did not answer.", part: plane)).contains { $0.contains("Tries again") || $0.contains("stopped") })
    }

    // MARK: The toolbar

    func testTheRefreshMenuListsThePartsWithTheirState() {
        let at = Date()
        let parts = [part(.fresh(at), title: "Review of K-1"), part(.stale(at, error: "x"), title: "Diff of a.go")]
        let menu = RefreshButton.menu(for: parts, page: {}, everything: {})
        XCTAssertEqual(menu.items.map(\.title), ["Review of K-1 · " + ReadState.fresh(at).word,
                                                 "Diff of a.go · " + ReadState.stale(at, error: "").word,
                                                 "", "Refresh page", "Refresh everything"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[4].keyEquivalentModifierMask, [.command, .option])
        XCTAssertNotNil(menu.items[1].image)

        let none = RefreshButton.menu(for: [], page: {}, everything: {})
        XCTAssertEqual(none.items.first?.title, "This page has no parts to refresh")
        XCTAssertEqual(none.items.first?.isEnabled, false)
    }

    func testAClickOnAMenuRowRefreshesThatPartOnly() {
        var hit: [String] = []
        let parts = ["a", "b"].map { id in PagePart(id: id, title: id, state: .idle, retry: nil, refresh: { hit.append(id) }) }
        let menu = RefreshButton.menu(for: parts, page: { hit.append("page") }, everything: { hit.append("all") })
        for i in [1, 3, 4] { _ = menu.items[i].target?.perform(menu.items[i].action, with: menu.items[i]) }
        XCTAssertEqual(hit, ["b", "page", "all"])
    }

    func testTheButtonShowsADotWhenAPartFailed() {
        let b = RefreshButton(target: NSObject(), action: #selector(NSObject.description))
        let busy = BusyTracker()
        b.show(busy, parts: [part(.fresh(Date()))])
        XCTAssertFalse(b.showsDot)
        XCTAssertEqual(b.accessibilityLabel(), "Refresh")
        b.show(busy, parts: [part(.fresh(Date())), part(.failed("x"), title: "Review of K-1")])
        XCTAssertTrue(b.showsDot)
        XCTAssertEqual(b.accessibilityLabel(), "Refresh. 1 part of the page did not load")
        XCTAssertTrue(b.toolTip?.contains("Review of K-1 did not load") == true)
        XCTAssertTrue(b.toolTip?.hasSuffix("Refresh now (⌘R) · Refresh everything (⌥⌘R)") == true)
    }
}
