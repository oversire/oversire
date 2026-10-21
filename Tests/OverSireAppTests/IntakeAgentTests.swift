import OverSireAI
import OverSireCore
import OverSireSync
import OverSireTestKit
import RuntimeOrca
import XCTest
@testable import OverSireApp

private final class FakeEnhanceHost: EnhanceHost, @unchecked Sendable {
    let account = AccountID(provider: "orca", id: "local")
    let installed = true
    var state: OrcaWorkerState = .running
    func startWorker(spec: String, title: String, path: String, agent: String) async throws -> OrcaWorker {
        OrcaWorker(dispatch: "d1", task: "t1", terminal: "term-1")
    }
    func workerState(_ w: OrcaWorker) async throws -> OrcaWorkerState { state }
    func stopWorker(_ w: OrcaWorker) async throws {}
    func releaseWorker(_ w: OrcaWorker) async throws {}
    func reveal(_ s: SessionRef) async throws {}
}

final class IntakeAgentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
    private lazy var ref = ItemRef(project: project, id: "w1", key: "OVERSIRE-9", url: URL(string: "https://plane.example/OVERSIRE-9")!)
    private let item = IntakeItem(id: "in1", workItemId: "w1", name: "labels drop", priority: nil, createdAt: Date(), author: nil, source: nil)

    private func make() -> (IntakeAgent, QuestionHub, FakeEnhanceHost) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let hub = QuestionHub(agents: AgentIndex(writes: nil), writes: writes)
        hub.tellAfter = { nil }
        let store = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let agent = IntakeAgent(store: store, memory: ProjectMemory(writes: writes), questions: hub)
        let host = FakeEnhanceHost()
        agent.host = { host }
        agent.now = { self.t0 }
        return (agent, hub, host)
    }

    private func run(_ host: FakeEnhanceHost) -> IntakeAgent.Run {
        let s = SessionRef(workspace: WorkspaceRef(account: host.account, id: "intake"), id: "term-1")
        return IntakeAgent.Run(worker: OrcaWorker(dispatch: "d1", task: "t1", terminal: "term-1"), session: s, item: ref,
                               original: "label sync is broken", since: t0)
    }

    private let result = ###"{"verdict":"vague","description":"## Problem\nThe sync drops labels.","priority":"high","labels":["bug","nope"],"relations":[{"kind":"blocked_by","key":"OVERSIRE-3","reason":"api"},{"kind":"relates_to","key":"OVERSIRE-404","reason":""}],"findings":["One page of labels."]}"###

    func testRunMovesFromEnhancingToAskingToReady() async {
        let (agent, hub, host) = make()
        let r = run(host)
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
        XCTAssertEqual(IntakeAgent.pill(agent.states[item.id]!)?.text, "2 questions")

        host.state = .done(outcome: "succeeded", body: "I read the code.\n" + result)
        await agent.poll()
        guard case .ready(let res, _) = agent.states[item.id] else { return XCTFail("\(String(describing: agent.states[item.id]))") }
        XCTAssertEqual(res.verdict, .vague)
        XCTAssertEqual(IntakeAgent.pill(agent.states[item.id]!)?.text, "Enhanced · High")
        XCTAssertNil(hub.key(q), "the worker is no longer tracked")
    }

    func testNoResultFailsAndKeepsTheText() async {
        let (agent, _, host) = make()
        agent.begin(item.id, run(host))
        host.state = .done(outcome: "succeeded", body: "I could not finish.")
        await agent.poll()
        XCTAssertEqual(agent.states[item.id], .failed("The agent sent no result that OverSire can read. Its text is below.", kept: "I could not finish."))
    }

    func testEditHasOnlyTheCheckedProperties() throws {
        let (agent, _, host) = make()
        let res = try XCTUnwrap(EnhanceResult.parse(result))
        let labels = [StatusOption(id: "L1", name: "Bug", color: "#f00"), StatusOption(id: "L2", name: "ui", color: "#0f0")]
        let blocker = ItemRef(project: project, id: "w3", key: "OVERSIRE-3", url: URL(string: "https://plane.example/OVERSIRE-3")!)
        let all = agent.edit(item, res, run: run(host), labels: labels, keep: ["L2"], items: ["OVERSIRE-3": blocker])
        XCTAssertEqual(all.patch.priority, "high")
        XCTAssertEqual(all.patch.labels, ["L2", "L1"], "the known label adds to the kept ones")
        XCTAssertEqual(all.relations, [ItemRelation(kind: .blockedBy, item: blocker)], "an unknown key drops")
        let body = try XCTUnwrap(all.patch.bodyMarkdown)
        XCTAssertTrue(body.hasSuffix("## Original note\n\nlabel sync is broken"), body)

        agent.toggle(item, .description)
        agent.toggle(item, .priority)
        agent.toggle(item, .label("bug"))
        agent.toggle(item, .relation("OVERSIRE-3"))
        XCTAssertTrue(agent.edit(item, res, run: run(host), labels: labels, keep: ["L2"], items: ["OVERSIRE-3": blocker]).isEmpty)
        agent.toggle(item, .priority)
        XCTAssertTrue(agent.isChecked(item, .priority))
    }

    func testDuplicateNeedsItsCheck() throws {
        let (agent, _, _) = make()
        let res = try XCTUnwrap(EnhanceResult.parse(##"{"verdict":"duplicate","description":"","relations":[{"kind":"duplicate","key":"oversire-3"}]}"##))
        let other = ItemRef(project: project, id: "w3", key: "OVERSIRE-3", url: URL(string: "https://plane.example/OVERSIRE-3")!)
        XCTAssertEqual(agent.duplicate(item, res, items: ["OVERSIRE-3": other]), other)
        agent.toggle(item, .relation("oversire-3"))
        XCTAssertNil(agent.duplicate(item, res, items: ["OVERSIRE-3": other]))
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
        XCTAssertTrue(old.enhanceVague)
        XCTAssertTrue(IntakeAgent.vague("label sync is broken"))
        XCTAssertFalse(IntakeAgent.vague(String(repeating: "word ", count: 30)))
    }
}

final class AcceptAndQueueTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
    private let item = IntakeItem(id: "in1", workItemId: "w1", name: "labels drop", priority: nil, createdAt: Date(), author: nil, source: nil)

    private func ref(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "w\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://plane.example/OVERSIRE-\(n)")!)
    }

    func testQueueAddsTheLabelOnceAndKeepsTheOthers() {
        let plain = IntakeAgent.queued(IntakeEdit(), label: "L-agent", keep: ["L2"])
        XCTAssertEqual(plain.patch.labels, ["L2", "L-agent"])
        XCTAssertEqual(IntakeAgent.queued(plain, label: "L-agent", keep: ["L2"]).patch.labels, ["L2", "L-agent"], "no second label")
        XCTAssertTrue(IntakeEdit().isEmpty, "Accept with no Enhance run writes no label")
    }

    func testOnlyCheckedRelationsAndNoCycle() throws {
        let agent = IntakeAgent(store: ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                                    statePath: NSTemporaryDirectory() + "/q-\(UUID()).json", activityPath: NSTemporaryDirectory() + "/q-\(UUID()).jsonl"),
                                memory: ProjectMemory(writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))),
                                questions: QuestionHub(agents: AgentIndex(writes: nil), writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))))
        let res = EnhanceResult(verdict: .clear, description: "", relations: [
            .init(kind: "blocked_by", key: "OVERSIRE-3", reason: ""), .init(kind: "blocks", key: "OVERSIRE-4", reason: ""),
            .init(kind: "relates_to", key: "OVERSIRE-5", reason: "")])
        let run = IntakeAgent.Run(worker: OrcaWorker(dispatch: "d", task: "t", terminal: nil), session: nil, item: ref(9), original: "x", since: Date())
        let items = ["OVERSIRE-3": ref(3), "OVERSIRE-4": ref(4), "OVERSIRE-5": ref(5)]
        // OVERSIRE-3 waits for OVERSIRE-9 already: 9 blocked by 3 makes a cycle.
        let graph = BlockGraph(["OVERSIRE-3": [ItemRelation(kind: .blockedBy, item: ref(9))]])
        agent.toggle(item, .description)
        agent.toggle(item, .relation("OVERSIRE-5"))
        let e = agent.edit(item, res, run: run, labels: [], keep: [], items: items, graph: graph)
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
