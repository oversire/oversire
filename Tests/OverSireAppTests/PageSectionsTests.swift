import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

/// The rows of single pages: stable ids, and a hash that changes only for the row that changed.
final class PageSectionsTests: XCTestCase {
    private func ids(_ s: [PageSection]?) -> [String] { PageSection.flatten(s ?? []).map(\.id) }

    private func pr(_ n: Int, title: String = "Fix", mine: Bool = false) -> ChangeRequest {
        ChangeRequest(number: n, title: title, state: "OPEN", author: .init(login: "a"), headRefName: "b\(n)", baseRefName: "main", url: "",
                      createdAt: "2026-10-20T09:00:00Z", updatedAt: "2026-10-20T10:00:00Z", reviewDecision: nil, additions: 1,
                      deletions: 0, isDraft: false, labels: [], body: nil, mine: mine)
    }

    private func listRows(_ page: Page, section: String, row: String) -> PageRow? {
        page.sections()?.first { $0.id == section }?.rows.first { $0.id == row }
    }

    func testRunsPageChangesOnlyTheChangedRun() {
        let data = TestAppData()
        data.grouped = [("o/a", [Run.sample(1), Run.sample(2)]), ("o/b", [Run.sample(3)])]
        let page = RunsPage(.runs(.all), data: data, router: Router())
        let before = page.sections()!
        data.grouped[1] = ("o/b", [Run.sample(3, status: "in_progress", conclusion: nil)])
        let after = page.sections()!
        XCTAssertNotEqual(PageSection.fingerprint(before), PageSection.fingerprint(after))
        XCTAssertEqual(ids(before), ids(after))
        XCTAssertTrue(page.watches.contains(.runs))
        XCTAssertFalse(page.watches.contains(.logs))
    }

    func testRunsPageSameDataSameFingerprint() {
        let data = TestAppData()
        data.grouped = [("o/a", [Run.sample(1)])]
        let page = RunsPage(.runs(.all), data: data, router: Router())
        XCTAssertEqual(PageSection.fingerprint(page.sections()!), PageSection.fingerprint(page.sections()!))
    }

    func testPRsPageRowIdsAreRepoAndNumber() {
        let data = TestAppData()
        data.prGrouped = [("o/a", [pr(7), pr(8, mine: true)])]
        let page = PRsPage(.prs, data: data, router: Router())
        let list = listRows(page, section: "prs", row: "table")
        XCTAssertNotNil(list)
        let before = list!.hash
        data.prGrouped = [("o/a", [pr(7, title: "Fix it"), pr(8, mine: true)])]
        XCTAssertNotEqual(listRows(page, section: "prs", row: "table")!.hash, before)
        XCTAssertFalse(page.watches.contains(.queue))
    }

    func testRunPageWatchesItsRepoOnly() {
        let data = TestAppData()
        data.grouped = [("o/a", [Run.sample(1)])]
        let page = RunPage(.run(repo: "o/a", id: "1"), data: data, router: Router())
        XCTAssertEqual(page.shownRepos, ["o/a"])
        let print = page.fingerprint()
        XCTAssertEqual(print, page.fingerprint())
        data.grouped = [("o/a", [Run.sample(1, status: "in_progress", conclusion: nil)])]
        XCTAssertNotEqual(print, page.fingerprint())
    }

    func testItemPageWatchesItsItem() {
        let page = ItemPage(.item("SLING-4", .overview), data: TestAppData(), router: Router())
        XCTAssertTrue(page.shownItems?.contains("SLING-4") == true)
        XCTAssertTrue(page.watches.contains(.relations))
        let session = ItemPage(.item("SLING-4", .subitems), data: TestAppData(), router: Router())
        XCTAssertFalse(session.watches.contains(.relations))
    }

    func testQueuePageEmptyHasStableRows() {
        let page = QueuePage(.work(.lanes), data: TestAppData(), router: Router())
        let a = page.sections()!, b = page.sections()!
        XCTAssertEqual(PageSection.fingerprint(a), PageSection.fingerprint(b))
        XCTAssertTrue(ids(a).contains("queue/empty"))
    }

    func testProjectPageMissingProject() {
        let page = ProjectPage(.project("NOPE"), data: TestAppData(), router: Router())
        XCTAssertEqual(ids(page.sections()), ["top/header", "top/missing"])
    }
}

final class PopoverReconcileTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func panel(_ bus: ChangeBus, tab: Tab = .actions) -> TabVC {
        let vc = TabVC(grouped: [], prGrouped: [], updated: Date(), loading: false, tab: tab, repo: nil, bus: bus)
        _ = vc.view
        return vc
    }

    func testOtherTabDataDoesNotRebuild() {
        let clock = ManualSchedule()
        let bus = ChangeBus(schedule: clock.schedule)
        let vc = panel(bus)
        XCTAssertEqual(vc.builds, 1)
        bus.post(DataChange(.projects))
        clock.advance(1)
        XCTAssertEqual(vc.builds, 1)
        bus.post(DataChange(.runs, repos: ["o/a"]))
        clock.advance(1)
        XCTAssertEqual(vc.builds, 2)
    }

    func testProjectsTabWatchesProjects() {
        let clock = ManualSchedule()
        let bus = ChangeBus(schedule: clock.schedule)
        let vc = panel(bus, tab: .projects)
        bus.post(DataChange(.runs))
        clock.advance(1)
        XCTAssertEqual(vc.builds, 1)
        bus.post(DataChange(.projects, projects: ["ocral/p1"]))
        clock.advance(1)
        XCTAssertEqual(vc.builds, 2)
    }

    func testPollWithNoChangeDoesNotRebuild() {
        let vc = panel(ChangeBus(schedule: { _, _ in }))
        vc.update(grouped: [], prGrouped: [], updated: Date(), loading: false)
        XCTAssertEqual(vc.builds, 1)
        vc.update(grouped: [], prGrouped: [], updated: Date(), loading: true)
        XCTAssertEqual(vc.builds, 2)
    }
}
