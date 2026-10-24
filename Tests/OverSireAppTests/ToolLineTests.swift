import XCTest
@testable import OverSireApp

final class ToolLineTests: XCTestCase {
    func testBriefInput() {
        XCTAssertEqual(ToolLine.brief(input: #"{"command":"npm test -- callback","description":"Run the tests"}"#), "npm test -- callback")
        XCTAssertEqual(ToolLine.brief(input: #"{"file_path":"/repo/src/auth/callback.ts"}"#), "/repo/src/auth/callback.ts")
        XCTAssertEqual(ToolLine.brief(input: #"{"description":"Wait","command":"echo \"hi\" && ls"}"#), #"echo "hi" && ls"#)
        XCTAssertEqual(ToolLine.brief(input: #"{"command":"for i in $(seq 1 60); do echo $i; /bin/sle"#), "for i in $(seq 1 60); do echo $i; /bin/sle")
        XCTAssertEqual(ToolLine.brief(input: #"{"command":"a\nb"}"#), "a")
        XCTAssertEqual(ToolLine.brief(input: "{}"), "")
        XCTAssertEqual(ToolLine.brief(input: #"{"n":3}"#), #"{"n":3}"#)
        XCTAssertEqual(ToolLine.brief(input: "src/auth/callback.ts"), "src/auth/callback.ts")
    }

    func testBriefResult() {
        XCTAssertEqual(ToolLine.brief(result: "<tool_use_error>Blocked: standalone sleep 90.</tool_use_error>\nmore"), "Blocked: standalone sleep 90.")
        XCTAssertEqual(ToolLine.brief(result: "\n3 matches in 2 files"), "3 matches in 2 files")
    }
}
