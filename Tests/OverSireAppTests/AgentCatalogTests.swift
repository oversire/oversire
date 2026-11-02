import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

/// Shared agents in the home store, agents of one Mac, the env of a start and the secrets on home (OVERSIRE-399).
@MainActor
final class AgentCatalogTests: XCTestCase {
    private var root: URL!
    private let hub = FakeStoreHub()
    private let at = Date(timeIntervalSince1970: 1_793_650_000)

    private final class App {
        let store: SyncedStore
        let writes: StoreWrites
        let catalog: AgentCatalog
        var cfg = RuntimeConfig()
        var events: [(String, [String: JSONValue])] = []

        init(store: SyncedStore, name: String, at: Date) {
            self.store = store
            writes = StoreWrites(store: store)
            catalog = AgentCatalog(writes: writes)
            catalog.config = { [unowned self] in self.cfg }
            catalog.setConfig = { [unowned self] in self.cfg = $0 }
            catalog.machine = { name }
            catalog.now = { at }
            catalog.record = { [unowned self] s, p in self.events.append((s, p)) }
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID().uuidString)")
        RuntimeConfig.shared = SharedAgents()
    }

    override func tearDown() async throws {
        RuntimeConfig.shared = SharedAgents()
        try? FileManager.default.removeItem(at: root)
    }

    private func app(_ name: String) throws -> App {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SyncedStore(local: LocalStore(dir: dir.appendingPathComponent("store")), replication: hub.replication(), device: name,
                                dir: dir.appendingPathComponent("sync"), cursors: CursorStore(url: dir.appendingPathComponent("cursors.json")),
                                autoSync: false)
        return App(store: store, name: name, at: at)
    }

    /// Waits for the queued writes, sends them, and reads them in `to` as the watch of a remote change does.
    private func sync(_ from: App, _ to: App, until: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            await from.store.sync()
            await to.store.sync()
            to.writes.changed(AgentDef.collection)
            if until() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("no sync")
    }

    private let maxDef = AgentDef(name: "claude-max", cli: "claude", model: "claude-opus-5-5", effort: "max",
                                  env: [EnvVar(key: "PLANE_ITEM", value: "{KEY}"), EnvVar(key: "PLANE_API_TOKEN", secret: true)])

    // MARK: Sync and merge

    func testASharedAgentReachesTheOtherMac() async throws {
        let mba = try app("mba"), mini = try app("mini")
        try mba.catalog.save(maxDef, scope: .shared)
        XCTAssertEqual(mba.events.last?.1, ["agent": .string("claude-max"), "scope": .string("shared"), "action": .string("saved")])

        try await sync(mba, mini) { mini.catalog.shared.count == 1 }
        let got = try XCTUnwrap(mini.catalog.shared.first)
        XCTAssertEqual(got.def.model, "claude-opus-5-5")
        XCTAssertEqual(got.def.updatedBy, "mba", "edited on mba")
        XCTAssertEqual(got.def.updatedAt, at)
        XCTAssertNil(got.def.env[1].value, "a secret row has no value in the store")
        XCTAssertTrue(mini.cfg.agents.contains("claude-max"), "the start menus list a shared agent")
        XCTAssertEqual(mini.cfg.profile("claude-max").model, "claude-opus-5-5")
    }

