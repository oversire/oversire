import OverSireCore
import XCTest
@testable import OverSireApp

final class RunbookTabTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_400_000)
    private var full: Runbook { Runbook.planAndShip(ProjectsConfig().runtime) }

    private func run(_ id: RunbookRunID, _ steps: [StepRun], state: RunbookRun.State = .running, current: String? = "implement") -> RunbookRun {
        let ref = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
                          id: "i349", key: "OVERSIRE-349", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-349/")!)
        return RunbookRun(id: id, item: ref, machine: "mba", runtime: "orca", repo: "/src", runbook: full, agents: [:],
                          state: state, current: current, steps: steps, started: t0, updated: t0)
    }

    private func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func testTheMarkOfEachStep() {
        let r = run("rb_marks", [StepRun(step: "plan", state: .done, started: at(0), ended: at(27)),
                                 StepRun(step: "review-plan", state: .gaps, started: at(28), ended: at(34)),
                                 StepRun(step: "review-plan", round: 2, state: .pass, started: at(47), ended: at(50)),
                                 StepRun(step: "implement", state: .working, started: at(52))])
        let text = { (id: String) in StepMark.of(self.full.step(id)!, in: r, now: self.at(83)).text }
        XCTAssertEqual(text("plan"), "Done · 27m")
        XCTAssertEqual(text("review-plan"), "Pass · 2 rounds")
        XCTAssertEqual(text("plan-fixes"), "On gaps", "a fix step that did not start runs only on gaps")
        XCTAssertEqual(text("implement"), "Working · 31m")
        XCTAssertEqual(text("review"), "Waits")
    }

    func testTheGateLine() {
        let implement = full.step("implement")!
        XCTAssertEqual(StepMark.gate(implement, in: run("rb_g1", [StepRun(step: "implement", state: .waits)], state: .gate)),
                       "Waits for your approval")
        XCTAssertEqual(StepMark.gate(implement, in: run("rb_g2", [StepRun(step: "implement", state: .working, started: at(1))])),
                       "You approved Implement")
        XCTAssertEqual(StepMark.gate(implement, in: run("rb_g3", [], current: "plan")), "Pause before Implement")
    }

    func testTheDetailShowsThePickElseTheCurrentStep() {
        let r = run("rb_pick", [StepRun(step: "review-plan", state: .gaps, started: at(0), ended: at(5)),
                                StepRun(step: "review-plan", round: 2, state: .pass, started: at(6), ended: at(9))])
        let tab = RunbookTab()
        var reloads = 0
        tab.reload = { reloads += 1 }
        XCTAssertEqual(tab.selected(r)?.id, "implement")
        XCTAssertEqual(tab.round(of: "review-plan", in: r)?.round, 2, "the last round with no pick")
        tab.select("review-plan", in: r)
        XCTAssertEqual(tab.selected(r)?.id, "review-plan")
        XCTAssertEqual(reloads, 1)
        RunbookTab.seed(r, pick: "review-plan", round: 1)
        XCTAssertEqual(tab.round(of: "review-plan", in: r)?.round, 1)
        XCTAssertEqual(tab.selected(run("rb_none", [], current: nil))?.id, "plan", "a run with no current step shows the first step")
    }

    func testTheTabToneOfEachState() {
        XCTAssertEqual(RunbookTab.tone(.gate).word, "Waits for your approval")
        XCTAssertNotEqual(RunbookTab.tone(.paused).symbol, RunbookTab.tone(.running).symbol, "a pause has its own shape")
    }
}
