import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeDaemon

/// The contract fixture Contract/fixtures/<type>/<name>.json.
func contract<T: Decodable>(_: T.Type, _ type: String, _ name: String, file: String = #filePath) throws -> T {
    let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try DaemonClient.decode(try Data(contentsOf: root.appendingPathComponent("Contract/fixtures/\(type)/\(name).json")))
}

final class MachineRuntimeTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_792_400_000)
    let repo = "/Users/ada/Projects/towertail"

    /// Gives wo-1, wo-2 and so on.
    private final class IDs: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String { lock.withLock { n += 1; return "wo-\(n)" } }
    }

    private func local(_ d: FakeDaemon) -> LocalMachineRuntime {
        let at = self.at
        let ids = IDs()
        return LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: d),
                                   now: { at }, newID: ids.next, pause: { _ in })
    }

    private static func remote(_ d: FakeDaemon, token: String? = "t") -> MachineRuntime {
        MachineRuntime(machine: "mbp", client: DaemonClient(base: URL(string: "http://mbp:7690")!, token: token, http: d), pause: { _ in })
    }

    // MARK: Conformance

    func testRuntimeConformance() async {
        let d = FakeDaemon()
        let rt = local(d)
        let r = await RuntimeConformance.run(repo: repo) {
            try await rt.refresh()
            return rt
        }
        XCTAssertTrue(r.passed, r.description)
        XCTAssertEqual(d.runtime.reveals.count, 1)
        XCTAssertEqual(d.runtime.files.map { $0.map(\.name) }, [["conformance.txt"]])
    }

    func testProviderConformance() async {
        let r = await ProviderConformance.run { scenario in
            let rt = Self.remote(FakeDaemon(machine: "mbp", token: "t"), token: scenario == .unauthorized ? "bad" : "t")
            if scenario == .normal { try await rt.refresh() }
            return rt
        }
        XCTAssertTrue(r.passed, r.description)
    }

    func testQuestionChannelConformance() async throws {
        let d = FakeDaemon()
        let q = try contract(DaemonQuestion.self, "daemon-question", "form-hook")
        d.questions = [q]
        let rt = local(d)
        try await rt.refresh()
        let s = SessionRef(workspace: WorkspaceRef(account: rt.account, id: "wt-1"), id: q.terminal!)
        let r = await QuestionChannelConformance.run(sessions: [s]) { rt }
        XCTAssertTrue(r.passed, r.description)
    }

    // MARK: Capabilities

    func testCapabilitiesComeFromTheReachableRuntimes() async throws {
        let d = FakeDaemon()
        let rt = local(d)
        XCTAssertEqual(rt.capabilities, [.questions], "no read of /v1/runtimes yet")
        try await rt.refresh()
        XCTAssertEqual(rt.capabilities, [.questions, .sessionInput, .sessionTail, .sessionHistory, .hostFiles, .reveal, .removeWorkspace, .workers])

        d.runtime.runtimes = try contract(DaemonRuntimesPage.self, "daemon-runtimes-page", "orca-down").runtimes
        try await rt.refresh()
        XCTAssertEqual(rt.capabilities, [.questions])
        do {
            _ = try await rt.launch(LaunchRequest(repo: repo, name: "TOWERTAIL-9", agent: .claude, prompt: "Go"))
            XCTFail("no error")
        } catch ProviderError.transport(let text) {
            XCTAssertEqual(text, "mba has no agent runtime that runs")
        }
    }

    func testOnlyThisMacReveals() async throws {
        let d = FakeDaemon(machine: "mbp", token: "t")
        let rt = Self.remote(d)
        try await rt.refresh()
        XCTAssertFalse(rt is any Revealing)
        XCTAssertFalse(rt.capabilities.contains(.reveal))
        let there = try await rt.environments()
        let here = try await local(FakeDaemon()).environments()
        XCTAssertEqual(there, [RuntimeEnvironment(id: "mbp", name: "mbp", kind: .ssh)])
        XCTAssertEqual(here, [.local])
    }

    // MARK: Workspaces

    func testWorkspacesJoinTheSessions() async throws {
        let d = FakeDaemon()
        d.runtime.workspaces = try contract(DaemonWorkspacesPage.self, "daemon-workspaces-page", "two").workspaces
        var s = try contract(DaemonSession.self, "daemon-session", "orca-working")
        s.workspace = "r-towertail::/Users/ada/orca/workspaces/towertail/TOWERTAIL-2"
        s.id = "tab-3:leaf-1"
        var cli = s
        cli.id = "cli:1"
        cli.runtime = "cli"
        d.sessions = [s, cli]
        let rt = local(d)
        let ws = try await rt.workspaces()
        XCTAssertEqual(ws.map(\.id), ["r-towertail::/Users/ada/orca/workspaces/towertail/TOWERTAIL-2", "r-oversire::/Users/ada/Projects/oversire-workspace"])
        let w = ws[0]
        XCTAssertEqual([w.repo, w.name, w.branch, w.comment], ["towertail", "TOWERTAIL-2", "towertail-2", "https://app.plane.so/ocral/browse/TOWERTAIL-2/"])
        XCTAssertEqual(w.kind, .worktree)
        XCTAssertEqual(ws[1].kind, .folder)
        XCTAssertEqual(w.agents, [AgentSession(phase: .working, since: s.stateSince, card: w.id, paneKey: "tab-3:leaf-1",
                                               agent: AgentName(rawValue: s.harness), repo: "towertail", prompt: s.prompt, message: s.lastMessage)],
                       "a session of another runtime is not an agent of the workspace")
        let terms = try await rt.sessions(WorkspaceRef(account: rt.account, id: w.id))
        XCTAssertEqual(terms, [RuntimeSession(ref: SessionRef(workspace: WorkspaceRef(account: rt.account, id: w.id), id: "term_7c1e"),
                                              title: "claude", paneKey: "tab-3:leaf-1", orphaned: false)])
    }

    func testAllRuntimesFailing() async throws {
        let d = FakeDaemon()
        d.runtime.runtimes = []
        let rt = local(d)
        let none = try await rt.workspaces()
        XCTAssertEqual(none, [])
        // The two calls run at the same time. Answer by URL, not by order.
        let http = RecordedHTTP()
        http.on("GET", "http://127.0.0.1:7690/v1/workspaces", 200, #"{"workspaces":[],"errors":{"orca":"Orca is not running."}}"#)
        http.on("GET", "http://127.0.0.1:7690/v1/sessions", 200, #"{"sessions":[]}"#)
        let down = MachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: http))
        do {
            _ = try await down.workspaces()
            XCTFail("no error")
        } catch ProviderError.transport(let text) {
            XCTAssertEqual(text, "orca: Orca is not running.")
        }
    }

    // MARK: Work orders

    func testALaunchIsADirectOrderThatEnds() async throws {
        let d = FakeDaemon()
        let rt = local(d)
        try await rt.refresh()
        let l = try await rt.launch(LaunchRequest(repo: repo, name: "TOWERTAIL-9", agent: .claude, prompt: "Go", environment: "mbp"))
        XCTAssertEqual(l, Launch(card: "r-1::/Users/ada/Projects/towertail-wt/TOWERTAIL-9", handle: "term_1", paneKey: "tab-1:leaf-1", turnStarted: true))
        let o = try XCTUnwrap(d.runtime.orders.first)
        XCTAssertEqual([o.id, o.runner, o.runtime.rawValue, o.suggestion], ["wo-1", "mba", "orca", ""])
        XCTAssertEqual(o.createdAt, at)
        guard case .start(let r) = o.order else { return XCTFail("\(o.order)") }
        XCTAssertNil(r.environment, "the daemon runs the order on its own machine")
        XCTAssertEqual(d.calls.filter { $0.hasPrefix("GET /v1/orders/") }, ["GET /v1/orders/wo-1", "GET /v1/orders/wo-1"], "acked, then done")

        let s = SessionRef(workspace: WorkspaceRef(account: rt.account, id: l.card), id: l.handle)
        let started = try await rt.send(s, text: "More")
        XCTAssertTrue(started)
        guard case .send(let sent, "More", nil, nil) = d.runtime.orders.last!.order else { return XCTFail() }
        XCTAssertEqual(sent, SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: l.card), id: "term_1"))

        d.runtime.screen("term_1", ["a", "b", "c"])
        let tail = try await rt.tail(s, lines: 2)
        let output = try await rt.output(s, lines: 5)
        XCTAssertEqual(tail, ["b", "c"])
        XCTAssertEqual(output, ["a", "b", "c"])
        guard case .read(_, 5, true) = d.runtime.orders.last!.order else { return XCTFail() }
    }

    func testAFailedOrderThrowsItsError() async throws {
        let d = FakeDaemon()
        let rt = local(d)
        d.runtime.fail(.sessionSend, "The terminal is gone.")
        do {
            try await rt.send(SessionRef(workspace: WorkspaceRef(account: rt.account, id: "wt-1"), id: "term_1"), text: "Hi")
            XCTFail("no error")
        } catch ProviderError.vendor(let code, let message) {
            XCTAssertEqual([code, message], ["failed", "The terminal is gone."])
        }
    }

    func testHistoryReadsTheTerminalOfThePane() async throws {
        let d = FakeDaemon()
        let rt = local(d)
        try await rt.refresh()
        let l = try await rt.launch(LaunchRequest(repo: repo, name: "TOWERTAIL-9", agent: .claude, prompt: "Go"))
        let w = try await rt.workspaces().first { $0.id == l.card }!
        let digest = try await rt.history(of: w.agents[0], in: w, budget: HistoryBudget())
        XCTAssertEqual(digest.last.map(\.text), ["Hello."])
        guard case .history(let s, _) = d.runtime.orders.last!.order else { return XCTFail() }
        XCTAssertEqual(s.id, "term_1")
        do {
            _ = try await rt.history(of: AgentSession(phase: .done, since: at, paneKey: "tab-9:leaf-1"), in: w, budget: HistoryBudget())
            XCTFail("no error")
        } catch ProviderError.notFound {}
    }

    func testRemoveSendsTheRuntimeOfTheWorkspace() async throws {
        let d = FakeDaemon()
        d.runtime.workspaces = try contract(DaemonWorkspacesPage.self, "daemon-workspaces-page", "two").workspaces
        let rt = local(d)
        let w = try await rt.workspaces()[0]
        _ = try await rt.remove(w, force: true, runHooks: false)
        XCTAssertEqual(d.calls.last, "DELETE /v1/workspaces/r-towertail::/Users/ada/orca/workspaces/towertail/TOWERTAIL-2")
        XCTAssertTrue(d.requests.last!.url!.absoluteString.contains("%2FUsers%2Fada"), "the id is one path segment")
        XCTAssertEqual(d.body(of: d.calls.last!) as? [String: AnyHashable], ["runtime": "orca", "force": true, "runHooks": false])
    }

    // MARK: Files

    func testFileNamesAreSafeForTheDaemon() async throws {
        XCTAssertEqual(MachineRuntime.safeNames([".env", "a b.png", "a b.png", "...", "ü.txt"]), ["env", "a-b.png", "a-b-2.png", "file", "-.txt"])
        let d = FakeDaemon()
        let lock = NSLock()
        nonisolated(unsafe) var progress: [[Int]] = []
        let paths = try await local(d).writeFiles([HostFile(name: "shot 1.png", data: Data("abc".utf8))], workspacePath: repo, dir: "/tmp/x") { sent, total in
            lock.withLock { progress.append([sent, total]) }
        }
        XCTAssertEqual(paths, ["/Users/ada/.oversire/files/0000000000000001/shot-1.png"])
        XCTAssertEqual(progress, [[0, 3], [3, 3]])
        XCTAssertEqual(d.runtime.files.first?.first?.data, Data("abc".utf8))
    }

    // MARK: Workers

    func testAWorkerLife() async throws {
        let d = FakeDaemon()
        let rt = local(d)
        let w = try await rt.startWorker(WorkerStart(spec: "Enhance it", title: "Enhance TOWERTAIL-9", path: repo, agent: "claude"))
        XCTAssertEqual([w.id, w.terminal], ["wk-1", "term_w1"])
        let running = try await rt.workerState(w)
        XCTAssertEqual(running.state, .running)
        d.runtime.worker(w.id, WorkerState(state: .done, outcome: "succeeded", body: #"{"verdict":"clear"}"#))
        let done = try await rt.workerState(w)
        XCTAssertEqual(done.body, #"{"verdict":"clear"}"#)
        try await rt.stopWorker(w)
        try await rt.releaseWorker(w)
        XCTAssertEqual(d.runtime.workerCalls, ["start", "stop wk-1", "release wk-1"])
        do {
            _ = try await rt.workerState(w)
            XCTFail("no error")
        } catch ProviderError.notFound {}
    }

    // MARK: Poll

    func testPollGivesOneEventForEachChange() async throws {
        let d = FakeDaemon()
        var s = try contract(DaemonSession.self, "daemon-session", "orca-working")
        s.workspace = "wt-1"
        d.sessions = [s]
        let rt = local(d)
        let first = try await rt.poll(since: nil)
        XCTAssertEqual(first.events, [])
        XCTAssertTrue(first.busy)
        let same = try await rt.poll(since: first.cursor)
        XCTAssertEqual(same.events, [])
        s.state = .waiting
        s.stateSince = s.stateSince.addingTimeInterval(60)
        d.sessions = [s]
        let next = try await rt.poll(since: same.cursor)
        XCTAssertEqual(next.events.map(\.action), ["waiting"])
        XCTAssertEqual(next.events.first?.subject, .session(SessionRef(workspace: WorkspaceRef(account: rt.account, id: "wt-1"), id: s.id)))
        XCTAssertFalse(next.busy)
    }

    // MARK: Questions

    private func ref(_ rt: MachineRuntime, _ handle: String) -> SessionRef {
        SessionRef(workspace: WorkspaceRef(account: rt.account, id: "wt-1"), id: handle)
    }

    func testEachDaemonQuestionFixtureMaps() async throws {
        let names = ["form-hook", "form-screen-page", "permission-bash", "plan-approval", "turn", "waiting", "cli-not-answerable", "ask-reply"]
        let qs = try names.map { try contract(DaemonQuestion.self, "daemon-question", $0) }
        let d = FakeDaemon(machine: "mbp", token: "t")
        d.questions = qs
        let rt = Self.remote(d)
        let got = try await rt.openQuestions(in: Set(qs.compactMap(\.terminal)).map { ref(rt, $0) })
        // The turn question of s-4f8a2c1e and the CLI question have no terminal: the app does not know them.
        XCTAssertEqual(got.count, qs.filter { $0.terminal != nil }.count)
        for q in got {
            let src = qs.first { "daemon:mbp:" + $0.id.rawValue == q.id.rawValue }!
            XCTAssertEqual(q.session, ref(rt, src.terminal!))
            XCTAssertEqual(q.items, src.items)
            XCTAssertEqual(q.via.rawValue, src.via.rawValue)
            XCTAssertEqual(q.answerable, src.answerable)
        }
        XCTAssertTrue(rt.owns(got[0].id))
        XCTAssertFalse(rt.owns("daemon:mba:x"))
    }

    func testANotAnswerableQuestionShowsAsWaiting() throws {
        let q = try contract(DaemonQuestion.self, "daemon-question", "cli-not-answerable")
        let rt = Self.remote(FakeDaemon())
        let s = rt.question(q, session: ref(rt, "term"))
        XCTAssertEqual(s.via, .waiting)
        XCTAssertFalse(s.answerable)
    }

    func testAnswerMapsEachResult() async throws {
        let dq = try contract(DaemonQuestion.self, "daemon-question", "form-hook")
        let d = FakeDaemon(machine: "mbp", token: "t")
        let rt = Self.remote(d)
        let q = rt.question(dq, session: ref(rt, dq.terminal!))
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["D1"]), .init(id: "q2", choices: ["Event log"])], note: "go")
        let id = dq.id.rawValue
        for (name, want) in [("sent", AnswerResult.sent), ("already-answered", .alreadyAnswered)] {
            d.result(id, try contract(DaemonAnswerResult.self, "daemon-answer-result", name))
            let got = try await rt.answer(q, a)
            XCTAssertEqual(got, want, name)
        }
        d.result(id, try contract(DaemonAnswerResult.self, "daemon-answer-result", "form-changed"))
        do {
            _ = try await rt.answer(q, a)
            XCTFail("no error")
        } catch ProviderError.vendor(let code, _) {
            XCTAssertEqual(code, "form_changed")
        }
        XCTAssertEqual(d.answers.last?.answer, RunnerAnswer(id: id, items: a.items, note: "go"))
    }

    func testAnswerGivenReadsTheDaemon() async throws {
        let dq = try contract(DaemonQuestion.self, "daemon-question", "turn")
        let d = FakeDaemon(machine: "mbp", token: "t")
        let rt = Self.remote(d)
        let q = rt.question(dq, session: ref(rt, "term"))
        let none = try await rt.answerGiven(q)
        XCTAssertNil(none)
        d.given(dq.id.rawValue, RunnerAnswer(id: dq.id.rawValue, items: [.init(id: "reply", other: "Only questions.")]))
        let given = try await rt.answerGiven(q)
        XCTAssertEqual(given, QuestionAnswer(question: q.id, items: [.init(id: "reply", other: "Only questions.")]))
    }

    func testPushesWakeEachStream() async throws {
        let p = MachineRuntime.Pushes()
        let rt = MachineRuntime(machine: "mbp", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: FakeDaemon()), pushes: p)
        var first = rt.changes!.makeAsyncIterator()
        var second = rt.changes!.makeAsyncIterator()
        p.push()
        let a: Void? = await first.next()
        let b: Void? = await second.next()
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
    }
}
