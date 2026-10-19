import XCTest
@testable import OverSireApp

final class HookHealthTests: XCTestCase {
    func testCountsAndRepair() {
        let repos = ["a/live", "a/wait", "a/none", "a/unknown", "a/admin", "a/err"]
        let h = HookHealth(repos: repos, statuses: ["a/live": .live("200"), "a/wait": .waiting, "a/unknown": .unknown,
                                                    "a/admin": .pollingOnly("no admin"), "a/err": .error("404")])
        XCTAssertEqual(h.live, ["a/live", "a/wait"])
        XCTAssertEqual(h.counts.label, "2 live, 3 missing, 1 failed")
        XCTAssertEqual(h.repair, ["a/none", "a/unknown", "a/err"], "Repair skips a repo that needs an admin")
    }

    func testAllLive() {
        let h = HookHealth(repos: ["a/b"], statuses: ["a/b": .live("200")])
        XCTAssertEqual(h.counts.label, "1 live")
        XCTAssertTrue(h.repair.isEmpty)
    }

    func testNoRepos() {
        XCTAssertEqual(HookHealth(repos: [], statuses: [:]).counts.label, "None")
    }
}
