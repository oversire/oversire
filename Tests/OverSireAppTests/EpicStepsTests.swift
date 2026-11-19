import XCTest
@testable import OverSireApp

final class EpicStepsTests: XCTestCase {
    func testGoalHeadline() {
        XCTAssertEqual(EpicPage.headline("Give the reviewer one desk for **plans and diffs**.\n\n- Show the reviews."),
                       "Give the reviewer one desk for plans and diffs.")
        XCTAssertEqual(EpicPage.headline("\n## Ship `v2`\nmore"), "Ship v2")
        XCTAssertEqual(EpicPage.headline("- First point"), "First point")
        XCTAssertNil(EpicPage.headline("  \n"))
        XCTAssertNil(EpicPage.headline(nil))
    }

    func testStepsTabIsSecond() {
        XCTAssertEqual(Route.EpicTab.allCases, [.overview, .steps, .items, .timeline])
        XCTAssertEqual(Route(path: "epic/OVERSIRE/e1"), .epic("OVERSIRE", "e1", .overview))
        XCTAssertTrue(Route.samples.contains(.epic("OVERSIRE", "uishots-epic", .steps)))
    }
}
