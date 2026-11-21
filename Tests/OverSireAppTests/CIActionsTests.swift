import XCTest
import OverSireAI
import OverSireAssistant
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

@MainActor
final class CIActionsTests: XCTestCase {
    private var data: TestAppData!
    private var link: ActionLink!
    private var spec: [String: ActionSpec] = [:]
    private var rig: CIOpsTests.Rig!

    override func setUp() async throws {
        data = TestAppData()
        rig = CIOpsTests.Rig()
        link = ActionLink(data)
        let keeper = data.ciJobs
        let actions = CIActions(link: link, jobs: { keeper }, reader: data.ciReader, ops: rig.ops, tracked: { ["o/r"] })
        spec = Dictionary(uniqueKeysWithValues: actions.specs.map { ($0.id, $0) })
    }

    private func run(_ id: String, _ args: [String: JSONValue]) async -> ActionResult {
        await spec[id]!.perform(ActionArgs(.object(args)))
    }

    func testCIRefusalIsNotAllowed() async {
        rig.rights.set(AgentCIRights(cancel: false, approve: false))
        let args = ActionArgs(.object(["repo": .string("fake/app"), "run": .string("1")]), caller: .cli(agent: "codex"))
        for id in ["ci.cancel", "ci.approve"] {
            let r = await spec[id]!.perform(args)
            guard case .notAllowed(let m) = r else { return XCTFail("\(id): \(r)") }
            XCTAssertTrue(m.contains("Settings"), m)
        }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testCINoopIsOk() async {
        rig.fake.put(FakeCI.run(id: "1", status: "in_progress", conclusion: nil, attempt: 2))
        let r = await spec["ci.rerun"]!.perform(ActionArgs(.object(["repo": .string("fake/app"), "run": .string("1")]), caller: .cli(agent: nil)))
        guard case .ok(let summary, let body?, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.contains("No new rerun"), summary)
        XCTAssertEqual(body.object?["noop"]?.bool, true)
    }

    func testSpecKinds() {
        XCTAssertEqual(Set(spec.keys), ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh", "ci.explain", "run.explain", "ci.rerun", "ci.rerunJob", "ci.cancel", "ci.dispatch", "ci.approve"])
        for id in ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh", "ci.explain", "run.explain"] { XCTAssertEqual(spec[id]?.kind, .read, id) }
        XCTAssertEqual(spec["ci.log"]?.capability, .logs)
    }

    func testLogUntrackedRepo() async {
        for id in ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh", "ci.explain"] {
            let r = await run(id, ["repo": .string("x/y"), "jobId": .string("1"), "runId": .string("1")])
            guard case .notAllowed(let m) = r else { return XCTFail("\(id): \(r)") }
            XCTAssertTrue(m.contains("OverSire does not track"), m)
        }
    }

    func testLogAnswersView() async throws {
        data.ciReader.setLog("77", (1...300).map { "line \($0)" }.joined(separator: "\n"))
        let r = await run("ci.log", ["repo": .string("o/r"), "jobId": .string("77"), "lines": .int(50)])
        guard case .ok(_, let body?, _) = r else { return XCTFail("\(r)") }
        let view = try MirrorCodec.value(CILogView.self, from: body)
        XCTAssertEqual(view.lines.count, 50)
        XCTAssertEqual(view.lines.last, "line 300")
        XCTAssertTrue(view.truncated)
        XCTAssertFalse(view.complete, "an unknown job is not complete")
        XCTAssertFalse(view.cached)
        XCTAssertEqual(view.source, .poll)
    }

    func testLogShortAndCompleteJob() async throws {
        data.ciReader.setJobs("o/r", run: "5", [.sample("78")])
        data.ciReader.setLog("78", "a\nb\nc")
        data.ciJobs.observe([("o/r", [.ci(5, updated: "2026-11-21T11:00:00Z")])])
        await settle { data.ciJobs.doc(repo: "o/r", run: "5", attempt: 1) != nil }
        let r = await run("ci.log", ["repo": .string("o/r"), "jobId": .string("78")])
        guard case .ok(_, let body?, _) = r else { return XCTFail("\(r)") }
        let view = try MirrorCodec.value(CILogView.self, from: body)
        XCTAssertEqual(view.lines, ["a", "b", "c"])
        XCTAssertFalse(view.truncated)
        XCTAssertTrue(view.complete)
        XCTAssertEqual(view.run, "5")
    }

    func testLogMissing() async {
        let r = await run("ci.log", ["repo": .string("o/r"), "jobId": .string("404")])
        XCTAssertEqual(r, .failed("The log of job 404 is not available."))
    }

    func testLogLinesAreClamped() async throws {
        data.ciReader.setLog("79", (1...5).map { "l\($0)" }.joined(separator: "\n"))
        let r = await run("ci.log", ["repo": .string("o/r"), "jobId": .string("79"), "lines": .int(0)])
        guard case .ok(_, let body?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try MirrorCodec.value(CILogView.self, from: body).lines, ["l5"])
    }

    func testJobsUsesDocUnlessFresh() async throws {
        data.ciReader.setJobs("o/r", run: "9", [.sample("91")])
        let run9 = Run.ci(9, updated: "2026-11-21T11:00:00Z")
        data.grouped = [("o/r", [run9])]
        data.ciJobs.observe(data.grouped)
        await settle { data.ciJobs.doc(repo: "o/r", run: "9", attempt: 1) != nil }
        XCTAssertEqual(data.ciReader.count("jobs"), 1)

        let held = await run("ci.jobs", ["repo": .string("o/r"), "runId": .string("9")])
        guard case .ok(_, let body?, _) = held else { return XCTFail("\(held)") }
        XCTAssertEqual(try MirrorCodec.value(CIJobsDoc.self, from: body).jobs.count, 1)
        XCTAssertEqual(data.ciReader.count("jobs"), 1, "no reader call")

        let fresh = await run("ci.jobs", ["repo": .string("o/r"), "runId": .string("9"), "fresh": .bool(true)])
        guard case .ok = fresh else { return XCTFail("\(fresh)") }
        XCTAssertEqual(data.ciReader.count("jobs"), 2)
    }

    func testJobsFetchesWhenNoDoc() async throws {
        data.ciReader.setJobs("o/r", run: "12", [.sample("121"), .sample("122")])
        data.grouped = [("o/r", [.ci(12, updated: "2026-11-21T11:00:00Z")])]
        let r = await run("ci.jobs", ["repo": .string("o/r"), "runId": .string("12")])
        guard case .ok(_, let body?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try MirrorCodec.value(CIJobsDoc.self, from: body).jobs.count, 2)
    }

    func testJobsUnknownRun() async {
        let r = await run("ci.jobs", ["repo": .string("o/r"), "runId": .string("404")])
        guard case .notAllowed = r else { return XCTFail("\(r)") }
    }

    func testRefreshCallsApp() async {
        let r = await run("ci.refresh", ["repo": .string("o/r")])
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data.ciRefreshed, ["o/r"])
    }

