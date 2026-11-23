import OverSireAssistant
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// Submit and merge from the review of the parent (OVERSIRE-592).
final class ReviewFoldMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func detail(_ key: String, repo: String, state: ReviewState = .ready) -> ReviewDetail {
        let s = ReviewSummary(key: key, kind: .code, machine: "mba", state: state, root: "/w", group: ".wt/\(key.lowercased())",
                              repos: [ReviewRepo(name: repo, branch: key.lowercased(), base: "main", ahead: 1)], readyAt: t0, updatedAt: t0)
        return ReviewDetail(summary: s, files: [ReviewFile(repo: repo, path: "\(key).go", status: .added, added: 1, removed: 0)])
    }

    /// X-1 with the sub-items X-2 and X-3, in a folded desk.
    private func desk(x3: ReviewState = .ready, tracker: FakeTracking? = nil) async -> (ReviewDesk, FakeReviewSource) {
        let src = FakeReviewSource(machine: "mba")
        src.seed([detail("X-1", repo: "app"), detail("X-2", repo: "app"), detail("X-3", repo: "cli", state: x3)])
        src.parents = ["X-2": "X-1", "X-3": "X-1"]
        let d = ReviewDesk(summary: src.detail("X-1", kind: .code)!.summary, source: src, tracker: tracker, bus: ChangeBus(schedule: { _, _ in }))
        d.reviewFold = ReviewFold(on: true)
        await d.load()
        return (d, src)
    }

    func testASubmitSendsOneRoundToEachPartWithPendingComments() async throws {
        let (d, src) = await desk()
        XCTAssertTrue(d.folded)
        _ = await d.add(.code(repo: "app", path: "X-2.go", line: 1, side: .new), text: "one", item: "X-2")
        _ = await d.add(.code(repo: "cli", path: "X-3.go", line: 1, side: .new), text: "two", item: "X-3")
        XCTAssertEqual(d.submitKeys(.requestChanges), ["X-2", "X-3"])
        XCTAssertEqual(d.submitKeys(.approve), ["X-2", "X-3", "X-1"], "an approve goes to each ready part")
        let rounds = try await d.submit(.requestChanges, summary: nil, post: false)
        XCTAssertEqual(rounds.compactMap(\.item), ["X-2", "X-3"])
        XCTAssertEqual(src.calls.filter { $0.hasPrefix("submit") }, ["submit X-2", "submit X-3"])
        XCTAssertEqual(d.pending.count, 0)
    }

    func testAFailedPartDoesNotStopTheOtherParts() async throws {
        let (d, src) = await desk()
        _ = await d.add(.code(repo: "app", path: "X-2.go", line: 1, side: .new), text: "one", item: "X-2")
        _ = await d.add(.code(repo: "cli", path: "X-3.go", line: 1, side: .new), text: "two", item: "X-3")
        src.failures["X-3"] = ProviderError.transport("down")
        do {
            _ = try await d.submit(.requestChanges, summary: nil, post: false)
            XCTFail("no error")
        } catch let e as PartialSubmit {
            XCTAssertEqual(e.sent.compactMap(\.item), ["X-2"])
            XCTAssertEqual(e.failed.map(\.key), ["X-3"])
            XCTAssertEqual(d.error, "Sent to X-2. Not sent to X-3 (down).")
        }
    }

    func testAMergeSendsTheItemsAndAFullMergeSetsTheParentToDone() async throws {
        let tracker = FakeTracking()
        let (d, src) = await desk(tracker: tracker)
        let r = try await d.merge(items: ["X-2", "X-3", "X-1"], removeGroup: true, setDone: true)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(src.mergeItems, [["X-2", "X-3", "X-1"]])
        await d.settledWrites()
        let acts = await MainActor.run { tracker.acts.filter { $0.id == "item.setStatus" } }
        XCTAssertEqual(acts.map { "\($0.values["key"]?.string ?? "") \($0.values["subItems"] == .bool(true))" }, ["X-2 false", "X-3 false", "X-1 true"])
    }

    func testAMergeOfSomeSubItemsSetsOnlyThemToDone() async throws {
        let tracker = FakeTracking()
        let (d, _) = await desk(tracker: tracker)
        _ = try await d.merge(items: ["X-2", "X-3"], removeGroup: false, setDone: true)
        await d.settledWrites()
        let moves = await MainActor.run { tracker.moves }
        XCTAssertEqual(moves, ["X-2 done", "X-3 done"], "the parent has no write while a part is open")
        let notes = await MainActor.run { tracker.acts.filter { $0.id == "item.comment" }.map { $0.values["key"]?.string ?? "" } }
        XCTAssertEqual(notes, ["X-2", "X-3"])
    }

    func testAnOldDaemonAsksForAnUpdate() async {
        let (d, src) = await desk()
        src.failure = ProviderError.vendor(code: "400", message: "json: unknown field \"items\"")
        do {
            _ = try await d.merge(items: ["X-2"], removeGroup: false, setDone: false)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(d.error, "Update oversire on mba to merge sub-items.")
        }
    }

    func testTheMergeSheetPicksOnlyTheReadyParts() {
        let repos = [ReviewRepo(name: "app", branch: "x-2", base: "main", ahead: 1, item: "X-2"),
                     ReviewRepo(name: "cli", branch: "x-3", base: "main", ahead: 1, item: "X-3"),
                     ReviewRepo(name: "app", branch: "x-1", base: "main", ahead: 1, item: "X-1")]
        let parts = [ReviewPart(key: "X-2", root: "/w", state: .ready), ReviewPart(key: "X-3", root: "/w", state: .waiting, round: 2),
                     ReviewPart(key: "X-1", root: "/w", state: .ready)]
        var p = MergePicks(parts: parts, repos: repos)
        XCTAssertEqual(p.items, ["X-2", "X-1"])
        XCTAssertFalse(p.allReady, "Merge all is off while a part waits")
        XCTAssertEqual(p.notReady, "3: the agent works on round 2")
        XCTAssertFalse(p.canSetDone)
        p.set("X-3", true)
        XCTAssertEqual(p.items, ["X-2", "X-1"], "a part that is not ready cannot be picked")

        var all = MergePicks(parts: parts.map { var x = $0; x.state = .ready; return x }, repos: repos)
        XCTAssertTrue(all.allReady)
        XCTAssertTrue(all.canSetDone)
        all.set("X-2", false)
        XCTAssertFalse(all.canSetDone, "Done needs all parts")
        all.pickAll()
        XCTAssertEqual(all.items, ["X-2", "X-3", "X-1"])
    }
}
