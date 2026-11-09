import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

@MainActor
final class DiffModalTests: XCTestCase {
    func testEscClosesTheModalAndThePanelGoesBack() {
        let file = ReviewFile(repo: "cli", path: "review/routes.go", status: .modified, added: 2, removed: 1)
        let s = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let d = ReviewDesk(detail: ReviewDetail(summary: s, files: [file], comments: []))
        let p = DiffPanel(desk: d, threads: ReviewThreads(d))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let home = NSView()
        w.contentView = home
        home.addSubview(p)
        p.update(file, diff: UIShots.longDiff)

        var reloads = 0
        p.reload = { reloads += 1 }
        d.maximized = true
        var m: DiffModal!
        m = DiffModal.show(p, in: w) {
            d.maximized = false
            m.dismiss()
            home.addSubview(p)
        }
        w.layoutIfNeeded()
        XCTAssertTrue(p.isDescendant(of: m))
        XCTAssertEqual(m.panel, p)
        XCTAssertEqual(p.frame.width, home.bounds.width * 0.9, accuracy: 1, "the card is 90% of the window")

        m.cancelOperation(nil)
        XCTAssertFalse(d.maximized)
        XCTAssertNil(m.superview)
        XCTAssertTrue(p.superview === home, "the panel goes back to the page")

        XCTAssertFalse(p.handle(.close), "Esc in the page is not for the panel")
        d.maximized = true
        XCTAssertTrue(p.handle(.close))
        XCTAssertFalse(d.maximized)
        XCTAssertEqual(reloads, 1)
    }
}
