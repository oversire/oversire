import OverSireCore
import XCTest
@testable import OverSireApp

final class RunbookConfigTests: XCTestCase {
    private func runtime(_ json: String) throws -> RuntimeConfig {
        try JSONDecoder().decode(RuntimeConfig.self, from: Data(json.utf8))
    }

    func testNoRunbooksDecodesToTheDefaults() throws {
        let r = try runtime(#"{"agent":"claude"}"#)
        XCTAssertEqual(r.runbooks.map(\.id), ["full", "small", "plan-only"])
        XCTAssertEqual(r.runbooks.map { $0.steps.count }, [6, 3, 3])
        XCTAssertEqual(r.runbook("full")?.steps.map(\.agent), Array(repeating: "claude", count: 6), "no claude-max: the default agent")
        XCTAssertEqual(r.runbook("full")?.steps.filter(\.pauses).map(\.id), ["implement"])
        for b in r.runbooks { XCTAssertEqual(b.validate(agents: r.runbookAgents), [], b.name) }
    }

    func testTheDefaultsUseClaudeMaxWhenItExists() throws {
        var r = RuntimeConfig()
        r.add("claude-max", cli: "claude")
        let full = try XCTUnwrap(r.defaultRunbooks.first)
        XCTAssertEqual(full.steps.map(\.agent), ["claude-max", "claude", "claude-max", "claude", "claude-max", "claude-max"])
        for b in r.defaultRunbooks { XCTAssertEqual(b.validate(agents: r.runbookAgents), [], b.name) }
    }

    func testASavedRunbookEncodesAndDecodesTheSame() throws {
        var r = RuntimeConfig()
        r.runbooks.append(Runbook(id: "mine", name: "Mine", steps: [
            RunbookStep(id: "a", name: "A", agent: "codex", prompt: "Do {key}. {done}"),
            RunbookStep(id: "r", name: "R", agent: "claude", prompt: "Check. {done}", pauseBefore: true, review: .init(fix: "f", rounds: 3)),
            RunbookStep(id: "f", name: "F", agent: "claude", prompt: "Fix. {done}"),
        ]))
        let again = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(again, r)
        r.runbooks = []
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(r)).runbooks, [], "an empty list stays empty")
    }

    func testAProjectDefaultFallsBackToFull() throws {
        var p = ProjectsConfig()
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "full")
        var local = ProjectLocalSettings()
        local.runbook = "small"
        p.settings["OVERSIRE"] = local
        XCTAssertEqual(p.runbook(for: "oversire")?.id, "small")
        p.runtime.runbooks.removeAll { $0.id == "small" }
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "full", "a removed runbook falls back to full")
        p.runtime.runbooks.removeAll { $0.id == "full" }
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "plan-only")
        let back = try JSONDecoder().decode(ProjectLocalSettings.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(back.runbook, "small")
    }
}
