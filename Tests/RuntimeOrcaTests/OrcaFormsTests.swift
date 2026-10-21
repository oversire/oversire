import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Screens and a transcript recorded from Claude Code 2.1.305 in Orca 1.4.223 on 2026-10-21.
final class OrcaFormsTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func screen(_ name: String) -> [String] {
        try! String(contentsOf: dir.appendingPathComponent(name + ".txt"), encoding: .utf8).components(separatedBy: "\n")
    }
    static func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
    static func read(_ name: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["terminal": ["tail": screen(name)]]])
        return String(decoding: data, as: UTF8.self)
    }
    static let tool = "toolu_01DmZe1tnBzub1Aa8VinKYuf"
    static let storeText = "Which storage engine should the sync service use for the event log when it runs on a small Mac with little disk space? "
        + "Each option has different disk use, write speed, and setup effort, so choose the one that best fits a constrained machine."
    static let ps = #"""
        {"ok":true,"result":{"worktrees":[{"worktreeId":"b07c::/w","path":"/w","displayName":"W","agents":[
         {"paneKey":"tab1:leaf1","state":"waiting","agentType":"claude","toolName":"AskUserQuestion","toolInput":null,"stateStartedAt":1792550175956},
         {"paneKey":"tab2:leaf2","state":"waiting","agentType":"claude","toolName":"Bash","stateStartedAt":1792550175956}]}]}}
        """#
    static let terminals = #"""
        {"ok":true,"result":{"terminals":[
         {"handle":"term_form","tabId":"tab1","leafId":"leaf1","worktreeId":"b07c::/w","worktreePath":"/w","title":"✳ W"},
         {"handle":"term_bash","tabId":"tab2","leafId":"leaf2","worktreeId":"b07c::/w","worktreePath":"/w","title":"✳ W"},
         {"handle":"term_104c03f1-cadf-4275-ad2b-570ff118945e","tabId":"tab9","leafId":"leaf9","title":"oversire-coordinator"}]}}
        """#

    final class Files: TranscriptReading, @unchecked Sendable {
        var file: String?
        func digest(file: String, agent: AgentName, budget: HistoryBudget) throws -> SessionDigest { throw ProviderError.notFound }
        func locate(agent: AgentName, sessionId: String) -> String? { nil }
        func newest(agent: AgentName, cwd: String) -> String? { cwd == "/w" ? file : nil }
    }

    var orca: ReplayOrca!
    var files: Files!

    override func setUp() {
        orca = ReplayOrca()
        files = Files()
        orca.on("terminal list", Self.terminals)
        orca.on("orchestration run-current", OrcaAskFixtures.bound)
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[]}}"#)
        orca.on("worktree ps", Self.ps)
        orca.on("terminal read", Self.read("form-local"))
    }

    func runtime(_ env: String?) -> OrcaRuntime {
        OrcaRuntime(exe: "/bin/sh", environment: env, commands: orca, transcripts: files)
    }

    func testFormOnScreen() throws {
        let f = try XCTUnwrap(ClaudeForm.parse(Self.screen("form-local")))
        XCTAssertEqual(f.headers, ["Store", "Tests"])
        XCTAssertEqual(f.items, [QuestionItem(id: "q1", text: Self.storeText, kind: .single, options: [
            .init(label: "SQLite", detail: "Single file, low disk overhead, no server process. Good fit for a small Mac."),
            .init(label: "JSON files", detail: "Simplest format to read and debug. Uses the most disk and is slow to append at scale."),
            .init(label: "Postgres", detail: "Full database server. Highest disk and memory cost, so it suits a larger host better."),
        ], allowsOther: true)], "a long question on three rows; Chat about this drops")
        XCTAssertEqual(f.key, "Store|Tests")

        let m = try XCTUnwrap(ClaudeForm.parse(Self.screen("form-multi")))
        XCTAssertEqual(m.items.first?.text, "Which tests do you want?")
        XCTAssertEqual(m.items.first?.kind, .multi)
        XCTAssertEqual(m.items.first?.options.map(\.label), ["Unit", "Live", "Snapshot"])
        XCTAssertEqual(m.key, f.key, "the same form on another page")

        let r = try XCTUnwrap(ClaudeForm.parse(Self.screen("form-review")))
        XCTAssertEqual(r.items.map(\.text), [Self.storeText, "Which tests do you want?"])
        XCTAssertEqual(r.key, f.key)
    }

    func testNoForm() {
        XCTAssertNil(ClaudeForm.parse(Self.screen("no-form-answered")))
        XCTAssertNil(ClaudeForm.parse(Self.screen("false-footer")), "the footer text in normal output")
        XCTAssertNil(ClaudeForm.parse([]))
    }

    func testTranscript() throws {
        let open = try XCTUnwrap(ClaudeAsk.last(in: Data(contentsOf: Self.dir.appendingPathComponent("ask-open.jsonl"))))
        XCTAssertEqual(open.id, Self.tool)
        XCTAssertTrue(open.open)
        XCTAssertEqual(open.items.map(\.header), ["Store", "Tests"])
        XCTAssertEqual(open.items.map(\.kind), [.single, .multi])
        XCTAssertEqual(open.items[0].text, Self.storeText)
        XCTAssertTrue(open.matches(ClaudeForm.parse(Self.screen("form-local"))!))
        XCTAssertFalse(open.matches(ClaudeForm(headers: ["Other"], items: [QuestionItem(id: "q1", text: "Else?", kind: .free)])))

        let data = try Data(contentsOf: Self.dir.appendingPathComponent("ask-answered.jsonl"))
        let done = try XCTUnwrap(ClaudeAsk.last(in: data.dropFirst(40)), "a cut first line is skipped")
        XCTAssertFalse(done.open)
        let q = QuestionID(rawValue: "x")
        XCTAssertEqual(done.answer(q), QuestionAnswer(question: q, items: [.init(id: "q1", choices: ["SQLite"]), .init(id: "q2", choices: ["Unit", "Live"])]))
    }

    func testFreeTextAnswer() {
        let ask = ClaudeAsk(id: "t", items: [QuestionItem(id: "q1", text: "Pick", kind: .single, options: [.init(label: "A")], allowsOther: true)],
                            answers: ["Pick": "Neither, see the logs"], notes: ["Look at run 7."])
        let q = QuestionID(rawValue: "x")
        XCTAssertEqual(ask.answer(q), QuestionAnswer(question: q, items: [.init(id: "q1", other: "Neither, see the logs")], note: "Look at run 7."))
    }

    func testLocalFormUsesTheTranscript() async throws {
        files.file = Self.path("ask-open.jsonl")
        let rt = runtime(nil)
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let bash = rt.sessionRef(workspace: "b07c::/w", handle: "term_bash")
        let qs = try await rt.openQuestions(in: [s, bash])
        XCTAssertEqual(qs.map(\.id.rawValue), ["orca:local:form:" + Self.tool], "a session that waits in another tool has no form")
        let q = qs[0]
        XCTAssertEqual(q.via, .form)
        XCTAssertFalse(q.answerable)
        XCTAssertEqual(q.items.map(\.header), ["Store", "Tests"])
        XCTAssertEqual(q.askedAt, Date(timeIntervalSince1970: 1792550175.956))
        XCTAssertEqual(orca.args("terminal read").count, 1, "only the waiting session")

        let none = try await rt.answerGiven(q)
        XCTAssertNil(none, "still open")
        files.file = Self.path("ask-answered.jsonl")
        let given = try await rt.answerGiven(q)
        XCTAssertEqual(given?.items.map(\.choices), [["SQLite"], ["Unit", "Live"]])
    }

    func testRemoteFormUsesTheScreen() async throws {
        files.file = Self.path("ask-open.jsonl")
        let rt = runtime("mbp")
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let first = try await rt.openQuestions(in: [s])
        orca.on("terminal read", Self.read("form-multi"))
        let second = try await rt.openQuestions(in: [s])
        XCTAssertEqual(first.map(\.id), second.map(\.id), "the id stays on another page")
        XCTAssertTrue(first[0].id.rawValue.hasPrefix("orca:mbp:form:term_form:"))
        XCTAssertEqual(first[0].items.first?.text, Self.storeText)
        let given = try await rt.answerGiven(first[0])
        XCTAssertNil(given, "no transcript on a paired server")

        orca.on("terminal read", Self.read("no-form-answered"))
        let gone = try await rt.openQuestions(in: [s])
        XCTAssertTrue(gone.isEmpty, "the footer left the screen")
    }

    func testATranscriptOfAnotherSessionIsNotUsed() async throws {
        files.file = Self.path("ask-answered.jsonl")
        let rt = runtime(nil)
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let qs = try await rt.openQuestions(in: [s])
        XCTAssertTrue(qs[0].id.rawValue.hasPrefix("orca:local:form:term_form:"), "the call in the file has a result")
    }

    func testConformanceWithAFormAndAnAsk() async {
        let rt = runtime(nil)
        let asker = rt.sessionRef(workspace: "b07c::/w", handle: OrcaAskFixtures.asker)
        let form = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let body = #"{"answers":{"q1":["Unit"],"q2":"Free text"},"round":2}"#
        orca.on("orchestration inbox", OrcaAskFixtures.inbox(), OrcaAskFixtures.inbox(), OrcaAskFixtures.inbox(),
                OrcaAskFixtures.inbox(OrcaAskFixtures.replyRow("msg_x", to: "msg_4492d9a3289a", body: body)))
        orca.on("orchestration reply", OrcaAskFixtures.replied)
        let r = await QuestionChannelConformance.run(sessions: [asker, form]) { rt }
        XCTAssertTrue(r.passed, r.description)
    }

    func testAskAgainWaitsUntilTheFormIsGone() async throws {
        orca.on("terminal read", Self.read("form-local"), Self.read("no-form-answered"))
        orca.on("terminal wait", #"{"ok":true,"result":{"wait":{"satisfied":true}}}"#)
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"prompt":{"stages":["turn_started"]}}}}"#)
        let rt = runtime(nil)
        try await rt.askAgainWithOverSire(rt.sessionRef(workspace: "w", handle: "term_form"), every: .zero)
        XCTAssertEqual(orca.args("terminal read").count, 2)
        XCTAssertEqual(orca.args("terminal send").first?[5], OrcaRuntime.askAgainLine)
        let sends = orca.calls.firstIndex { $0.prefix(2) == ["terminal", "send"] }!
        let reads = orca.calls.lastIndex { $0.prefix(2) == ["terminal", "read"] }!
        XCTAssertGreaterThan(sends, reads, "no key while the form shows")
    }
}
