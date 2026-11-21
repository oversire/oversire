import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

/// A page with one row for each key of `rows`.
private final class CountPage: Page {
    var rows: [String: Int] = ["a": 1, "b": 1]
    var domains: DataDomains = [.runs]
    var repos: Set<String>?
    override var watches: DataDomains { domains }
    override var shownRepos: Set<String>? { repos }
    var refreshed: [String] = []
    var sectionCalls = 0
    override var parts: [PagePart] {
        ["a", "b"].map { id in PagePart(id: id, title: id, state: .idle, retry: nil) { [unowned self] in refreshed.append(id) } }
    }
    override func sections() -> [PageSection]? {
        sectionCalls += 1
        return [PageSection("s", rows: rows.keys.sorted().map { id in
            let v = rows[id]!
            return PageRow(id, v) { NSTextField.text("\(id) \(v)") }
        })]
    }
}

private func makePage(_ data: TestAppData) -> CountPage {
    let p = CountPage(.home, data: data, router: Router())
    _ = p.view
    return p
}

final class PageBuildCountTests: XCTestCase {
    func testOpenBuildsOnce() {
        let p = makePage(TestAppData())
        XCTAssertEqual(p.buildCount, 1)
        XCTAssertEqual(p.lastBuildReason, "open")
    }

    func testTheDefaultPageRefreshCallsEachPart() {
        let p = makePage(TestAppData())
        p.refresh(nil)
        XCTAssertEqual(p.refreshed, ["a", "b"])
        p.refreshed = []
        p.refresh("b")
        XCTAssertEqual(p.refreshed, ["b"])
        p.refresh("none")
        XCTAssertEqual(p.refreshed, ["b"])
    }

    func testSameDataDoesNotBuild() {
        let p = makePage(TestAppData())
        p.receive(DataChange(.runs))
        XCTAssertEqual(p.buildCount, 1)
    }

    func testChangedRowBuildsOnceAndKeepsTheOthers() {
        let p = makePage(TestAppData())
        p.rows["b"] = 2
        p.receive(DataChange(.runs, repos: ["o/r"]))
        XCTAssertEqual(p.buildCount, 2)
        XCTAssertEqual(p.lastBuildReason, "data: runs o/r")
        XCTAssertEqual(p.lastResult?.updated, 1)
        XCTAssertEqual(p.lastResult?.kept, 1)
    }

    func testTwentyEventsForOneRepoGiveOneApply() {
        let data = TestAppData()
        let p = makePage(data)
        let o = data.bus.observe { p.receive($0) }
        p.rows["a"] = 5
        for _ in 0..<20 { data.bus.post(DataChange(.runs, repos: ["o/r"], origin: .event)) }
        data.clock.advance(1)
        XCTAssertEqual(p.buildCount, 2)
        withExtendedLifetime(o) {}
    }
}

final class PageWatchTests: XCTestCase {
    func testOtherDomainDoesNotBuild() {
        let p = makePage(TestAppData())
        p.rows["a"] = 9
        p.receive(DataChange(.projects))
        XCTAssertEqual(p.buildCount, 1)
        XCTAssertFalse(p.wants(DataChange(.queue)))
    }

    func testOtherRepoDoesNotBuild() {
        let p = makePage(TestAppData())
        p.repos = ["o/a"]
        p.rows["a"] = 9
        p.receive(DataChange(.runs, repos: ["o/b"]))
        XCTAssertEqual(p.buildCount, 1)
        p.receive(DataChange(.runs, repos: ["o/a"]))
        XCTAssertEqual(p.buildCount, 2)
    }

    @MainActor
    func testAHiddenWindowDoesNotBuildSectionsForAChange() {
        _ = NSApplication.shared
        let data = TestAppData()
        var page: CountPage?
        let w = AppWindow(data: data) { r, d, router in
            let p = CountPage(r, data: d, router: router)
            page = p
            return p
        }
        defer { w.window?.orderOut(nil) }
        guard let p = page else { return XCTFail("no page") }
        _ = p.view
        let before = p.sectionCalls
        p.rows["a"] = 9
        data.bus.post(DataChange(.runs))
        data.clock.advance(1)
        XCTAssertEqual(p.sectionCalls, before, "a hidden window does not build the sections")
        w.window?.orderFront(nil)
        // A test run with no window server never reports the window as visible.
        guard w.window?.occlusionState.contains(.visible) == true else { return }
        w.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        XCTAssertGreaterThan(p.sectionCalls, before, "the window checks the held change when it shows")
    }

