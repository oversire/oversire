import XCTest
@testable import OverSireTestKit

final class WaitTests: XCTestCase {
    func testUntilReturnsWhenTheConditionHolds() async {
        var calls = 0
        let ok = await Wait.until(every: .milliseconds(1)) {
            calls += 1
            return calls == 3
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(calls, 3)
    }

    func testUntilGivesFalseAfterTheTimeout() async {
        let start = ContinuousClock.now
        let ok = await Wait.until(timeout: .milliseconds(50)) { false }
        let took = ContinuousClock.now - start
        XCTAssertFalse(ok)
        XCTAssertGreaterThanOrEqual(took, .milliseconds(50))
        XCTAssertLessThan(took, .seconds(1))
    }

    @MainActor
    func testUntilReadsMainActorState() async {
        var flag = false
        Task { @MainActor in flag = true }
        let ok = await Wait.until { flag }
        XCTAssertTrue(ok)
    }
}
