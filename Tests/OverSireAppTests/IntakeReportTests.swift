import XCTest
@testable import OverSireApp

final class IntakeReportTests: XCTestCase {
    func testOffVision() throws {
        let lines = ["Reading the code…", #"{"verdict":"off_vision","findings":["It adds a web runtime.","second"],"block":"","labels":[]}"#]
        let r = try XCTUnwrap(IntakeReport.parse(lines))
        XCTAssertTrue(r.offVision)
        XCTAssertEqual(r.word, "Off vision")
        XCTAssertEqual(r.tone.word, Tone.warning.word)
        XCTAssertEqual(r.shown, ["It adds a web runtime."], "off vision shows one reason")
        XCTAssertEqual(IntakeReport.parse([#"{"verdict":"not_reproduced","findings":[]}"#])?.word, "Not Reproduced")
    }

    func testDefaultPromptVision() {
        let t = AgentsConfig.defaultIntakePrompt
        let with = IntakeAgent.prompt(t, key: "K-1", title: "T", url: "u", body: "b", vision: "Small and native.")
        XCTAssertTrue(with.contains("Project vision (the true north of the project):\nSmall and native."))
        XCTAssertTrue(with.contains("off_vision"))
        let without = IntakeAgent.prompt(t, key: "K-1", title: "T", url: "u", body: "b")
        XCTAssertFalse(without.contains("{vision}"))
        XCTAssertFalse(without.contains("Project vision"))
        XCTAssertFalse(without.contains("\n\n\n"))
    }
}
