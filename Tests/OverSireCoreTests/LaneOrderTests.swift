import OverSireCore
import XCTest

final class LaneOrderTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "A")

    private func rel(_ kind: RelationKind, _ key: String) -> ItemRelation {
        ItemRelation(kind: kind, item: ItemRef(project: project, id: key, key: key, url: URL(string: "https://x/\(key)")!))
    }

    func testFreeItemsOrderByPriority() {
        let prio = ["A-1": "low", "A-2": "high", "A-3": nil]
        let keys = ["A-2", "A-1", "A-3"]
        XCTAssertEqual(LaneOrder.insert("urgent", into: keys) { prio[$0] ?? nil }, 0)
        XCTAssertEqual(LaneOrder.insert("High", into: keys) { prio[$0] ?? nil }, 1, "after the same priority")
        XCTAssertEqual(LaneOrder.insert("medium", into: keys) { prio[$0] ?? nil }, 1)
        XCTAssertEqual(LaneOrder.insert(nil, into: keys) { prio[$0] ?? nil }, 3, "no priority goes last")
        XCTAssertEqual(LaneOrder.insert("low", into: []) { _ in nil }, 0)
    }

    func testCycleFromAProposalDrops() {
        var g = BlockGraph(["A-2": [rel(.blockedBy, "A-1")], "A-3": [rel(.blockedBy, "A-2")]])
        XCTAssertTrue(g.has("A-2", rel(.blockedBy, "A-1")))
        XCTAssertFalse(g.add("A-1", rel(.blockedBy, "A-3")), "A-1 → A-3 → A-2 → A-1")
        XCTAssertFalse(g.add("A-1", rel(.blocks, "A-1")), "the item itself")
        XCTAssertFalse(g.has("A-1", rel(.blockedBy, "A-3")), "a dropped line makes no change")
        XCTAssertTrue(g.add("A-1", rel(.relatesTo, "A-3")), "relatesTo is no edge")
        XCTAssertTrue(g.add("A-4", rel(.blocks, "A-1")))
        XCTAssertTrue(g.has("A-1", rel(.blockedBy, "A-4")))
    }
}
