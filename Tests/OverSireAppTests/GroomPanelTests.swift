import AppKit
import OverSireAI
import OverSireCore
import OverSireTestKit
import RuntimeDaemon
import XCTest
@testable import OverSireApp

/// The Groom panel and the "Groom…" button of the Intake page (OVERSIRE-340).
extension GroomAgentTests {
    private func all<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all($0, t) } }
    private func texts(_ v: NSView) -> [String] { all(v, NSTextField.self).map(\.stringValue) }
    private func button(_ v: NSView, _ title: String) -> NSButton? { all(v, NSButton.self).first { $0.title == title } }

    private func review(_ r: Rig) -> GroomAgent.Review {
        typealias P = GroomResult.Proposal
        let result = GroomResult(proposals: [
            P(kind: .merge, keys: ["FAKE-1", "FAKE-2"], keep: "FAKE-1", reason: "Same cause.", confidence: .sure, description: "## New\nOne."),
            P(kind: .done, keys: ["FAKE-3"], reason: "Shipped.", evidence: ["a41f9c2"], confidence: .maybe),
            P(kind: .obsolete, keys: ["FAKE-6"], reason: "Not valid.", confidence: .sure),
            P(kind: .vague, keys: ["FAKE-7"], reason: "Only a title.", confidence: .sure),
        ], skipped: [], findings: [])
        return GroomAgent.Review(result: result, keys: (1...7).map { "FAKE-\($0)" }, intake: [:], open: 7, scope: .all, skipped: ["FAKE-4"],
                                 rounds: 1, worked: 300, at: Date())
    }

    @MainActor
    private func panel(_ r: Rig, _ s: GroomAgent.State) -> GroomPanel {
        r.agent.sample = { $0 == r.pk ? s : nil }
        return GroomPanel(s, projectKey: r.pk, identifier: "FAKE", agent: r.agent, enhance: r.enhance, questions: r.hub,
                          title: { "Title of \($0)" }, retry: {}, undo: {})
    }

    @MainActor
    func testPanelBuildsEachState() async throws {
        let r = try await make()
        let rev = review(r)
        let run = GroomAgent.Run(key: StartKey.groom("FAKE"), project: r.fake.project, keys: rev.keys, open: 7, scope: .all, skipped: [], since: Date())
        let states: [GroomAgent.State] = [.starting("Reading 7 items…"), .grooming(run), .asking(run, n: 1), .ready(rev, run),
                                          .applying(rev, done: 1, of: 3), .applied(rev, GroomOutcome(written: [rev.changes[0].id])),
                                          .failed("No result.", kept: "text")]
        for s in states {
            let p = panel(r, s)
            XCTAssertEqual(p.accessibilityLabel(), "Groom FAKE")
            XCTAssertTrue(texts(p).contains { $0.hasPrefix("Groom FAKE") }, "\(s)")
        }
    }

    @MainActor
    func testReviewChecksTheSureLinesAndCountsApply() async throws {
        let r = try await make()
        let rev = review(r)
        r.agent.preselect(r.pk, rev)
        var p = panel(r, .ready(rev, nil))
        XCTAssertNotNil(button(p, "Apply 2 changes"), "merge and obsolete are sure, done is maybe")
        let lines = all(p, GroomLine.self)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.filter { $0.accessibilityRole() == .checkBox }.count, 3, "a vague line is not a change")
        XCTAssertTrue(lines.allSatisfy { ($0.accessibilityLabel() ?? "").contains(".") })
        XCTAssertTrue(lines[0].accessibilityLabel()?.hasPrefix("Merge") == true)

        lines[1].onClick?()
        XCTAssertTrue(r.agent.isChecked(r.pk, rev.changes[1]))
        p = panel(r, .ready(rev, nil))
        XCTAssertNotNil(button(p, "Apply 3 changes"))
        XCTAssertNil(all(p, GroomLine.self)[3].onClick, "a vague line has no toggle")
    }

    @MainActor
    func testReviewWithNoSelectionCannotApply() async throws {
        let r = try await make()
        let rev = review(r)
        let p = panel(r, .ready(rev, nil))
        let apply = try XCTUnwrap(button(p, "Apply 0 changes"))
        XCTAssertFalse(apply.isEnabled)
        XCTAssertNil(button(p, "Ask again"), "no session")
    }

    @MainActor
    func testAppliedShowsTryAgainForAFailedLine() async throws {
        let r = try await make()
        let rev = review(r)
        let ids = rev.changes.map(\.id)
        let p = panel(r, .applied(rev, GroomOutcome(written: [ids[0]], failed: [ids[1]: "Plane said 403"], vague: ["FAKE-7"])))
        XCTAssertNotNil(button(p, "Try again"))
        XCTAssertTrue(texts(p).contains("Groom wrote 1 of 2 changes."))
        XCTAssertTrue(texts(p).contains { $0.contains("Plane said 403") })
        XCTAssertNil(button(p, "Undo last Groom"), "no journal")
        r.agent.undoable.insert(r.pk)
        XCTAssertNotNil(button(panel(r, .applied(rev, GroomOutcome(written: [ids[0]]))), "Undo last Groom"))
    }

    @MainActor
    func testIntakeHeaderHasGroomButtonAndHint() async throws {
        let r = try await make()
        let d = TestAppData()
        d.projectStore.seed(r.snap)
        d.groomAgent.host = { r.host }
        let page = IntakeListPage(.intake("FAKE"), data: d, router: Router())
        let rows = try XCTUnwrap(page.sections()).flatMap(\.rows)
        let header = try XCTUnwrap(rows.first { $0.id == "header" }).make()
        let groom = try XCTUnwrap(button(header, "Groom…"))
        XCTAssertEqual(groom.accessibilityLabel(), "Groom FAKE")
        XCTAssertTrue(rows.contains { $0.id == "groom.hint" })

        d.groomAgent.sample = { _ in .starting("Reading…") }
        let busy = try XCTUnwrap(page.sections()).flatMap(\.rows)
        XCTAssertFalse(busy.contains { $0.id == "groom.hint" })
        XCTAssertTrue(busy.contains { $0.id == "groom." + r.pk })
        XCTAssertNil(button(try XCTUnwrap(busy.first { $0.id == "header" }).make(), "Groom…"), "one run for each project")
    }
}
