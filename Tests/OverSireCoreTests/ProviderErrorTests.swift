import XCTest
import OverSireCore

final class ProviderErrorTests: XCTestCase {
    func testLocalizedDescriptionIsTheMessage() {
        let e: Error = ProviderError.vendor(code: "400", message: "Intake is off for MCPQ in Plane.")
        XCTAssertEqual(e.localizedDescription, "Intake is off for MCPQ in Plane.")
        XCTAssertEqual((ProviderError.notFound as Error).localizedDescription, "Not found")
    }
}
