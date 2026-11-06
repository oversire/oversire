import XCTest
import OverSireCore
@testable import OverSireApp

/// The first Plane adapter of an account makes its rate gate. The gate reads the budget, which takes the same lock.
final class AppEnvironmentGateTests: XCTestCase {
    func testTheFirstPlaneGateDoesNotDeadlock() {
        let env = AppEnvironment()
        let made = expectation(description: "io")
        Thread.detachNewThread {
            _ = env.io(.plane, account: AccountID(provider: .plane, id: "ocral"))
            _ = env.io(.plane, account: AccountID(provider: .plane, id: "ocral"))
            made.fulfill()
        }
        wait(for: [made], timeout: 5)
    }
}
