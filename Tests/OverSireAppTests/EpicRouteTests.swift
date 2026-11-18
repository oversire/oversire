import XCTest
@testable import OverSireApp

final class EpicRouteTests: XCTestCase {
    func testEpicPathsRoundTrip() {
        for tab in Route.EpicTab.allCases {
            let r = Route.epic("OVERSIRE", "e1", tab)
            XCTAssertEqual(r.path, "epic/OVERSIRE/e1/\(tab.rawValue)")
            XCTAssertEqual(Route(path: r.path), r)
        }
        XCTAssertEqual(Route(path: "epic/OVERSIRE/e1"), .epic("OVERSIRE", "e1", .overview))
        XCTAssertEqual(Route(path: "work/epics"), .work(.epics))
        XCTAssertEqual(Route.work(.epics).path, "work/epics")
    }

    func testEpicCrumbs() {
        XCTAssertEqual(Route.epic("OVERSIRE", "e1", .items).crumbs, ["OVERSIRE", "Epics"])
        XCTAssertEqual(Route.epic("OVERSIRE", "e1", .items).title, "Epic")
    }

    func testEpicTabsAreSamePage() {
        XCTAssertTrue(Route.epic("OVERSIRE", "e1", .overview).samePage(.epic("OVERSIRE", "e1", .timeline)))
        XCTAssertFalse(Route.epic("OVERSIRE", "e1", .overview).samePage(.epic("OVERSIRE", "e2", .overview)))
    }
}