    func testHiddenPageBuildsOnceWhenShown() {
        let p = makePage(TestAppData())
        p.detach()
        p.rows["a"] = 2
        p.receive(DataChange(.runs))
        p.rows["a"] = 3
        p.receive(DataChange(.runs))
        XCTAssertEqual(p.buildCount, 1)
        XCTAssertTrue(p.stale)
        p.attach()
        XCTAssertEqual(p.buildCount, 2)
        XCTAssertEqual(p.lastBuildReason, "attach stale")
    }

    func testHiddenPageWithSameDataDoesNotBuild() {
        let p = makePage(TestAppData())
        p.detach()
        p.receive(DataChange(.runs))
        p.attach()
        XCTAssertEqual(p.buildCount, 1)
    }

    func testUserConfigChangeAlwaysBuilds() {
        let p = makePage(TestAppData())
        p.domains = [.runs, .config]
        p.receive(.config())
        XCTAssertEqual(p.buildCount, 2)
        p.receive(.config(.poll))
        XCTAssertEqual(p.buildCount, 2)
    }

    func testProjectDigestIgnoresTheFetchTime() {
        let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")
        let summary = ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false)
        let a = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date())
        let b = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date().addingTimeInterval(60))
        XCTAssertEqual(ProjectStore.digest(a), ProjectStore.digest(b))
        let c = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling 2", url: "", closed: false),
                                statusOptions: [], items: [], fetchedAt: Date())
        XCTAssertNotEqual(ProjectStore.digest(a), ProjectStore.digest(c))
    }
}

final class PageReconcileTests: XCTestCase {
    private func rows(_ n: Int, changed: Int? = nil) -> [PageRow] {
        (0..<n).map { i in
            let v = i == changed ? 1 : 0
            return PageRow("r\(i)", v) { NSTextField.text("row \(i) \(v)") }
        }
    }

    func testUnchangedRowsKeepTheirViews() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        r.apply(rows(10))
        let kept = r.view("r3"), changed = r.view("r5")
        let res = r.apply(rows(10, changed: 5))
        XCTAssertEqual(res, RowReconciler.Result(kept: 9, updated: 1, inserted: 0, removed: 0))
        XCTAssertTrue(r.view("r3") === kept)
        XCTAssertFalse(r.view("r5") === changed)
    }

    func testChangedRowUpdatesInPlaceWithNoTint() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        let make = { (v: Int) in
            [PageRow("a", v, update: { ($0 as? NSTextField)?.stringValue = "a \(v)" }) { NSTextField.text("a \(v)") }]
        }
        r.apply(make(0))
        let view = r.view("a")
        let res = r.apply(make(1))
        XCTAssertEqual(res.updated, 1)
        XCTAssertTrue(r.view("a") === view)
        XCTAssertEqual((view as? NSTextField)?.stringValue, "a 1")
        XCTAssertNil(view?.layer?.sublayers?.first { $0.name == "oversire.mark" })
    }

    func testInsertRemoveAndOrder() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        r.apply(rows(3))
        let next = [rows(4)[3], rows(3)[0], rows(3)[2]]
        let res = r.apply(next)
        XCTAssertEqual(res.inserted, 1)
        XCTAssertEqual(res.removed, 1)
        XCTAssertEqual(r.ids, ["r3", "r0", "r2"])
        XCTAssertEqual(stack.arrangedSubviews.count, 3)
    }

    func testFiveHundredRowsApplyFast() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        r.apply(rows(500))
        var best = Double.infinity
        for k in 0..<5 {
            let next = rows(500, changed: k)
            let t = Date()
            r.apply(next)
            best = min(best, Date().timeIntervalSince(t))
        }
        XCTAssertLessThan(best * 1000, 5, "500 rows with one change take \(best * 1000) ms")
    }
}

