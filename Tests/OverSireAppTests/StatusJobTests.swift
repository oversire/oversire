import XCTest
import OverSireCore
import OverSireAI
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

@MainActor
final class StatusJobTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var dir: URL!
    private var engine: FakeAIEngine!
    private var agents: AgentIndex!
    private var job: StatusJob!
    private var clock: Date!

    private let reply = #"{"state":"done","headline":"The page is merged.","done":["a","b","c","d","e"],"next":[],"needsYou":[],"blockedBy":["A-1","B-2"]}"#

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("status-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AGENTS.aiMode = .ask
        AI_CFG.agentChecks = true
        clock = t0
        engine = FakeAIEngine()
        engine.on(.status, .success(reply))
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                    statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        agents = AgentIndex(writes: nil)
        agents.hold = true
        agents.now = { [unowned self] in self.clock }
        job = StatusJob(path: dir.path + "/status.json", agents: agents,
                        queue: WorkQueue(writes: writes, store: projects, agents: agents))
        job.now = { [unowned self] in self.clock }
        job.ai = { [unowned self] in AIClient(cfg: AIConfig(), router: AIRouter(engines: [self.engine])) }
        world = (WorkstreamIndex(), projects)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private var world: (WorkstreamIndex, ProjectStore)!

    private func seed(_ phase: AgentSession.Phase, message: String?, fingerprint: String = "f1", same: TimeInterval = 0) {
        let a = AgentSession(phase: phase, since: t0, card: "c1", paneKey: "p1", message: message)
        var w = SessionWatch(at: clock.addingTimeInterval(-same))
        w.fingerprint = fingerprint
        w.readAt = clock
        agents.seed("A-1", a, watch: w)
    }

    private func tick() { job.tick(workstreams: world.0, store: world.1) }

    private func settle() {
        let done = expectation(forNotification: StatusJob.changed, object: job) { [unowned self] _ in self.job.reading.isEmpty }
        wait(for: [done], timeout: 5)
    }

    func testATurnEndReadsOnceForEachMessage() {
        seed(.done, message: "The page is merged.")
        tick()
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
        let s = job.status("A-1")
        XCTAssertEqual(s?.state, .done)
        XCTAssertEqual(s?.trigger, .turnEnd)
        XCTAssertEqual(s?.reply.done.count, 4, "the parse caps done at 4")
        XCTAssertEqual(s?.reply.blockedBy, ["B-2"], "the own key is dropped")
        XCTAssertEqual(s?.read, "Read the screen", "no runtime: the screen only")

        tick()
        clock = clock.addingTimeInterval(3600)
        tick()
        XCTAssertEqual(engine.tasks.count, 1, "the same screen and message get no second call")
        XCTAssertEqual(job.pending.map(\.key), ["A-1"])
    }

    // Session done does not mean the item is done. A Completed or Cancelled item gets no status.
    func testAClosedItemGetsNoStatus() throws {
        world = (WorkstreamIndex(), try projects(group: "cancelled"))
        seed(.done, message: "The page is merged.")
        job.tick(workstreams: world.0, store: world.1)
        XCTAssertTrue(engine.tasks.isEmpty)
        XCTAssertEqual(job.refreshable, [])

        world = (WorkstreamIndex(), try projects(group: "started"))
        job.tick(workstreams: world.0, store: world.1)
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
        XCTAssertEqual(job.refreshable, ["A-1"])
    }

    private func projects(group: String) throws -> ProjectStore {
        let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ws"), id: "p1", key: "A")
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "A", title: "A", url: "https://plane/a", closed: false),
                                   statusOptions: [StatusOption(id: "s1", name: group, color: "#000", group: group)],
                                   items: [Item(id: "i1", key: "A-1", title: "Page", url: "https://plane/A-1", statusOptionId: "s1", fields: [:],
                                                assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: t0, activityAt: t0,
                                                commentCount: 0, lastComment: nil, mentionsMe: false)],
                                   fetchedAt: t0)
        let path = dir.path + "/state-\(group).json"
        let disk: [String: AnyEncodable] = ["snapshots": AnyEncodable([ref.storeKey: snap]), "readActivity": AnyEncodable([String]()),
                                            "readItems": AnyEncodable([String]())]
        try JSONEncoder().encode(disk).write(to: URL(fileURLWithPath: path))
        let store = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: path, activityPath: dir.path + "/activity.jsonl")
        XCTAssertNotNil(store.item(key: "A-1"))
        return store
    }

    func testNoReadWhenAnotherAppOwnsTheAutomations() {
        seed(.done, message: "The page is merged.")
        job.mayAct = { false }
        tick()
        XCTAssertTrue(job.reading.isEmpty)
        XCTAssertEqual(engine.tasks.count, 0)
        job.mayAct = { true }
        tick()
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
    }

    func testIdleWaitsForTheQuietMinutes() {
        seed(.working, message: nil, same: 4 * 60)
        tick()
        XCTAssertTrue(engine.tasks.isEmpty, "4 min is not idle")
        seed(.working, message: nil, same: AGENTS.quietMinutes * 60 + 1)
        tick()
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
        XCTAssertEqual(job.status("A-1")?.trigger, .idle)

        seed(.working, message: nil, fingerprint: "f2", same: 60)
        XCTAssertNotNil(job.outOfDate(job.status("A-1")!), "a screen change puts the status out of date")
        tick()
        XCTAssertEqual(engine.tasks.count, 1, "each screen change starts the wait again")
    }

    func testWithoutAIOnlyTheBlockedHeuristicsRun() {
        job.ai = { nil }
        seed(.done, message: "Released.\n\nI need you for the manual check:\n- Take a capture on 2 displays\n- Send it to Orca")
        tick()
        let s = job.status("A-1")
        XCTAssertEqual(s?.state, .blocked)
        XCTAssertEqual(s?.byAI, false)
        XCTAssertEqual(s?.reply.needsYou.map(\.text), ["Take a capture on 2 displays", "Send it to Orca"])
        XCTAssertEqual(agents.state("A-1"), .blocked, "the status feeds the session state")
        XCTAssertEqual(job.blocking.map(\.key), ["A-1"])

        job.toggle(s!.id, step: 1)
        XCTAssertEqual(job.status("A-1")?.report, "Manual check: 1 of 2 pass.\n- [ ] Take a capture on 2 displays\n- [x] Send it to Orca")
        job.snooze(s!.id)
        XCTAssertTrue(job.blocking.isEmpty, "a snoozed status leaves the list")
    }

    func testTheHistoryGoesIntoThePrompt() {
        let rt = FakeRuntime()
        rt.setHistory(SessionDigest(harness: .claude, sessionId: "s1", source: .file, turns: 5,
                                    earlier: [.init(prompt: "work on A-1", closing: "I read the code.")],
                                    last: [.init(prompt: "go on", text: "The page is merged.", tools: 3)]), paneKey: "p1")
        agents.runtime = { rt }
        agents.seed(cards: [Workspace(id: "c1", repo: "app", path: "/fake/app", name: "a-1", comment: nil, liveTerminals: 1,
                                      lastActivity: t0, agents: [])])
        seed(.done, message: "The page is merged.")
        tick()
        settle()
        let ctx = engine.tasks.first?.input.context ?? [:]
        XCTAssertEqual(ctx["turns"], "5")
        XCTAssertEqual(ctx["earlier"], "[turn 4] work on A-1 → I read the code.")
        XCTAssertEqual(ctx["screen"], "", "an ended session sends no screen")
        XCTAssertEqual(job.status("A-1")?.read, "Read 1 turn and 1 closing message")
    }

    func testMarkAsBlockedTakesTheNextSteps() throws {
        engine.on(.status, .success(#"{"state":"unfinished","headline":"Half done.","next":["Add the tests","Update the docs"]}"#))
        seed(.done, message: "I stop here.")
        tick()
        settle()
        let s = try XCTUnwrap(job.status("A-1"))
        XCTAssertEqual(job.pending.map(\.state), [.unfinished])
        job.markBlocked(s.id)
        XCTAssertEqual(job.status("A-1")?.state, .blocked)
        XCTAssertEqual(job.status("A-1")?.reply.needsYou.map(\.text), ["Add the tests", "Update the docs"])
        XCTAssertTrue(job.pending.isEmpty)
    }

    func testAFailedSendKeepsTheStatusOpen() throws {
        engine.on(.status, .success(#"{"state":"unfinished","headline":"Half done.","next":["Add the tests"]}"#))
        seed(.done, message: "I stop here.")
        tick()
        settle()
        let s = try XCTUnwrap(job.status("A-1"))
        agents.runtime = { nil }
        var err: ProviderError?
        let sent = expectation(description: "done")
        job.ask(s.id) { err = $0; sent.fulfill() }
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(err?.message, "No machine runs the sessions. Pick one in Settings › Machines.")
        XCTAssertEqual(job.status("A-1")?.handled, .open, "the user can try again")
        XCTAssertEqual(job.pending.count, 1)
    }

    func testTheStatusesStayOnDisk() {
        job.ai = { nil }
        seed(.done, message: "I need you to set the API key.")
        tick()
        let again = StatusJob(path: dir.path + "/status.json", agents: AgentIndex(writes: nil),
                              queue: WorkQueue(writes: StoreWrites(store: LocalStore(dir: dir)), store: world.1, agents: agents))
        XCTAssertEqual(again.status("A-1")?.state, .blocked)
        XCTAssertEqual(SessionStatus.readText(nil, description: true, screen: true), "Read the screen and the description")
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
