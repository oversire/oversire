import Foundation
import OverSireCore
import OverSireSync
import XCTest

final class ReviewFrameTests: XCTestCase {
    func testReviewFrameParses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Contract/fixtures/review-event/changed.json"), encoding: .utf8)
        XCTAssertEqual(DaemonFrame.parse(text), .review(ReviewEvent(event: .changed, key: "OVERSIRE-371", kind: .plan)))
        XCTAssertNil(DaemonFrame.parse(#"{"type":"review","event":"review.nope","key":"K-1","kind":"code"}"#))
    }
}