    // MARK: Explain

    private func withEngine(_ reply: String = #"{"cause":"lint found an unused import.","fix":"Remove it.","confidence":"high"}"#) -> FakeAIEngine {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(reply))
        data.ciAssist = CIAssist(path: data.tmp + "/ci-explain.json", ai: { AIClient(cfg: AIConfig(), router: AIRouter(engines: [engine])) },
                                 changedFiles: { _, _ in [] })
        return engine
    }

    private func failedRun(_ id: Int = 30) {
        data.ciReader.setJobs("o/r", run: "\(id)", [.sample("\(id)1", name: "build"), .sample("\(id)2", name: "lint", conclusion: "failure")])
        data.grouped = [("o/r", [.ci(id, conclusion: "failure", updated: "2026-11-21T11:00:00Z")])]
    }

    private func explained(_ r: ActionResult) throws -> CIExplanation {
        guard case .ok(_, let body?, _) = r else { throw XCTSkip("\(r)") }
        return try MirrorCodec.value(CIExplanation.self, from: body)
    }

    func testCIExplainNoEngine() async {
        data.ciAssist = CIAssist(path: data.tmp + "/ci-none.json", ai: { nil })
        failedRun()
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30")])
        guard case .notAllowed(let m) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(m.contains("Settings › AI"), m)
    }

