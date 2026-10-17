import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

final class BusyTrackerTests: XCTestCase {
    func testNestedBeginAndEnd() {
        let b = BusyTracker()
        let a = b.begin("Refreshing runs")
        let c = b.begin("Loading Inbox")
        XCTAssertEqual(b.labels, ["Refreshing runs", "Loading Inbox"])
        b.end(a)
        XCTAssertEqual(b.labels, ["Loading Inbox"])
        XCTAssertTrue(b.isBusy)
        b.end(c)
        XCTAssertFalse(b.isBusy)
    }

    func testUpdateKeepsOrderAndEndTwiceIsSafe() {
        let b = BusyTracker()
        let a = b.begin("Loading projects: 0 of 4")
        _ = b.begin("Loading OVERSIRE-50")
        b.update(a, "Loading projects: 2 of 4")
        XCTAssertEqual(b.labels, ["Loading projects: 2 of 4", "Loading OVERSIRE-50"])
        b.end(a)
        b.end(a)
        XCTAssertEqual(b.labels, ["Loading OVERSIRE-50"])
    }

    func testPostsAChange() {
        let b = BusyTracker()
        let e = expectation(forNotification: BusyTracker.changed, object: b)
        e.expectedFulfillmentCount = 2
        b.end(b.begin("x"))
        wait(for: [e], timeout: 1)
    }
}

final class JobsLoadTests: XCTestCase {
    private let job = Job(id: "1", name: "build", status: "completed", conclusion: "success", url: nil, startedAt: nil,
                          completedAt: nil, runnerName: nil, steps: nil)

    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    @MainActor
    func testNilJobsShowAnErrorAndRetry() throws {
        var l = JobsLoad()
        XCTAssertTrue(l.placeholder(retry: {}) is SkeletonRows)
        l.absorb(nil)
        XCTAssertTrue(l.failed)
        var retried = false
        let p = try XCTUnwrap(l.placeholder(retry: { retried = true }))
        let retry = try XCTUnwrap(buttons(p).first { $0.title == "Retry" })
        retry.performClick(nil)
        XCTAssertTrue(retried)
        l.retry()
        XCTAssertTrue(l.placeholder(retry: {}) is SkeletonRows)
    }

    @MainActor
    func testAFailedPollKeepsTheJobs() {
        var l = JobsLoad()
        l.absorb([job])
        l.absorb(nil)
        XCTAssertFalse(l.failed)
        XCTAssertEqual(l.jobs?.count, 1)
        XCTAssertNil(l.placeholder(retry: {}))
        l = JobsLoad()
        l.absorb([])
        XCTAssertTrue(l.placeholder(retry: {}) is EmptyNote)
    }
}

final class ActionButtonBusyTests: XCTestCase {
    @MainActor
    func testBusyAndDone() {
        let b = ActionButton("Re-run all")
        b.busy("Re-running…")
        XCTAssertEqual(b.title, "Re-running…")
        XCTAssertFalse(b.isEnabled)
        XCTAssertTrue(b.isBusy)
        b.done()
        XCTAssertEqual(b.title, "Re-run all")
        XCTAssertTrue(b.isEnabled)
        XCTAssertFalse(b.subviews.contains { $0 is Spinner })
    }
}
