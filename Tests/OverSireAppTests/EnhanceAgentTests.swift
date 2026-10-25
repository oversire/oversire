import OverSireAI
import OverSireCore
import OverSireSync
import OverSireTestKit
import RuntimeDaemon
import XCTest
@testable import OverSireApp

final class EnhanceAgentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
    private lazy var ref = ItemRef(project: project, id: "w1", key: "OVERSIRE-9", url: URL(string: "https://plane.example/OVERSIRE-9")!)
    private let item = IntakeItem(id: "in1", workItemId: "w1", name: "labels drop", priority: nil, createdAt: Date(), author: nil, source: nil)

    private func make() -> (EnhanceAgent, QuestionHub, FakeDaemon) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let hub = QuestionHub(agents: AgentIndex(writes: nil), writes: writes)
        hub.tellAfter = { nil }
        let store = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let agent = EnhanceAgent(store: store, memory: ProjectMemory(writes: writes), questions: hub)
        let daemon = FakeDaemon()
        let host = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: daemon), pause: { _ in })
        agent.host = { host }
        agent.now = { self.t0 }
        return (agent, hub, daemon)
    }

    private static let account = AccountID(provider: .daemon, id: "mba")

    private func run(_ w: Worker = Worker(id: "wk-1", runtime: "orca", terminal: "term_w1", startedAt: Date())) -> EnhanceAgent.Run {
        let s = SessionRef(workspace: WorkspaceRef(account: Self.account, id: "intake"), id: w.terminal ?? "")
        return EnhanceAgent.Run(worker: w, session: s, item: ref, original: "label sync is broken", since: t0)
    }

    /// A run with a worker that the FakeDaemon started.
    private func started(_ agent: EnhanceAgent) async throws -> EnhanceAgent.Run {
        let host = try XCTUnwrap(agent.host())
        return run(try await host.startWorker(WorkerStart(spec: "Read the item.", title: "Enhance OVERSIRE-9",
                                                          path: "/Users/ada/Projects/towertail", agent: "claude")))
    }

    private let result = ###"{"verdict":"vague","description":"## Problem\nThe sync drops labels.","priority":"high","labels":["bug","nope"],"relations":[{"kind":"blocked_by","key":"OVERSIRE-3","reason":"api"},{"kind":"relates_to","key":"OVERSIRE-404","reason":""}],"findings":["One page of labels."]}"###

    func testRunMovesFromEnhancingToAskingToReady() async throws {
        let (agent, hub, daemon) = make()
        let r = try await started(agent)
        XCTAssertEqual(daemon.runtime.workerCalls, ["start"])
        agent.begin(item.id, r)
        XCTAssertEqual(agent.states[item.id], .enhancing(r))

        let q = SessionQuestion(id: QuestionID(rawValue: "fake:e1"), session: r.session!, origin: .session,
                                items: [QuestionItem(id: "q1", text: "Which sync?", kind: .single, options: [.init(label: "A")]),
                                        QuestionItem(id: "q2", text: "Which tests?", kind: .single, options: [.init(label: "B")])],
                                via: .askReply, askedAt: t0)
        hub.seed([QuestionBoard.Entry(question: q, state: .open, firstSeen: t0)], keys: [:])
        XCTAssertEqual(hub.key(q), "OVERSIRE-9", "the question of the worker is about the intake item")
        XCTAssertTrue(hub.origin(q).isIntake)
        await agent.poll()
        guard case .asking(_, let n) = agent.states[item.id] else { return XCTFail("\(String(describing: agent.states[item.id]))") }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(EnhanceAgent.pill(agent.states[item.id]!)?.text, "2 questions")

        daemon.runtime.worker(r.worker.id, WorkerState(state: .done, outcome: "succeeded", body: "I read the code.\n" + result))
        await agent.poll()
        guard case .ready(let res, _) = agent.states[item.id] else { return XCTFail("\(String(describing: agent.states[item.id]))") }
        XCTAssertEqual(res.verdict, .vague)
        XCTAssertEqual(EnhanceAgent.pill(agent.states[item.id]!)?.text, "Enhanced · High")
        XCTAssertNil(hub.key(q), "the worker is no longer tracked")
    }

    func testNoResultFailsAndKeepsTheText() async throws {
        let (agent, _, daemon) = make()
        let r = try await started(agent)
        agent.begin(item.id, r)
        daemon.runtime.worker(r.worker.id, WorkerState(state: .done, outcome: "succeeded", body: "I could not finish."))
        await agent.poll()
        XCTAssertEqual(agent.states[item.id], .failed("The agent sent no result that OverSire can read. Its text is below.", kept: "I could not finish."))
    }

    func testEndedWorkerFails() async throws {
        let (agent, _, daemon) = make()
        let r = try await started(agent)
        agent.begin(item.id, r)
        daemon.runtime.worker(r.worker.id, WorkerState(state: .ended, reason: "terminal closed"))
        await agent.poll()
        XCTAssertEqual(agent.states[item.id], .failed("The worker stopped (terminal closed) with no result.", kept: nil))
    }

    func testOnlyThisMacOpensTheWorker() {
        let (agent, _, daemon) = make()
        XCTAssertTrue(agent.canReveal)
        XCTAssertEqual(EnhancePanel.place(agent), "this Mac")
        let remote = MachineRuntime(machine: "mbp", client: DaemonClient(base: URL(string: "http://mbp:7690")!, token: "t", http: daemon))
        agent.host = { remote }
        XCTAssertFalse(agent.canReveal)
        XCTAssertEqual(EnhancePanel.place(agent), "mbp")
        agent.host = { nil }
        XCTAssertEqual(EnhancePanel.place(agent), "no machine")
    }

    func testEditHasOnlyTheCheckedProperties() throws {
        let (agent, _, _) = make()
        let res = try XCTUnwrap(EnhanceResult.parse(result))
        let labels = [StatusOption(id: "L1", name: "Bug", color: "#f00"), StatusOption(id: "L2", name: "ui", color: "#0f0")]
        let blocker = ItemRef(project: project, id: "w3", key: "OVERSIRE-3", url: URL(string: "https://plane.example/OVERSIRE-3")!)
        let all = agent.edit(.intake(item), res, run: run(), labels: labels, keep: ["L2"], items: ["OVERSIRE-3": blocker])
        XCTAssertEqual(all.patch.priority, "high")
        XCTAssertEqual(all.patch.labels, ["L2", "L1"], "the known label adds to the kept ones")
        XCTAssertEqual(all.relations, [ItemRelation(kind: .blockedBy, item: blocker)], "an unknown key drops")
        let body = try XCTUnwrap(all.patch.bodyMarkdown)
        XCTAssertTrue(body.hasSuffix("## Original note\n\nlabel sync is broken"), body)

        agent.toggle(.intake(item), .description)
        agent.toggle(.intake(item), .priority)
        agent.toggle(.intake(item), .label("bug"))
        agent.toggle(.intake(item), .relation("OVERSIRE-3"))
        XCTAssertTrue(agent.edit(.intake(item), res, run: run(), labels: labels, keep: ["L2"], items: ["OVERSIRE-3": blocker]).isEmpty)
        agent.toggle(.intake(item), .priority)
        XCTAssertTrue(agent.isChecked(.intake(item), .priority))
    }

    func testDuplicateNeedsItsCheck() throws {
        let (agent, _, _) = make()
        let res = try XCTUnwrap(EnhanceResult.parse(##"{"verdict":"duplicate","description":"","relations":[{"kind":"duplicate","key":"oversire-3"}]}"##))
        let other = ItemRef(project: project, id: "w3", key: "OVERSIRE-3", url: URL(string: "https://plane.example/OVERSIRE-3")!)
        XCTAssertEqual(agent.duplicate(.intake(item), res, items: ["OVERSIRE-3": other]), other)
        agent.toggle(.intake(item), .relation("oversire-3"))
        XCTAssertNil(agent.duplicate(.intake(item), res, items: ["OVERSIRE-3": other]))
    }

    func testDefaultPromptAndOldPromptReset() throws {
        let t = AgentsConfig.defaultIntakePrompt
        XCTAssertEqual(t, EnhancePrompt.template)
        let with = EnhancePrompt.render(t, EnhancePrompt.input(key: "K-1", title: "T", url: "u", body: "b", vision: "Small and native."))
        XCTAssertTrue(with.contains("Project vision (the true north of the project):\nSmall and native."))
        XCTAssertTrue(with.contains("## Original note"))
        let without = EnhancePrompt.render(t, EnhancePrompt.input(key: "K-1", title: "T", url: "u", body: "b"))
        XCTAssertFalse(without.contains("{{"))
        XCTAssertFalse(without.contains("Project vision"))
        XCTAssertTrue(without.hasSuffix("Item K-1: T\nu\n\nb"), without)

        let old = try JSONDecoder().decode(AgentsConfig.self, from: Data(##"{"intakePrompt":"Read {KEY} now"}"##.utf8))
        XCTAssertEqual(old.intakePrompt, t)
        let v1 = try JSONDecoder().decode(AgentsConfig.self, from: Data(##"{"intakePrompt":"You enhance a new intake item. Be short."}"##.utf8))
        XCTAssertEqual(v1.intakePrompt, "You enhance {{kind}}. Be short.", "a saved version 1 prompt gets the kind")
        XCTAssertTrue(old.enhanceVague)
        XCTAssertTrue(EnhanceAgent.vague("label sync is broken"))
        XCTAssertFalse(EnhanceAgent.vague(String(repeating: "word ", count: 30)))
    }
}

final class AcceptAndQueueTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
    private let item = IntakeItem(id: "in1", workItemId: "w1", name: "labels drop", priority: nil, createdAt: Date(), author: nil, source: nil)

    private func ref(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "w\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://plane.example/OVERSIRE-\(n)")!)
    }

    func testQueueAddsTheLabelOnceAndKeepsTheOthers() {
        let plain = EnhanceAgent.queued(IntakeEdit(), label: "L-agent", keep: ["L2"])
        XCTAssertEqual(plain.patch.labels, ["L2", "L-agent"])
        XCTAssertEqual(EnhanceAgent.queued(plain, label: "L-agent", keep: ["L2"]).patch.labels, ["L2", "L-agent"], "no second label")
        XCTAssertTrue(IntakeEdit().isEmpty, "Accept with no Enhance run writes no label")
    }

    func testOnlyCheckedRelationsAndNoCycle() throws {
        let agent = EnhanceAgent(store: ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                                    statePath: NSTemporaryDirectory() + "/q-\(UUID()).json", activityPath: NSTemporaryDirectory() + "/q-\(UUID()).jsonl"),
                                memory: ProjectMemory(writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))),
                                questions: QuestionHub(agents: AgentIndex(writes: nil), writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))))
        let res = EnhanceResult(verdict: .clear, description: "", relations: [
            .init(kind: "blocked_by", key: "OVERSIRE-3", reason: ""), .init(kind: "blocks", key: "OVERSIRE-4", reason: ""),
            .init(kind: "relates_to", key: "OVERSIRE-5", reason: "")])
        let run = EnhanceAgent.Run(worker: Worker(id: "wk-1", runtime: "orca", startedAt: Date()), session: nil, item: ref(9), original: "x", since: Date())
        let items = ["OVERSIRE-3": ref(3), "OVERSIRE-4": ref(4), "OVERSIRE-5": ref(5)]
        // OVERSIRE-3 waits for OVERSIRE-9 already: 9 blocked by 3 makes a cycle.
        let graph = BlockGraph(["OVERSIRE-3": [ItemRelation(kind: .blockedBy, item: ref(9))]])
        agent.toggle(.intake(item), .description)
        agent.toggle(.intake(item), .relation("OVERSIRE-5"))
        let e = agent.edit(.intake(item), res, run: run, labels: [], keep: [], items: items, graph: graph)
        XCTAssertEqual(e.relations, [ItemRelation(kind: .blocks, item: ref(4))])
        XCTAssertNil(e.patch.labels)
    }

    func testBlockedItemIsNotUpNext() {
        var lane = QueueLane(project: "ocral/p1", identifier: "OVERSIRE")
        lane.entries = ["OVERSIRE-1", "OVERSIRE-2"].map { QueueEntry(key: $0, title: $0, added: Date(), source: .you) }
        let world = QueueWorld(busy: { _ in 0 }, slots: { _ in 1 }, ciPassed: { _ in true }, done: { _ in false }, now: Date(),
                               blockers: { $0 == "OVERSIRE-1" ? ["OVERSIRE-7"] : [] })
        let pick = lane.pick(state: nil, world: world)
        XCTAssertEqual(pick.next, "OVERSIRE-2")
        XCTAssertEqual(pick.entry?.key, "OVERSIRE-2")
        XCTAssertEqual(pick.holds["OVERSIRE-1"].map(QueueBoard.note), "⏸ Waits for OVERSIRE-7")
    }
}

