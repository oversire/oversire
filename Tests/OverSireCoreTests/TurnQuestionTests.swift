import XCTest
import OverSireCore

final class TurnQuestionTests: XCTestCase {
    func q(_ m: String?) -> String? { AgentSession.question(in: m) }

    func testLastParagraphOfAQuestion() {
        XCTAssertEqual(q("notes.md has two lines. Do you want me to add a third line?"), "notes.md has two lines. Do you want me to add a third line?")
        XCTAssertEqual(q("I fixed the test.\n\nShould I push the branch?\n"), "Should I push the branch?")
        XCTAssertEqual(q("Done.\n\n**Do you want the PR now?**"), "**Do you want the PR now?**")
        XCTAssertEqual(q("Two ways:\n\n```swift\nlet a = 1\n```\n\nWhich one do you want?"), "Which one do you want?")
    }

    func testNoQuestion() {
        XCTAssertNil(q(nil))
        XCTAssertNil(q("All tests pass."))
        XCTAssertNil(q("Is it fast? Yes. The run takes 2 s."), "the last sentence is a statement")
        XCTAssertNil(q("The rule:\n\n```\nwhy?\n```"), "a ? in a code block")
        XCTAssertNil(q("Run this:\n```\nls ?\n```\nThen it works."))
        XCTAssertNil(q("Should I go on?\n\n```sh\nmake\n```"), "the reply ends with code")
    }

    func testNeedsInput() {
        XCTAssertTrue(AgentSession(phase: .waiting, since: Date()).needsInput)
        XCTAssertTrue(AgentSession(phase: .done, since: Date(), message: "Push it?").needsInput)
        XCTAssertFalse(AgentSession(phase: .done, since: Date(), message: "Pushed.").needsInput)
        XCTAssertFalse(AgentSession(phase: .working, since: Date(), message: "Push it?").needsInput)
    }
}
