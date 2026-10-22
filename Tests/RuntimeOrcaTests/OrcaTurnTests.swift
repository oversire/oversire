import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

final class OrcaTurnTests: XCTestCase {
    typealias F = OrcaFormsTests
    static let message = "The file `notes.md` has two lines: `hello` and `world`.\n\nDo you want me to add a third line?"

    static func ps(_ state: String, started: Int64 = 1792670066795, message: String? = OrcaTurnTests.message, tool: String? = nil) -> String {
        var a: [String: Any] = ["paneKey": "tab2:leaf2", "state": state, "agentType": "claude", "stateStartedAt": started]
        a["lastAssistantMessage"] = message
        a["toolName"] = tool
        let d: [String: Any] = ["ok": true, "result": ["worktrees": [["worktreeId": "b07c::/w", "path": "/w", "agents": [a]]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self)
    }

    var orca: ReplayOrca!

    override func setUp() {
        orca = ReplayOrca()
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", OrcaAskFixtures.bound)
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[]}}"#)
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"accepted":true,"prompt":{"stages":["submitted","turn_started"]}}}}"#)
        orca.on("terminal read", F.read("turn-question-2.1.308"))
    }

    func questions(_ rt: OrcaRuntime) async throws -> [SessionQuestion] {
        try await rt.openQuestions(in: [rt.sessionRef(workspace: "b07c::/w", handle: "term_bash")])
    }

    func runtime() -> OrcaRuntime { OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca, transcripts: nil) }

    func testTurnThatEndsWithAQuestion() async throws {
        orca.on("worktree ps", Self.ps("done"))
        let rt = runtime()
        let qs = try await questions(rt)
        let q = try XCTUnwrap(qs.first)
        XCTAssertEqual(q.via, .turn)
        XCTAssertEqual(q.id.rawValue, "orca:local:turn:term_bash:1792670066795")
        XCTAssertEqual(q.items, [QuestionItem(id: "q1", text: "Do you want me to add a third line?", why: Self.message, kind: .free)])
        XCTAssertTrue(q.answerable)
        XCTAssertTrue(orca.args("terminal read").isEmpty, "a turn card needs no screen")
    }

    func testNoTurnCard() async throws {
        for ps in [Self.ps("done", message: "Added the line."), Self.ps("done", message: "Run:\n```\nwhy?\n```"), Self.ps("working")] {
            orca.on("worktree ps", ps)
            let qs = try await questions(runtime())
            XCTAssertTrue(qs.isEmpty, ps)
        }
        orca.on("worktree ps", Self.ps("done"))
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[{"id":"m1","type":"status","from_handle":"term_bash","#
            + #""to_handle":"\#(OrcaAskFixtures.coord)","body":"working","created_at":"2026-10-22T08:00:00Z"}]}}"#)
        let supervised = try await questions(runtime())
        XCTAssertTrue(supervised.isEmpty, "a supervised worker replies through ask/reply")
    }

    func testTurnAnswerIsAPrompt() async throws {
        orca.on("worktree ps", Self.ps("done"))
        let rt = runtime()
        let qs = try await questions(rt)
        let q = try XCTUnwrap(qs.first)
        let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "Yes, add foo")]))
        XCTAssertEqual(r, .sent)
        let sends = orca.args("terminal send")
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?[5], "Yes, add foo")
        XCTAssertTrue(sends.first?.contains("--enter") == true)
    }

    func testTurnAnsweredInTheTerminal() async throws {
        orca.on("worktree ps", Self.ps("done"))
        let rt = runtime()
        let qs = try await questions(rt)
        let q = try XCTUnwrap(qs.first)
        for ps in [Self.ps("working", started: 1792670099000), Self.ps("done", started: 1792670099000, message: "Added. Another?")] {
            orca.on("worktree ps", ps)
            let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "Yes")]))
            XCTAssertEqual(r, .alreadyAnswered)
        }
        XCTAssertTrue(orca.args("terminal send").isEmpty)
    }

    func testUnknownPauseGetsTheFallbackCard() async throws {
        orca.on("worktree ps", Self.ps("waiting", started: 1792670100000, message: nil, tool: "WebFetch"))
        let rt = runtime()
        let qs = try await questions(rt)
        let q = try XCTUnwrap(qs.first)
        XCTAssertEqual(q.via, .waiting)
        XCTAssertEqual(q.id.rawValue, "orca:local:wait:term_bash:1792670100000")
        XCTAssertEqual(q.items.first?.text, "The session waits for you. OverSire cannot read the prompt.")
        XCTAssertFalse(q.answerable)
        do {
            _ = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "x")]))
            XCTFail("no error")
        } catch QuestionError.notAnswerable {}
        XCTAssertTrue(orca.args("terminal send").isEmpty)
    }
}
