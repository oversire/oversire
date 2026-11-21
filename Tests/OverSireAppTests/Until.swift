import OverSireTestKit
import XCTest

extension XCTestCase {
    /// Waits until `ok` holds, or fails after the timeout.
    func until(_ what: String = "", timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line,
               isolation: isolated (any Actor)? = #isolation, _ ok: () async -> Bool) async {
        if await Wait.until(timeout: timeout, isolation: isolation, ok) { return }
        XCTFail("timeout: \(what)", file: file, line: line)
    }
}
