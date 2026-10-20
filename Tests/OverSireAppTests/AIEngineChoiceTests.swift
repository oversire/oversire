import XCTest
import OverSireAI
@testable import OverSireApp

final class AIEngineChoiceTests: XCTestCase {
    func testTheLocalCLIFallsBackToAPassedKey() throws {
        var cfg = AIConfig()
        cfg.baseURL = "https://api.anthropic.com"
        cfg.model = "m"
        cfg.verified = cfg.fingerprint(key: "k")
        XCTAssertEqual(AIClient.engines(cfg, key: "k").map(\.id), [.apiKey])

        cfg.engine = .localCLI
        cfg.cliHarness = "claude"
        XCTAssertEqual(AIClient.engines(cfg, key: "k").map(\.id), [.localCLI, .apiKey])
        XCTAssertEqual(AIClient.engines(cfg, key: "other").map(\.id), [.localCLI], "a key with no passed Test is no fallback")
        cfg.fallback = .skip
        XCTAssertEqual(AIClient.engines(cfg, key: "k").map(\.id), [.localCLI])
    }

    func testTheTestCoversTheEngineAndTheHarness() throws {
        var cfg = AIConfig()
        cfg.enabled = true
        cfg.engine = .localCLI
        cfg.cliHarness = "claude"
        XCTAssertFalse(cfg.isOn(key: nil))
        cfg.cliVerified = cfg.cliFingerprint
        XCTAssertTrue(cfg.isOn(key: nil), "the local CLI needs no key")
        cfg.cliModel = "claude-haiku-5-5"
        XCTAssertTrue(cfg.isOn(key: nil), "a new model keeps the pass")
        cfg.cliHarness = "codex"
        XCTAssertFalse(cfg.isOn(key: nil), "a new harness needs a new Test")
        cfg.engine = .apiKey
        XCTAssertFalse(cfg.isOn(key: "k"))

        let old = try JSONDecoder().decode(AIConfig.self, from: Data(#"{"enabled":true,"model":"m"}"#.utf8))
        XCTAssertEqual(old.engine, .apiKey, "an old config keeps the API key")
        XCTAssertEqual(old.fallback, .apiKey)
        XCTAssertEqual(old.cliLimitPause, 90)
    }
}
