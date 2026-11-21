import XCTest
import OverSireAssistant
import OverSireCore
@testable import OverSireApp

@MainActor
final class CIActionsTests: XCTestCase {
    private var data: TestAppData!
    private var link: ActionLink!
    private var spec: [String: ActionSpec] = [:]

    override func setUp() async throws {
        data = TestAppData()
        link = ActionLink(data)
        let keeper = data.ciJobs
        let actions = CIActions(link: link, jobs: { keeper }, reader: data.ciReader, tracked: { ["o/r"] })
        spec = Dictionary(uniqueKeysWithValues: actions.specs.map { ($0.id, $0) })
    }

    private func run(_ id: String, _ args: [String: JSONValue]) async -> ActionResult {
        await spec[id]!.perform(ActionArgs(.object(args)))
    }

    func testSpecsAreReads() {
        XCTAssertEqual(Set(spec.keys), ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh"])
        XCTAssertTrue(spec.values.allSatisfy { $0.kind == .read })
        XCTAssertEqual(spec["ci.log"]?.capability, .logs)
    }

    func testLogUntrackedRepo() async {
        for id in ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh"] {
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
}
