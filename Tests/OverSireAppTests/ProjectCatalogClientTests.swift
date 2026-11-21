import OverSireCore
import XCTest
@testable import OverSireApp

/// A client picks projects from the catalog of the home (OVERSIRE-534).
final class ProjectCatalogClientTests: XCTestCase {
    private final class Dir: TrackerDirectory {
        var trackerIds: [String] { [] }
        func tracker(_ id: String) -> (any Tracker)? { nil }
        func trackerError(_ id: String) -> String? { nil }
    }

    private func summary(_ n: Int, ws: String = "w1", closed: Bool = false) -> ProjectSummary {
        ProjectSummary(ref: ProjectRef(account: AccountID(provider: "plane", id: ws), id: "p\(n)", key: "P\(n)"), identifier: "P\(n)",
                       title: "Project \(n)", url: "https://x/P\(n)", closed: closed)
    }

    private func client(allOf: [String] = [], workspaces: [CatalogWorkspace]?) -> ProjectCatalog {
        let c = ProjectCatalog(trackers: Dir(), path: NSTemporaryDirectory() + "plane-cache-\(UUID().uuidString).json")
        c.mirrored = ClientCatalog(projects: [], capabilities: [:], trackers: ["w1"], workspaces: workspaces)
        return c
    }

    func testClientWorkspacesComeFromTheMirror() {
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: [summary(1), summary(2)]), CatalogWorkspace(id: "w2", projects: [summary(3, ws: "w2")])])
        XCTAssertEqual(c.workspaces, ["w1", "w2"])
        XCTAssertEqual(c.projects(of: "w1").map(\.identifier), ["P1", "P2"])
        XCTAssertEqual(c.projects(of: "none"), [])
        XCTAssertEqual(c.project(key: "p3")?.ref.account.id, "w2")
    }

    func testAnOldHomeGivesNoWorkspaces() {
        let c = client(workspaces: nil)
        XCTAssertEqual(c.workspaces, [])
        XCTAssertNil(c.project(key: "P1"))
    }

    func testClientFetchStateComesFromTheMirrorError() {
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: [], error: "Plane is down"), CatalogWorkspace(id: "w2", projects: [])])
        guard case .failed("Plane is down") = c.fetch("w1") else { return XCTFail("a mirrored error shows") }
        XCTAssertTrue(c.fetch("w2").isIdle)
    }

    func testANewMirroredCatalogNotifies() {
        let c = client(workspaces: [])
        let seen = expectation(description: "changed")
        let token = NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: c, queue: nil) { _ in seen.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        c.mirrored = ClientCatalog(projects: [], capabilities: [:], trackers: [], workspaces: [CatalogWorkspace(id: "w1", projects: [summary(1)])])
        wait(for: [seen], timeout: 1)
    }

    func testClientToggleInAllOfKeepsTheOtherProjects() {
        let open = [summary(1), summary(2), summary(3)]
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: open)])
        var cfg = ProjectsConfig()
        cfg.allOf = ["w1"]
        let out = ProjectListView.toggled(cfg, key: open[0].ref.storeKey, on: false, catalog: c)
        XCTAssertEqual(out.allOf, [])
        XCTAssertEqual(Set(out.picked), [open[1].ref.storeKey, open[2].ref.storeKey])
    }

    func testToggleOnAndOffOutsideAnAllOfWorkspace() {
        let open = [summary(1), summary(2)]
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: open)])
        let on = ProjectListView.toggled(ProjectsConfig(), key: open[0].ref.storeKey, on: true, catalog: c)
        XCTAssertEqual(on.picked, [open[0].ref.storeKey])
        let off = ProjectListView.toggled(on, key: open[0].ref.storeKey, on: false, catalog: c)
        XCTAssertEqual(off.picked, [])
    }

    func testClientRefreshForwardsCatalogRefresh() {
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: [])])
        var asked: [String?] = []
        var finish: ((String?) -> Void)?
        c.forwardRefresh = { w, done in
            asked.append(w)
            finish = done
        }
        c.refresh("w1", force: true)
        XCTAssertEqual(asked, ["w1"])
        guard case .loading = c.fetch("w1") else { return XCTFail("the refresh runs") }
        XCTAssertTrue(c.refreshing)
        finish?("Plane is offline")
        guard case .failed("Plane is offline") = c.fetch("w1") else { return XCTFail("the failure shows") }
        c.refresh("w1", force: true)
        finish?(nil)
        XCTAssertTrue(c.fetch("w1").isIdle)
    }

    func testClientRefreshAllAndLookUpForwardOnce() {
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: []), CatalogWorkspace(id: "w2", projects: [])])
        var asked: [String?] = []
        c.forwardRefresh = { w, _ in asked.append(w) }
        c.refreshAll(force: true)
        XCTAssertEqual(asked, [nil])
        XCTAssertTrue(c.lookUp("NEW"))
        XCTAssertFalse(c.lookUp("new"))
        XCTAssertEqual(asked, [nil, nil])
    }

    func testAnOldRefreshAnswerDoesNotOverrideANewerOne() {
        let c = client(workspaces: [CatalogWorkspace(id: "w1", projects: [])])
        var finish: [(String?) -> Void] = []
        c.forwardRefresh = { _, done in finish.append(done) }
        c.refresh("w1", force: true)
        c.refresh("w1", force: true)
        finish[0]("old")
        guard case .loading = c.fetch("w1") else { return XCTFail("the newer refresh still runs") }
        finish[1](nil)
        XCTAssertTrue(c.fetch("w1").isIdle)
    }

    /// The picks of a client go to the home as one `settings.patch` of the projects section.
    func testClientSaveSyncsPicks() async throws {
        final class Calls: @unchecked Sendable { var sent: [MemberCallRequest] = [] }
        var base = ProjectsConfig()
        base.allOf = ["w1"]
        var before = AppConfig(repos: [])
        before.projects = base
        let home = homeSettings(from: before)
        let open = [summary(1), summary(2)]
        let catalog = client(workspaces: [CatalogWorkspace(id: "w1", projects: open)])
        var after = AppConfig(repos: [])
        after.projects = ProjectListView.toggled(base, key: open[0].ref.storeKey, on: false, catalog: catalog)
        let mine = homeSettings(from: after)

        let cs = ClientSettings()
        let calls = Calls()
        cs.current = { mine }
        cs.adopt = { _ in }
        cs.changed = {}
        cs.sent = {}
        cs.call = { req in
            calls.sent.append(req)
            return AppCallResult(id: "1", status: .ok, summary: "saved")
        }
        cs.received(try MirrorCodec.body(home))
        cs.current = { mine }
        cs.sync()
        for _ in 0..<400 where cs.state != .idle { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(calls.sent.count, 1)
        XCTAssertEqual(calls.sent[0].action, "settings.patch")
        XCTAssertEqual(calls.sent[0].args["section"]?.string, "projects")
        let shared = try MirrorCodec.value(ProjectsShared.self, from: try XCTUnwrap(calls.sent[0].args["value"]))
        XCTAssertEqual(shared.picked, [open[1].ref.storeKey])
        XCTAssertEqual(shared.allOf, [])
    }
}
