import XCTest
@testable import OverSireApp

final class SessionConfigTests: XCTestCase {
    func testEmptyJSONGivesTheDefaults() throws {
        let c = try JSONDecoder().decode(SessionConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c, SessionConfig())
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.intake)
        XCTAssertNil(c.lastProject)
        XCTAssertEqual(c.maxBytes, 10 * 1024 * 1024)
        XCTAssertEqual(c.shortcutLabel, "⌃⌥⌘N")
    }

    func testOldConfigWithNoSessionKeyDecodes() throws {
        let cap = try JSONDecoder().decode(CaptureConfig.self, from: Data(#"{"enabled":true,"keyCode":45,"modifiers":6144,"snap":{}}"#.utf8))
        XCTAssertEqual(cap.session, SessionConfig())
        XCTAssertEqual(cap.shortcutLabel, "⌃⌥N", "the New item sheet keeps its own shortcut")
        let rt = try JSONDecoder().decode(RuntimeConfig.self, from: Data(#"{"agent":"codex"}"#.utf8))
        XCTAssertEqual(rt.sessionIntakePrompt, SessionPrompt.intakeDefault)
        XCTAssertEqual(rt.sessionFilesPrompt, SessionPrompt.filesDefault)
    }

    func testRoundTripKeepsEachField() throws {
        var c = SessionConfig()
        c.enabled = false
        c.keyCode = 1
        c.modifiers = 0x0900
        c.intake = false
        c.lastProject = "ocral/p1"
        c.maxBytes = 5 * 1024 * 1024
        let back = try JSONDecoder().decode(SessionConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        var r = RuntimeConfig()
        r.sessionIntakePrompt = "a {key}"
        r.sessionFilesPrompt = "b {paths}"
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(r)), r)
    }
}
