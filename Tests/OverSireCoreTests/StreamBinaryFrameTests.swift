import XCTest
@testable import OverSireCore

final class StreamBinaryFrameTests: XCTestCase {
    func testRoundTrip() throws {
        let f = StreamBinaryFrame(op: .output, seq: 0x0102_0304_0506_0708, data: Data("hi\u{1b}[0m".utf8))
        let bytes = f.encoded
        XCTAssertEqual(Array(bytes.prefix(9)), [2, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(StreamBinaryFrame(bytes), f)
        // A slice keeps its own start index.
        XCTAssertEqual(StreamBinaryFrame((Data([0]) + bytes).dropFirst()), f)
    }

    func testRejectsShortOrUnknown() {
        XCTAssertNil(StreamBinaryFrame(Data([1, 0, 0])))
        XCTAssertNil(StreamBinaryFrame(Data([9] + Array(repeating: 0, count: 8))))
        XCTAssertEqual(StreamBinaryFrame(Data([1] + Array(repeating: 0, count: 8)))?.data, Data())
    }
}
