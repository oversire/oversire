import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Screens and a transcript recorded from Claude Code 2.1.305 in Orca 1.4.223 on 2026-10-21.
/// The files with a version in the name come from that version of Claude Code, in Orca 1.4.223 on 2026-10-22.
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
        XCTAssertTrue(q.answerable)
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
        rt.now = { ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")! }
        let asker = rt.sessionRef(workspace: "b07c::/w", handle: OrcaAskFixtures.asker)
        let form = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let body = #"{"answers":{"q1":["Unit"],"q2":"Free text"},"round":2}"#
        orca.on("orchestration inbox", OrcaAskFixtures.inbox(), OrcaAskFixtures.inbox(), OrcaAskFixtures.inbox(),
                OrcaAskFixtures.inbox(OrcaAskFixtures.replyRow("msg_x", to: "msg_4492d9a3289a", body: body)))
        orca.on("orchestration reply", OrcaAskFixtures.replied)
        let r = await QuestionChannelConformance.run(sessions: [asker, form]) { rt }
        XCTAssertTrue(r.passed, r.description)
    }

    // MARK: Answer by keys

    final class Logs: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [LogEntry] = []
        var entries: [LogEntry] { lock.withLock { all } }
        func write(_ e: LogEntry) { lock.withLock { all.append(e) } }
    }

    static let v = "2.1.308"
    static func flow(_ i: Int) -> String { read(String(format: "flow-\(v)-%02d", i)) }
    static let flowTool = "toolu_01Eo8u8RwXETDbPyaRoFUVy8"
    static let down = "\u{1b}[B"

    func item(_ id: String, _ text: String, _ kind: QuestionItem.Kind, _ labels: [String]) -> QuestionItem {
        QuestionItem(id: id, text: text, kind: kind, options: labels.map { .init(label: $0) }, allowsOther: !labels.isEmpty)
    }

    func plan(_ items: [QuestionItem], _ answers: [QuestionAnswer.Item]) -> [FormKeys.Step] {
        let q = SessionQuestion(id: "orca:local:form:t", session: runtime(nil).sessionRef(workspace: "w", handle: "h"), origin: .session,
                                items: items, via: .form, askedAt: Date())
        return FormKeys(q, QuestionAnswer(question: q.id, items: answers)).steps
    }

    func testRecordedScreensParse() throws {
        let single = try XCTUnwrap(ClaudeForm.parse(Self.screen("form-single-\(Self.v)")))
        XCTAssertEqual(single.headers, ["Name"], "a form with one question has a bar with no arrows")
        XCTAssertEqual(single.items.first?.text, "Which name do you want for the new sync setting?")
        XCTAssertEqual(single.items.first?.options.map(\.label), ["autoSync", "syncOnStart", "manual"])
        XCTAssertEqual(single.items.first?.allowsOther, true)
        XCTAssertEqual(single.cursor, "1. autoSync")
        XCTAssertFalse(single.review)
        XCTAssertEqual(ClaudeForm.parse(Self.screen("form-other-typing-\(Self.v)"))?.cursor, "4. liveSync")

        let toggled = try XCTUnwrap(ClaudeForm.parse(Self.screen("flow-\(Self.v)-04")))
        XCTAssertEqual(toggled.headers, ["Store", "Tests"])
        XCTAssertEqual(toggled.items.first?.kind, .multi)
        XCTAssertEqual(toggled.boxes, [1: true, 2: false, 3: false, 4: true])
        XCTAssertEqual(toggled.cursor, "2. [ ] uishots")
        XCTAssertEqual(ClaudeForm.parse(Self.screen("flow-\(Self.v)-08"))?.cursor, "Submit")
        let review = try XCTUnwrap(ClaudeForm.parse(Self.screen("flow-\(Self.v)-09")))
        XCTAssertTrue(review.review)
        XCTAssertEqual(review.cursor, "1. Submit answers")
        XCTAssertEqual(review.items.map(\.text), ["Which store?", "Which tests?"])

        for name in ["flow-\(Self.v)-10", "form-submitted-\(Self.v)", "permission-bash-\(Self.v)", "permission-edit-\(Self.v)",
                     "plan-approval-\(Self.v)", "turn-question-\(Self.v)"] {
            XCTAssertNil(ClaudeForm.parse(Self.screen(name)), name)
        }
    }

    func testKeysForASingleChoice() {
        let steps = plan([item("q1", "Pick", .single, ["A", "B"])], [.init(id: "q1", choices: ["B"])])
        XCTAssertEqual(steps, [FormKeys.Step(question: "Pick", keys: "2")], "one question with one choice has no review page")
    }

    func testKeysForTheOtherText() {
        let steps = plan([item("q1", "Pick", .single, ["A", "B"])], [.init(id: "q1", other: " Neither,\nsee the logs ")])
        XCTAssertEqual(steps.map(\.keys), ["3", "Neither, see the logs", "\r"], "a new line in the text would submit early")
        XCTAssertEqual(steps.map(\.cursor), [nil, "3.", "3."])
    }

    func testKeysForAMultiChoice() {
        let steps = plan([item("q1", "Tests", .multi, ["Unit", "uishots", "Live"])], [.init(id: "q1", choices: ["Live", "Unit"])])
        XCTAssertEqual(steps.map(\.keys), ["3", "1", Self.down, Self.down, Self.down, Self.down, "\r", "1"])
        XCTAssertEqual(steps[0].boxes, [3: false], "a toggle needs the box off")
        XCTAssertEqual(steps[2...5].map(\.cursor), ["1.", "2.", "3.", "4."])
        XCTAssertEqual(steps[6].cursor, "Submit")
        XCTAssertEqual(steps[6].boxes, [1: true, 2: false, 3: true, 4: false])
        XCTAssertEqual(steps[7], FormKeys.Step(question: nil, cursor: "1. Submit answers", keys: "1"), "a multi question has a review page")
    }

    func testKeysForAFreeQuestion() {
        let steps = plan([item("q1", "Why?", .free, [])], [.init(id: "q1", other: "Disk")])
        XCTAssertEqual(steps.map(\.keys), ["Disk", "\r"])
    }

    func testKeysForThreeQuestions() {
        let steps = plan([item("q1", "Store", .single, ["SQLite", "JSON"]), item("q2", "Tests", .multi, ["Unit", "Live"]),
                          item("q3", "Mode", .single, ["Fast", "Safe"])],
                         [.init(id: "q1", choices: ["JSON"]), .init(id: "q2", choices: ["Unit"], other: "perf"), .init(id: "q3", choices: ["Safe"])])
        XCTAssertEqual(steps.map(\.keys), ["2", "1", "3", Self.down, Self.down, "perf", Self.down, "\r", "2", "1"])
        XCTAssertEqual(steps.map(\.question), ["Store", "Tests", "Tests", "Tests", "Tests", "Tests", "Tests", "Tests", "Mode", nil])
        XCTAssertEqual(steps[7].cursor, "Next", "a multi question before the last one")
        XCTAssertEqual(steps[7].boxes, [1: true, 2: false, 3: true])
    }

    func testFormAnswerSendsTheRecordedKeys() async throws {
        files.file = Self.path("ask-flow-open.jsonl")
        orca.on("terminal read", Self.flow(0))
        let logs = Logs()
        let rt = OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca, transcripts: files, log: logs)
        rt.formWait = .zero
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let open = try await rt.openQuestions(in: [s])
        let q = try XCTUnwrap(open.first)
        XCTAssertEqual(q.id.rawValue, "orca:local:form:" + Self.flowTool)
        XCTAssertTrue(q.answerable)

        orca.on("terminal read", list: (0...10).map(Self.flow))
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"accepted":true,"bytesWritten":1}}}"#)
        files.file = Self.path("ask-flow-answered.jsonl")
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["JSON"]), .init(id: "q2", choices: ["Unit"], other: "perf")])
        let r = try await rt.answer(q, a)
        XCTAssertEqual(r, .sent)
        let sends = orca.args("terminal send")
        XCTAssertEqual(sends.map { $0[5] }, ["2", "1", "4", Self.down, Self.down, Self.down, "perf", Self.down, "\r", "1"])
        XCTAssertTrue(sends.allSatisfy { !$0.contains("--enter") })
        XCTAssertEqual(orca.args("terminal read").count, 1 + 11, "one read before each key, and one after the last")
        XCTAssertEqual(logs.entries, [], "the transcript has the same answer")
        let given = try await rt.answerGiven(q)
        XCTAssertEqual(given.map(OrcaRuntime.flat), OrcaRuntime.flat(a))
    }

    func testFormAnsweredInOrcaSendsNoKey() async throws {
        files.file = Self.path("ask-flow-open.jsonl")
        let rt = runtime(nil)
        rt.formWait = .zero
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        orca.on("terminal read", Self.flow(0))
        let open = try await rt.openQuestions(in: [s])
        let q = try XCTUnwrap(open.first)
        orca.on("terminal read", Self.flow(10))
        let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["JSON"]), .init(id: "q2", choices: ["Unit"])]))
        XCTAssertEqual(r, .alreadyAnswered)
        XCTAssertTrue(orca.args("terminal send").isEmpty)
    }

    func testFormThatChangesStopsTheKeys() async throws {
        files.file = Self.path("ask-flow-open.jsonl")
        let rt = runtime(nil)
        rt.formWait = .zero
        let s = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        orca.on("terminal read", Self.flow(0))
        let open = try await rt.openQuestions(in: [s])
        let q = try XCTUnwrap(open.first)
        orca.on("terminal read", Self.flow(0), Self.read("form-single-\(Self.v)"))
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"accepted":true,"bytesWritten":1}}}"#)
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["JSON"]), .init(id: "q2", choices: ["Unit"])])
        do {
            _ = try await rt.answer(q, a)
            XCTFail("no error")
        } catch ProviderError.vendor(let code, _) {
            XCTAssertEqual(code, "form_changed")
        }
        XCTAssertEqual(orca.args("terminal send").map { $0[5] }, ["2"], "no key after the other form showed")
    }
}
