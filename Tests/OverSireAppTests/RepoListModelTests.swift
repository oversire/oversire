import XCTest
@testable import OverSireApp

final class RepoListModelTests: XCTestCase {
    private let catalog: [(owner: String, repos: [String])] = [
        ("me", ["me/zeta", "me/Alpha", "me/beta"]),
        ("acme", ["acme/api", "acme/web"]),
        ("empty", []),
    ]

    private func model(_ hooks: [String: HookStatus]? = nil) -> RepoListModel {
        RepoListModel(catalog: catalog, picked: ["me/Alpha", "me/beta", "other/tool"], orgs: ["acme"], hooks: hooks)
    }

    func testGroupsKeepOwnerOrderAndSortRepos() {
        let g = model().groups
        XCTAssertEqual(g.map(\.owner), ["me", "acme", "empty", "other"], "catalog owners, then owners that only the picks name")
        XCTAssertEqual(g[0].repos.map(\.name), ["me/Alpha", "me/beta", "me/zeta"])
        XCTAssertEqual(g[0].tracked, 2)
        XCTAssertEqual(g[0].total, 3)
        XCTAssertTrue(g[1].wholeOwner)
        XCTAssertEqual(g[1].tracked, 2, "a picked owner tracks all its repos")
        XCTAssertEqual(g[3].repos.map(\.name), ["other/tool"])
    }

    func testCounts() {
        let m = model(["me/Alpha": .live("200"), "acme/api": .error("404")])
        XCTAssertEqual(m.counts[.all], 6)
        XCTAssertEqual(m.counts[.tracked], 5)
        XCTAssertEqual(m.counts[.problems], 4, "only Alpha has a live hook")
    }

    func testFilters() {
        var m = model(["me/Alpha": .live("200"), "me/beta": .live("200"), "acme/api": .live("200"), "acme/web": .live("200")])
        m.filter = .tracked
        XCTAssertEqual(m.groups.flatMap(\.repos).map(\.name), ["me/Alpha", "me/beta", "acme/api", "acme/web", "other/tool"])
        XCTAssertFalse(m.groups.contains { $0.owner == "empty" }, "a filter hides an owner with no rows")
        m.filter = .problems
        XCTAssertEqual(m.groups.flatMap(\.repos).map(\.name), ["other/tool"])
        m.filter = .all
        m.text = "ALP"
        XCTAssertEqual(m.groups.flatMap(\.repos).map(\.name), ["me/Alpha"])
    }

    func testAddableRow() {
        var m = model()
        m.text = "new/thing"
        XCTAssertEqual(m.addable, "new/thing")
        m.text = "me/alpha"
        XCTAssertNil(m.addable, "the list has it")
        m.text = "alpha"
        XCTAssertNil(m.addable, "not owner/repo")
    }

    func testBadges() {
        let m = model(["me/Alpha": .live("200"), "me/beta": .pollingOnly("no admin"), "acme/api": .error("404"), "acme/web": .waiting])
        let r = Dictionary(uniqueKeysWithValues: m.groups.flatMap(\.repos).map { ($0.name, $0.badge) })
        XCTAssertEqual(r["me/Alpha"], .webhook)
        XCTAssertEqual(r["me/beta"], .pollingOnly("no admin"))
        XCTAssertEqual(r["acme/api"], .failed("404"))
        XCTAssertEqual(r["acme/web"], .webhook)
        XCTAssertEqual(r["other/tool"], .missing)
        XCTAssertEqual(r["me/zeta"], .some(nil), "an untracked repo has no badge")
        XCTAssertTrue(RepoListModel.Badge.missing.fixable)
        XCTAssertTrue(RepoListModel.Badge.failed("x").fixable)
        XCTAssertFalse(RepoListModel.Badge.pollingOnly("x").fixable)
        XCTAssertNil(model().groups[0].repos[0].badge, "no badge with the cloud off")
    }

    func testTrackAndUntrack() {
        var m = model()
        m.set("acme/web", tracked: false)
        XCTAssertFalse(m.isOwnerPicked("acme"))
        XCTAssertTrue(m.isTracked("acme/api"), "the rest of the owner stays as single picks")
        XCTAssertFalse(m.isTracked("acme/web"))
        m.toggleOwner("me")
        XCTAssertEqual(m.savedOrgs, ["me"])
        XCTAssertFalse(m.savedRepos.contains { $0.hasPrefix("me/") })
        m.toggleOwner("me")
        XCTAssertFalse(m.isTracked("me/Alpha"), "all goes to none")
    }

    func testCap() {
        let names = (0..<30).map { String(format: "big/r%02d", $0) }
        var m = RepoListModel(catalog: [("big", names)], picked: ["big/r25"], orgs: [], hooks: nil)
        var g = m.groups[0]
        XCTAssertEqual(g.repos.count, RepoListModel.firstRows)
        XCTAssertEqual(g.hidden, 30 - RepoListModel.firstRows)
        XCTAssertTrue(g.repos.contains { $0.name == "big/r25" }, "a tracked repo takes the cap first")
        XCTAssertEqual(g.repos.map(\.name), g.repos.map(\.name).sorted(), "the rows keep the name order")
        m.showMore("big")
        g = m.groups[0]
        XCTAssertEqual(g.repos.count, 30)
        XCTAssertEqual(g.hidden, 0)
        XCTAssertEqual(m.counts[.all], 30, "the counts ignore the cap")
    }
}
