import XCTest
import OverSireCore
@testable import RuntimeOrca

/// A full Enhance worker run with two rounds of questions. The shapes come from Orca 1.4.223.
final class OrcaWorkersTests: XCTestCase {
    typealias F = OrcaAskFixtures
    static let worker = "term_5e5e5e5e-0000-4000-8000-000000000001"
    static let started = #"""
        {"ok":true,"result":{"stage":"ready","task":{"id":"task_aa11bb22cc33"},"dispatch":{"id":"ctx_ee44ff556677","taskId":"task_aa11bb22cc33","dispatchId":"ctx_ee44ff556677"},"agentTerminalHandle":"\#(worker)"}}
        """#
    static let running = #"{"ok":true,"result":{"worker":{"dispatchId":"ctx_ee44ff556677","workerState":"running","dispatchStatus":"dispatched"}}}"#
    static let stopped = #"{"ok":true,"result":{"worker":{"dispatchId":"ctx_ee44ff556677","workerState":"stopped","dispatchStatus":"failed"}}}"#

    static func ask(_ id: String, round: Int, at: String) -> String {
        let body = #"{\"round\":\#(round),\"questions\":[{\"id\":\"q\#(round)\",\"type\":\"single\",\"text\":\"Which sync?\",\"options\":[\"Plane\",\"GitHub\"]}]}"#
        return #"{"id":"\#(id)","run_id":"run_305c4998aa1e","from_handle":"\#(worker)","to_handle":"run:run_305c4998aa1e","subject":"Question","body":"\#(body)","type":"question","thread_id":null,"payload":null,"created_at":"\#(at)"}"#
    }

    static let done = ###"""
        {"id":"msg_d0d0d0d0d0d0","run_id":"run_305c4998aa1e","from_handle":"\###(worker)","to_handle":"run:run_305c4998aa1e","subject":"Enhanced","body":"{\"verdict\":\"clear\",\"description\":\"## Goal\\nSync.\"}","type":"worker_done","thread_id":null,"payload":"{\"taskId\":\"task_aa11bb22cc33\",\"dispatchId\":\"ctx_ee44ff556677\",\"outcome\":\"succeeded\"}","created_at":"2026-10-21T02:40:00Z"}
        """###

    var orca: ReplayOrca!
    var rt: OrcaRuntime!

    override func setUp() {
        orca = ReplayOrca()
        rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.now = { ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")! }
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", F.bound)
        orca.on("worktree ps", #"{"ok":true,"result":{"worktrees":[]}}"#)
    }

    func testStartPutsTheWorkerInTheCoordinatorRun() async throws {
        orca.on("orchestration worker-start", Self.started)
        let w = try await rt.startWorker(spec: "Enhance it", title: "Enhance TREBI-9", path: "/w")
        XCTAssertEqual(w, OrcaWorker(dispatch: "ctx_ee44ff556677", task: "task_aa11bb22cc33", terminal: Self.worker))
        XCTAssertEqual(orca.args("orchestration worker-start").first,
                       ["orchestration", "worker-start", "--spec", "Enhance it", "--task-title", "Enhance TREBI-9", "--worktree", "path:/w",
                        "--agent", "claude", "--run", "run_305c4998aa1e", "--from", F.coord, "--json", "--environment", "mbp"])
    }

    func testTwoRoundsThenDone() async throws {
        let w = OrcaWorker(dispatch: "ctx_ee44ff556677", task: "task_aa11bb22cc33", terminal: Self.worker)
        let s = rt.sessionRef(workspace: "intake", handle: Self.worker)
        let r1 = Self.ask("msg_r1r1r1r1r1r1", round: 1, at: "2026-10-21T02:31:00Z")
        let a1 = F.replyRow("msg_a1a1a1a1a1a1", to: "msg_r1r1r1r1r1r1", body: #"{"round":1,"answers":{"q1":"Plane"}}"#)
        let r2 = Self.ask("msg_r2r2r2r2r2r2", round: 2, at: "2026-10-21T02:35:00Z")
        let a2 = F.replyRow("msg_a2a2a2a2a2a2", to: "msg_r2r2r2r2r2r2", body: #"{"round":2,"answers":{"q2":"GitHub"}}"#)
        func inbox(_ rows: String...) -> String { #"{"ok":true,"result":{"messages":["# + rows.joined(separator: ",") + "]}}" }
        orca.on("orchestration worker-show", Self.running)

        orca.on("orchestration inbox", inbox(r1))
        var qs = try await rt.openQuestions(in: [s])
        XCTAssertEqual(qs.map(\.round), [1])
        XCTAssertEqual(qs.first?.session, s, "the worker terminal asks")
        let state1 = try await rt.workerState(w)
        XCTAssertEqual(state1, .running)

        orca.on("orchestration inbox", inbox(r2, a1, r1))
        qs = try await rt.openQuestions(in: [s])
        XCTAssertEqual(qs.map(\.round), [2], "round 1 has its answer")

        orca.on("orchestration inbox", inbox(Self.done, a2, r2, a1, r1))
        qs = try await rt.openQuestions(in: [s])
        XCTAssertTrue(qs.isEmpty)
        let state2 = try await rt.workerState(w)
        XCTAssertEqual(state2, .done(outcome: "succeeded", body: ###"{"verdict":"clear","description":"## Goal\nSync."}"###))
    }

    func testAStoppedWorkerWithNoResultEnds() async throws {
        let w = OrcaWorker(dispatch: "ctx_ee44ff556677", task: "", terminal: nil)
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[]}}"#)
        orca.on("orchestration worker-show", Self.stopped)
        let state = try await rt.workerState(w)
        XCTAssertEqual(state, .ended("stopped"))
    }
}
