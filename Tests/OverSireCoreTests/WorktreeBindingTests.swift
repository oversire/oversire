import XCTest
@testable import OverSireCore

final class WorktreeBindingTests: XCTestCase {
    func testDirJoinsARelativeGroupToTheRoot() {
        let rel = WorktreeBinding(key: "X-1", machine: "mbp", root: "/w", group: ".wt/x-1")
        XCTAssertEqual(rel.dir, "/w/.wt/x-1")
        let abs = WorktreeBinding(key: "X-1", machine: "mbp", root: "/w", group: "/tmp/quick")
        XCTAssertEqual(abs.dir, "/tmp/quick")
    }

    func testGroupFromATemplateUsesTheLowerKeyAndRefusesDotDot() {
        XCTAssertEqual(WorktreeBinding.group(from: ".wt/{key}", key: "X-1"), ".wt/x-1")
        XCTAssertEqual(WorktreeBinding.defaultGroup("X-1"), ".wt/x-1")
        XCTAssertNil(WorktreeBinding.group(from: "../a", key: "X-1"))
        XCTAssertNil(WorktreeBinding.group(from: "", key: "X-1"))
    }

    func testTheIdIsTheUpperCaseKey() {
        XCTAssertEqual(WorktreeBinding(key: "x-1", machine: "m", root: "/w", group: "g").id, "X-1")
    }
}
