import XCTest
import OverSireCore

final class MirrorCodecTests: XCTestCase {
    func testCIIDs() {
        XCTAssertEqual(MirrorCodec.ciJobsID(repo: "o/r", run: "12", attempt: 2), "o/r/12/2")
        XCTAssertEqual(MirrorCodec.ciChecksID(repo: "o/r", sha: "abc"), "o/r/abc")
        XCTAssertEqual(MirrorCodec.ciStateID, "home")
    }
}