    func testASaveWithNoChangeWritesNothing() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .shared)
        try mba.catalog.save(maxDef, scope: .shared)
        XCTAssertEqual(mba.events.count, 1)
    }

    func testTheLocalAgentWinsOnThisMac() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .shared)
        var mine = maxDef
        mine.model = "claude-sonnet-5-5"
        mine.env = []
        try mba.catalog.save(mine, scope: .local)

        XCTAssertEqual(mba.catalog.shared.map(\.shadowed), [true])
        XCTAssertEqual(mba.catalog.local.map(\.name), ["claude-max"])
        let l = mba.cfg.launch("claude-max", name: "ENG-4", key: "ENG-4", title: "t", device: "app-1")
        XCTAssertEqual(l.model, "claude-sonnet-5-5")
        XCTAssertTrue(l.env.isEmpty, "the env of the shared agent does not apply")
        XCTAssertTrue(l.envSecrets.isEmpty)
    }

    func testABadEnvDoesNotSave() throws {
        let mba = try app("mba")
        var d = maxDef
        d.env = [EnvVar(key: "OVERSIRE_SESSION", value: "x")]
        XCTAssertThrowsError(try mba.catalog.save(d, scope: .shared)) { e in
            XCTAssertEqual(e as? CatalogError, .env([.reserved("OVERSIRE_SESSION")]))
        }
        XCTAssertTrue(mba.catalog.shared.isEmpty)
        XCTAssertTrue(mba.events.isEmpty)
    }

    func testShareAndKeepLocalMoveTheAgent() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .local)
        XCTAssertTrue(mba.cfg.isLocal("claude-max"))

        let again = try mba.catalog.share("claude-max")
        XCTAssertEqual(again, ["PLANE_API_TOKEN"], "a secret value stays under the scope of this Mac")
        XCTAssertFalse(mba.cfg.isLocal("claude-max"))
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["claude-max"])
        XCTAssertEqual(mba.events.last?.1["action"], .string("moved"))

        try mba.catalog.keepLocal("claude-max")
        XCTAssertTrue(mba.catalog.shared.isEmpty)
        XCTAssertEqual(mba.cfg.localDef("claude-max")?.env, maxDef.env)
        XCTAssertEqual(mba.cfg.localDef("claude-max")?.model, "claude-opus-5-5")
    }

    func testDuplicateAndRemove() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .shared)
        try mba.catalog.duplicate("claude-max", scope: .shared, as: "claude-fast")
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["claude-fast", "claude-max"])
        XCTAssertThrowsError(try mba.catalog.duplicate("claude-max", scope: .shared, as: "claude-fast"))
        mba.catalog.remove("claude-fast", scope: .shared)
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["claude-max"])
        XCTAssertEqual(mba.events.last?.1["action"], .string("removed"))
    }

    func testTheShareOffer() throws {
        let mba = try app("mba")
        mba.cfg.setProfile("claude", AgentProfile(cli: "claude"))
        XCTAssertFalse(mba.catalog.needsShareOffer, "a built-in CLI at its defaults is not an offer")
        mba.cfg.add("pi-fast", cli: "pi")
        XCTAssertTrue(mba.catalog.needsShareOffer)
        try mba.catalog.shareAll()
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["pi-fast"])
        XCTAssertFalse(mba.catalog.needsShareOffer)
        XCTAssertTrue(mba.cfg.shareOfferClosed)
    }

    // MARK: Launch

    func testALaunchHasTheMergedEnvAndTheSecretRefs() throws {
        let mba = try app("mba")
        try mba.catalog.saveAllEnv([EnvVar(key: "GIT_AUTHOR_NAME", value: "Ada"), EnvVar(key: "PLANE_ITEM", value: "all"),
                                    EnvVar(key: "GH_TOKEN", secret: true)])
        try mba.catalog.save(maxDef, scope: .shared)
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["claude-max"], "the env for all agents is not an agent")

        let l = mba.cfg.launch("claude-max", name: "ENG-4", key: "ENG-4", title: "Fix it", device: "app-1")
        XCTAssertEqual(l.env, ["GIT_AUTHOR_NAME": "Ada", "PLANE_ITEM": "ENG-4"])
        XCTAssertEqual(l.envSecrets, ["PLANE_API_TOKEN": AgentSecretRef(agent: "claude-max", scope: "shared"),
                                      "GH_TOKEN": AgentSecretRef(agent: "*", scope: "shared")])
        var req = LaunchRequest(repo: "/r", agent: .claude, prompt: "p")
        req.apply(l)
        XCTAssertEqual(req.env?["PLANE_ITEM"], "ENG-4")
        XCTAssertEqual(req.envSecrets?.count, 2)

        let spec = l.spec(command: "claude")
        XCTAssertEqual(spec.env, l.env)
        XCTAssertEqual(spec.envSecrets, l.envSecrets)
    }

    func testALocalAgentKeepsItsSecretsUnderTheDevice() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .local)
        let l = mba.cfg.launch("claude-max", name: "ENG-4", key: "ENG-4", title: "t", device: "app-1")
        XCTAssertEqual(l.envSecrets["PLANE_API_TOKEN"], AgentSecretRef(agent: "claude-max", scope: "app-1"))
    }

    func testAnAgentWithNoEnvSendsNone() {
        let l = RuntimeConfig().launch("claude", name: "ENG-4", key: "ENG-4", title: "t", device: "app-1")
        var req = LaunchRequest(repo: "/r", agent: .claude, prompt: "p")
        req.apply(l)
        XCTAssertNil(req.env)
        XCTAssertNil(req.envSecrets)
        XCTAssertFalse(l.hasEnv)
    }

    func testRunsOnRefusesOtherMachines() throws {
        let mba = try app("mba")
        var d = maxDef
        d.runsOn = ["mini"]
        try mba.catalog.save(d, scope: .shared)
        let l = mba.cfg.launch("claude-max", name: "ENG-4", key: "ENG-4", title: "t", device: "app-1")
        XCTAssertNil(l.refusal(on: "mini"))
        XCTAssertEqual(l.refusal(on: "mba"), "claude-max runs only on mini. Run sessions on is mba.")
        XCTAssertNil(l.withoutEnv.refusal(on: "mini"))
        XCTAssertFalse(l.withoutEnv.hasEnv)
        XCTAssertEqual(mba.cfg.refusal("claude-max", on: "mba"), "claude-max runs only on mini. Run sessions on is mba.")
        mba.cfg.add("pi-fast", cli: "pi")
        mba.cfg.runsOn["pi-fast"] = ["mba"]
        XCTAssertNil(mba.cfg.refusal("pi-fast", on: "mba"))
        XCTAssertNotNil(mba.cfg.refusal("pi-fast", on: "mini"))
    }

    func testShareSomeNames() throws {
        let mba = try app("mba")
        try mba.catalog.save(maxDef, scope: .local)
        mba.cfg.add("pi-fast", cli: "pi")
        let again = try mba.catalog.share(["claude-max"])
        XCTAssertEqual(again, ["claude-max": ["PLANE_API_TOKEN"]])
        XCTAssertEqual(mba.catalog.shared.map(\.name), ["claude-max"])
        XCTAssertTrue(mba.cfg.isLocal("pi-fast"), "an agent that was not picked stays on this Mac")
        XCTAssertFalse(mba.catalog.needsShareOffer, "a pick closes the offer")
    }

    func testTheSharedCommandIsUsed() throws {
        let mba = try app("mba")
        try mba.catalog.save(AgentDef(name: "pi-fast", cli: "pi", command: "pi --fast -n {name}"), scope: .shared)
        let l = mba.cfg.launch("pi-fast", name: "ENG-4", key: "ENG-4", title: "t", device: "app-1")
        XCTAssertEqual(l.cli, "pi")
        XCTAssertEqual(l.command, "pi --fast -n ENG-4")
    }

    // MARK: Secrets

    func testSecretsGoToHomeAndNeverComeBack() async throws {
        let home = FakeDaemon(machine: "mini")
        let client = DaemonClient(base: URL(string: "http://mini:7690")!, token: nil, http: home)
        let s = AgentSecrets(device: "app-1") { .success(("mini", client)) }
        try await s.set("claude-max", scope: .shared, key: "PLANE_API_TOKEN", value: "line1\n\"q\" $X")
        try await s.set("mine", scope: .local, key: "T", value: "v")
        XCTAssertEqual(home.secrets["shared/claude-max/PLANE_API_TOKEN"], "line1\n\"q\" $X")
        XCTAssertEqual(home.secrets["app-1/mine/T"], "v")

        let list = try await s.list()
        XCTAssertEqual(list.machine, "mini")
        XCTAssertEqual(list.keys.map(\.key), ["T", "PLANE_API_TOKEN"])
        try await s.remove("mine", scope: .local, key: "T")
        XCTAssertNil(home.secrets["app-1/mine/T"])
        XCTAssertFalse(home.requests.contains { $0.url?.absoluteString.contains("line1") ?? false }, "the value is not in the URL")
    }

    func testNoHomeIsAClearError() async {
        let s = AgentSecrets(device: "app-1") { .failure(.homeOffline("mini")) }
        do {
            try await s.set("a", scope: .shared, key: "K", value: "v")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The home daemon on mini does not answer. Try again when mini is online.")
        }
    }
}
