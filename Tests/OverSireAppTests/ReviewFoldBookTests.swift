import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// Work › Review with the code of the sub-items in the row of the parent (OVERSIRE-591).
final class ReviewFoldBookTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func detail(_ key: String, repo: String, path: String, state: ReviewState = .ready) -> ReviewDetail {
        let s = ReviewSummary(key: key, kind: .code, machine: "mba", state: state, root: "/w", group: ".wt/\(key.lowercased())",
                              repos: [ReviewRepo(name: repo, branch: key.lowercased(), base: "main", ahead: 1)], readyAt: t0, updatedAt: t0)
        return ReviewDetail(summary: s, files: [ReviewFile(repo: repo, path: path, status: .modified, added: 1, removed: 1)])
    }

    /// X-1 with the sub-items X-2 and X-3. X-2 and X-1 change the same file name in the same repo.
    private func family() -> FakeReviewSource {
        let src = FakeReviewSource(machine: "mba")
        src.seed([detail("X-1", repo: "app", path: "a.go"), detail("X-2", repo: "app", path: "a.go"),
                  detail("X-3", repo: "cli", path: "b.go", state: .waiting)],
                 diffs: [FileDiff(repo: "app", path: "a.go", status: .modified, hunks: [])])
        src.parents = ["X-2": "X-1", "X-3": "X-1"]
        return src
    }

    private func book(_ src: FakeReviewSource, fold: ReviewFold = ReviewFold(on: true)) -> ReviewBook {
        let b = ReviewBook(sources: { [src] }, bus: ChangeBus(schedule: { _, _ in }))
        b.fold = { fold }
        return b
    }

    private func desk(_ b: ReviewBook, _ key: String) async -> ReviewDesk? {
        let d = await MainActor.run { b.review(key, kind: .code).flatMap { b.desk($0) } }
        await d?.load()
        return d
    }

    func testTheBookReadsWithTheFoldAndFindsTheParentOfASubItem() async {
        let src = family()
        let b = book(src)
        await b.refresh()
        XCTAssertEqual(src.lastFold, ReviewFold(on: true))
        XCTAssertEqual(b.rows.map(\.key), ["X-1"])
        XCTAssertEqual(b.rows.first?.parts?.map(\.key), ["X-2", "X-3", "X-1"])
        XCTAssertEqual(b.parent(of: "X-3")?.key, "X-1")
        XCTAssertNil(b.parent(of: "X-1"), "the parent has its own row")
        XCTAssertNil(b.review("X-2", kind: .code))
    }

    func testTheFoldOffGivesARowForEachGroup() async {
        let src = family()
        let b = book(src, fold: ReviewFold(on: true, except: ["X"]))
        await b.refresh()
        XCTAssertEqual(Set(b.rows.map(\.key)), ["X-1", "X-2", "X-3"])
        XCTAssertNil(b.parent(of: "X-2"))
    }

    func testAFrameOfASubItemReloadsTheDeskOfTheParent() async {
        let src = family()
        let b = book(src)
        await b.refresh()
        _ = await desk(b, "X-1")
        let before = src.calls.filter { $0 == "review X-1" }.count
        await b.apply(ReviewEvent(event: .changed, key: "X-2", kind: .code, machine: "mba"), from: "mba")
        XCTAssertEqual(src.calls.filter { $0 == "review X-1" }.count, before + 1)
    }

    func testTheDeskSendsEachCallToTheSubItemThatOwnsTheFile() async throws {
        let src = family()
        let b = book(src)
        await b.refresh()
        let got = await desk(b, "X-1")
        let d = try XCTUnwrap(got)
        XCTAssertTrue(d.folded)
        XCTAssertEqual(d.files.map(\.id), ["X-2/app/a.go", "X-3/cli/b.go", "X-1/app/a.go"], "the same path in two groups has two ids")
        let kid = d.files[0]
        XCTAssertEqual(d.owner(kid), "X-2")

        await d.diff(kid)
        XCTAssertTrue(src.calls.contains("diff X-2 app/a.go full"), "\(src.calls)")
        let added = await d.add(.code(repo: "app", path: "a.go", line: 1, side: .new), text: "Why?", item: d.owner(kid))
        XCTAssertTrue(added)
        XCTAssertTrue(src.calls.contains("comment X-2"))
        XCTAssertEqual(d.comments(in: kid).map(\.key), ["X-2"])
        XCTAssertTrue(d.comments(in: d.files[2]).isEmpty, "the comment of X-2 is not on the file of X-1")
        XCTAssertEqual(d.pendingByFile, ["X-2/app/a.go": 1])

        _ = await d.setViewed(kid, true)
        XCTAssertTrue(src.calls.contains("viewed X-2"))
        let c = try XCTUnwrap(d.pending.first)
        _ = await d.delete(c)
        XCTAssertTrue(src.calls.contains("delete X-2"))
        XCTAssertEqual(d.absolutePath(kid), "/w/.wt/x-2/app/a.go")
    }

    func testALinePickKeepsItsItem() {
        let p = LinePick(item: "X-2", repo: "app", path: "a.go", side: .new, line: 3).click(5, side: .old, shift: true)
        XCTAssertEqual(p.item, "X-2")
    }

    func testAFoldedRowShowsTheGroupsAndRoutesToChanges() async {
        let src = family()
        let b = book(src)
        await b.refresh()
        let s = b.rows[0]
        XCTAssertEqual(ReviewRow.kids(s).map(\.key), ["X-2", "X-3"])
        XCTAssertEqual(ReviewRow.route(s), .item("X-1", .changes))
        XCTAssertEqual(ReviewRow.word(.waiting), "waiting")
        XCTAssertEqual(FilePanel.short("OVERSIRE-401"), "401")
        XCTAssertEqual(FilePanel.short("NOKEY"), "NOKEY")
    }
}
