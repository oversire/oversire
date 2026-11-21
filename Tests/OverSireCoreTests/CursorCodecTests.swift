import XCTest
@testable import OverSireCore

final class CursorCodecTests: XCTestCase {
    func testRoundTrip() throws {
        XCTAssertEqual(try Cursor(encoding: ["a": 1]).decoded(as: [String: Int].self), ["a": 1])
    }

    func testSameTextAsTheEncoder() throws {
        let v = ["a": 1]
        XCTAssertEqual(try Cursor(encoding: v).rawValue, String(decoding: try JSONEncoder().encode(v), as: UTF8.self))
    }

    func testOtherJSONGivesNil() {
        XCTAssertNil(Cursor(rawValue: "0").decoded(as: [String: Date].self))
        XCTAssertNil(Cursor(rawValue: "nope").decoded(as: [String: Date].self))
    }
}
