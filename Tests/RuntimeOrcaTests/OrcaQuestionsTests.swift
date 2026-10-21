import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Replies recorded from Orca 1.4.223 on 2026-10-21, cut to the fields that the adapter reads.
enum OrcaAskFixtures {
    static let coord = "term_104c03f1-cadf-4275-ad2b-570ff118945e"
    static let asker = "term_97a9447f-d7ea-4a20-9fd4-e7e05f033240"
    static let other = "term_c910a6dc-ed2f-4913-83f4-cec2f8ba18cc"

    static let terminals = #"""
        {"ok":true,"result":{"terminals":[
         {"handle":"term_8e5049bf-6ff3-4d95-82df-7af239b270c5","orphaned":true,"title":"oversire-coordinator"},
         {"handle":"term_104c03f1-cadf-4275-ad2b-570ff118945e","orphaned":false,"worktreeId":"b07c::/w","title":"oversire-coordinator"},
         {"handle":"term_97a9447f-d7ea-4a20-9fd4-e7e05f033240","orphaned":false,"title":"◐ OVERSIRE-178"}],"totalCount":3,"truncated":false}}
        """#
    static let noCoordinator = #"{"ok":true,"result":{"terminals":[{"handle":"term_97a9447f-d7ea-4a20-9fd4-e7e05f033240","title":"◐ OVERSIRE-178"}]}}"#
    static let created = #"""
        {"ok":true,"result":{"terminal":{"handle":"term_104c03f1-cadf-4275-ad2b-570ff118945e","worktreeId":"","title":"oversire-coordinator","surface":"visible"}}}
        """#
    static let bound = #"""
        {"ok":true,"result":{"run":{"id":"run_305c4998aa1e","objective":"OverSire questions","coordinator_handle":"term_104c03f1-cadf-4275-ad2b-570ff118945e","consumer_generation":1,"legacy":0}}}
        """#
    static let unbound = #"{"ok":true,"result":{"run":null}}"#
    static let runs = #"""
        {"ok":true,"result":{"runs":[
         {"id":"run_f133144ba28e","objective":"OverSire Enhance remote ask test","created_at":"2026-10-20T20:38:28Z"},
         {"id":"run_1111aaaa2222","objective":"OverSire questions","created_at":"2026-10-19T10:00:00Z"},
         {"id":"run_305c4998aa1e","objective":"OverSire questions","created_at":"2026-10-21T02:29:30Z"},
         {"id":"run_legacy_local","objective":"Legacy orchestration state (inspect only)","created_at":"2026-09-20T23:45:01Z"}],"nextCursor":null}}
        """#
    static let noRuns = #"{"ok":true,"result":{"runs":[],"nextCursor":null}}"#
    static let runCreated = #"{"ok":true,"result":{"run":{"id":"run_9999bbbb0000","objective":"OverSire questions"}}}"#

    static let multi = #"{\"round\":2,\"questions\":[{\"id\":\"q1\",\"type\":\"multi\",\"text\":\"Which tests?\",\"options\":[\"Unit\",\"Live\"]},{\"id\":\"q2\",\"type\":\"free\",\"text\":\"Any note?\"}]}"#

    /// The rows of `orchestration inbox`, newest first. `extra` goes on top.
    static func inbox(_ extra: String...) -> String {
        let rows = extra + [
            #"{"id":"msg_4492d9a3289a","run_id":"run_305c4998aa1e","from_handle":"\#(asker)","to_handle":"run:run_305c4998aa1e","subject":"Question","body":"\#(multi)","type":"question","thread_id":null,"read":1,"created_at":"2026-10-21T02:30:31Z"}"#,
            #"{"id":"msg_b85085f7892a","run_id":"run_305c4998aa1e","from_handle":"\#(asker)","to_handle":"run:run_305c4998aa1e","subject":"alive","body":"","type":"heartbeat","thread_id":null,"read":1,"created_at":"2026-10-21T02:30:31Z"}"#,
            #"{"id":"msg_0b0b0b0b0b0b","run_id":"run_305c4998aa1e","from_handle":"\#(other)","to_handle":"run:run_305c4998aa1e","subject":"Question","body":"May I delete the old cache dir?","type":"question","thread_id":null,"read":1,"created_at":"2026-10-21T02:30:00Z"}"#,
            #"{"id":"msg_cdeeb63b70ec","run_id":"run_305c4998aa1e","from_handle":"\#(coord)","to_handle":"\#(asker)","subject":"Re: Question","body":"Yes, delete it.","type":"status","thread_id":"msg_ada24b90f93a","read":0,"created_at":"2026-10-21T02:29:47Z"}"#,
            #"{"id":"msg_ada24b90f93a","run_id":"run_305c4998aa1e","from_handle":"\#(asker)","to_handle":"run:run_305c4998aa1e","subject":"Question","body":"Plain text: may I delete the old cache dir?","type":"question","thread_id":null,"read":1,"created_at":"2026-10-21T02:29:38Z"}"#,
            #"{"id":"msg_ab9c01cb8cd7","run_id":"run_f133144ba28e","from_handle":"dispatch:ctx_dca5db967184","to_handle":"run:run_f133144ba28e","subject":"Question","body":"{\"round\":3,\"questions\":[{\"id\":\"q8\",\"type\":\"multi\",\"text\":\"Which fixes?\",\"options\":[\"A\",\"B\"]}]}","type":"question","thread_id":"msg_ab9c01cb8cd7","read":1,"created_at":"2026-10-20T20:39:26Z"}"#,
            #"{"id":"msg_e1d1e1d1e1d1","run_id":"run_305c4998aa1e","from_handle":"term_old","to_handle":"run:run_305c4998aa1e","subject":"Question","body":"Old?","type":"question","thread_id":null,"read":1,"created_at":"2026-10-18T02:00:00Z"}"#,
        ]
        return #"{"ok":true,"result":{"messages":["# + rows.joined(separator: ",") + "]}}"
    }

    static func replyRow(_ id: String, to msg: String, body: String) -> String {
        let b = String(decoding: try! JSONSerialization.data(withJSONObject: [body], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast()
        return #"{"id":"\#(id)","run_id":"run_305c4998aa1e","from_handle":"\#(coord)","to_handle":"\#(asker)","subject":"Re: Question","body":\#(b),"type":"status","thread_id":"\#(msg)","read":0,"created_at":"2026-10-21T02:31:00Z"}"#
    }

    static let replied = #"""
        {"ok":true,"result":{"message":{"id":"msg_e5bc6764ce37","run_id":"run_305c4998aa1e","from_handle":"term_104c03f1-cadf-4275-ad2b-570ff118945e","type":"status","thread_id":"msg_4492d9a3289a"},"mutation":{"replayed":false}}}
        """#
}

final class OrcaQuestionsTests: XCTestCase {
    typealias F = OrcaAskFixtures
    var orca: ReplayOrca!
    var rt: OrcaRuntime!
    var asker: SessionRef!
    var other: SessionRef!

    override func setUp() {
        orca = ReplayOrca()
        rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.now = { ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")! }
        rt.changesRetry = .milliseconds(1)
        asker = rt.sessionRef(workspace: "b07c::/w::workspace:e760", handle: F.asker)
        other = rt.sessionRef(workspace: "b07c::/w", handle: F.other)
    }

    func bound() {
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", F.bound)
        orca.on("worktree ps", #"{"ok":true,"result":{"worktrees":[]}}"#)
    }

    func testCoordinatorIsFoundAgainAndKept() async throws {
        bound()
        let c = try await rt.coordinator()
        XCTAssertEqual(c, OrcaCoordinator(terminal: F.coord, run: "run_305c4998aa1e"), "the orphaned one is skipped")
        XCTAssertEqual(c.address, "run:run_305c4998aa1e")
        XCTAssertEqual(orca.args("orchestration run-current").first, ["orchestration", "run-current", "--from", F.coord, "--json", "--environment", "mbp"])
        _ = try await rt.coordinator()
        XCTAssertEqual(orca.calls.count, 2, "one search for each runtime")
        XCTAssertTrue(orca.args("terminal create").isEmpty)
    }

    func testCoordinatorIsMadeWhenGoneAndTakesTheLastRun() async throws {
        orca.on("terminal list", F.noCoordinator)
        orca.on("terminal create", F.created)
        orca.on("orchestration run-current", F.unbound)
        orca.on("orchestration run-list", F.runs)
        orca.on("orchestration run-use", #"{"ok":true,"result":{}}"#)
        let c = try await rt.coordinator()
        XCTAssertEqual(c, OrcaCoordinator(terminal: F.coord, run: "run_305c4998aa1e"))
        XCTAssertEqual(orca.args("terminal create").first, ["terminal", "create", "--title", "oversire-coordinator", "--json", "--environment", "mbp"])
        XCTAssertEqual(orca.args("orchestration run-use").first?.prefix(5), ["orchestration", "run-use", "--id", "run_305c4998aa1e", "--from"])
        XCTAssertTrue(orca.args("orchestration run-create").isEmpty)
    }

    func testCoordinatorMakesARunWhenNoneFits() async throws {
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", F.unbound)
        orca.on("orchestration run-list", F.noRuns)
        orca.on("orchestration run-create", F.runCreated)
        let c = try await rt.coordinator()
        XCTAssertEqual(c.run, "run_9999bbbb0000")
        XCTAssertEqual(orca.args("orchestration run-create").first?.prefix(4), ["orchestration", "run-create", "--objective", "OverSire questions"])
    }

    func testAFailedSearchIsNotKept() async throws {
        orca.on("terminal list", #"{"ok":false,"error":{"code":"runtime_unavailable","message":"no server"}}"#)
        do { _ = try await rt.coordinator(); XCTFail("no error") } catch {}
        bound()
        let c = try await rt.coordinator()
        XCTAssertEqual(c.terminal, F.coord)
    }

    func testOpenQuestions() async throws {
        bound()
        orca.on("orchestration inbox", F.inbox())
        let qs = try await rt.openQuestions(in: [asker, other])
        XCTAssertEqual(qs.map(\.id.rawValue), ["orca:mbp:msg_0b0b0b0b0b0b", "orca:mbp:msg_4492d9a3289a"],
                       "oldest first; the heartbeat, the answered ask, the ask of another Run and the old ask drop")
        let plain = qs[0]
        XCTAssertEqual(plain.session, other)
        XCTAssertEqual(plain.items, [QuestionItem(id: "q1", text: "May I delete the old cache dir?", kind: .free)])
        XCTAssertEqual(plain.via, .askReply)
        XCTAssertTrue(plain.answerable)
        let json = qs[1]
        XCTAssertEqual(json.session, asker, "the session ref of the caller")
        XCTAssertEqual(json.round, 2)
        XCTAssertEqual(json.items.map(\.kind), [.multi, .free])
        XCTAssertEqual(json.items[0].options.map(\.label), ["Unit", "Live"])
        XCTAssertTrue(json.items[0].allowsOther)
        XCTAssertEqual(json.askedAt, ISO8601DateFormatter().date(from: "2026-10-21T02:30:31Z"))
        XCTAssertEqual(orca.args("orchestration inbox").first, ["orchestration", "inbox", "--limit", "200", "--json", "--environment", "mbp"])

        let only = try await rt.openQuestions(in: [asker])
        XCTAssertEqual(only.map(\.id), [json.id], "only the asked sessions")
    }

    func testANewerAskReplacesAnOlderOne() async throws {
        bound()
        let newer = #"{"id":"msg_newer","from_handle":"\#(F.other)","to_handle":"\#(F.coord)","body":"And the logs?","type":"question","thread_id":null,"created_at":"2026-10-21T02:40:00Z"}"#
        orca.on("orchestration inbox", F.inbox(newer))
        let qs = try await rt.openQuestions(in: [other])
        XCTAssertEqual(qs.map(\.id.rawValue), ["orca:mbp:msg_newer"], "the terminal mailbox counts too")
    }

    func testAnswerSendsJSONAndChecksTheThreadFirst() async throws {
        bound()
        orca.on("orchestration inbox", F.inbox())
        orca.on("orchestration reply", F.replied)
        let q = try await rt.openQuestions(in: [asker])[0]
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["Unit"], other: "Smoke"), .init(id: "q2", other: "None")],
                               note: "Go on.")
        let res = try await rt.answer(q, a)
        XCTAssertEqual(res, .sent)
        let body = #"{"answers":{"q1":["Unit","Smoke"],"q2":"None"},"note":"Go on.","round":2}"#
        XCTAssertEqual(orca.args("orchestration reply").first,
                       ["orchestration", "reply", "--id", "msg_4492d9a3289a", "--body", body, "--from", F.coord, "--json", "--environment", "mbp"])

        orca.on("orchestration inbox", F.inbox(F.replyRow("msg_e5bc6764ce37", to: "msg_4492d9a3289a", body: body)))
        let again = try await rt.answer(q, a)
        XCTAssertEqual(again, .alreadyAnswered)
        XCTAssertEqual(orca.args("orchestration reply").count, 1, "Orca makes a new message for each reply")
        let given = try await rt.answerGiven(q)
        XCTAssertEqual(given, a)
        let open = try await rt.openQuestions(in: [asker])
        XCTAssertTrue(open.isEmpty)
    }

    func testPlainAskGetsAPlainReply() async throws {
        bound()
        orca.on("orchestration inbox", F.inbox())
        orca.on("orchestration reply", F.replied)
        let q = try await rt.openQuestions(in: [other])[0]
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "Yes")], note: "Keep a copy.")
        _ = try await rt.answer(q, a)
        XCTAssertEqual(orca.args("orchestration reply").first?[5], "Yes\n\nKeep a copy.")

        orca.on("orchestration inbox", F.inbox(F.replyRow("msg_r", to: "msg_0b0b0b0b0b0b", body: "Yes")))
        let given = try await rt.answerGiven(q)
        XCTAssertEqual(given, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "Yes")]))
    }

    func testAnswerOnAGoneAskSendsNothing() async throws {
        bound()
        orca.on("orchestration inbox", F.inbox())
        let q = try await rt.openQuestions(in: [asker])[0]
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[]}}"#)
        let res = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["Unit"]), .init(id: "q2", other: "x")]))
        XCTAssertEqual(res, .gone)
        let local = OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca)
        let foreign = try await local.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["Unit"]), .init(id: "q2", other: "x")]))
        XCTAssertEqual(foreign, .gone, "an id of another server")
        XCTAssertTrue(orca.args("orchestration reply").isEmpty)
    }

    func testReplyFromAClosedCoordinatorFindsItAgain() async throws {
        bound()
        orca.on("orchestration inbox", F.inbox())
        orca.on("orchestration reply", #"{"ok":false,"error":{"code":"stable_pane_required","message":"no pane"}}"#, F.replied)
        let q = try await rt.openQuestions(in: [other])[0]
        let res = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "Yes")]))
        XCTAssertEqual(res, .sent)
        XCTAssertEqual(orca.args("orchestration reply").count, 2)
        XCTAssertEqual(orca.args("terminal list").count, 2, "the coordinator search runs again")
    }

    func testBodyParse() {
        XCTAssertNil(OrcaAskBody.parse("{\"round\":1}"), "no questions")
        XCTAssertNil(OrcaAskBody.parse("{\"questions\":[{\"id\":\"q1\"}]}"), "no text")
        let p = OrcaAskBody.parse(#"{"questions":[{"text":"Pick","type":"approve","options":[{"label":"A","detail":"first"},"B"],"allowsOther":false},{"text":"Why?","type":"single"}]}"#)
        XCTAssertEqual(p?.round, 1)
        XCTAssertEqual(p?.items, [
            QuestionItem(id: "q1", text: "Pick", kind: .single, options: [.init(label: "A", detail: "first"), .init(label: "B")], allowsOther: false),
            QuestionItem(id: "q2", text: "Why?", kind: .free),
        ], "an unknown type falls back; a choice with no options is free")
    }

    func testConformance() async {
        bound()
        let body = #"{"answers":{"q1":["Unit"],"q2":"Free text"},"round":2}"#
        orca.on("orchestration inbox", F.inbox(), F.inbox(), F.inbox(), F.inbox(F.replyRow("msg_x", to: "msg_4492d9a3289a", body: body)))
        orca.on("orchestration reply", F.replied)
        let rt = self.rt!, asker = self.asker!
        let r = await QuestionChannelConformance.run(sessions: [asker]) { rt }
        XCTAssertTrue(r.passed, r.description)
    }

    func testChangesWakeAndAcknowledge() async throws {
        bound()
        let delivery = #"{"ok":true,"result":{"runId":"run_305c4998aa1e","deliveryId":"delivery_8b9d97015833","messages":[{"id":"msg_4492d9a3289a","type":"question"}],"count":1,"timedOut":false}}"#
        let none = #"{"ok":true,"result":{"runId":"run_305c4998aa1e","deliveryId":null,"messages":[],"count":0,"acknowledged":"delivery_8b9d97015833","timedOut":true}}"#
        orca.on("orchestration check", delivery, none)
        guard let stream = rt.changes else { return XCTFail("no stream") }
        var it = stream.makeAsyncIterator()
        _ = await it.next()
        for _ in 0..<200 where orca.args("orchestration check").count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let calls = orca.args("orchestration check")
        XCTAssertEqual(calls[0].prefix(9), ["orchestration", "check", "--terminal", F.coord, "--wait", "--types", "question", "--timeout-ms", "60000"])
        XCTAssertFalse(calls[0].contains("--ack"))
        XCTAssertEqual(calls[1][9...10], ["--ack", "delivery_8b9d97015833"])
    }
}
