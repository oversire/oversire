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

    func testGroupByEpic() {
        let snap = EpicFixture.snap()
        let groups = ProjectPage.epicGroups(snap: snap, items: snap.items)
        XCTAssertEqual(groups.map(\.title), ["Review desk", "Epics", "Planned", "Old", "No epic"], "open epics by target date, a done epic, then No epic")
        XCTAssertEqual(groups.map(\.id), ["desk", "e2", "plan", "old", "none"])
        XCTAssertEqual(groups.map(\.items.count), [8, 1, 0, 1, 2])
        XCTAssertNil(groups.last?.epic)
        let desk = groups[0].epic
        XCTAssertEqual(desk?.done, 6)
        XCTAssertEqual(desk?.total, 8)
        XCTAssertNotNil(desk?.lateDays)
        XCTAssertEqual(groups.last?.items.map(\.key), ["ENG-11", "ENG-12"], "an item of an unknown epic lands in No epic")
        let mine = ProjectPage.epicGroups(snap: snap, items: snap.items.filter { $0.key == "ENG-9" })
        XCTAssertEqual(mine.map(\.items.count), [0, 1, 0], "the filter drops items; the open epics stay")
    }

    func testGroupByHiddenInBoardOrWithoutEpics() {
        let with = EpicFixture.snap(), without = EpicFixture.snap(epics: false)
        XCTAssertTrue(ProjectPage.showsGroupBy(snap: with, board: false))
        XCTAssertFalse(ProjectPage.showsGroupBy(snap: with, board: true))
        XCTAssertFalse(ProjectPage.showsGroupBy(snap: without, board: false))
        XCTAssertTrue(ProjectPage.groupsByEpic(snap: with, board: false, preferred: true))
        XCTAssertFalse(ProjectPage.groupsByEpic(snap: with, board: false, preferred: false))
        XCTAssertFalse(ProjectPage.groupsByEpic(snap: with, board: true, preferred: true), "the board keeps the status columns")
        XCTAssertFalse(ProjectPage.groupsByEpic(snap: without, board: false, preferred: true))
    }
}
