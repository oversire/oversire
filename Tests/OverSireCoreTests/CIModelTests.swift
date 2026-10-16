import XCTest
@testable import OverSireCore

final class CIModelTests: XCTestCase {
    func run(_ wf: String, sha: String = "s", status: String = "completed", conclusion: String? = "success",
             created: String = "", updated: String = "") -> Run {
        Run(id: "3", name: wf, displayTitle: "t", status: status, conclusion: conclusion, headBranch: "main", headSha: sha,
            event: "workflow_dispatch", url: "u/\(wf)/\(sha)", updatedAt: updated, createdAt: created, startedAt: nil,
            number: 1, workflowName: wf, actorLogin: "a")
    }

    func testGrouped() {
        let rows = [run("Deploy", sha: "s2"), run("Deploy", sha: "s1"), run("Deploy", sha: "s1"), run("Build", sha: "s1")].grouped()
        XCTAssertEqual(rows.map(\.count), [1, 1, 2], "other commits or the same workflow get their own row")
    }

    func testIsFailure() {
        XCTAssertTrue(run("ci", conclusion: "failure").isFailure)
        XCTAssertFalse(run("ci", status: "in_progress", conclusion: "failure").isFailure)
    }

    func testEstimatedTotal() {
        let now = parseISO("2026-10-02T00:00:00Z")!
        let hist = [run("ci", created: "2026-10-01T10:00:00Z", updated: "2026-10-01T10:02:00Z"),
                    run("ci", created: "2026-10-01T11:00:00Z", updated: "2026-10-01T11:04:00Z"),
                    run("ci", created: "2026-09-01T11:00:00Z", updated: "2026-09-01T11:30:00Z"),
                    run("lint", created: "2026-10-01T11:00:00Z", updated: "2026-10-01T11:10:00Z")]
        XCTAssertEqual(run("ci").estimatedTotal(history: hist, now: now), 180)
        XCTAssertNil(run("other").estimatedTotal(history: hist, now: now))
    }

    func testIDsDecodeFromNumbers() throws {
        let json = #"{"id":42,"name":"ci","displayTitle":"t","status":"queued","headBranch":"main","headSha":"s","event":"push","url":"u","updatedAt":"","createdAt":"","number":7}"#
        let r = try JSONDecoder().decode(Run.self, from: Data(json.utf8))
        XCTAssertEqual(r.id, "42")
        XCTAssertEqual(try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(r)), r)
        let job = try JSONDecoder().decode(Job.self, from: Data(#"{"id":9,"name":"build"}"#.utf8))
        XCTAssertEqual(job.id, "9")
    }

    func testParseISO() {
        XCTAssertNotNil(parseISO("2026-10-01T10:00:00Z"))
        XCTAssertNotNil(parseISO("2026-10-01T10:00:00.123Z"))
        XCTAssertNil(parseISO(""))
        XCTAssertNil(parseISO(nil))
    }
}
