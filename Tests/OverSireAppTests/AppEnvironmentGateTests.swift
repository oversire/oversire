import XCTest
import OverSireCore
import TrackerBigTimer
@testable import OverSireApp

/// The first Plane adapter of an account makes its rate gate. The gate reads the budget, which takes the same lock.
final class AppEnvironmentGateTests: XCTestCase {
    func testTheFirstPlaneGateDoesNotDeadlock() {
        let env = AppEnvironment()
        let made = expectation(description: "io")
        Thread.detachNewThread {
            _ = env.io(.plane, account: AccountID(provider: .plane, id: "ocral"))
            _ = env.io(.plane, account: AccountID(provider: .plane, id: "ocral"))
            made.fulfill()
        }
        wait(for: [made], timeout: 5)
    }

    private let plane = AccountConfig(account: AccountID(provider: .plane, id: "ocral"), values: ["workspace": "ocral"])
    private let timer = AccountConfig(account: AccountID(provider: .bigtimer, id: "bt.example.com"), values: ["server": "https://bt.example.com"])

    func testBigTimerIsRegistered() throws {
        let d = try XCTUnwrap(AppEnvironment().registry.descriptor(.bigtimer))
        XCTAssertEqual(d.layer, .tracker)
        XCTAssertEqual(d.displayName, "Big Timer")
    }

    func testTrackerNames() {
        let env = AppEnvironment()
        XCTAssertEqual(env.trackerNames(), "your tracker")
        env.load([plane])
        XCTAssertEqual(env.trackerNames(), "Plane")
        env.load([plane, timer])
        XCTAssertEqual(env.trackerNames(), "Plane or Big Timer")
        XCTAssertEqual(env.trackerName(timer.account), "Big Timer")
        env.load([plane, timer, AccountConfig(account: AccountID(provider: .plane, id: "other"))])
        XCTAssertEqual(env.trackerNames(), "Plane or Big Timer", "each name shows once")
    }

    func testRemoveDropsTrackerPicks() {
        let (accounts, projects) = (ACCOUNTS, PROJECTS_CFG)
        defer { ACCOUNTS = accounts; PROJECTS_CFG = projects }
        let env = AppEnvironment()
        ACCOUNTS = [plane, timer]
        PROJECTS_CFG.allOf = ["ocral", "bt.example.com"]
        PROJECTS_CFG.picked = ["ocral/\(UUID().uuidString)", "bt.example.com/\(UUID().uuidString)"]
        env.remove(timer.account)
        XCTAssertEqual(PROJECTS_CFG.allOf, ["ocral"])
        XCTAssertEqual(PROJECTS_CFG.picked.count, 1)
        XCTAssertTrue(PROJECTS_CFG.picked[0].hasPrefix("ocral/"))
        XCTAssertEqual(ACCOUNTS.map(\.account), [plane.account])
    }

    func testDropStaleKeepsTrackerPicks() throws {
        let id = UUID().uuidString
        var cfg = try JSONDecoder().decode(ProjectsConfig.self, from: Data("""
        {"picked":["bt.example.com/\(id)","gone/\(id)","owner/3"],"allOf":["bt.example.com","gone"]}
        """.utf8))
        XCTAssertEqual(cfg.picked, ["bt.example.com/\(id)", "gone/\(id)"], "a GitHub pick drops at decode")
        cfg.dropStale(trackers: ["bt.example.com"])
        XCTAssertEqual(cfg.picked, ["bt.example.com/\(id)"])
        XCTAssertEqual(cfg.allOf, ["bt.example.com"])
    }

    func testFeedFilterMapsPlaneSource() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "oversire-feed-filter-\(UUID().uuidString)"))
        d.set(["Plane", "GitHub"], forKey: "activity.filter.sources")
        XCTAssertEqual(FeedFilter.load(d).sources, ["Tracker", "GitHub"])
    }
}
