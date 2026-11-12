import AppKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

@MainActor
final class ReviewChangesTabTests: XCTestCase {
    private var saved = true

    override func setUp() {
        super.setUp()
        saved = ReviewDesk.maxFilesOn
        ReviewDesk.maxFilesOn = true
    }

    override func tearDown() {
        ReviewDesk.maxFilesOn = saved
        UserDefaults.standard.removeObject(forKey: "review.maxFiles")
        super.tearDown()
    }

    private struct Rig {
        let tab: ReviewChangesTab
        let desk: ReviewDesk
        let window: NSWindow
        let pane: TwoPane
        let row: PageRow
    }

    private func rig() -> Rig {
        let files = (0..<60).map { ReviewFile(repo: "cli", path: "d\($0 % 4)/f\($0).swift", status: .modified, added: 1, removed: 0) }
        let s = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let diff = FileDiff(repo: "cli", path: files[0].path, status: .modified, hunks: UIShots.longDiff.hunks)
        let desk = ReviewDesk(detail: ReviewDetail(summary: s, files: files, comments: []), diffs: [diff])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let home = NSView()
        w.contentView = home
        let tab = ReviewChangesTab()
        tab.window = { w }
        let row = tab.rows(desk).first { $0.id == "body" }!
        let pane = row.make() as! TwoPane
        home.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: home.leadingAnchor), pane.trailingAnchor.constraint(equalTo: home.trailingAnchor),
            pane.topAnchor.constraint(equalTo: home.topAnchor), pane.bottomAnchor.constraint(equalTo: home.bottomAnchor),
        ])
        w.layoutIfNeeded()
        return Rig(tab: tab, desk: desk, window: w, pane: pane, row: row)
    }

    private func find<T: NSView>(_ v: NSView, _ match: (T) -> Bool = { _ in true }) -> T? {
        if let t = v as? T, match(t) { return t }
        for s in v.subviews { if let f: T = find(s, match) { return f } }
        return nil
    }

    private func modal(_ r: Rig) -> DiffModal? { find(r.window.contentView!) }

    /// Builds the rows again, as the page does after a change, and runs the update of the body row.
    private func update(_ r: Rig) {
        let row = r.tab.rows(r.desk).first { $0.id == "body" }!
        row.update?(r.pane)
        r.window.layoutIfNeeded()
    }

    func testTheFilePanelMovesIntoTheLargeViewAndBack() {
        let r = rig()
        let p = r.tab.panel(r.desk)
        r.desk.collapsed = ["cli/d3"]
        update(r)
        p.card.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        p.card.scroll.reflectScrolledClipView(p.card.scroll.contentView)
        let head = p.head
        let search: NSSearchField? = find(head)
        XCTAssertTrue(p.card.isDescendant(of: r.pane.side), "the page holds the panel")

        r.desk.maximized = true
        update(r)
        let m = modal(r)
        XCTAssertNotNil(m)
        XCTAssertTrue(p.card.isDescendant(of: m!), "the panel is in the large view")
        XCTAssertTrue(p.head === head)
        XCTAssertTrue(find(p.head) as NSSearchField? === search)
        XCTAssertEqual(p.card.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5)
        let closed: TreeRow? = find(p.card) { $0.accessibilityLabel()?.hasSuffix(", closed") == true }
        XCTAssertNotNil(closed, "the closed folder stays closed")
        let note: NSTextField? = find(r.pane.side) { $0.stringValue.contains("files are in the large view") }
        XCTAssertNotNil(note)

        ReviewDesk.maxFilesOn = false
        update(r)
        XCTAssertTrue(p.card.isDescendant(of: r.pane.side))
        XCTAssertNotNil(modal(r), "the diff stays in the large view")
        XCTAssertTrue(modal(r)!.panel?.isDescendant(of: modal(r)!) == true)
        XCTAssertEqual(p.card.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5)

        ReviewDesk.maxFilesOn = true
        update(r)
        XCTAssertTrue(p.card.isDescendant(of: modal(r)!))

        r.desk.maximized = false
        update(r)
        XCTAssertNil(modal(r))
        XCTAssertTrue(p.card.isDescendant(of: r.pane.side))
        XCTAssertEqual(p.card.scroll.contentView.bounds.origin.y, 200, accuracy: 0.5)

        r.desk.filter.query = "f1"
        update(r)
        XCTAssertEqual(search?.stringValue, "f1", "the search field keeps its text")
    }

    func testTheBodyRowHashFollowsTheChoice() {
        let r = rig()
        let a = r.tab.rows(r.desk).first { $0.id == "body" }!.hash
        ReviewDesk.maxFilesOn = false
        let b = r.tab.rows(r.desk).first { $0.id == "body" }!.hash
        XCTAssertNotEqual(a, b)
    }

    // MARK: Failed reads (OVERSIRE-462)

    private func failedDesk() async -> (ReviewDesk, ReviewFile, FakeReviewSource) {
        let src = FakeReviewSource(machine: "mba")
        let sum = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let f = ReviewFile(repo: "cli", path: "a.go", status: .modified, added: 1, removed: 0)
        let d = FileDiff(repo: "cli", path: "a.go", status: .modified, hunks: UIShots.longDiff.hunks)
        src.seed([ReviewDetail(summary: sum, files: [f])], diffs: [d])
        let desk = ReviewDesk(summary: sum, source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }), schedule: { _, _ in })
        await desk.load()
        src.failure = ProviderError.transport("The request timed out.")
        await desk.diff(f)
        return (desk, f, src)
    }

    func testAFailedDiffShowsTheNoteWithTryAgain() async throws {
        let (desk, f, src) = await failedDesk()
        let panel = DiffPanel(desk: desk, threads: ReviewThreads(desk))
        panel.update(f, diff: nil)
        let note: ReadNote = try XCTUnwrap(find(panel))
        let again: ActionButton = try XCTUnwrap(find(note) { $0.title == "Try again" })
        let reason: NSTextField? = find(note) { $0.stringValue == "The request timed out." }
        XCTAssertNotNil(reason)
        src.failure = nil
        again.performClick(nil)
        await desk.diffRead(f).settled()
        XCTAssertNotNil(desk.shownDiff(f))
        panel.update(f, diff: desk.shownDiff(f))
        XCTAssertNil(find(panel) as ReadNote?)
    }

    func testAStaleDiffDimsTheTableAndKeepsItsAccessory() async throws {
        let (desk, f, src) = await failedDesk()
        src.failure = nil
        await desk.diff(f, force: true)
        src.failure = ProviderError.transport("down")
        await desk.diff(f, force: true)
        let panel = DiffPanel(desk: desk, threads: ReviewThreads(desk))
        panel.update(f, diff: desk.shownDiff(f))
        XCTAssertEqual(panel.table.scroll.alphaValue, 0.6, accuracy: 0.01)
        XCTAssertNil(find(panel) as ReadNote?)
        let again: IconButton? = find(panel) { $0.accessibilityLabel()?.hasPrefix("Try again") == true }
        XCTAssertNotNil(again, "the header shows Try again")
    }

    func testTheReviewErrorRowIsAReadNote() async throws {
        let src = FakeReviewSource(machine: "mba")
        src.failure = ProviderError.transport("down")
        let sum = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let desk = ReviewDesk(summary: sum, source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }), schedule: { _, _ in })
        await desk.load()
        let rows = ReviewChangesTab().rows(desk)
        let row = try XCTUnwrap(rows.first { $0.id == "error" })
        let note = row.make() as? ReadNote
        XCTAssertNotNil(note)
        XCTAssertFalse(rows.contains { $0.id == "loading" }, "a failed read shows no loading row")
        let plan = ReviewDesk(summary: ReviewSummary(key: "K-1", kind: .plan, machine: "mba", state: .ready, root: "/src", updatedAt: Date()),
                              source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }), schedule: { _, _ in })
        await plan.load()
        XCTAssertTrue(ReviewPlanTab().rows(plan).first { $0.id == "error" }?.make() is ReadNote)
    }
}
