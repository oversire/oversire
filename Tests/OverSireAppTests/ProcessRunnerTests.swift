import OverSireCore
import XCTest
@testable import OverSireApp

final class ProcessRunnerTests: XCTestCase {
    func testCancelStopsTheChildAndThrows() async throws {
        let arg = "30.\(Int.random(in: 1000...9999))"
        let start = Date()
        let task = Task { try await ProcessRunner().run("/bin/sleep", [arg], stdin: nil, timeout: .seconds(60)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let left = try await ProcessRunner().run("/usr/bin/pgrep", ["-f", "sleep \(arg)"], stdin: nil, timeout: .seconds(5))
        XCTAssertEqual(left.status, 1, "no sleep process is left")
    }

    func testCancelBeforeTheStartThrows() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run("/bin/echo", ["hi"], stdin: nil, timeout: .seconds(5))
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTimeoutStopsTheChildWithNoError() async throws {
        let start = Date()
        let out = try await ProcessRunner().run("/bin/sleep", ["30"], stdin: nil, timeout: .milliseconds(200))
        XCTAssertNotEqual(out.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
