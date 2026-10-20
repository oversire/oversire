import XCTest
import OverSireCore
@testable import OverSireApp

final class MyItemsOrderTests: XCTestCase {
    private let options = [StatusOption(id: "b", name: "Backlog", color: "#888888", group: "backlog"),
                           StatusOption(id: "t", name: "Todo", color: "#888888", group: "unstarted"),
                           StatusOption(id: "p", name: "In progress", color: "#F59E0B", group: "started")]
    private var snap: ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "acme", id: "w"), identifier: "ENG", title: "Board", url: "", closed: false),
                        statusOptions: options, items: [], fetchedAt: Date(), me: "ada")
    }

    private func entry(_ n: Int, _ status: String, priority: String? = nil, ago: Double = 0, ciFails: Bool = false) -> MyItemsPage.Entry {
        let at = Date(timeIntervalSince1970: 1_700_000_000 - ago)
        let item = Item(id: "\(n)", key: "ENG-\(n)", title: "Item \(n)", url: "", statusOptionId: status,
                        fields: priority.map { ["Priority": $0] } ?? [:], assignees: ["ada"], labels: [], author: "ada",
                        updatedBy: "ada", updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil, mentionsMe: false)
        var s = Workstream(key: item.key)
        if ciFails {
            let r = Run(id: "9", name: "CI", displayTitle: "t", status: "completed", conclusion: "failure", headBranch: "main", headSha: "s",
                        event: "push", url: "", updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: "CI", actorLogin: nil, attempt: 1)
            s.runs = [RunLink(repo: "o/r", run: r, reason: .branch)]
        }
        return (item, snap, s)
    }

    private func status(_ attention: [String: Int]) -> (String) -> ItemStatus? {
        { k in attention[k].map { ItemStatus(source: .ai, tone: .bad, text: "x", attention: $0) } }
    }

    func testInProgressBeforeNotStarted() {
        let g = MyItemsPage.groups([entry(1, "b"), entry(2, "t"), entry(3, "p")], status: status([:]))
        XCTAssertEqual(g.map(\.title), ["In progress", "Not started"])
        XCTAssertEqual(g[0].lanes.flatMap(\.entries).map(\.item.key), ["ENG-3"])
        XCTAssertEqual(Set(g[1].lanes.flatMap(\.entries).map(\.item.key)), ["ENG-1", "ENG-2"])
    }

    func testPriorityLanes() {
        let g = MyItemsPage.groups([entry(1, "p", priority: "Low"), entry(2, "p"), entry(3, "p", priority: "Urgent"),
                                    entry(4, "p", priority: "High"), entry(5, "p", priority: "None")], status: status([:]))
        XCTAssertEqual(g[0].lanes.map(\.priority), ["Urgent", "High", "Low", "No priority"])
        XCTAssertEqual(g[0].lanes.last?.entries.map(\.item.key), ["ENG-2", "ENG-5"])
    }

    func testNeedsYouFirstInALane() {
        let list = [entry(1, "p", ago: 0), entry(2, "p", ago: 10), entry(3, "p", ago: 20), entry(4, "p", ago: 30, ciFails: true),
                    entry(5, "p", ago: 40), entry(6, "p", ago: 50)]
        let got = MyItemsPage.order(list, status: status(["ENG-6": 0, "ENG-5": 1, "ENG-3": 2, "ENG-2": 3])).map(\.item.key)
        XCTAssertEqual(got, ["ENG-6", "ENG-5", "ENG-3", "ENG-4", "ENG-2", "ENG-1"])
    }

    func testNewestActivityLast() {
        let got = MyItemsPage.order([entry(1, "t", ago: 100), entry(2, "t", ago: 5), entry(3, "t", ago: 50)], status: status([:]))
        XCTAssertEqual(got.map(\.item.key), ["ENG-2", "ENG-3", "ENG-1"])
    }
}
