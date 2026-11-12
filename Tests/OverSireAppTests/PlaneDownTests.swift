import AppKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// A directory with no tracker: each read fails with "no token".
private final class NoTrackers: TrackerDirectory {
    var trackerIds: [String] { [] }
    func tracker(_ id: String) -> (any Tracker)? { nil }
}

/// Pages with Plane down, and the GitHub notes of Runs and PRs (OVERSIRE-462).
@MainActor
final class PlaneDownTests: XCTestCase {
    private let fake = FakeTracker()
    private var summary: ProjectSummary!
    private var data: TestAppData!
    private var savedError: String?

    override func setUp() async throws {
        savedError = lastFetchError
        summary = try await fake.projects()[0]
        data = TestAppData()
        data.projectStore = ProjectStore(trackers: NoTrackers(), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                         statePath: data.tmp + "/s.json", activityPath: data.tmp + "/a.jsonl")
    }

    override func tearDown() { lastFetchError = savedError }

    private var key: String { summary.ref.storeKey }
    private func texts(_ v: NSView) -> [String] { (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts) }
    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    private func built(_ page: Page) -> [NSView] { PageSection.flatten(page.sections() ?? []).map { $0.make() } }

    private func trackAndWait(_ want: (PagePart) -> Bool) async throws {
        data.projectStore.track([summary], live: [])
        for _ in 0..<300 where !want(data.projectStore.plane) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(want(data.projectStore.plane), "the state did not come")
    }

    func testThePlanePartHasNoRetryPlan() async throws {
        let idle = data.projectStore.part([key])
        XCTAssertEqual(idle.state, .idle)
        XCTAssertNil(idle.retry)
        XCTAssertFalse(idle.auto)
        XCTAssertEqual(idle.id, "plane")
        data.projectStore.seed(ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date()))
        guard case .fresh = data.projectStore.part([key]).state else { return XCTFail("the state is fresh") }
    }

    func testMyItemsWithPlaneDownShowsTheFailure() async throws {
        try await trackAndWait { if case .failed = $0.state { return true } else { return false } }
        let page = WorkPage(.work(.items), data: data, router: Router())
        XCTAssertEqual(page.parts.map(\.id), ["plane"])
        let views = built(page)
        let all = views.flatMap(texts)
        XCTAssertTrue(all.contains("Plane did not give your items."))
        XCTAssertFalse(all.contains("No open items are yours."))
        XCTAssertTrue(views.flatMap(buttons).contains { $0.title == "Try again" })
    }

    func testIntakeAndHomeShowTheFailureToo() async throws {
        try await trackAndWait { if case .failed = $0.state { return true } else { return false } }
        let intake = built(IntakeListPage(.intake(nil), data: data, router: Router())).flatMap(texts)
        XCTAssertTrue(intake.contains("Plane did not give your items."))
        let home = built(HomePage(.home, data: data, router: Router())).flatMap(texts)
        XCTAssertTrue(home.contains("Plane did not give your items."))
    }

    func testOldDataWithPlaneDownShowsTheStaleAccessoryNotTheNote() async throws {
        data.projectStore.seed(ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date(timeIntervalSince1970: 1_792_400_000)))
        try await trackAndWait { if case .stale = $0.state { return true } else { return false } }
        XCTAssertEqual(data.projectStore.plane.staleAccessory.count, 1)
        let all = built(WorkPage(.work(.items), data: data, router: Router())).flatMap(texts)
        XCTAssertTrue(all.contains { $0.hasPrefix("Read failed") })
        XCTAssertFalse(all.contains("Plane did not give your items."))
        let fresh = ProjectStore(trackers: NoTrackers(), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: data.tmp + "/f.json", activityPath: data.tmp + "/f.jsonl")
        XCTAssertTrue(fresh.plane.staleAccessory.isEmpty)
    }

    func testRunsEmptyNoteShowsTheGhErrorAndTryAgainRefreshes() throws {
        lastFetchError = "gh: HTTP 401: Bad credentials. Run gh auth login."
        data.grouped = []
        let views = built(RunsPage(.runs(.all), data: data, router: Router()))
        let all = views.flatMap(texts)
        XCTAssertTrue(all.contains("GitHub did not give the runs."))
        XCTAssertTrue(all.contains("gh: HTTP 401: Bad credentials. Run gh auth login."))
        XCTAssertFalse(all.contains("No runs match."))
        try XCTUnwrap(views.flatMap(buttons).first { $0.title == "Try again" }).performClick(nil)
        XCTAssertEqual(data.forcedRefreshes, 1)
    }

    func testRunsEmptyNoteStaysWithoutAnError() {
        lastFetchError = nil
        data.grouped = []
        XCTAssertTrue(built(RunsPage(.runs(.all), data: data, router: Router())).flatMap(texts).contains("No runs match."))
    }

    func testPRsEmptyNoteShowsTheGhErrorAndTryAgainRefreshes() throws {
        lastFetchError = "gh: timed out"
        data.prGrouped = []
        let views = built(PRsPage(.prs, data: data, router: Router()))
        XCTAssertTrue(views.flatMap(texts).contains("GitHub did not give the pull requests."))
        try XCTUnwrap(views.flatMap(buttons).first { $0.title == "Try again" }).performClick(nil)
        XCTAssertEqual(data.forcedRefreshes, 1)
    }
}
