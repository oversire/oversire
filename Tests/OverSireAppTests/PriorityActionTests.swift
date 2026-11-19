import XCTest
import OverSireCore
import OverSireAssistant
@testable import OverSireApp

final class PriorityActionTests: XCTestCase {
    func testSetPriorityRefusedWithoutCapability() async {
        let d = TestAppData()
        let ref = ProjectRef(account: AccountID(provider: .plane, id: "ocral"), id: "p1", key: "SLING")
        let item = Item(id: "i1", key: "SLING-1", title: "One", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        d.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false),
                                            statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted")],
                                            items: [item], fetchedAt: Date()))
        let r = await d.actions.run("item.setPriority", ActionArgs(.object(["key": .string("SLING-1"), "priority": .string("high")])))
        XCTAssertEqual(r, .notAllowed("Plane has no priority."))
        let created = await d.actions.run("item.create", ActionArgs(.object(["project": .string("SLING"), "title": .string("New"), "priority": .string("high")])))
        XCTAssertEqual(created, .notAllowed("Plane has no priority."))
    }
}
