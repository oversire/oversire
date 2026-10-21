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
    override func sections() -> [PageSection]? {
        [PageSection("s", rows: rows.keys.sorted().map { id in
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
        r.apply(rows(10), mark: false)
        let kept = r.view("r3"), changed = r.view("r5")
        let res = r.apply(rows(10, changed: 5), mark: false)
        XCTAssertEqual(res, RowReconciler.Result(kept: 9, updated: 1, inserted: 0, removed: 0))
        XCTAssertTrue(r.view("r3") === kept)
        XCTAssertFalse(r.view("r5") === changed)
    }

    func testInsertRemoveAndOrder() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        r.apply(rows(3), mark: false)
        let next = [rows(4)[3], rows(3)[0], rows(3)[2]]
        let res = r.apply(next, mark: false)
        XCTAssertEqual(res.inserted, 1)
        XCTAssertEqual(res.removed, 1)
        XCTAssertEqual(r.ids, ["r3", "r0", "r2"])
        XCTAssertEqual(stack.arrangedSubviews.count, 3)
    }

    func testFiveHundredRowsApplyFast() {
        let stack = NSStackView(v: [], spacing: 0)
        let r = RowReconciler(stack)
        r.apply(rows(500), mark: false)
        var best = Double.infinity
        for k in 0..<5 {
            let next = rows(500, changed: k)
            let t = Date()
            r.apply(next, mark: false)
            best = min(best, Date().timeIntervalSince(t))
        }
        XCTAssertLessThan(best * 1000, 5, "500 rows with one change take \(best * 1000) ms")
    }
}

final class TimeTickerTests: XCTestCase {
    func testTickRefreshesTheText() {
        var date = Date().addingTimeInterval(-120)
        let l = RelativeTimeLabel({ date }, format: { "updated " + $0 })
        XCTAssertEqual(l.stringValue, "updated " + relativeTime(date))
        date = Date().addingTimeInterval(-7200)
        TimeTicker.shared.tick()
        XCTAssertEqual(l.stringValue, "updated " + relativeTime(date))
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
