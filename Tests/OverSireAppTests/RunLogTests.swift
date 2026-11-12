import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

/// The jobs of a run, from a fixed list.
private struct JobsSource: RunSource {
    let jobs: [Job]
    func run(_ repo: String, id: String) async -> Run? { Run.sample(Int(id) ?? 1, conclusion: "failure") }
    func jobs(_ repo: String, runId: String) async -> [Job]? { jobs }
}

/// The raw log of a job: nil while `down` is true. It counts its calls.
private final class RawLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _down = true
    private var _calls = 0
    var down: Bool { get { lock.withLock { _down } } set { lock.withLock { _down = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    func read(_ repo: String, _ id: String) async -> String? {
        lock.withLock { _calls += 1 }
        return down ? nil : "compile\nerror: boom\ndone"
    }
}

@MainActor
final class RunLogTests: XCTestCase {
    private let raw = RawLog()
    private var saved: ((String, String) async -> String?)!
    private var savedSource: (any RunSource)!
    private var page: RunPage?

    override func setUp() {
        saved = JobLogs.shared.raw
        savedSource = RunPage.source
        JobLogs.shared.raw = { [raw] in await raw.read($0, $1) }
    }

    override func tearDown() {
        page?.viewWillDisappear()
        page = nil
        JobLogs.shared.raw = saved
        RunPage.source = savedSource
    }

    private func job(_ id: String) -> Job {
        Job(id: id, name: "build", status: "completed", conclusion: "failure", url: "https://github.com/o/a/actions/runs/\(id)/job/\(id)",
            startedAt: "2026-10-20T09:00:00Z", completedAt: "2026-10-20T09:05:00Z", runnerName: nil, steps: nil)
    }

    private func texts(_ v: NSView) -> [String] { (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts) }
    private func terms(_ v: NSView) -> [TermView] { (v as? TermView).map { [$0] } ?? v.subviews.flatMap(terms) }
    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    /// A page that has read its jobs and has started the read of the log.
    private func shown(_ id: String) async throws -> RunPage {
        RunPage.source = JobsSource(jobs: [job(id)])
        let data = TestAppData()
        data.grouped = [("o/a", [Run.sample(Int(id)!, conclusion: "failure")])]
        // The id of the run is the id of the job, because the page keeps the jobs of an ended run by run id.
        let p = RunPage(.run(repo: "o/a", id: id), data: data, router: Router())
        page = p
        p.viewDidAppear()
        for _ in 0..<200 where p.parts.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(p.parts.map(\.id), ["jobs", "log"])
        await p.logRead(job(id)).settled()
        return p
    }

    private func column(_ p: RunPage) -> NSStackView {
        let col = NSStackView()
        p.build(col)
        return col
    }

    func testAFailedLogShowsTheNoteNotAnEmptyLog() async throws {
        let p = try await shown("901")
        XCTAssertEqual(p.parts.last?.state, .failed("GitHub did not give the log."))
        let col = column(p)
        let all = texts(col)
        XCTAssertTrue(all.contains("The log of build did not load."))
        XCTAssertTrue(buttons(col).contains { $0.title == "Try again" })
        XCTAssertFalse(all.contains { $0.contains("last 0 lines") })
        XCTAssertFalse(all.contains("No error lines."))
    }

    func testTryAgainAfterAFailureReadsAgainAndShowsTheLog() async throws {
        let p = try await shown("902")
        let before = raw.calls
        raw.down = false
        p.parts.last?.refresh()
        await p.logRead(job("902")).settled()
        XCTAssertEqual(raw.calls, before + 1)
        guard case .fresh = p.parts.last?.state else { return XCTFail("the state is fresh") }
        let all = texts(column(p))
        XCTAssertTrue(all.contains { $0.hasSuffix("last 3 lines") })
        XCTAssertFalse(all.contains("The log of build did not load."))
    }

    func testAFailedReadKeepsTheOldLines() async throws {
        let p = try await shown("903")
        let r = p.logRead(job("903"))
        r.seed(Read(value: ["old line"]))
        p.parts.last?.refresh()
        await r.settled()
        XCTAssertEqual(r.value, ["old line"])
        guard case .stale = r.state else { return XCTFail("the state is stale") }
        let col = column(p)
        let all = texts(col)
        XCTAssertTrue(terms(col).first?.text.string.contains("old line") == true)
        XCTAssertEqual(terms(col).first?.alphaValue, 0.6, "the stale log is dim")
        XCTAssertTrue(all.contains { $0.hasPrefix("Read failed") })
        XCTAssertTrue(buttons(col).contains { $0.title == "Try again" })
        XCTAssertFalse(all.contains("The log of build did not load."))
    }

    func testAFailedLogDoesNotReadOnEachLoad() async throws {
        let p = try await shown("904")
        let before = raw.calls
        for _ in 0..<5 {
            p.viewDidAppear()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await p.logRead(job("904")).settled()
        XCTAssertEqual(raw.calls, before)
    }
}
