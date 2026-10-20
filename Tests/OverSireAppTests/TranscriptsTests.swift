import XCTest
import OverSireCore
@testable import OverSireApp

final class TranscriptsTests: XCTestCase {
    private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Contract/fixtures/session-digest")

    func testTheAgentBinderReaderMatchesTheContractFixtures() throws {
        for name in ["basic", "notices", "interrupted", "tools-only", "long"] {
            let want = try JSONDecoder().decode(SessionDigest.self, from: Data(contentsOf: dir.appendingPathComponent(name + ".json")))
            let got = try BinderTranscripts().digest(file: dir.appendingPathComponent("claude/\(name).jsonl").path, agent: .claude, budget: .standard)
            XCTAssertEqual(got, want, name)
        }
    }

    func testOtherHarnessesAreUnsupported() {
        XCTAssertThrowsError(try BinderTranscripts().digest(file: dir.appendingPathComponent("claude/basic.jsonl").path, agent: "codex",
                                                           budget: .standard)) { e in
            XCTAssertEqual(e as? ProviderError, .unsupported(.sessionHistory))
        }
    }
}