final class TickerTests: XCTestCase {
    func testTickRefreshesTheText() {
        var date = Date().addingTimeInterval(-120)
        let l = RelativeTimeLabel({ date }, format: { "updated " + $0 })
        XCTAssertEqual(l.stringValue, "updated " + relativeTime(date))
        date = Date().addingTimeInterval(-7200)
        Ticker.relative.tick()
        XCTAssertEqual(l.stringValue, "updated " + relativeTime(date))
    }

    /// A label in a window. `shown` orders the window front.
    private func labelInWindow(shown: Bool, _ text: @escaping () -> String) -> (LiveLabel, NSWindow) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let l = LiveLabel.make(.systemFont(ofSize: 10), .labelColor, text)
        w.contentView?.addSubview(l)
        if shown { w.orderFrontRegardless() }
        return (l, w)
    }

    func testALiveLabelInAShownWindowTicks() throws {
        var n = 0
        let (l, w) = labelInWindow(shown: true) { n += 1; return "t\(n)" }
        defer { w.close() }
        guard w.isVisible else { throw XCTSkip("the window does not show under swift test") }
        let before = n
        Ticker.seconds.tick()
        XCTAssertGreaterThan(n, before)
        XCTAssertEqual(l.stringValue, "t\(n)")
    }

    func testALiveLabelInAHiddenWindowDoesNotRecompute() {
        var n = 0
        let (l, w) = labelInWindow(shown: false) { n += 1; return "t\(n)" }
        defer { w.close() }
        let before = n
        Ticker.seconds.tick()
        XCTAssertEqual(n, before)
        XCTAssertEqual(l.stringValue, "t\(before)")
    }

    func testTheTimerStopsWhenTheLastLabelLeaves() {
        let (l, w) = labelInWindow(shown: false) { "x" }
        defer { w.close() }
        XCTAssertTrue(Ticker.seconds.isRunning)
        XCTAssertEqual(Ticker.seconds.count, 1)
        l.removeFromSuperview()
        XCTAssertEqual(Ticker.seconds.count, 0)
        XCTAssertFalse(Ticker.seconds.isRunning)
    }

    func testOcclusionChangeRefreshesTheLabelsOfThatWindow() throws {
        var text = "a"
        let (l, w) = labelInWindow(shown: true) { text }
        defer { w.close() }
        guard w.isVisible else { throw XCTSkip("the window does not show under swift test") }
        XCTAssertEqual(l.stringValue, "a")
        text = "b"
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        XCTAssertEqual(l.stringValue, "b")
    }

    func testNoDateShowsADash() {
        XCTAssertEqual(RelativeTimeLabel({ nil }).stringValue, "—")
    }

    func testTimeIsNotPartOfTheRowHash() {
        let data = TestAppData()
        let run = Run.sample(1)
        data.grouped = [("o/r", [run])]
        let a = RunLine.row(repo: "o/r", run: run, data: data, commands: nil) { _ in }
        let b = RunLine.row(repo: "o/r", run: run, data: data, commands: nil) { _ in }
        XCTAssertEqual(a.hash, b.hash)
    }
}

final class LiveLineTests: XCTestCase {
    func testSidebarTooltipNamesALiveFeed() {
        XCTAssertEqual(LiveLineModel(state: .off, liveFeeds: 1).tooltip, "No cloud. OverSire polls GitHub. Big Timer sends its changes live.")
        XCTAssertEqual(LiveLineModel(state: .off, liveFeeds: 0).tooltip, "No cloud. OverSire polls GitHub and the trackers.")
        XCTAssertEqual(LiveLineModel(state: .live, liveFeeds: 1).tooltip, "No events yet", "with the cloud live, the cloud text stays")
    }

