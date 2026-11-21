import XCTest
@testable import OverSireApp

final class SnapTicketTests: XCTestCase {
    func testPromptMigrates() {
        XCTAssertEqual(SnapTicket.migrate(SnapTicket.planeCLIPrompt), SnapTicket.defaultPrompt)
        XCTAssertEqual(SnapTicket.migrate("my prompt"), "my prompt")
        XCTAssertFalse(SnapTicket.defaultPrompt.contains("plane-cli"))
        XCTAssertTrue(SnapTicket.planeCLIPrompt.contains("plane-cli"))
    }
}
