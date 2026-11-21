import XCTest
@testable import OverSireApp

final class SessionPromptTests: XCTestCase {
    private let values = ["text": "Fix it", "key": "K-1", "item": "i1", "intake": "n1", "workspace": "w", "project": "K"]

    func testDefaultsHaveNoPlaneCLI() {
        for t in [SessionPrompt.intakeDefault, SessionPrompt.refineDefault, SessionPrompt.planSteps] {
            XCTAssertFalse(t.contains("plane-cli"), t)
        }
        let p = SessionPrompt.intake(SessionPrompt.intakeDefault, values: values, files: true)
        XCTAssertTrue(p.contains("  oversire intake accept K-1\n"), p)
        XCTAssertTrue(p.contains("oversire item edit K-1 --body-file <file>"), p)
    }

    func testPlaneCLIDefaultMigrates() {
        XCTAssertEqual(SessionPrompt.migrate(intake: SessionPrompt.intakePlaneCLI), SessionPrompt.intakeDefault)
        XCTAssertEqual(SessionPrompt.migrate(refine: SessionPrompt.refinePlaneCLI), SessionPrompt.refineDefault)
        XCTAssertTrue(SessionPrompt.intakePlaneCLI.contains("plane-cli intake update"))
        XCTAssertTrue(SessionPrompt.refinePlaneCLI.contains("plane-cli wi update"))
    }

    func testEditedTemplateStays() {
        XCTAssertEqual(SessionPrompt.migrate(intake: "{text} plane-cli mine"), "{text} plane-cli mine")
        XCTAssertEqual(SessionPrompt.migrate(refine: SessionPrompt.refineDefault + " mine"), SessionPrompt.refineDefault + " mine")
    }

    func testFilesLineDropsWithoutFiles() {
        for t in [SessionPrompt.intakeDefault, SessionPrompt.refineDefault] {
            XCTAssertFalse(SessionPrompt.intake(t, values: values, files: false).contains("vendor run"))
            XCTAssertTrue(SessionPrompt.intake(t, values: values, files: true)
                .contains("Its files: oversire vendor run --project K -- wi attachment download i1 --dir .oversire/K-1"))
        }
    }
}
