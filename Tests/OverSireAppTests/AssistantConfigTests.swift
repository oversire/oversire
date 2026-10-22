import XCTest
import OverSireAI
import OverSireAssistant
@testable import OverSireApp

final class AssistantConfigTests: XCTestCase {
    func testRoundTrip() throws {
        var cfg = AIConfig()
        cfg.assistant.source = .localCLI
        cfg.assistant.permissions = AssistantPermissions(read: .askOnce, change: .askEach)
        cfg.assistant.follow = false
        cfg.assistant.hotkey = KeyShortcut(keyCode: 38, modifiers: 0x0900)
        cfg.assistant.retention = .always
        let back = try JSONDecoder().decode(AIConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.assistant, cfg.assistant)
        XCTAssertEqual(back, cfg)
    }

    func testOldConfigGetsTheDefaults() throws {
        let old = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"enabled":true,"model":"m"}"#.utf8))
        XCTAssertEqual(old.assistant, AssistantConfig())
        XCTAssertEqual(old.assistant.permissions.rule(.read), .allow)
        XCTAssertEqual(old.assistant.permissions.rule(.change), .askOnce)
        XCTAssertEqual(old.assistant.permissions.rule(.outward), .askEach)
        XCTAssertEqual(old.assistant.permissions.rule(.settings), .never)
        XCTAssertTrue(old.assistant.follow)
        XCTAssertFalse(old.assistant.hotkey.hasShortcut)
        XCTAssertEqual(old.assistant.retention, .days30)

        let part = try JSONDecoder().decode(AssistantConfig.self, from: Data(#"{"follow":false}"#.utf8))
        XCTAssertFalse(part.follow)
        XCTAssertEqual(part.source, .jobs)
    }

    func testSourcePicksTheEngine() {
        var a = AssistantConfig()
        XCTAssertEqual(a.engine(jobs: .localCLI), .localCLI)
        XCTAssertEqual(a.engine(jobs: .apiKey), .apiKey)
        a.source = .apiKey
        XCTAssertEqual(a.engine(jobs: .localCLI), .apiKey)
        a.source = .localCLI
        XCTAssertEqual(a.engine(jobs: .apiKey), .localCLI)
    }
}
