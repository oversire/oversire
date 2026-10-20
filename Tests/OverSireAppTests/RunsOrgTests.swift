import XCTest
@testable import OverSireApp

final class RunsOrgTests: XCTestCase {
    func testSplit() {
        XCTAssertTrue(RunsPage.split("trebi-ai/trebi-pro") == ("trebi-ai", "trebi-pro"))
        XCTAssertTrue(RunsPage.split("bare") == ("", "bare"))
    }

    func testOrgsByCount() {
        let o = RunsPage.orgs(["b/x", "a/y", "b/z", "c/w", "a/v", "b/u"])
        XCTAssertEqual(o.map(\.org), ["b", "a", "c"])
        XCTAssertEqual(o.map(\.count), [3, 2, 1])
    }

    func testOrgFilter() {
        let repos = ["a/x", "b/y", "a/z"]
        XCTAssertEqual(RunsPage.byOrg(repos, org: "a") { $0 }, ["a/x", "a/z"])
        XCTAssertEqual(RunsPage.byOrg(repos, org: nil) { $0 }, repos)
        XCTAssertEqual(RunsPage.byOrg(repos, org: "gone") { $0 }, repos, "a remembered org without runs shows all")
    }
}
