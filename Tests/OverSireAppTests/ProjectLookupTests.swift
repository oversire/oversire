import XCTest
import OverSireCore
@testable import OverSireApp

final class ProjectLookupTests: XCTestCase {
    private func of(tracked: Bool = true, fetching: Bool = false, error: String? = nil, catalogBusy: Bool = false,
                    asked: Bool = true, inCatalog: Bool = true) -> ProjectLookup {
        .of(tracked: tracked, fetching: fetching, error: error, catalogBusy: catalogBusy, asked: asked, inCatalog: inCatalog)
    }

    func testTrackedWithNoItemsLoads() {
        XCTAssertEqual(of(), .loading)
        XCTAssertEqual(of(fetching: true, error: "403 Forbidden"), .loading)
    }

    func testFailedFetchShowsTheError() {
        XCTAssertEqual(of(error: "403 Forbidden"), .failed("403 Forbidden"))
    }

    func testUnknownKeyLooksInPlaneFirst() {
        XCTAssertEqual(of(tracked: false, asked: false), .looking)
        XCTAssertEqual(of(tracked: false, catalogBusy: true), .looking)
    }

    func testUntrackedAfterTheLookup() {
        XCTAssertEqual(of(tracked: false), .untracked(canTrack: true))
        XCTAssertEqual(of(tracked: false, inCatalog: false), .untracked(canTrack: false))
    }

    func testTrackPublishesWhenTheTrackedSetChanges() {
        let d = TestAppData()
        d.projectStore.hold = true
        var got: [DataChange] = []
        d.projectStore.onChange = { got.append($0) }
        let p = ProjectSummary(ref: ProjectRef(workspace: "acme", id: "p1"), identifier: "MCPQ", title: "MCP query", url: "", closed: false)
        d.projectStore.track([p], live: [])
        XCTAssertEqual(got, [DataChange(.projects, origin: .event)])
        got = []
        d.projectStore.track([p], live: [])
        XCTAssertEqual(got, [])
    }
}
