import XCTest
@testable import OverSireApp

final class SettingsRouteTests: XCTestCase {
    private func open(_ s: String) -> Route? { Route(url: URL(string: s)!) }

    func testOldSlugsOpenTheirNewHome() {
        let cases: [(String, Route)] = [
            ("providers", .settings(.accounts)),
            ("live", .settings(.accounts, anchor: "live")),
            ("repos", .settings(.projects, tab: .repos)),
            ("linking", .settings(.projects, tab: .linking)),
            ("writeback", .settings(.projects, tab: .linking, anchor: "writeback")),
            ("runtime", .settings(.agents)),
            ("orca", .settings(.agents)),
            ("queue", .settings(.agents, anchor: "queue")),
            ("planner", .settings(.agents, anchor: "planner")),
            ("menubar", .settings(.general, anchor: "menubar")),
            ("shortcuts", .settings(.general, anchor: "shortcuts")),
        ]
        for (slug, want) in cases {
            XCTAssertEqual(open("oversire://settings/\(slug)"), want, slug)
            XCTAssertEqual(open("oversire://settings/\(slug.uppercased())"), want, "case does not matter: \(slug)")
        }
    }

    func testOldLinksOpenTheWorkTabs() {
        let cases: [(String, Route)] = [
            ("mine", .work(.items)), ("sessions", .work(.worktrees)), ("agents", .work(.worktrees)),
            ("queue", .work(.lanes)), ("plan", .work(.lanes)),
        ]
        for (path, want) in cases { XCTAssertEqual(open("oversire://\(path)"), want, path) }
    }

    func testCrumbsDoNotRepeatTheTitle() {
        XCTAssertEqual(Route.item("OVERSIRE-131", .overview).crumbs, ["Projects", "OVERSIRE"])
        XCTAssertEqual(Route.run(repo: "oversire/oversire", id: "9").crumbs, ["Runs", "oversire/oversire"])
        XCTAssertEqual(Route.run(repo: "oversire/oversire", id: "9").title, "Run 9")
        XCTAssertEqual(Route.settings(.ai).title, "AI")
        XCTAssertTrue(Route.home.crumbs.isEmpty)
        for r in Route.samples { XCTAssertFalse(r.crumbs.contains(r.title), "\(r)") }
    }

    func testNewPagesKeepTheirSlug() {
        for p in Route.SettingsPage.allCases {
            XCTAssertEqual(open("oversire://settings/\(p.rawValue)"), .settings(p), p.rawValue)
        }
        XCTAssertEqual(open("oversire://settings/accounts"), .settings(.accounts), "accounts is now its own page")
        XCTAssertEqual(open("oversire://settings"), .settings(.general))
        XCTAssertEqual(open("oversire://settings/nope"), .settings(.general))
    }

    func testTabsAndAnchors() {
        XCTAssertEqual(open("oversire://settings/projects/repos"), .settings(.projects, tab: .repos))
        XCTAssertEqual(open("oversire://settings/projects/linking/writeback"), .settings(.projects, tab: .linking, anchor: "writeback"))
        XCTAssertEqual(open("oversire://settings/projects/nope"), .settings(.projects, anchor: "nope"), "an unknown tab is an anchor")
        XCTAssertEqual(open("oversire://settings/agents#queue"), .settings(.agents, anchor: "queue"))
        XCTAssertEqual(open("oversire://settings/agents/queue"), .settings(.agents, anchor: "queue"))
        XCTAssertEqual(open("oversire://settings/repos#problems"), .settings(.projects, tab: .repos, anchor: "problems"))
    }

    func testRoundTrip() {
        let routes: [Route] = Route.SettingsPage.allCases.map { .settings($0) }
            + Route.SettingsTab.allCases.map { .settings(.projects, tab: $0) }
            + [.settings(.agents, anchor: "queue"), .settings(.projects, tab: .linking, anchor: "writeback")]
        for r in routes {
            XCTAssertEqual(Route(url: r.url), r, r.path)
            XCTAssertEqual(Route(path: r.path), r, r.path)
        }
        XCTAssertEqual(Route.settings(.projects, tab: .repos).path, "settings/projects/repos")
    }

    func testTabChangeReplacesTheHistoryEntry() {
        let router = Router()
        router.go(.home)
        router.go(.settings(.projects, tab: .projects))
        router.go(.settings(.projects, tab: .repos))
        XCTAssertEqual(router.current, .settings(.projects, tab: .repos))
        router.back()
        XCTAssertEqual(router.current, .home)
    }
}
