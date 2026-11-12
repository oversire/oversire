import AppKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// The read of the history of a runbook step (OVERSIRE-462).
@MainActor
final class RunbookHistoryReadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_400_000)
    private let rt = FakeRuntime()
    private let tab = RunbookTab()
    private var saved: (() -> (any SessionHistoryReading)?)!

    override func setUp() {
        saved = RunbookTab.historyRuntime
        RunbookTab.historyRuntime = { [rt] in rt }
    }

    override func tearDown() { RunbookTab.historyRuntime = saved }

    private let account = AccountID(provider: "plane", id: "ocral")
    private var digest: SessionDigest {
        SessionDigest(harness: .claude, sessionId: "s1", source: .file, turns: 1, last: [.init(prompt: "go", text: "The plan is ready.", tools: 2)])
    }

    private func run(_ id: RunbookRunID) -> (RunbookRun, StepRun) {
        let ref = ItemRef(project: ProjectRef(account: account, id: "p1", key: "OVERSIRE"), id: "i1", key: "OVERSIRE-1", url: URL(string: "https://x.test/")!)
        let step = StepRun(step: "plan", state: .done, session: SessionRef(workspace: WorkspaceRef(account: account, id: "w1"), id: "t1"),
                           daemonSession: "p1", started: t0, ended: t0.addingTimeInterval(600))
        let r = RunbookRun(id: id, item: ref, machine: "mba", runtime: "orca", repo: "/src", runbook: Runbook.planAndShip(ProjectsConfig().runtime),
                           agents: [:], state: .running, current: nil, steps: [step], started: t0, updated: t0)
        return (r, step)
    }

    private func item() -> Item {
        Item(id: "i1", key: "OVERSIRE-1", title: "T", url: "https://x.test/", statusOptionId: nil, fields: [:], assignees: [], labels: [], author: nil,
             updatedBy: nil, updatedAt: t0, activityAt: t0, commentCount: 0, lastComment: nil, mentionsMe: false)
    }

    private func split(_ r: RunbookRun) throws -> NSView {
        let summary = ProjectSummary(ref: r.item.project, identifier: "OVERSIRE", title: "O", url: "", closed: false)
        let snap = ProjectSnapshot(summary: summary, statusOptions: [], items: [item()], fetchedAt: t0)
        let rows = tab.rows(r, item: item(), snap: snap, canReveal: false, live: nil)
        return try XCTUnwrap(rows.first { $0.id == "rb-split" }).make()
    }

    private func texts(_ v: NSView) -> [String] { (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts) }
    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    private func waitFor(_ r: RunbookRun, _ ok: (ReadState) -> Bool) async throws {
        for _ in 0..<200 {
            if let s = tab.part(r)?.state, ok(s) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the state did not come")
    }

    func testAFailedHistoryShowsTryAgainAndReadsAgain() async throws {
        let (r, s) = run("rb_hist_fail")
        RunbookTab.seed(r, pick: "plan")
        RunbookTab.seed(r, round: s, read: Read(error: "timed out", tries: 1))
        let v = try split(r)
        XCTAssertTrue(texts(v).contains("OverSire could not read the session."))
        XCTAssertTrue(texts(v).contains("timed out"))
        let again = try XCTUnwrap(buttons(v).first { $0.title == "Try again" })
        XCTAssertNotNil(again.accessibilityLabel())
        rt.setHistory(digest, paneKey: "p1")
        again.performClick(nil)
        try await waitFor(r) { if case .fresh = $0 { return true } else { return false } }
        let after = texts(try split(r))
        XCTAssertTrue(after.contains("The plan is ready."))
        XCTAssertFalse(after.contains("OverSire could not read the session."))
    }

    func testAClosedTerminalDoesNotRetry() async throws {
        let (r, _) = run("rb_hist_closed")
        RunbookTab.seed(r, pick: "plan")
        _ = try split(r)
        try await waitFor(r) { $0.didFail }
        XCTAssertNil(tab.part(r)?.retry)
        let v = try split(r)
        XCTAssertTrue(texts(v).contains("The terminal of this step is closed. Its history is gone."))
        XCTAssertFalse(buttons(v).contains { $0.title == "Try again" })
        XCTAssertFalse(texts(v).contains("OverSire could not read the session."))
    }

    func testAFailedNewReadKeepsTheOldTurns() async throws {
        let (r, s) = run("rb_hist_stale")
        RunbookTab.seed(r, pick: "plan")
        RunbookTab.seed(r, round: s, read: Read(value: digest))
        _ = try split(r)
        tab.part(r)?.refresh()
        try await waitFor(r) { $0.didFail }
        guard case .stale = tab.part(r)?.state else { return XCTFail("the state is stale") }
        let v = try split(r)
        XCTAssertTrue(texts(v).contains("The plan is ready."))
        XCTAssertTrue(texts(v).contains { $0.hasPrefix("Read failed") })
        XCTAssertTrue(buttons(v).contains { $0.title == "Try again" })
    }
}
