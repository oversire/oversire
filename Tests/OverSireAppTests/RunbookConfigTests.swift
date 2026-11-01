import OverSireCore
import XCTest
@testable import OverSireApp

final class RunbookConfigTests: XCTestCase {
    private func runtime(_ json: String) throws -> RuntimeConfig {
        try JSONDecoder().decode(RuntimeConfig.self, from: Data(json.utf8))
    }

    func testNoRunbooksDecodesToTheDefaults() throws {
        let r = try runtime(#"{"agent":"claude"}"#)
        XCTAssertEqual(r.runbooks.map(\.id), ["plan", "ship"])
        XCTAssertEqual(r.runbooks.map { $0.steps.map(\.id) }, [["plan", "review-plan", "plan-fixes"], ["implement", "review", "fixes"]])
        XCTAssertEqual(r.runbook("ship")?.steps.map(\.agent), Array(repeating: "claude", count: 3), "no claude-max: the default agent")
        XCTAssertEqual(r.runbooks.flatMap(\.steps).filter(\.pauses), [], "the review gate replaces the pause")
        XCTAssertNil(r.runbookNote)
        for b in r.runbooks { XCTAssertEqual(b.validate(agents: r.runbookAgents), [], b.name) }
    }

    func testTheDefaultsEndAtTheReviewGate() {
        let r = RuntimeConfig()
        let plan = r.runbook("plan")!, ship = r.runbook("ship")!
        XCTAssertTrue(plan.steps.last!.prompt.contains("oversire review ready --key {key} --kind plan"))
        XCTAssertTrue(ship.steps.last!.prompt.contains("oversire review ready --key {key} --kind code"))
        XCTAssertTrue(ship.steps.allSatisfy { $0.prompt.contains("{group}") }, "Ship works in the group of the parent")
        XCTAssertFalse(plan.steps[0].prompt.contains("{group}"), "a plan writes no code")
    }

    func testTheDefaultsUseClaudeMaxWhenItExists() throws {
        var r = RuntimeConfig()
        r.add("claude-max", cli: "claude")
        XCTAssertEqual(r.defaultRunbooks.map { $0.steps.map(\.agent) }, [["claude-max", "claude", "claude-max"], ["claude", "claude-max", "claude-max"]])
        for b in r.defaultRunbooks { XCTAssertEqual(b.validate(agents: r.runbookAgents), [], b.name) }
    }

    /// The runbooks of a config before OVERSIRE-373.
    private func oldBooks(implementAgent: String = "claude") -> [Runbook] {
        let p = Runbook.oldPrompts
        func st(_ id: String, _ name: String, agent: String = "claude", pause: Bool? = nil, fix: String? = nil) -> RunbookStep {
            RunbookStep(id: id, name: name, agent: agent, prompt: p[id]!, pauseBefore: pause, review: fix.map { .init(fix: $0) })
        }
        let plan = [st("plan", "Plan & Refine"), st("review-plan", "Review Plan", fix: "plan-fixes"), st("plan-fixes", "Implement Plan Fixes")]
        let ship = [st("review", "Review Implementation", fix: "fixes"), st("fixes", "Implement Fixes")]
        return [
            Runbook(id: "full", name: "Full", steps: plan + [st("implement", "Implement", agent: implementAgent, pause: true)] + ship),
            Runbook(id: "small", name: "Small", steps: [st("implement", "Implement")] + ship),
            Runbook(id: "plan-only", name: "Plan only", steps: plan),
        ]
    }

    func testTheOldRunbooksMoveToPlanAndShip() throws {
        var old = RuntimeConfig()
        old.runbooks = oldBooks(implementAgent: "codex")
        old.runbooks.append(Runbook(id: "mine", name: "Mine", steps: [RunbookStep(id: "a", name: "A", agent: "claude", prompt: "Do {key}. {done}")]))
        let r = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(r.runbooks.map(\.id), ["plan", "ship", "mine"], "Small with the old defaults goes; a user runbook stays")
        let ship = try XCTUnwrap(r.runbook("ship"))
        XCTAssertEqual(ship.name, "Ship")
        XCTAssertEqual(ship.steps.map(\.id), ["implement", "review", "fixes"])
        XCTAssertEqual(ship.steps[0].agent, "codex", "an edit of the user stays")
        XCTAssertFalse(ship.steps[0].pauses)
        XCTAssertEqual(ship.steps.map(\.prompt), RuntimeConfig().runbook("ship")!.steps.map(\.prompt), "an old default prompt gets the new one")
        XCTAssertEqual(r.runbook("plan")?.steps.map(\.prompt), RuntimeConfig().runbook("plan")!.steps.map(\.prompt))
        XCTAssertEqual(r.runbook("full")?.id, "ship", "a queue entry or a project that names full finds Ship")
        XCTAssertEqual(r.runbook("small")?.id, "ship")
        XCTAssertEqual(r.runbook("plan-only")?.id, "plan")
        let note = try XCTUnwrap(r.runbookNote)
        XCTAssertTrue(note.contains("Full → Ship") && note.contains("Plan only → Plan") && note.contains("Small → Ship"), note)
        let again = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(again, r, "the move runs once")
    }

    func testAnEditedSmallAndPromptStay() throws {
        var books = oldBooks()
        books[0].steps[3].prompt = "My implement {key}. {done}"
        books[1].steps[0].prompt = "Quick {key}. {done}"
        let m = RuntimeConfig.migrate(books, defaults: RuntimeConfig().defaultRunbooks)
        XCTAssertEqual(m.books.map(\.id), ["plan", "ship", "small"])
        XCTAssertEqual(m.books[1].steps[0].prompt, "My implement {key}. {done}")
        XCTAssertNotNil(m.note)
        XCTAssertNil(RuntimeConfig.migrate(m.books, defaults: RuntimeConfig().defaultRunbooks).note, "nothing to move")
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

    func testAProjectDefaultFallsBackToShip() throws {
        var p = ProjectsConfig()
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "ship")
        var local = ProjectLocalSettings()
        local.runbook = "plan"
        p.settings["OVERSIRE"] = local
        XCTAssertEqual(p.runbook(for: "oversire")?.id, "plan")
        local.runbook = "full"
        p.settings["OVERSIRE"] = local
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "ship", "an old id finds its new runbook")
        local.runbook = "plan"
        p.settings["OVERSIRE"] = local
        p.runtime.runbooks.removeAll { $0.id == "plan" }
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "ship", "a removed runbook falls back to ship")
        p.runtime.runbooks = [Runbook(id: "mine", name: "Mine", steps: [])]
        XCTAssertEqual(p.runbook(for: "OVERSIRE")?.id, "mine")
        let back = try JSONDecoder().decode(ProjectLocalSettings.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(back.runbook, "plan")
    }
}
