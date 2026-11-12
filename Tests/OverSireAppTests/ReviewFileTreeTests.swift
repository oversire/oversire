import OverSireCore
import XCTest
@testable import OverSireApp

final class ReviewFileTreeTests: XCTestCase {
    private let files = [
        ReviewFile(repo: "oversire", path: "Sources/OverSireApp/review_tab.swift", status: .added, added: 10, removed: 0),
        ReviewFile(repo: "oversire", path: "Sources/OverSireApp/work_page.swift", status: .modified, added: 2, removed: 3),
        ReviewFile(repo: "oversire", path: "Sources/OverSireCore/Review.swift", status: .renamed, added: 1, removed: 1),
        ReviewFile(repo: "oversire", path: "docs/old.md", status: .deleted, added: 0, removed: 9),
        ReviewFile(repo: "oversire", path: "README.md", status: .modified, added: 1, removed: 0),
        ReviewFile(repo: "cli", path: "review/routes.go", status: .modified, added: 4, removed: 1),
    ]

    private func tree(_ filter: FileFilter = FileFilter(), collapsed: Set<String> = [], pending: [String: Int] = [:]) -> FileTree {
        FileTree(files: files, repos: ["oversire", "cli"], filter: filter, collapsed: collapsed, pending: pending)
    }

    private func names(_ rows: [FileTree.Row]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.name }
    }

    func testTheTreeShowsReposThenFoldersThenFiles() {
        XCTAssertEqual(names(tree().rows(.tree)), [
            "oversire",
            "  docs",
            "    old.md",
            "  Sources",
            "    OverSireApp",
            "      review_tab.swift",
            "      work_page.swift",
            "    OverSireCore",
            "      Review.swift",
            "  README.md",
            "cli",
            "  review",
            "    routes.go",
        ])
    }

    @MainActor
    func testTheCurrentFileScrollsIntoTheTree() {
        let many = (0..<60).map { ReviewFile(repo: "cli", path: "f\($0).swift", status: .modified, added: 1, removed: 0) }
        let s = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src", updatedAt: Date())
        let desk = ReviewDesk(detail: ReviewDetail(summary: s, files: many, comments: []))
        let p = FilePanel(desk)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let home = NSView()
        w.contentView = home
        p.card.translatesAutoresizingMaskIntoConstraints = false
        home.addSubview(p.card)
        NSLayoutConstraint.activate([
            p.card.leadingAnchor.constraint(equalTo: home.leadingAnchor), p.card.trailingAnchor.constraint(equalTo: home.trailingAnchor),
            p.card.topAnchor.constraint(equalTo: home.topAnchor), p.card.bottomAnchor.constraint(equalTo: home.bottomAnchor),
        ])
        p.refresh()
        let last = many.last!.id
        desk.file = last
        p.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        w.layoutIfNeeded()
        func find(_ v: NSView) -> TreeRow? {
            if let r = v as? TreeRow, r.identifier?.rawValue == FilePanel.rowID(last) { return r }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        let row = find(p.card)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.selected, true)
        let at = row.map { p.card.scroll.documentView!.convert($0.bounds, from: $0) } ?? .zero
        XCTAssertTrue(p.card.scroll.documentVisibleRect.intersects(at), "the open file is in sight")
        XCTAssertGreaterThan(p.card.scroll.contentView.bounds.origin.y, 100)
    }

    func testAFolderChainWithOneChildIsOneRow() {
        let t = FileTree(files: [ReviewFile(repo: "cli", path: "a/b/c/x.go", status: .added, added: 1, removed: 0),
                                 ReviewFile(repo: "cli", path: "a/b/c/y.go", status: .added, added: 1, removed: 0)],
                         repos: ["cli"])
        XCTAssertEqual(names(t.rows(.tree)), ["a/b/c", "  x.go", "  y.go"], "one repo shows no repo row")
        XCTAssertEqual(t.rows(.tree).first?.id, "cli/a/b/c")
    }

    func testAClosedFolderHidesItsFilesAndKeepsItsCounts() {
        let rows = tree(collapsed: ["oversire/Sources"], pending: ["oversire/Sources/OverSireApp/work_page.swift": 2]).rows(.tree)
        let sources = rows.first { $0.id == "oversire/Sources" }
        XCTAssertEqual(sources?.open, false)
        XCTAssertEqual(sources?.files, 3)
        XCTAssertEqual(sources?.pending, 2)
        XCTAssertFalse(rows.contains { $0.name == "work_page.swift" })
        XCTAssertEqual(rows.first { $0.id == "oversire" }?.pending, 2, "the repo row counts the pending comments too")
    }

    func testASearchOpensAllFoldersAndMatchesThePath() {
        var f = FileFilter()
        f.query = "overSireapp"
        let rows = tree(f, collapsed: ["oversire", "oversire/Sources"]).rows(.tree)
        XCTAssertEqual(rows.filter { $0.kind == .file }.map(\.name), ["review_tab.swift", "work_page.swift"])
        XCTAssertTrue(rows.allSatisfy(\.open))
    }

    func testTheStatusSwitchesAndTheRepoFilter() {
        var f = FileFilter()
        f.hidden = [.changed]
        XCTAssertEqual(tree(f).shown.map(\.path), ["Sources/OverSireApp/review_tab.swift", "docs/old.md"], "a renamed file counts as changed")
        f.repo = "cli"
        XCTAssertTrue(tree(f).rows(.tree).isEmpty)
        f.hidden = []
        XCTAssertEqual(names(tree(f).rows(.tree)), ["review", "  routes.go"], "one repo shows no repo row")
    }

    func testTheListHasAHeadForEachRepo() {
        let rows = tree().rows(.list)
        XCTAssertEqual(rows.filter { $0.kind == .head }.map(\.name), ["oversire", "cli"])
        XCTAssertEqual(rows.filter { $0.kind == .file }.count, files.count)
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 })
    }

    func testTheGroupOfEachStatus() {
        XCTAssertEqual([FileStatus.added, .modified, .renamed, .deleted].map(FileGroup.init), [.new, .changed, .changed, .deleted])
    }

    func testTheGutterMarksOfAFile() {
        let open = ReviewComment(id: "c1", key: "K-1", round: 2, state: .pending,
                                 anchor: .code(repo: "cli", path: "r.go", line: 12, from: 10, side: .new), text: "x", createdAt: Date())
        let done = ReviewComment(id: "c2", key: "K-1", round: 1, state: .answered,
                                 anchor: .code(repo: "cli", path: "r.go", line: 12, side: .new), text: "y", createdAt: Date())
        let old = ReviewComment(id: "c3", key: "K-1", round: 1, state: .answered,
                                anchor: .code(repo: "cli", path: "r.go", line: 4, side: .old), text: "z", createdAt: Date())
        let m = ReviewChangesTab.marks([done, open, old])
        XCTAssertEqual(m[.init(side: .new, line: 10)], .pending)
        XCTAssertEqual(m[.init(side: .new, line: 12)], .pending, "an open comment wins over an answered one")
        XCTAssertEqual(m[.init(side: .old, line: 4)], .answered)
        XCTAssertNil(m[.init(side: .new, line: 4)])
        XCTAssertEqual(m.count, 4)
    }

    @MainActor
    func testThePanelOffersToClearFiltersThatHideAllFiles() {
        let summary = ReviewSummary(key: "K-1", kind: .code, machine: "mba", state: .ready, root: "/src",
                                    repos: [ReviewRepo(name: "oversire", branch: "b", base: "main", ahead: 1), ReviewRepo(name: "cli", branch: "b", base: "main", ahead: 1)],
                                    readyAt: Date(), updatedAt: Date())
        let desk = ReviewDesk(detail: ReviewDetail(summary: summary, files: files))
        let panel = FilePanel(desk)
        var builds = 0
        panel.changed = { builds += 1 }
        desk.filter.query = "nothing-like-this"
        let body = panel.body()
        XCTAssertNotNil(UIShots.find(body) { ($0 as? NSTextField)?.stringValue == "No files match." })
        let clear = UIShots.find(body) { ($0 as? ActionButton)?.title == "Clear the filters" } as? ActionButton
        clear?.onClick?()
        XCTAssertEqual(desk.filter, FileFilter())
        XCTAssertEqual(builds, 1)
    }

    func testTheFilesOfTheTreeIgnoreCollapsedFolders() {
        let t = tree(collapsed: ["oversire/Sources"])
        XCTAssertFalse(t.rows(.tree).contains { $0.file?.path == "Sources/OverSireCore/Review.swift" }, "the folder is collapsed")
        XCTAssertEqual(t.steps(.tree).map(\.path), [
            "docs/old.md", "Sources/OverSireApp/review_tab.swift", "Sources/OverSireApp/work_page.swift",
            "Sources/OverSireCore/Review.swift", "README.md", "review/routes.go",
        ])
        var q = FileFilter()
        q.query = "review"
        XCTAssertEqual(tree(q).steps(.list).map(\.id), tree(q).rows(.list).compactMap(\.file?.id), "the steps use the filter")
    }
}
