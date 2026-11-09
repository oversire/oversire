import XCTest
@testable import OverSireApp

/// The plan gate names the state as not planned (OVERSIRE-448).
final class ShipGateTests: XCTestCase {
    func testGateTextSaysNotPlanned() {
        let s = SessionStartMenu.gateSpec(key: "OVERSIRE-443", state: "Backlog")
        XCTAssertEqual(s.title, "Plan first, or ship as is?")
        XCTAssertTrue(s.info.contains("OVERSIRE-443 is in Backlog, not planned"), s.info)
        XCTAssertFalse(s.info.contains("not Todo"))
        XCTAssertEqual(s.buttons, ["Plan first", "Ship as is", "Cancel"])
    }
}
