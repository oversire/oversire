import AppKit
import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class ItemLineTests: XCTestCase {
    private let snap = ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "acme", id: "w"), identifier: "ENG", title: "Board", url: "", closed: false),
                                       statusOptions: [StatusOption(id: "t", name: "Todo", color: "#888888", group: "unstarted")], items: [], fetchedAt: Date())
    private let item = Item(id: "1", key: "ENG-1", title: "Item", url: "", statusOptionId: "t", fields: [:], assignees: [], labels: [], author: nil,
                            updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)

    private func stream(_ status: String?, conclusion: String? = nil) -> Workstream {
        var s = Workstream(key: "ENG-1")
        if let status {
            let r = Run(id: "9", name: "CI", displayTitle: "t", status: status, conclusion: conclusion, headBranch: "main", headSha: "s",
                        event: "push", url: "", updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: "CI", actorLogin: nil, attempt: 1)
            s.runs = [RunLink(repo: "o/r", run: r, reason: .branch)]
        }
        return s
    }

    private func marks(_ v: NSView) -> Int { (v is Spinner && v.toolTip == CIRunningMark.label ? 1 : 0) + v.subviews.reduce(0) { $0 + marks($1) } }

    private func line(_ s: Workstream) -> ItemLine {
        let layout = ColumnLayout(id: "t-\(UUID().uuidString)", columns: ItemLine.columns(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return ItemLine(item, snap: snap, stream: s, status: nil, layout: layout) { _ in }
    }

    func testNoCIColumn() {
        XCTAssertFalse(ItemLine.columns().contains { $0.id == "ci" })
    }

    func testSpinnerOnlyWhileCIRuns() {
        XCTAssertEqual(marks(line(stream("in_progress"))), 1)
        XCTAssertEqual(marks(line(stream("completed", conclusion: "failure"))), 0, "no mark for a failed run")
        XCTAssertEqual(marks(line(stream("completed", conclusion: "success"))), 0, "no mark for a passed run")
        XCTAssertEqual(marks(line(stream(nil))), 0)
        XCTAssertTrue(line(stream("completed", conclusion: "failure")).accessibilityLabel()?.contains("CI Failed") == true, "the label keeps the CI word")
    }
}