    func testStatesHaveTextNotOnlyColor() {
        XCTAssertEqual(LiveLineModel(state: .live).mark, .connected)
        XCTAssertEqual(LiveLineModel(state: .live).title, "Connected")
        XCTAssertEqual(LiveLineModel(state: .connecting).title, "Connecting…")
        XCTAssertEqual(LiveLineModel(state: .connecting).detail, "polling meanwhile")
        XCTAssertEqual(LiveLineModel(state: .error("x"), pollEvery: 60).detail, "polling every 60 s")
        XCTAssertEqual(LiveLineModel(state: .error("x")).mark, .disconnected)
        XCTAssertEqual(LiveLineModel(state: .off).title, "Polling")
        XCTAssertNil(LiveLineModel(state: .off).detail)
    }

    func testClientTexts() {
        let waiting = LiveLineModel(state: .off, client: .waiting, clientName: "mbp")
        XCTAssertEqual(waiting.title, "Waiting for mbp")
        XCTAssertEqual(waiting.mark, .waiting)
        XCTAssertNil(waiting.detail)
        let at = Date()
        let live = LiveLineModel(state: .off, client: .live(updated: at, items: 3, repos: 2), clientName: "mbp")
        XCTAssertEqual(live.title, "From mbp")
        XCTAssertEqual(live.mark, .connected)
        XCTAssertEqual(live.detail, "updated " + ClientLink.clock(at))
        XCTAssertEqual(ClientLink.live(updated: at, items: 2140, repos: 38).note("mbp"), "Updated \(ClientLink.clock(at)) · 2,140 items · 38 repos")
        XCTAssertEqual(ClientLink.waiting.note("mbp"), "Waiting for mbp to send its data.")
        XCTAssertEqual(LiveLineModel(state: .live).title, "Connected", "Full mode keeps the cloud texts")
    }

    // OVERSIRE-530
    func testOfflineTexts() {
        let data = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: Date())!
        let off = LiveLineModel(state: .off, client: .homeOffline(home: "mbp", since: Date(), data: data), clientName: "mbp")
        XCTAssertEqual(off.title, "mbp is offline")
        XCTAssertEqual(off.detail, "data from 14:02")
        XCTAssertEqual(off.mark, .warning)
        XCTAssertEqual(off.tooltip, "mbp is offline. Try again when it is back.")
        XCTAssertEqual(ClientLink.homeOffline(home: "mbp", since: Date(), data: data).footer("mbp"), "mbp offline · data from 14:02")
        let closed = LiveLineModel(state: .off, client: .appClosed(home: "mbp", data: data), clientName: "mbp")
        XCTAssertEqual(closed.title, "OverSire is not open on mbp")
        XCTAssertEqual(closed.tooltip, "The OverSire app on mbp is not open.")
        XCTAssertEqual(LiveLineModel(state: .off, client: .noSource(home: "mbp"), clientName: "mbp").title, "No Mac runs the automations")
        let moving = LiveLineModel(state: .off, client: .moving(to: "box"), clientName: "mbp")
        XCTAssertEqual(moving.title, "Moving to box…")
        XCTAssertEqual(moving.mark, .waiting)
    }

    func testJustNowShowsFourSeconds() {
        let t = Date()
        let m = LiveLineModel(state: .live, lastBurst: t)
        XCTAssertTrue(m.justNow(at: t.addingTimeInterval(1)))
        XCTAssertFalse(m.justNow(at: t.addingTimeInterval(5)))
        XCTAssertFalse(LiveLineModel(state: .live).justNow(at: t))
    }

    func testBurstShowsPingThenHidesIt() {
        let clock = ManualSchedule()
        var now = Date()
        let line = LiveLine(now: { now }, schedule: clock.schedule)
        line.set(LiveLineModel(state: .live, lastBurst: now))
        XCTAssertTrue(line.showsPing)
        now = now.addingTimeInterval(5)
        clock.advance(LiveLineModel.pingTime)
        XCTAssertFalse(line.showsPing)
    }

    func testTooltipTellsTheError() {
        XCTAssertEqual(LiveLineModel(state: .error("401")).tooltip, "Cloud error: 401")
        XCTAssertEqual(LiveLineModel(state: .live).tooltip, "No events yet")
    }
}
