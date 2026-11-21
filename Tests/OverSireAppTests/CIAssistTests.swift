import OverSireAI
import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class CIAssistTests: XCTestCase {
    private let reply = #"{"cause":"StoreTests.testPut expects 3 rows, but the store keeps 2.","fix":"Update the count.","confidence":"high"}"#

    private func run(attempt: Int = 1) -> Run {
        Run(id: "99", name: "CI", displayTitle: "Fix the store", status: "completed", conclusion: "failure", headBranch: "main", headSha: "abc123",
            event: "push", url: "https://github.com/o/r/actions/runs/99", updatedAt: "", createdAt: "", startedAt: nil,
            number: 4, workflowName: "CI", actorLogin: nil, attempt: attempt)
    }

    private let job = Job(id: "5", name: "build", status: "completed", conclusion: "failure", url: nil, startedAt: nil, completedAt: nil,
                          runnerName: nil, steps: nil)

    private func explain(_ cia: CIAssist, _ r: Run, log: [String]) {
        let done = expectation(forNotification: CIAssist.changed, object: cia) { _ in cia.explanation(r) != nil }
        cia.explain(repo: "o/r", run: r, job: job, log: log)
        wait(for: [done], timeout: 5)
    }

    func testExplainSendsTheLogTailAndCachesTheCause() throws {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(reply))
        let path = NSTemporaryDirectory() + "ci-assist-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cia = CIAssist(path: path, ai: { AIClient(cfg: AIConfig(), router: AIRouter(engines: [engine])) },
                           changedFiles: { _, _ in ["Sources/Store.swift"] })
        let log = CILog.clean(try String(contentsOf: fixtureDir("ci").appendingPathComponent("job-log.txt"), encoding: .utf8))

        explain(cia, run(), log: log)
        XCTAssertEqual(engine.tasks.count, 1)
        let input = engine.tasks[0].input
        XCTAssertTrue(input.text.hasSuffix("##[error]Process completed with exit code 1."), "the prompt ends with the log tail")
        XCTAssertTrue(input.text.contains("[110/140] Compiling"))
        XCTAssertFalse(input.text.contains("[20/140] Compiling"), "only the last lines")
        XCTAssertTrue(input.text.hasPrefix("/home/runner/work/app/Tests/StoreTests.swift:42: error:"), "the error lines come first")
        XCTAssertEqual(input.context["files"], "Sources/Store.swift")
        XCTAssertEqual(cia.explanation(run())?.confidence, "high")

        cia.explain(repo: "o/r", run: run(), job: job, log: log)
        XCTAssertTrue(cia.busy.isEmpty)
        XCTAssertEqual(engine.tasks.count, 1, "a cached cause does not call the engine again")
        XCTAssertEqual(CIAssist(path: path, ai: { nil }).explanation(run())?.cause.hasPrefix("StoreTests.testPut"), true, "the cache is on disk")

        explain(cia, run(attempt: 2), log: log)
        XCTAssertEqual(engine.tasks.count, 2, "a new attempt has its own cause")
    }

    func testExplainNeedsAnEngine() {
        let cia = CIAssist(path: NSTemporaryDirectory() + "ci-assist-\(UUID().uuidString).json", ai: { nil })
        XCTAssertFalse(cia.hasEngine)
        XCTAssertFalse(cia.canExplain)
        cia.explain(repo: "o/r", run: run(), job: job, log: ["x"])
        XCTAssertTrue(cia.busy.isEmpty)
    }

    private func assist(_ engine: FakeAIEngine) -> CIAssist {
        CIAssist(path: NSTemporaryDirectory() + "ci-assist-\(UUID().uuidString).json", ai: { AIClient(cfg: AIConfig(), router: AIRouter(engines: [engine])) },
                 changedFiles: { _, _ in [] })
    }

    @MainActor
    func testExplainNowUsesCache() async throws {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(reply))
        let cia = assist(engine)
        _ = await cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        XCTAssertEqual(engine.tasks.count, 1)
        let again = await cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        XCTAssertEqual(try again.get().confidence, "high")
        XCTAssertEqual(engine.tasks.count, 1, "a saved cause needs no engine call")
    }

    @MainActor
    func testExplainNowRunsOnce() async throws {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(reply))
        let cia = assist(engine)
        async let a = cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        async let b = cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(try ra.get(), try rb.get())
        XCTAssertEqual(engine.tasks.count, 1)
        XCTAssertTrue(cia.busy.isEmpty)
    }

    @MainActor
    func testExplainNowForce() async throws {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(reply))
        let cia = assist(engine)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ci-force-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = AIOutputBook(writes: StoreWrites(store: LocalStore(dir: dir)))
        cia.outputs = book
        _ = await cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        engine.on(.failureReason, .success(#"{"cause":"A new cause.","fix":"Fix it.","confidence":"medium"}"#))
        let r = await cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: true)
        XCTAssertEqual(try r.get().cause, "A new cause.")
        XCTAssertEqual(engine.tasks.count, 2)
        XCTAssertEqual(cia.explanation(run())?.cause, "A new cause.")
        let shared = book.all(.ciExplanation, as: RunExplanation.self)
        XCTAssertEqual(shared.map(\.value.cause), ["A new cause."])
    }

    @MainActor
    func testExplainNowNoCause() async {
        let engine = FakeAIEngine()
        engine.on(.failureReason, .success(#"{"fix":"x"}"#))
        let cia = assist(engine)
        let r = await cia.explainNow(repo: "o/r", run: run(), job: job, log: ["x"], force: false)
        XCTAssertEqual(r, .failure(.badReply("The AI reply had no cause.")))
        XCTAssertNil(cia.explanation(run()))
        XCTAssertTrue(cia.busy.isEmpty)
    }
}
