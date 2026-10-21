import XCTest
import OverSireCore
@testable import OverSireAI

final class EnhancePromptTests: XCTestCase {
    func testPromptRenders() {
        let input = EnhancePrompt.input(key: "TREBI-9", title: "Sync fails", url: "https://x/TREBI-9", body: "it breaks", vision: "Small and native.",
                                        ask: AskSkill.promptLine)
        let text = EnhancePrompt.render(EnhancePrompt.template, input)
        XCTAssertTrue(text.hasPrefix("You enhance a new intake item. Do not change files."))
        XCTAssertTrue(text.contains(AskSkill.promptLine))
        XCTAssertTrue(text.contains("Project vision (the true north of the project):\nSmall and native."))
        XCTAssertTrue(text.hasSuffix("Item TREBI-9: Sync fails\nhttps://x/TREBI-9\n\nit breaks"), text)
        XCTAssertTrue(text.contains(EnhancePrompt.originalHeading))

        let bare = EnhancePrompt.render("", EnhancePrompt.input(key: "K-1", title: "T", url: "u", body: ""))
        XCTAssertFalse(bare.contains("Project vision"))
        XCTAssertFalse(bare.contains("{{"))
        XCTAssertTrue(bare.contains("3. If the code cannot tell you a fact, ask the user. Ask at most 4 questions in one round. You can ask more rounds.\n4. "),
                      "no ask line, no empty line")
        XCTAssertTrue(bare.hasSuffix("(no description)"))
    }

    func testEachVerdictParses() throws {
        for v in EnhanceResult.Verdict.allCases {
            let r = try XCTUnwrap(EnhanceResult.parse(#"{"verdict":"\#(v.rawValue)","description":"d"}"#), v.rawValue)
            XCTAssertEqual(r.verdict, v)
        }
        XCTAssertEqual(EnhanceResult.Verdict.offVision.word, "Off vision")
        XCTAssertEqual(EnhanceResult.Verdict.notReproduced.word, "Not reproduced")
    }

    func testFullResult() throws {
        let body = """
            I read the sync code. The result:
            {"verdict":"vague","description":"## Goal\\nSync labels.","priority":"high","labels":["sync","bug"],
             "relations":[{"kind":"blocked_by","key":"TREBI-4","reason":"needs the new API"},{"kind":"duplicate","key":"TREBI-2","reason":"same"},{"kind":"blocks","key":""}],
             "findings":["No steps","Two stores"]}
            """
        let r = try XCTUnwrap(EnhanceResult.parse(body))
        XCTAssertEqual(r.verdict, .vague)
        XCTAssertEqual(r.description, "## Goal\nSync labels.")
        XCTAssertEqual(r.priority, "high")
        XCTAssertEqual(r.labels, ["sync", "bug"])
        XCTAssertEqual(r.relations.map(\.key), ["TREBI-4", "TREBI-2"], "a relation with no key drops")
        XCTAssertEqual(r.relations.first?.relationKind, .blockedBy)
        XCTAssertNil(r.duplicateOf?.relationKind)
        XCTAssertEqual(r.duplicateOf?.key, "TREBI-2")
        XCTAssertEqual(r.findings, ["No steps", "Two stores"])
        XCTAssertNil(EnhanceResult.parse(#"{"verdict":"clear","priority":"none"}"#)?.priority, "none is no priority")
    }

    func testBadJSONGivesNoResult() {
        XCTAssertNil(EnhanceResult.parse("I could not finish. {\"verdict\": \"clear\", \"description\": "))
        XCTAssertNil(EnhanceResult.parse(#"{"verdict":"maybe"}"#), "an unknown verdict is no result")
        XCTAssertNil(EnhanceResult.parse("Plain text only."))
    }

    func testOriginalNoteIsKept() {
        let r = EnhanceResult(verdict: .clear, description: "## Goal\nSync.")
        XCTAssertEqual(r.description(keeping: " fix sync \n"), "## Goal\nSync.\n\n## Original note\n\nfix sync")
        let kept = EnhanceResult(verdict: .clear, description: "## Goal\n\n## Original note\n\nfix sync")
        XCTAssertEqual(kept.description(keeping: "fix sync"), "## Goal\n\n## Original note\n\nfix sync", "the agent kept it")
        XCTAssertEqual(EnhanceResult(verdict: .clear, description: "").description(keeping: ""), "## Original note\n\n(no description)")
    }
}
