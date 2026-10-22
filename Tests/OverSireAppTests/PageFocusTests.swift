import AppKit
import OverSireCore
import OverSireAI
import OverSireAssistant
import XCTest
@testable import OverSireApp

/// Links with a row focus, and reveal on the pages.
final class PageFocusTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUp() { Page.deferBuilds = false }
    override func tearDown() { Page.deferBuilds = true; windows.forEach { $0.close() }; windows = [] }

    private func shown<P: Page>(_ p: P) -> P {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = p
        p.view.setFrameSize(NSSize(width: 900, height: 300))
        p.view.layoutSubtreeIfNeeded()
        windows.append(w)
        return p
    }

    private func pr(_ n: Int) -> ChangeRequest {
        ChangeRequest(number: n, title: "Fix \(n)", state: "OPEN", author: .init(login: "a"), headRefName: "b\(n)", baseRefName: "main", url: "",
                      createdAt: "2026-10-20T09:00:00Z", updatedAt: "2026-10-20T10:00:00Z", reviewDecision: nil, additions: 1,
                      deletions: 0, isDraft: false, labels: [], body: nil, mine: false)
    }

    func testTargetRoundTripsEachRoute() {
        for r in Route.samples {
            XCTAssertEqual(Target(path: r.path), Target(r), r.path)
            XCTAssertEqual(Target(url: r.url), Target(r), r.path)
            if case .settings = r { continue }
            let t = Target(r, focus: "OVERSIRE-12")
            XCTAssertEqual(Target(path: t.path), t, t.path)
            XCTAssertEqual(Target(url: t.url), t, t.url.absoluteString)
        }
    }

    func testFocusCanHoldAHash() {
        let t = Target(.runs(.all), focus: "o/a#7")
        XCTAssertEqual(Target(path: t.path), t)
        XCTAssertEqual(Target(url: t.url), t)
    }

    func testSettingsFragmentStaysTheAnchor() {
        XCTAssertEqual(Target(url: URL(string: "oversire://settings/agents#queue")!), Target(.settings(.agents, anchor: "queue")))
        XCTAssertEqual(Target(path: "settings/agents#queue"), Target(.settings(.agents, anchor: "queue")))
    }

    func testRunsPageRevealsARun() {
        let data = TestAppData()
        data.grouped = [("o/a", (1...30).map { Run.sample($0) })]
        let p = shown(RunsPage(.runs(.all), data: data, router: Router()))
        let last = p.scroll.rows.map(\.id).last { $0.hasPrefix("o/a#") }!
        XCTAssertTrue(p.reveal(last))
        XCTAssertFalse(p.reveal("o/a#999"))
    }

    func testPRsPageRevealsARowInItsList() {
        let data = TestAppData()
        data.prGrouped = [("o/a", (1...20).map(pr))]
        let p = shown(PRsPage(.prs, data: data, router: Router()))
        XCTAssertTrue(p.reveal("o/a#18"))
        let scroll = p.scroll.row("o/a#18")?.enclosingScrollView
        XCTAssertGreaterThan(scroll?.documentVisibleRect.minY ?? 0, 0)
        XCTAssertFalse(p.context.rows.contains { $0.id == "o/a#1" }, "the first rows are out of view")
    }

    func testFocusWaitsForTheRow() {
        let data = TestAppData()
        let p = shown(RunsPage(.runs(.all), data: data, router: Router()))
        p.focus("o/a#3")
        XCTAssertFalse(p.reveal("o/a#3"))
        data.grouped = [("o/a", [Run.sample(3)])]
        p.reload(reason: "test")
        XCTAssertTrue(p.reveal("o/a#3"))
    }

    func testContextListsTheRowsInView() {
        let data = TestAppData()
        data.grouped = [("o/a", [Run.sample(1), Run.sample(2)])]
        let p = shown(RunsPage(.runs(.all), data: data, router: Router()))
        let c = p.context
        XCTAssertEqual(c.route, "runs")
        XCTAssertFalse(c.rows.isEmpty)
        XCTAssertTrue(c.rows.allSatisfy { !$0.text.isEmpty })
    }

    func testNavigateNeedsFollowAlong() async {
        let data = TestAppData()
        data.actions.link.follows = { _ in false }
        let r = await data.actions.run("page.navigate", ActionArgs(.object(["route": .string("prs")]), caller: .assistant(thread: "t")))
        guard case .notAllowed = r else { return XCTFail("\(r)") }
        // Tests have no window.
        data.actions.link.follows = { _ in true }
        let r2 = await data.actions.run("page.navigate", ActionArgs(.object(["route": .string("prs")]), caller: .assistant(thread: "t")))
        XCTAssertEqual(r2, .notAllowed("The window is not open."))
    }
}
