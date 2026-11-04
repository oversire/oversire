import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

final class ReviewTextTests: XCTestCase {
    private func text(_ shown: String, code: String? = nil) -> DiffText {
        let t = DiffText(labelWithString: shown)
        t.code = code ?? shown
        return t
    }

    func testSelectAllCopiesTheCodeOfEachLine() {
        let body = DiffBody(v: [], spacing: 0)
        for (s, c) in [("func a() {", 0), ("    return", 0), ("}", 0), ("old", 1)] { body.adopt(text(s), column: c) }
        body.selectAll(nil)
        XCTAssertEqual(body.selected, "old", "a split diff selects all of the new side")

        let unified = DiffBody(v: [], spacing: 0)
        for s in ["func a() {", "    return", "}"] { unified.adopt(text(s), column: 0) }
        XCTAssertNil(unified.selected)
        unified.selectAll(nil)
        XCTAssertEqual(unified.selected, "func a() {\n    return\n}")
    }

    func testAPieceOfAShortFormGivesTheFullLine() {
        let full = String(repeating: "x", count: 20)
        let t = text(String(full.prefix(10)) + " …", code: full)
        XCTAssertEqual(t.piece(NSRange(location: 4, length: t.length - 4)), String(full.dropFirst(4)))
        XCTAssertEqual(t.piece(NSRange(location: 0, length: 3)), "xxx")
        XCTAssertEqual(text(" ", code: "").piece(NSRange(location: 0, length: 1)), "", "an empty line shows a space and copies nothing")
    }

    func testTheAbsolutePathJoinsTheRootTheGroupAndTheRepo() {
        let s = ReviewSummary(key: "A-1", kind: .code, machine: "mba", state: .ready, root: "/src/ws", group: ".wt/a-1", updatedAt: Date())
        let f = ReviewFile(repo: "cli", path: "core/a.go", status: .modified, added: 1, removed: 0)
        XCTAssertEqual(ReviewDesk(detail: ReviewDetail(summary: s)).absolutePath(f), "/src/ws/.wt/a-1/cli/core/a.go")
        var bare = s
        bare.group = nil
        XCTAssertEqual(ReviewDesk(detail: ReviewDetail(summary: bare)).absolutePath(f), "/src/ws/cli/core/a.go")
    }

    func testThePatchOfAFileDiff() {
        let d = FileDiff(repo: "cli", path: "a.go", status: .modified, hunks: [
            DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, header: "func a()", lines: [
                DiffLine(kind: .ctx, old: 1, new: 1, text: "x"),
                DiffLine(kind: .del, old: 2, text: "y"),
                DiffLine(kind: .add, new: 2, text: "z"),
            ]),
        ])
        XCTAssertEqual(d.patch, "--- a/a.go\n+++ b/a.go\n@@ -1,2 +1,2 @@ func a()\n x\n-y\n+z\n")
        let added = FileDiff(repo: "cli", path: "b.go", status: .added, hunks: [])
        XCTAssertEqual(added.patch, "--- /dev/null\n+++ b/b.go\n")
    }
}
