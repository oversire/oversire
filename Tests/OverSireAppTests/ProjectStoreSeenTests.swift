import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectStoreSeenTests: XCTestCase {
    private func store() -> ProjectStore {
        let d = TestAppData()
        let ref = ProjectRef(account: AccountID(provider: .plane, id: "ocral"), id: "p1", key: "SLING")
        let item = Item(id: "i1", key: "SLING-1", title: "One", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        d.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false),
                                            statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted")],
                                            items: [item], fetchedAt: Date()))
        return d.projectStore
    }

    func testMarkReadCallsOnSeenTwice() {
        let s = store()
        var seen: [String] = []
        s.onSeen = { id, key in seen.append("\(id ?? "-") \(key ?? "-")") }
        s.markRead(itemId: "i1")
        s.markRead(itemId: "i1")
        XCTAssertEqual(seen, ["i1 SLING-1", "i1 SLING-1"], "an item that is read already also clears")
    }

    func testSeenKeyResolvesId() {
        let s = store()
        var seen: [String] = []
        s.onSeen = { id, key in seen.append("\(id ?? "-") \(key ?? "-")") }
        s.seen(key: "sling-1")
        s.seen(key: "GONE-9")
        s.seen(itemId: "x")
        XCTAssertEqual(seen, ["i1 SLING-1", "- GONE-9", "x -"])
    }
}
