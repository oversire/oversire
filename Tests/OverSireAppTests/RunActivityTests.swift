import XCTest
import OverSireCore
@testable import OverSireApp

final class RunActivityTests: XCTestCase {
    private func run(_ id: String, status: String = "completed", created: String = "", updated: String = "") -> Run {
        Run(id: id, name: id, displayTitle: id, status: status, conclusion: nil, headBranch: "main", headSha: "s", event: "push",
            url: "u/\(id)", updatedAt: updated, createdAt: created, startedAt: nil, number: 1, workflowName: nil, actorLogin: nil)
    }

    func testRankOrderMatchesTheOldComparator() {
        let runs = [
            run("none"),
            run("done-old", created: "2026-10-01T10:00:00Z", updated: "2026-10-01T10:10:00Z"),
            run("active-old", status: "in_progress", created: "2026-10-02T10:00:00Z", updated: "2026-10-09T10:00:00Z"),
            run("done-new", created: "2026-10-01T09:00:00Z", updated: "2026-10-05T10:00:00Z"),
            run("no-update", created: "2026-10-03T10:00:00Z"),
            run("active-new", status: "queued", created: "2026-10-04T10:00:00Z"),
        ]
        XCTAssertEqual(byLastActivity(runs).map(\.id), ["active-new", "active-old", "done-new", "no-update", "done-old", "none"])
    }
}
