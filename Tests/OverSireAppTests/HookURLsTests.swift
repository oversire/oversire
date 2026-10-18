import XCTest
@testable import OverSireApp

final class HookURLsTests: XCTestCase {
    func testAnAccountUsesItsHookRoute() {
        let u = HookURLs(worker: "https://c.test", route: "a1b2c3d4e5f60718")
        XCTAssertEqual(u.github, "https://c.test/hooks/github/a1b2c3d4e5f60718")
        XCTAssertEqual(u.plane("acme"), "https://c.test/hooks/plane/a1b2c3d4e5f60718.acme")
        XCTAssertEqual(u.oldGitHub, "https://c.test/webhook")
        XCTAssertEqual(u.oldPlane("acme"), "https://c.test/plane/acme")
    }

    func testTheOldRelayKeepsTheOldURLs() {
        let u = HookURLs(worker: "https://c.test", route: nil)
        XCTAssertEqual(u.github, u.oldGitHub)
        XCTAssertEqual(u.plane("acme"), u.oldPlane("acme"))
    }

    func testAnOldConfigHasNoHookRoute() throws {
        let c = try JSONDecoder().decode(RelayConfig.self, from: Data(#"{"enabled":true,"workerURL":"https://c.test","deviceID":"AAAA"}"#.utf8))
        XCTAssertNil(c.hookRoute)
    }
}
