import OverSireCore
import XCTest

final class ReviewFoldTests: XCTestCase {
    func testTheFoldGivesTheQueryValuesAndSkipsTheExceptProjects() {
        let f = ReviewFold(on: true, except: ["sling", "OS"])
        XCTAssertEqual(f.fold, "1")
        XCTAssertEqual(f.nofold, "OS,SLING")
        XCTAssertTrue(f.folds("OVERSIRE-401"))
        XCTAssertFalse(f.folds("sling-3"))
        XCTAssertFalse(f.folds("NOKEY"))
        XCTAssertNil(ReviewFold.off.fold)
        XCTAssertNil(ReviewFold.off.nofold)
        XCTAssertFalse(ReviewFold.off.folds("OVERSIRE-401"))
    }

    func testTheIdsOfAFoldedReviewCarryTheItem() {
        XCTAssertEqual(ReviewFile(repo: "app", path: "a.go", status: .added, added: 1, removed: 0, item: "X-2").id, "X-2/app/a.go")
        XCTAssertEqual(ReviewFile(repo: "app", path: "a.go", status: .added, added: 1, removed: 0).id, "app/a.go")
        XCTAssertEqual(ReviewRepo(name: "app", branch: "x-2", base: "main", ahead: 1, item: "X-2").id, "X-2/app")
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertNotEqual(ReviewRound(n: 1, verdict: .approve, count: 0, submittedAt: at, delivery: .sent, item: "X-2").id,
                          ReviewRound(n: 1, verdict: .approve, count: 0, submittedAt: at, delivery: .sent, item: "X-3").id)
        let s = ReviewSummary(key: "X-1", kind: .code, machine: "m", state: .ready, root: "/w", updatedAt: at,
                              parts: [ReviewPart(key: "X-2", root: "/w", state: .ready)])
        XCTAssertTrue(s.folded)
        XCTAssertEqual(s.part("X-2")?.state, .ready)
        XCTAssertNil(s.part("X-1"))
    }
}
