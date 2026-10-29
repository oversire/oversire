import OverSireCore
import XCTest

final class RunbookCheckTests: XCTestCase {
    private let agents: Set<String> = ["claude", "claude-max"]

    private func step(_ id: String, agent: String = "claude", prompt: String = "Do {key}. Then run {done}.",
                      pause: Bool? = nil, review: RunbookStep.Review? = nil) -> RunbookStep {
        RunbookStep(id: id, name: id.capitalized, agent: agent, prompt: prompt, pauseBefore: pause, review: review)
    }

    private func texts(_ b: Runbook) -> [String] { b.validate(agents: agents).map(\.text) }

    func testAValidRunbookHasNoProblems() {
        let b = Runbook(id: "x", name: "X", steps: [step("a"), step("r", review: .init(fix: "f", rounds: 2)), step("f", pause: true)])
        XCTAssertEqual(texts(b), [])
    }

    func testNameAndSteps() {
        XCTAssertEqual(texts(Runbook(id: "x", name: " ", steps: [])), ["The runbook has no name.", "The runbook has no steps."])
    }

    func testStepIDs() {
        let b = Runbook(id: "x", name: "X", steps: [step("a"), step("a"), step("Bad_id")])
        let p = b.validate(agents: agents)
        XCTAssertEqual(p.map(\.text), ["A: two steps have the id a.", "Bad_Id: the id must use only a-z, 0-9 and -."])
        XCTAssertEqual(p.map(\.step), ["a", "Bad_id"])
    }

    func testAgentMustExist() {
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("a", agent: "gpt")])), ["A: there is no agent gpt."])
    }

    func testPromptNeedsDoneAndKnownPlaceholders() {
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("a", prompt: "Do {key} in {branch}.")])),
                       ["A: the prompt has no {done}.", "A: {branch} is not a placeholder."])
        let all = Runbook.placeholders.map { "{\($0)}" }.joined(separator: " ")
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("a", prompt: all)])), [])
    }

    func testReviewFixStep() {
        let before = Runbook(id: "x", name: "X", steps: [step("f"), step("r", review: .init(fix: "f"))])
        XCTAssertEqual(texts(before), ["R: the fix step must be a step after the review."])
        let missing = Runbook(id: "x", name: "X", steps: [step("r", review: .init(fix: "nope"))])
        XCTAssertEqual(texts(missing), ["R: the fix step must be a step after the review."])
        let review = Runbook(id: "x", name: "X", steps: [step("r", review: .init(fix: "q")), step("q", review: .init(fix: "f")), step("f")])
        XCTAssertEqual(texts(review), ["R: the fix step cannot be a review."])
        let shared = Runbook(id: "x", name: "X", steps: [step("r", review: .init(fix: "f")), step("q", review: .init(fix: "f")), step("f")])
        XCTAssertEqual(texts(shared), ["Q: F is the fix step of R already."])
    }

    func testRounds() {
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("r", review: .init(fix: "f", rounds: 6)), step("f")])),
                       ["R: the rounds must be 0 to 5."])
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("r", review: .init(fix: "f", rounds: 0)), step("f")])), [])
    }

    func testTheFirstStepHasNoGate() {
        XCTAssertEqual(texts(Runbook(id: "x", name: "X", steps: [step("a", pause: true), step("b")])),
                       ["A: the first step cannot pause before it starts."])
    }

    /// The Go Validate gives the same result for the shared fixtures.
    func testTheContractFixturesAreValid() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contract/fixtures/runbook")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            let b = try JSONDecoder().decode(Runbook.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            XCTAssertEqual(texts(b), [], name)
        }
    }
}
