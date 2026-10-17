import XCTest
@testable import OverSireApp
import OverSireCore

final class RunClockTests: XCTestCase {
    private func running(_ secondsAgo: TimeInterval) -> Run {
        let s = isoFmt.string(from: Date().addingTimeInterval(-secondsAgo))
        return Run(id: "1", name: "ci", displayTitle: "t", status: "in_progress", conclusion: nil, headBranch: "main", headSha: "s",
                   event: "push", url: "u", updatedAt: s, createdAt: s, startedAt: s, number: 1, workflowName: "ci", actorLogin: nil)
    }

    func testTimeLeft() {
        let label = RunClock(running(70), total: 200).accessibilityLabel() ?? ""
        XCTAssertTrue(label.hasPrefix("Running, 1m 1"), label)
        XCTAssertTrue(label.contains("left"), label)
    }

    func testOverEstimate() {
        let label = RunClock(running(400), total: 300).accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("over the estimate"), label)
    }

    func testNoEstimate() {
        XCTAssertTrue(RunClock(running(30), total: nil).accessibilityLabel()?.hasSuffix("no estimate yet") == true)
    }
}
