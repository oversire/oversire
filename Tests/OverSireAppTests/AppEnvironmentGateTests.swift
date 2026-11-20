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

    func testBigTimerGetsAStreamingTransport() {
        let env = AppEnvironment()
        XCTAssertNotNil(env.io(.bigtimer, account: timer.account).streaming)
        XCTAssertNil(env.io(.plane, account: plane.account).streaming)
        XCTAssertTrue(env.hasLiveFeed(timer.account))
        XCTAssertFalse(env.hasLiveFeed(plane.account))
    }

    func testTokenEditDropsTheCachedAdapter() {
        let accounts = ACCOUNTS
        let service = "com.oversire.test.\(UUID().uuidString)"
        let secrets = KeychainSecrets(accountsService: service)
        defer {
            ACCOUNTS = accounts
            secrets.delete(AppEnvironment.secretKey(timer.account, field: "token"))
        }
        let env = AppEnvironment(secrets: secrets)
        var saved: [AccountID] = []
        env.onSecretSaved = { saved.append($0) }
        env.save(timer, secrets: ["token": "btk_one"])
        XCTAssertEqual(saved, [timer.account])
        env.load(ACCOUNTS)
        let first = env.provider(timer.account) as? BigTimerTracker
        XCTAssertNotNil(first)
        XCTAssertTrue(first === (env.provider(timer.account) as? BigTimerTracker), "the adapter is cached")
        env.save(timer, secrets: ["token": "btk_two"])
        XCTAssertEqual(saved.count, 2)
        let second = env.provider(timer.account) as? BigTimerTracker
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "a new token makes a new adapter")
        env.save(timer, secrets: [:])
        XCTAssertEqual(saved.count, 2, "an edit with no new token keeps the adapter")
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

    func testMirroredCapabilities() {
        let env = AppEnvironment()
        XCTAssertFalse(env.has(.rerun))
        let summary = ProjectSummary(ref: ProjectRef(account: AccountID(provider: .plane, id: "ws"), id: "p"), identifier: "P", title: "P", url: "", closed: false)
        env.mirrored = ClientCatalog(projects: [CatalogProject(summary: summary, capabilities: [.links])],
                                     capabilities: ["ci": [.rerun], "tracker": [.links]], trackers: ["ws"])
        XCTAssertTrue(env.has(.rerun))
        XCTAssertTrue(env.capabilities(.tracker).contains(.links))
        XCTAssertFalse(env.capabilities(.ci).contains(.links))
        env.mirrored = ClientCatalog(projects: [], capabilities: [:], trackers: [])
        XCTAssertFalse(env.has(.rerun))
    }
}