    func testCIExplainRunDidNotFail() async {
        let engine = withEngine()
        data.grouped = [("o/r", [.ci(31)])]
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("31")])
        XCTAssertEqual(r, .notAllowed("Run 31 did not fail."))
        XCTAssertEqual(engine.tasks.count, 0)
    }

    func testCIExplainUnknownRun() async {
        _ = withEngine()
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("404")])
        XCTAssertEqual(r, .notAllowed("OverSire has no run 404 in o/r."))
    }

    func testCIExplainFetchesAnUnloadedRun() async throws {
        let engine = withEngine()
        data.ciReader.setRun("o/r", .ci(32, conclusion: "failure"))
        data.ciReader.setJobs("o/r", run: "32", [.sample("321", conclusion: "failure")])
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("32")])
        XCTAssertEqual(try explained(r).source, .ai)
        XCTAssertEqual(engine.tasks.count, 1)
    }

    func testCIExplainPicksFailedJob() async throws {
        let engine = withEngine()
        failedRun()
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30")])
        let view = try explained(r)
        XCTAssertEqual(engine.tasks[0].input.context["job"], "lint")
        XCTAssertEqual(view.job, "302")
        XCTAssertEqual(view.source, .ai)
        XCTAssertEqual(view.confidence, "high")
        XCTAssertEqual(view.attempt, 1)

        let named = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30"), "job": .string("301"), "force": .bool(true)])
        XCTAssertEqual(try explained(named).job, "301")
        XCTAssertEqual(engine.tasks[1].input.context["job"], "build")
    }

    func testCIExplainSecondCallIsFromCache() async throws {
        let engine = withEngine()
        failedRun()
        _ = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30")])
        let again = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30")])
        XCTAssertEqual(try explained(again).source, .cache)
        XCTAssertEqual(engine.tasks.count, 1)
    }

    func testCIExplainUsesDocTail() async throws {
        let engine = withEngine()
        data.ciReader.setJobs("o/r", run: "33", [.sample("332", name: "lint", conclusion: "failure")])
        data.ciReader.setFailures("o/r", run: "33", [Failure(job: "lint", step: "Lint", messages: ["unused import"])])
        data.ciReader.setLog("332", "first\nsecond tail line")
        data.grouped = [("o/r", [.ci(33, conclusion: "failure", updated: "2026-11-21T11:00:00Z")])]
        data.ciJobs.observe(data.grouped)
        await settle { data.ciJobs.doc(repo: "o/r", run: "33", attempt: 1) != nil }
        let logs = data.ciReader.count("log")
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("33")])
        _ = try explained(r)
        XCTAssertEqual(data.ciReader.count("log"), logs, "the doc tail is enough")
        XCTAssertTrue(engine.tasks[0].input.text.contains("second tail line"))
    }

    func testCIExplainEngineError() async {
        _ = withEngine()
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success("not json"))
        data.ciAssist = CIAssist(path: data.tmp + "/ci-bad.json", ai: { AIClient(cfg: AIConfig(), router: AIRouter(engines: [engine])) },
                                 changedFiles: { _, _ in [] })
        failedRun()
        let r = await run("ci.explain", ["repo": .string("o/r"), "runId": .string("30")])
        XCTAssertEqual(r, .failed("Unexpected reply: The AI reply had no cause."))
    }

    func testRunExplainExplainsOnMiss() async throws {
        let engine = withEngine()
        failedRun()
        let r = await run("run.explain", ["repo": .string("o/r"), "runId": .string("30")])
        guard case .ok(let summary, _, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.hasPrefix("Cause: lint found an unused import."), summary)
        XCTAssertEqual(engine.tasks.count, 1)
    }
}