final class EnhanceTicketTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    func testApplyWritesTheTicketAndItsRelations() async throws {
        let fake = FakeTracker()
        let ticket = try await fake.create(ItemDraft(title: "Labels drop", bodyMarkdown: "label sync is broken"), in: fake.project)
        let blocker = try await fake.create(ItemDraft(title: "Label API"), in: fake.project)
        let twin = try await fake.create(ItemDraft(title: "Labels vanish"), in: fake.project)
        let summary = try await fake.projects()[0]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let trackers = Trackers(fake)
        let store = ProjectStore(trackers: trackers, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let items = try await fake.items(fake.project, since: nil, limit: 50)
        await MainActor.run {
            store.seed(ProjectSnapshot(summary: summary, statusOptions: [], items: items, fetchedAt: Date(), me: "me"))
        }
        let agent = EnhanceAgent(store: store, memory: ProjectMemory(writes: writes),
                                 questions: QuestionHub(agents: AgentIndex(writes: nil), writes: writes))
        let daemon = FakeDaemon()
        let host = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: daemon), pause: { _ in })
        agent.host = { host }

        let target = EnhanceTarget.item(ticket)
        XCTAssertEqual(target.id, "item:" + ticket.id)
        let w = try await host.startWorker(WorkerStart(spec: "Read the item.", title: "Enhance " + ticket.key, path: "/tmp", agent: "claude"))
        await MainActor.run {
            agent.begin(target.id, EnhanceAgent.Run(worker: w, session: nil, item: ticket, original: "label sync is broken", since: Date()))
        }
        let result = ###"{"verdict":"vague","description":"## Problem\nThe sync drops labels.","relations":[{"kind":"blocked_by","key":"\###(blocker.key)"},{"kind":"duplicate","key":"\###(twin.key)"}]}"###
        daemon.runtime.worker(w.id, WorkerState(state: .done, outcome: "succeeded", body: result))
        await agent.poll()
        guard case .ready = agent.state(target) else { return XCTFail("\(String(describing: agent.state(target)))") }
        XCTAssertNil(agent.state(.intake(IntakeItem(id: ticket.id, workItemId: ticket.id, name: "", priority: nil, createdAt: Date(), author: nil, source: nil))),
                     "an intake item with the same id has no state")

        let applied = expectation(description: "apply")
        var err: String?
        await MainActor.run { agent.apply(ticket: ticket) { err = $0; applied.fulfill() } }
        await fulfillment(of: [applied], timeout: 5)
        XCTAssertNil(err)
        XCTAssertEqual(agent.state(target), .applied(accepted: false))
        let body = try await fake.detail(ticket).item.body ?? ""
        XCTAssertTrue(body.hasPrefix("## Problem\nThe sync drops labels."), body)
        XCTAssertTrue(body.hasSuffix("## Original note\n\nlabel sync is broken"), body)
        let rels = try await fake.relations(of: ticket)
        XCTAssertEqual(Set(rels), [ItemRelation(kind: .blockedBy, item: blocker), ItemRelation(kind: .relatesTo, item: twin)],
                       "a ticket has no duplicate action: the duplicate is a relates to")
    }
}
