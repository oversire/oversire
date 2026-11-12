import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

@MainActor
final class DiffModalTests: XCTestCase {
    private var savedMaxFiles = true

    override func setUp() {
        super.setUp()
        savedMaxFiles = ReviewDesk.maxFilesOn
        ReviewDesk.maxFilesOn = true
        UserDefaults.standard.removeObject(forKey: "review.maxFiles")
    }

    override func tearDown() {
        ReviewDesk.maxFilesOn = savedMaxFiles
        UserDefaults.standard.removeObject(forKey: "review.maxFiles")
        super.tearDown()
    }

    private func rig() -> (file: ReviewFile, desk: ReviewDesk, panel: DiffPanel, window: NSWindow, home: NSView) {
        let file = ReviewFile(repo: "cli", path: "review/routes.go", status: .modified, added: 2, removed: 1)
        let s = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let d = ReviewDesk(detail: ReviewDetail(summary: s, files: [file], comments: []))
        let p = DiffPanel(desk: d, threads: ReviewThreads(d))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let home = NSView()
        w.contentView = home
        home.addSubview(p)
        p.update(file, diff: UIShots.longDiff)
        return (file, d, p, w, home)
    }
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

    func testTheCardHoldsTheFilesAtTheLeft() {
        let r = rig()
        let v = NSView()
        r.home.addSubview(v)
        let m = DiffModal.show(r.panel, files: v, in: r.window) {}
        r.window.layoutIfNeeded()
        XCTAssertEqual(v.frame.width, ReviewChangesTab.sideWidth, accuracy: 0.5)
        XCTAssertEqual(r.panel.frame.width, r.home.bounds.width * 0.9 - ReviewChangesTab.sideWidth - 1, accuracy: 1)

        let before = r.panel.superview
        m.hold(r.panel, files: nil)
        r.window.layoutIfNeeded()
        XCTAssertEqual(r.panel.frame.width, r.home.bounds.width * 0.9, accuracy: 1)
        XCTAssertTrue(r.panel.superview === before, "the panel stays in place")

        r.home.addSubview(v)
        m.dismiss()
        XCTAssertTrue(v.superview === r.home, "dismiss leaves a view that is not in the card")
    }

    // A row takes only the mouse up. Its mouse down goes up the responder chain.
    func testAPressOnAFileRowKeepsTheLargeView() {
        let r = rig()
        let files = NSView()
        let row = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        files.addSubview(row)
        var closed = 0
        let m = DiffModal.show(r.panel, files: files, in: r.window) { closed += 1 }
        r.window.layoutIfNeeded()
        func press(_ v: NSView, at p: NSPoint) {
            let at = v.convert(p, to: nil)
            let hit = r.window.contentView!.hitTest(r.window.contentView!.convert(at, from: nil))!
            let e = NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            hit.mouseDown(with: e)
        }
        press(row, at: NSPoint(x: 20, y: 12))
        XCTAssertEqual(closed, 0, "a click on a file row does not close the large view")
        press(m, at: NSPoint(x: 4, y: 4))
        XCTAssertEqual(closed, 1, "a click on the scrim closes the large view")
    }

    func testHidingTheFilesMovesTheFocusToTheDiff() {
        let r = rig()
        let v = NSView()
        let field = NSTextField()
        v.addSubview(field)
        let m = DiffModal.show(r.panel, files: v, in: r.window) {}
        r.window.layoutIfNeeded()
        XCTAssertTrue(r.window.makeFirstResponder(field))
        r.home.addSubview(v)
        m.hold(r.panel, files: nil)
        XCTAssertTrue(r.window.firstResponder === r.panel.table.view)
    }

    func testControlCommandSWorksOnlyInTheLargeView() {
        let r = rig()
        var reloads = 0
        r.panel.reload = { reloads += 1 }
        XCTAssertFalse(r.panel.handle(.filePanel), "outside the large view the key stays View > Toggle Sidebar")
        XCTAssertTrue(ReviewDesk.maxFilesOn)
        XCTAssertEqual(reloads, 0)
        r.desk.maximized = true
        XCTAssertTrue(r.panel.handle(.filePanel))
        XCTAssertFalse(ReviewDesk.maxFilesOn)
        XCTAssertEqual(reloads, 1)
    }

    func testTheHeaderToggleShowsOnlyInTheLargeView() {
        let r = rig()
        func buttons() -> [IconButton] {
            var out: [IconButton] = []
            func walk(_ v: NSView) {
                if let b = v as? IconButton, b.accessibilityLabel()?.contains("file panel") == true { out.append(b) }
                v.subviews.forEach(walk)
            }
            walk(r.panel)
            return out
        }
        XCTAssertTrue(buttons().isEmpty)
        r.desk.maximized = true
        r.panel.update(r.file, diff: UIShots.longDiff)
        XCTAssertEqual(buttons().map { $0.accessibilityLabel() }, ["Hide the file panel"])
        ReviewDesk.maxFilesOn = false
        r.panel.update(r.file, diff: UIShots.longDiff)
        let b = buttons()
        XCTAssertEqual(b.map { $0.accessibilityLabel() }, ["Show the file panel"])
        b.first?.performClick(nil)
        XCTAssertTrue(ReviewDesk.maxFilesOn)
    }

    // The tree shows the file position, so the header gives its room to the path.
    func testTheFileButtonsShowOnlyWithoutTheFilePanel() {
        let r = rig()
        func labels() -> [String] {
            var out: [String] = []
            func walk(_ v: NSView) {
                if let b = v as? IconButton, let l = b.accessibilityLabel() { out.append(l) }
                v.subviews.forEach(walk)
            }
            walk(r.panel)
            return out
        }
        r.desk.maximized = true
        ReviewDesk.maxFilesOn = true
        r.panel.update(r.file, diff: UIShots.longDiff)
        XCTAssertFalse(labels().contains("Next file"))
        ReviewDesk.maxFilesOn = false
        r.panel.update(r.file, diff: UIShots.longDiff)
        XCTAssertTrue(labels().contains("Next file"))
    }
}
