import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectPageGroupsTests: XCTestCase {
    func testDoneParentWithOpenSubItemsListsAsStarted() {
        let now = Date()
        let todo = StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")
        let doing = StatusOption(id: "p", name: "In Progress", color: "", group: "started")
        let done = StatusOption(id: "d", name: "Done", color: "", group: "completed")
        func item(_ id: String, _ state: String, parent: String? = nil) -> Item {
            Item(id: id, key: "A-\(id)", title: "T\(id)", url: "u", statusOptionId: state, fields: [:], assignees: [], labels: [],
                 author: nil, updatedBy: nil, updatedAt: now, activityAt: now, commentCount: 0, lastComment: nil,
                 mentionsMe: false, parentId: parent)
        }
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "w", id: "p"), identifier: "A", title: "A", url: "", closed: false),
                                   statusOptions: [todo, doing, done],
                                   items: [item("1", "d"), item("2", "t", parent: "1"), item("3", "d"), item("4", "p")],
                                   fetchedAt: now)
        let groups = ProjectPage.statusGroups(snap, snap.rootItems, showDone: true, hideDoneAfterDays: 0)
        let ids = Dictionary(uniqueKeysWithValues: groups.map { ($0.0.id, $0.1.map(\.id)) })
        XCTAssertEqual(ids["p"], ["4", "1"], "the Done parent with an open sub-item lists with In Progress")
        XCTAssertEqual(ids["d"], ["3"])
        XCTAssertEqual(ids["t"], [])
    }
}
