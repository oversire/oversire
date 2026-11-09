import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

@MainActor
final class DiffTableTests: XCTestCase {
    private var wraps = false
    override func setUp() { wraps = ReviewDesk.wraps }
    override func tearDown() { ReviewDesk.wraps = wraps }

    private let file = ReviewFile(repo: "cli", path: "review/routes.go", status: .modified, added: 2, removed: 1)

    private func desk(_ comments: [ReviewComment] = []) -> ReviewDesk {
        let s = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        return ReviewDesk(detail: ReviewDetail(summary: s, files: [file], comments: comments))
    }

    /// A panel in a window of the given width, with the long sample diff.
    private func panel(width: CGFloat, wrap: Bool, desk d: ReviewDesk? = nil) -> (DiffPanel, NSWindow) {
        ReviewDesk.wraps = wrap
        let d = d ?? desk()
        let p = DiffPanel(desk: d, threads: ReviewThreads(d))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        p.translatesAutoresizingMaskIntoConstraints = true
        w.contentView = p
        p.update(file, diff: UIShots.longDiff)
        w.layoutIfNeeded()
        p.table.fit(force: true)
        p.table.view.layoutSubtreeIfNeeded()
        return (p, w)
    }

    private func row(_ t: DiffTable, new line: Int) -> Int? {
        t.items.firstIndex { if case .line(let i) = $0 { return t.fold.lines[i].new == line } else { return false } }
    }

    private func cell(_ t: DiffTable, _ r: Int) -> DiffLineCell? {
        t.view.scrollRowToVisible(r)
        t.view.layoutSubtreeIfNeeded()
        let c = t.view.view(atColumn: 0, row: r, makeIfNecessary: true) as? DiffLineCell
        c?.layoutSubtreeIfNeeded()
        return c
    }

    func testTheMarkKeepsItsWidthOnTheWidestLine() throws {
        let (p, w) = panel(width: 600, wrap: false)
        defer { w.close() }
        let t = p.table
        let r = try XCTUnwrap(row(t, new: 3938))
        let c = try XCTUnwrap(cell(t, r))
        XCTAssertEqual(c.markFrame(0).width, DiffTable.markWidth)
        XCTAssertGreaterThan(t.view.tableColumns[0].width, 600, "a long line widens the column, so the diff scrolls")
    }

    func testTheGutterShowsFourDigitsInFull() throws {
        let (p, w) = panel(width: 600, wrap: false)
        defer { w.close() }
        let t = p.table
        let c = try XCTUnwrap(cell(t, try XCTUnwrap(row(t, new: 3938))))
        XCTAssertEqual(c.gutterTexts(), ["", "3938"])
        let digits = ("3938" as NSString).size(withAttributes: [.font: DiffTable.gutterFont]).width
        XCTAssertTrue(c.gutterFrames().allSatisfy { $0.width - 6 >= ceil(digits) }, "the number fits with no cut")
    }

    func testRowHeightsWithWrap() throws {
        let (p, w) = panel(width: 500, wrap: false)
        let t = p.table
        let lineRows = t.items.indices.filter { if case .line = t.items[$0] { return true } else { return false } }
        XCTAssertEqual(Set(lineRows.map { t.view.rect(ofRow: $0).height }), [DiffTable.lineHeight])
        w.close()

        let (q, w2) = panel(width: 500, wrap: true)
        defer { w2.close() }
        let u = q.table
        let wide = try XCTUnwrap(row(u, new: 3938)), short = try XCTUnwrap(row(u, new: 3937))
        XCTAssertGreaterThan(u.view.rect(ofRow: wide).height, u.view.rect(ofRow: short).height)
        XCTAssertEqual(u.view.tableColumns[0].width, u.scroll.contentView.bounds.width, accuracy: 0.5)
    }

    func testRevealScrollsToTheThread() throws {
        let c = ReviewComment(id: "c_1", key: "K-1", round: 1, state: .pending, anchor: .code(repo: "cli", path: "review/routes.go", line: 3938, side: .new),
                              text: "Wrap the error once.", createdAt: Date())
        let (p, w) = panel(width: 700, wrap: false, desk: desk([c]))
        defer { w.close() }
        let t = p.table
        XCTAssertTrue(t.items.contains(.thread(DiffPlace(side: .new, line: 3938))))
        t.scroll.contentView.scroll(to: .zero)
        XCTAssertTrue(t.reveal(ReviewThreads.anchorID(c)))
        let r = try XCTUnwrap(t.items.firstIndex(of: .thread(DiffPlace(side: .new, line: 3938))))
        XCTAssertTrue(t.view.visibleRect.intersects(t.view.rect(ofRow: r)))
        XCTAssertFalse(t.reveal("comment.none"))
    }
}
