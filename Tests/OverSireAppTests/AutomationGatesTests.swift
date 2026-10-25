import XCTest
import OverSireCore
import OverSireAI
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

/// Each automatic action asks mayAct after its own checks. False: no start, no write, no AI call (OVERSIRE-325).
@MainActor
final class AutomationGatesTests: XCTestCase {
    private var dir: URL!
    private var writes: StoreWrites!
    private var projects: ProjectStore!
    private var agents: AgentIndex!
    private var asked = 0
    private var savedAgents = AGENTS
    private var savedAI = AI_CFG

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedAgents = AGENTS
        savedAI = AI_CFG
        writes = StoreWrites(store: LocalStore(dir: dir))
        projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        agents = AgentIndex(writes: nil)
        let rt = FakeRuntime()
        agents.runtime = { rt }
        asked = 0
    }

    override func tearDown() async throws {
        AGENTS = savedAgents
        AI_CFG = savedAI
        try? FileManager.default.removeItem(at: dir)
    }

    private func no() -> Bool {
        asked += 1
        return false
    }

    func testQueueAsksBeforeItStarts() {
        AGENTS.autoStart = true
        let q = WorkQueue(writes: writes, store: projects, agents: agents)
        q.mayAct = { [unowned self] in self.no() }
        q.tick(workstreams: WorkstreamIndex())
        XCTAssertEqual(asked, 1)
    }

    func testCleanerAsksBeforeItRemoves() {
        AGENTS.cleanup.auto = true
        let c = Cleaner(defaults: UserDefaults(suiteName: "oversire-tests")!)
        c.mayAct = { [unowned self] in self.no() }
        c.sweep(TestAppData())
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(c.running.isEmpty)
    }

    func testWriteBackAsksBeforeItWrites() {
        AGENTS.writeBack.enabled = true
        let w = PlaneWriteBack(path: dir.path + "/writeback.json", store: projects, trackers: ENV)
        w.mayAct = { [unowned self] in self.no() }
        w.sync([])
        XCTAssertEqual(asked, 1)
    }

    func testSessionNotesAskBeforeTheComment() {
        AI_CFG.sessionSummary = true
        AGENTS.writeBack.enabled = true
        AGENTS.writeBack.sessionComment = true
        let w = PlaneWriteBack(path: dir.path + "/writeback.json", store: projects, trackers: ENV)
        let n = SessionNotes(path: dir.path + "/sessions.json", agents: agents, store: projects, writeBack: w)
        n.mayAct = { [unowned self] in self.no() }
        n.tick()
        XCTAssertEqual(asked, 1)
    }

    func testCIDigestWaitsForTheOwner() {
        AI_CFG.digest = true
        AI_CFG.digestHour = 0
        let cia = CIAssist(path: dir.path + "/ci-assist.json", ai: { nil })
        cia.mayAct = { false }
        XCTAssertFalse(cia.digestDue())
        cia.mayAct = { true }
        XCTAssertTrue(cia.digestDue())
    }
}
