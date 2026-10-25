import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
import RuntimeDaemon
@testable import OverSireApp

/// Queue and item starts send work:<KEY>. Two apps that start one item get one session (OVERSIRE-326).
final class StartKeyTests: XCTestCase {
    private let ref = ProjectRef(workspace: "ocral", id: "p1")
    private var dir: URL!
    private var savedRoot: String?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("start-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let item = Item(id: "2", key: "OVERSIRE-2", title: "Two", url: "https://plane.example/OVERSIRE-2", statusOptionId: "t", fields: [:], assignees: [],
                        labels: [], author: "ada", updatedBy: "ada", updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [], items: [item], fetchedAt: Date(), me: "ada")
        let disk: [String: Any] = ["snapshots": [ref.storeKey: try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap))],
                                   "readActivity": [], "readItems": []]
        try JSONSerialization.data(withJSONObject: disk).write(to: dir.appendingPathComponent("state.json"))
        savedRoot = PROJECTS_CFG.orca.roots[ref.storeKey]
        PROJECTS_CFG.orca.roots[ref.storeKey] = "/Users/ada/Projects/oversire"
    }

    override func tearDown() async throws {
        PROJECTS_CFG.orca.roots[ref.storeKey] = savedRoot
        try? FileManager.default.removeItem(at: dir)
    }

    /// One app: its own store and agent index on the shared daemon.
    @MainActor
    private func app(_ host: LocalMachineRuntime, _ n: Int) -> (WorkQueue, AgentIndex) {
        let sub = dir.appendingPathComponent("app-\(n)")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: dir.appendingPathComponent("state.json"), to: sub.appendingPathComponent("state.json"))
        let writes = StoreWrites(store: LocalStore(dir: sub))
        let projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                    statePath: sub.path + "/state.json", activityPath: sub.path + "/activity.jsonl")
        let agents = AgentIndex(writes: writes)
        agents.runtime = { host }
        agents.hold = true
        return (WorkQueue(writes: writes, store: projects, agents: agents), agents)
    }

    private func host(_ d: FakeDaemon) async throws -> LocalMachineRuntime {
        let h = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: d), pause: { _ in })
        _ = try await h.refresh()
        return h
    }

    private func start(_ agents: AgentIndex) async -> Result<Launch, ProviderError> {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                let it = Item(id: "2", key: "OVERSIRE-2", title: "Two", url: "", statusOptionId: "t", fields: [:], assignees: [], labels: [],
                              author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
                agents.start(it, root: "/Users/ada/Projects/oversire") { c.resume(returning: $0) }
            }
        }
    }

    func testTwoQueuesStartOneSession() async throws {
        let daemon = FakeDaemon()
        let h = try await host(daemon)
        let (a, b) = await MainActor.run { (app(h, 1), app(h, 2)) }
        await MainActor.run {
            for (q, _) in [a, b] {
                XCTAssertTrue(q.add(key: "OVERSIRE-2"))
                XCTAssertNil(q.start("OVERSIRE-2", project: ref.storeKey))
                XCTAssertFalse(q.contains("OVERSIRE-2"), "the entry is started")
                XCTAssertEqual(q.state(ref.storeKey)?.lastStarted, "OVERSIRE-2")
                XCTAssertNil(q.state(ref.storeKey)?.error)
            }
        }
        for _ in 0..<100 where daemon.runtime.orders.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        let keys = daemon.runtime.orders.compactMap { o -> String? in if case .start(let r) = o.order { return r.key } else { return nil } }
        XCTAssertEqual(keys, ["work:OVERSIRE-2", "work:OVERSIRE-2"])
        XCTAssertEqual(daemon.sessions.count, 1, "the second start gets the live session")
    }

    func testManualStartOpensTheLiveKeyedSession() async throws {
        let daemon = FakeDaemon()
        let h = try await host(daemon)
        let (_, first) = await MainActor.run { app(h, 1) }
        let (_, other) = await MainActor.run { app(h, 2) }
        let one = try await start(first).get()
        let two = try await start(other).get()
        XCTAssertEqual(two.paneKey, one.paneKey)
        XCTAssertEqual(daemon.sessions.count, 1)
        let last = await MainActor.run { other.lastStarted }
        XCTAssertEqual(last, "OVERSIRE-2", "the item links to the live session, with no error")
    }

    func testAWorkKeyNamesTheItem() {
        let g = AgentSession(phase: .working, since: Date(), card: "c1", paneKey: "tab-1:leaf-1", key: StartKey.work("oversire-2"))
        let c = Workspace(id: "c1", repo: "oversire", path: "/Users/ada/Projects/oversire", name: "oversire", comment: nil, liveTerminals: 1,
                          lastActivity: Date(), agents: [g], kind: .folder)
        XCTAssertEqual(AgentIndex.index([c], launches: [:], now: Date()).keys.sorted(), ["OVERSIRE-2"])
        XCTAssertEqual(StartKey.workItem("enhance:OVERSIRE-2"), nil)
    }
}
