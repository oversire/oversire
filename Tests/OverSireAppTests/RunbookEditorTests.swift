import OverSireCore
import XCTest
@testable import OverSireApp

final class RunbookEditorTests: XCTestCase {
    private var saved = ProjectsConfig()
    private var e: RunbookEditor!

    override func setUp() {
        saved = PROJECTS_CFG
        var cfg = ProjectsConfig()
        cfg.runtime.add("claude-max", cli: "claude")
        cfg.runtime.runbooks = cfg.runtime.oldRunbooks
        PROJECTS_CFG = cfg
        e = RunbookEditor(undo: RunbookUndo(bus: ChangeBus()))
        e.follow()
    }

    override func tearDown() { PROJECTS_CFG = saved }

    private var ids: [String] { e.runbook?.steps.map(\.id) ?? [] }

    func testOpensOnFullWithAValidCheckLine() {
        XCTAssertEqual(e.runbook?.id, "full")
        XCTAssertEqual(e.problems, [])
        XCTAssertEqual(e.valid, "✓ Valid: 6 steps, all agents exist, each prompt has {done}, each review has a fix step after it.")
        XCTAssertEqual(e.reviewText(e.runbook!.steps[1]), "↻ fix 3 · 1 round")
        XCTAssertNil(e.undoLabel)
    }

    func testEditsSaveAtOnce() {
        e.set("plan") { $0.name = "Plan" }
        e.set("implement") { $0.agent = "codex" }
        e.setPause("implement", false)
        e.rename("Full and tests")
        let b = PROJECTS_CFG.runtime.runbook("full")!
        XCTAssertEqual(b.name, "Full and tests")
        XCTAssertEqual(b.steps[0].name, "Plan")
        XCTAssertEqual(b.step("implement")?.agent, "codex")
        XCTAssertNil(b.step("implement")?.pauseBefore)
        XCTAssertEqual(e.undoLabel, "Change Full")
    }

    func testMoveAddAndRemove() {
        XCTAssertFalse(e.move("plan", by: -1), "the first step cannot go up")
        XCTAssertTrue(e.move("implement", by: -1))
        XCTAssertEqual(ids, ["plan", "review-plan", "implement", "plan-fixes", "review", "fixes"])
        XCTAssertTrue(e.move("implement", to: 5))
        XCTAssertEqual(ids.last, "implement")
        e.open = "plan"
        XCTAssertEqual(e.addStep(), "step")
        XCTAssertEqual(ids[1], "step", "a new step goes after the open step")
        XCTAssertEqual(e.open, "step")
        XCTAssertEqual(e.addStep(), "step-2")
        e.removeStep("step-2")
        XCTAssertFalse(ids.contains("step-2"))
        XCTAssertNil(e.open)
    }

    func testCheckLineFollowsTheEdits() {
        e.set("implement") { $0.prompt = "Implement {key}." }
        e.setReview("review", fix: "plan-fixes")
        XCTAssertEqual(e.problems.map(\.text), [
            "Implement: the prompt has no {done}.",
            "Review Implementation: the fix step must be a step after the review.",
        ])
        XCTAssertEqual(e.problems.map(\.step), ["implement", "review"])
        XCTAssertEqual(PROJECTS_CFG.runtime.runbook("full")?.step("review")?.review?.fix, "plan-fixes", "an invalid edit saves too")
        e.setReview("review", fix: nil)
        XCTAssertNil(PROJECTS_CFG.runtime.runbook("full")?.step("review")?.review)
    }

    func testANewIDChangesTheReviewThatFixesWithIt() {
        e.open = "fixes"
        e.setID("fixes", "final-fixes")
        XCTAssertEqual(PROJECTS_CFG.runtime.runbook("full")?.step("review")?.review?.fix, "final-fixes")
        XCTAssertEqual(e.open, "final-fixes")
        e.follow()
        XCTAssertEqual(e.added, [], "a new id is not a new step")
    }

    func testAddedStepsHaveAMarkUntilTheNextChange() {
        var c = PROJECTS_CFG
        c.runtime.runbooks[0].steps.insert(RunbookStep(id: "tests", name: "Write Tests", agent: "codex", prompt: "{done}"), at: 4)
        PROJECTS_CFG = c   // as the assistant does it
        e.follow()
        XCTAssertEqual(e.added, ["tests"])
        e.follow()
        XCTAssertEqual(e.added, ["tests"], "a build with no change keeps the mark")
        e.setPause("tests", true)
        e.follow()
        XCTAssertEqual(e.added, [])
    }

    func testARunbookOfTheAssistantShowsAtOnce() {
        PROJECTS_CFG.runtime.runbooks.append(Runbook(id: "docs", name: "Docs", steps: []))
        e.follow()
        XCTAssertEqual(e.runbook?.id, "docs")
    }

    func testRunbooksAndUndo() {
        XCTAssertEqual(e.duplicate(), "full-copy")
        XCTAssertEqual(e.runbook?.name, "Full copy")
        XCTAssertEqual(e.addRunbook(), "runbook")
        XCTAssertEqual(e.runbook?.steps.map(\.id), ["implement"])
        e.delete("runbook")
        XCTAssertEqual(PROJECTS_CFG.runtime.runbooks.map(\.id), ["full", "small", "plan-only", "full-copy"])
        XCTAssertEqual(e.undoLast(), "Delete New runbook")
        XCTAssertEqual(e.undoLast(), "New New runbook")
        XCTAssertEqual(e.undoLast(), "New Full copy")
        XCTAssertEqual(PROJECTS_CFG.runtime.runbooks.map(\.id), ["full", "small", "plan-only"])
        XCTAssertNil(e.undoLast())
    }

    func testDeleteClearsTheProjectDefault() {
        PROJECTS_CFG.setRunbook("small", for: "SLING")
        XCTAssertEqual(e.users(PROJECTS_CFG.runtime.runbook("small")!, of: ["SLING"]), ["SLING"])
        e.delete("small")
        XCTAssertNil(PROJECTS_CFG.local("SLING").runbook)
        XCTAssertEqual(PROJECTS_CFG.runbook(for: "SLING")?.id, "full")
    }

    func testAnEmptyListCanGetTheDefaultsBack() {
        PROJECTS_CFG.runtime.runbooks = []
        e.follow()
        XCTAssertNil(e.runbook)
        XCTAssertNil(e.addStep())
        e.restoreDefaults()
        e.follow()
        XCTAssertEqual(e.runbooks.map(\.id), ["plan", "ship"])
    }

    func testTheAssistantSeesTheRunbook() {
        e.open = "implement"
        let c = e.context(route: .settings(.agents, tab: .runbooks), projects: ["SLING"])
        XCTAssertEqual(c.route, "settings/agents/runbooks")
        XCTAssertEqual(c.selection, ["runbook:full", "step:implement"])
        XCTAssertEqual(c.rows.first?.text, "Full · 6 steps · default of SLING")
        XCTAssertEqual(c.rows.first { $0.id == "step:implement" }?.text, "4. Implement · agent claude · pause before")
        XCTAssertEqual(c.rows.last?.id, "check")
    }

    func testEditorViewBuildsWithDefaultsAndWithNoRunbooks() {
        let v = RunbookEditorView(editor: e, projects: [], refusal: { _ in nil }, ask: {})
        XCTAssertEqual(v.identifier, SettingsAnchor.runbooks.id)
        PROJECTS_CFG.runtime.runbooks = []
        _ = RunbookEditorView(editor: e, projects: [], refusal: { _ in nil }, ask: {})
    }
}
