import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

final class RunDetailViewTests: XCTestCase {
    override func tearDown() { commitMsgCache.removeAll() }

    func testOnlyARunningWorkflowHasALiveLabel() {
        let done = Run.sample(1)
        let running = Run.sample(2, status: "in_progress", conclusion: nil)
        commitMsgCache[done.headSha] = "msg"
        commitMsgCache[running.headSha] = "msg"
        let v = RunDetailView(group: [done, running], primary: running, repo: "o/r", history: [], w: 600)
        let labels = v.subviews.compactMap { $0 as? NSTextField }
        let live = labels.compactMap { $0 as? LiveLabel }
        XCTAssertEqual(live.count, 2, "the Elapsed line and the running workflow")
        XCTAssertTrue(live.contains { $0.stringValue.hasSuffix("elapsed") })
        let finished = "\(done.statusText) \u{00B7} \(done.durationText)"
        let plain = labels.first { !($0 is LiveLabel) && $0.stringValue == finished }
        XCTAssertNotNil(plain, "a plain label with the same text for the finished run")
    }
}
