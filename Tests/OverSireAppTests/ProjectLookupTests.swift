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

    private func seeded(_ d: TestAppData, keys: [String]) {
        let ref = ProjectRef(account: AccountID(provider: .plane, id: "ocral"), id: "p1", key: "ACME")
        let items = keys.enumerated().map { i, k in
            Item(id: "i\(i)", key: k, title: "T\(i)", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                 author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        }
        d.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "ACME", title: "Acme", url: "", closed: false),
                                            statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted")],
                                            items: items, fetchedAt: Date()))
    }

    func testItemByKeyIgnoresCase() {
        let d = TestAppData()
        seeded(d, keys: ["ACME-1"])
        XCTAssertEqual(d.projectStore.item(key: "acme-1")?.item.id, "i0")
        XCTAssertNil(d.projectStore.item(key: "ACME-2"))
    }

    func testItemByKeySeesANewSnapshot() {
        let d = TestAppData()
        seeded(d, keys: ["ACME-1"])
        XCTAssertNil(d.projectStore.item(key: "ACME-2"))
        seeded(d, keys: ["ACME-2"])
        XCTAssertEqual(d.projectStore.item(key: "ACME-2")?.item.id, "i0")
        XCTAssertNil(d.projectStore.item(key: "ACME-1"))
    }

    func testItemByKeyKeepsTheFirstMatch() {
        let d = TestAppData()
        seeded(d, keys: ["ACME-1", "acme-1"])
        XCTAssertEqual(d.projectStore.item(key: "ACME-1")?.item.id, "i0")
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
