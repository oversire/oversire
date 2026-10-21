import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

final class ItemPageUpdateTests: XCTestCase {
    private func snap(title: String = "Item 1") -> ProjectSnapshot {
        let item = Item(id: "1", key: "ENG-1", title: title, url: "https://plane.example/ENG-1", statusOptionId: "p", fields: [:], assignees: [], labels: [],
                        author: "ada", updatedBy: "ada", updatedAt: Date(timeIntervalSince1970: 0), activityAt: Date(timeIntervalSince1970: 0),
                        commentCount: 0, lastComment: nil, mentionsMe: false, body: "A short description.")
        return ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "acme", id: "w"), identifier: "ENG", title: "Board", url: "", closed: false),
                               statusOptions: [StatusOption(id: "p", name: "In progress", color: "#F59E0B", group: "started")], items: [item],
                               fetchedAt: Date(), me: "ada")
    }

    private func page(_ data: TestAppData) -> ItemPage {
        data.projectStore.seed(snap())
        let p = ItemPage(.item("ENG-1", .overview), data: data, router: Router())
        _ = p.view
        return p
    }

    func testChangeForAnotherItemDoesNotBuild() {
        let p = page(TestAppData())
        XCTAssertEqual(p.buildCount, 1)
        p.receive(DataChange(.agents, items: ["ENG-2"]))
        p.receive(DataChange(.agents))
        XCTAssertEqual(p.buildCount, 1)
    }

    func testNewTitleUpdatesOnlyTheHead() {
        let data = TestAppData()
        let p = page(data)
        data.projectStore.seed(snap(title: "Item 1, new title"))
        p.receive(DataChange(.projects))
        XCTAssertEqual(p.buildCount, 2)
        XCTAssertEqual(p.lastResult?.updated, 1)
        XCTAssertEqual(p.lastResult?.inserted, 0)
        XCTAssertEqual(p.lastResult?.removed, 0)
    }

    func testCleanupRunPostsOneChangeForTheItemAtEachEnd() {
        let data = TestAppData()
        var keys: [String?] = []
        let o = NotificationCenter.default.addObserver(forName: Cleaner.changed, object: data.cleaner, queue: nil) {
            keys.append($0.userInfo?[Cleaner.keyInfo] as? String)
        }
        let done = expectation(description: "run")
        data.cleaner.run([], key: "eng-1", data: data) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        NotificationCenter.default.removeObserver(o)
        XCTAssertEqual(keys, ["ENG-1", "ENG-1"])
    }
}
