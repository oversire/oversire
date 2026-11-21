import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class CIJobsKeeperTests: XCTestCase {
    private var dir: URL!
    private var touched: [[String]] = []
    private let reader = FakeCIReader()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ci-jobs-\(UUID().uuidString)")
        touched = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func keeper(quota: CIQuota? = nil, reader: FakeCIReader? = nil, now: Date = CITestQuota.now) -> CIJobsKeeper {
        CIJobsKeeper(reader: reader ?? self.reader, quota: quota ?? CITestQuota.make(), store: dir.appendingPathComponent("ci-jobs.json"),
                     clock: { now }, touch: { [unowned self] in self.touched.append($0) }, saveDelay: 0)
    }

    private func runDoc(_ k: CIJobsKeeper, _ run: Int, attempt: Int? = 1) -> CIJobsDoc? { k.doc(repo: "o/r", run: "\(run)", attempt: attempt) }

    func testFetchesOncePerRunState() async {
        reader.setJobs("o/r", run: "1", [.sample("11")])
        let k = keeper()
        let run = Run.ci(1, status: "in_progress", conclusion: nil)
        k.observe([("o/r", [run])])
        k.observe([("o/r", [run])])
        await settle { runDoc(k, 1) != nil }
        k.observe([("o/r", [run])])
        await Task.yield()
        XCTAssertEqual(reader.count("jobs"), 1)
        XCTAssertEqual(runDoc(k, 1)?.final, false)
        XCTAssertEqual(touched.last, ["o/r"])
    }

    func testChangedRunFetchesAgain() async {
        reader.setJobs("o/r", run: "1", [.sample("11", status: "in_progress", conclusion: nil)])
        let k = keeper()
        k.observe([("o/r", [.ci(1, status: "in_progress", conclusion: nil, updated: "2026-11-21T10:00:00Z")])])
        await settle { runDoc(k, 1) != nil }
        reader.setJobs("o/r", run: "1", [.sample("11")])
        k.observe([("o/r", [.ci(1, updated: "2026-11-21T10:05:00Z")])])
        await settle { runDoc(k, 1)?.final == true }
        XCTAssertEqual(reader.count("jobs"), 2)
        XCTAssertEqual(runDoc(k, 1)?.jobs.first?.conclusion, "success")
    }

    func testFailedRunHasLogTailOfFortyLines() async {
        reader.setJobs("o/r", run: "2", [.sample("21", name: "test", conclusion: "failure"), .sample("22", name: "lint")])
        reader.setFailures("o/r", run: "2", [Failure(job: "test", step: "Run tests", messages: ["boom"])])
        reader.setLog("21", (1...100).map { "2026-11-20T10:00:00.0000000Z line \($0)" }.joined(separator: "\n"))
        let k = keeper()
        k.observe([("o/r", [.ci(2, conclusion: "failure", updated: "2026-11-21T11:00:00Z")])])
        await settle { runDoc(k, 2) != nil }
        let doc = try! XCTUnwrap(runDoc(k, 2))
        XCTAssertTrue(doc.final)
        XCTAssertEqual(doc.failures.count, 1)
        XCTAssertEqual(doc.failures[0].jobId, "21")
        XCTAssertEqual(doc.failures[0].step, "Run tests")
        XCTAssertEqual(doc.failures[0].logTail?.count, 40)
        XCTAssertEqual(doc.failures[0].logTail?.last, "line 100", "time stamps are cut")
    }

    func testFinalDocIsNotFetchedAgainAndSurvivesRestart() async {
        reader.setJobs("o/r", run: "3", [.sample("31")])
        let run = Run.ci(3, updated: "2026-11-21T11:00:00Z")
        let k = keeper()
        k.observe([("o/r", [run])])
        await settle { runDoc(k, 3) != nil }
        k.observe([("o/r", [run])])
        k.flush()
        let again = FakeCIReader()
        let k2 = keeper(reader: again)
        XCTAssertNotNil(runDoc(k2, 3))
        k2.observe([("o/r", [run])])
        await Task.yield()
        XCTAssertEqual(reader.count("jobs"), 1)
        XCTAssertEqual(again.count("jobs"), 0)
        XCTAssertEqual(k2.docs(nil).count, 1)
    }

    func testBadFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("ci-jobs.json"))
        XCTAssertTrue(keeper().docs(nil).isEmpty)
    }

    func testDegradedSkipsActiveRunButNotCompleted() async {
        reader.setJobs("o/r", run: "4", [.sample("41", status: "in_progress", conclusion: nil)])
        reader.setJobs("o/r", run: "5", [.sample("51")])
        let k = keeper(quota: CITestQuota.make(remaining: 100))
        XCTAssertTrue(k.quota.degraded)
        k.observe([("o/r", [.ci(4, status: "in_progress", conclusion: nil, updated: "2026-11-21T11:00:00Z"), .ci(5, updated: "2026-11-21T11:00:00Z")])])
        await settle { runDoc(k, 5) != nil }
        XCTAssertNil(runDoc(k, 4))
        XCTAssertNotNil(runDoc(k, 5))
    }

    func testOldCompletedRunWithNoDocIsSkipped() async {
        reader.setJobs("o/r", run: "6", [.sample("61")])
        let k = keeper()
        k.observe([("o/r", [.ci(6, updated: "2026-11-10T10:00:00Z")])])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reader.count("jobs"), 0)
    }

    func testAttemptsAreSeparateDocs() async {
        reader.setJobs("o/r", run: "7", [.sample("71")])
        let k = keeper()
        k.observe([("o/r", [.ci(7, updated: "2026-11-21T11:00:00Z", attempt: 1)])])
        await settle { runDoc(k, 7) != nil }
        k.observe([("o/r", [.ci(7, updated: "2026-11-21T11:30:00Z", attempt: 2)])])
        await settle { runDoc(k, 7, attempt: 2) != nil }
        XCTAssertEqual(k.docs(nil).map(\.id), ["o/r/7/1", "o/r/7/2"])
        XCTAssertEqual(runDoc(k, 7, attempt: nil)?.attempt, 2, "nil gives the newest attempt")
    }

    func testChangeDuringFlightMakesOneMorePass() async {
        reader.jobsDelay = 50_000_000
        reader.setJobs("o/r", run: "8", [.sample("81", status: "in_progress", conclusion: nil)])
        let k = keeper()
        k.observe([("o/r", [.ci(8, status: "in_progress", conclusion: nil, updated: "2026-11-21T10:00:00Z")])])
        try? await Task.sleep(nanoseconds: 10_000_000)
        k.observe([("o/r", [.ci(8, status: "in_progress", conclusion: nil, updated: "2026-11-21T10:01:00Z")])])
        k.observe([("o/r", [.ci(8, status: "in_progress", conclusion: nil, updated: "2026-11-21T10:02:00Z")])])
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(reader.count("jobs"), 2, "one running fetch and one more pass")
    }

    func testFetchNowForcesAFetch() async {
        reader.setJobs("o/r", run: "9", [.sample("91")])
        let run = Run.ci(9, updated: "2026-11-21T11:00:00Z")
        let k = keeper()
        k.observe([("o/r", [run])])
        await settle { runDoc(k, 9) != nil }
        let doc = await k.fetchNow(repo: "o/r", run: run)
        XCTAssertNotNil(doc)
        XCTAssertEqual(reader.count("jobs"), 2)
    }

    func testPruneDropsOldDocsAndTouchesRepo() async {
        reader.setJobs("o/r", run: "10", [.sample("101")])
        let k = keeper()
        k.observe([("o/r", [.ci(10, updated: "2026-11-21T11:00:00Z")])])
        await settle { runDoc(k, 10) != nil }
        touched = []
        k.prune(now: CITestQuota.now.addingTimeInterval(8 * 24 * 3600))
        XCTAssertTrue(k.docs(nil).isEmpty)
        XCTAssertEqual(touched, [["o/r"]])
    }

    func testPruneKeepsFiftyForEachRepo() async {
        var now = CITestQuota.now
        let k = CIJobsKeeper(reader: reader, quota: CITestQuota.make(), store: dir.appendingPathComponent("ci-jobs.json"),
                             clock: { now }, touch: { _ in }, saveDelay: 0)
        for i in 1...55 {
            reader.setJobs("o/r", run: "\(100 + i)", [.sample("j\(i)")])
            k.observe([("o/r", [.ci(100 + i, updated: "2026-11-21T11:00:00Z")])])
            await settle { k.doc(repo: "o/r", run: "\(100 + i)", attempt: 1) != nil }
            now = now.addingTimeInterval(1)
        }
        k.prune(now: now)
        XCTAssertEqual(k.docs(nil).count, 50)
        XCTAssertNil(k.doc(repo: "o/r", run: "101", attempt: 1), "the oldest are gone")
    }

    func testTailCutsLines() {
        let log = (1...10).map { "2026-11-20T10:00:00.0000000Z l\($0)" }.joined(separator: "\n")
        XCTAssertEqual(CIJobsKeeper.tail(log, lines: 3), ["l8", "l9", "l10"])
    }
}
