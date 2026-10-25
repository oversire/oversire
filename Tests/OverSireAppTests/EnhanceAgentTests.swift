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

    private struct Rig {
        let agent: EnhanceAgent
        let hub: QuestionHub
        let daemon: FakeDaemon
        let host: LocalMachineRuntime
        let agents: AgentIndex
    }

    private func make(_ daemon: FakeDaemon = FakeDaemon()) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let host = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: daemon), pause: { _ in })
        _ = try await host.refresh()
        return await MainActor.run {
            let agents = AgentIndex(writes: nil)
            agents.runtime = { host }
            agents.hold = true
            let hub = QuestionHub(agents: agents, writes: writes)
            hub.tellAfter = { nil }
            let store = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                     statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
            let agent = EnhanceAgent(store: store, memory: ProjectMemory(writes: writes), questions: hub, agents: agents)
            agent.host = { host }
            agent.now = { self.t0 }
            return Rig(agent: agent, hub: hub, daemon: daemon, host: host, agents: agents)
        }
    }

    private func run(_ pane: String? = "tab-1:leaf-1") -> EnhanceAgent.Run {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: .daemon, id: "mba"), id: "ws"), id: "term_1")
        return EnhanceAgent.Run(key: "enhance:OVERSIRE-9", session: s, pane: pane, item: ref, original: "label sync is broken", since: t0)
    }

    /// Starts a run as `start` does after the project lookups, and waits for its session.
    @discardableResult
    private func launch(_ r: Rig) async throws -> EnhanceAgent.Run {
        let spec = EnhanceAgent.Spec(kind: .intake, ref: ref, title: "labels drop", url: ref.url.absoluteString, body: "label sync is broken")
        let id = item.id
        let pane = await MainActor.run { r.agent.states[id]?.run?.pane }
        let began = expectation(forNotification: EnhanceAgent.changed, object: r.agent) { _ in
            r.agent.states[id]?.run.map { $0.pane != pane } ?? false
        }
        await MainActor.run { r.agent.launch(.intake(item), spec, root: "/Users/ada/Projects/towertail") }
        await fulfillment(of: [began], timeout: 5)
        return try XCTUnwrap(r.agent.states[id]?.run)
    }

    /// One poll of the agent index: the Enhance agent follows it.
    private func absorb(_ r: Rig) async throws {
        let cards = try await r.host.workspaces()
        await MainActor.run { r.agents.absorb(cards) }
    }

    private func end(_ r: Rig, message: String?, history: String?) {
        var all = r.daemon.sessions
        all[0].state = .done
        all[0].lastMessage = message
        r.daemon.sessions = all
        if let history { r.daemon.runtime.history(all[0].terminal ?? "", history) }
    }

    private func wait(_ r: Rig, until ok: @escaping (EnhanceAgent.State?) -> Bool) async {
        let id = item.id
        let e = expectation(forNotification: EnhanceAgent.changed, object: r.agent) { _ in ok(r.agent.states[id]) }
        await fulfillment(of: [e], timeout: 5)
    }

    private let result = ###"{"verdict":"vague","description":"## Problem\nThe sync drops labels.","priority":"high","labels":["bug","nope"],"relations":[{"kind":"blocked_by","key":"OVERSIRE-3","reason":"api"},{"kind":"relates_to","key":"OVERSIRE-404","reason":""}],"findings":["One page of labels."]}"###

    private var block: String { "I read the code.\n\n```oversire-result\n" + result + "\n```" }

    func testStartSendsOneKeyedSessionInPlace() async throws {
        let r = try await make()
        let run = try await launch(r)
        guard case .start(let req) = try XCTUnwrap(r.daemon.runtime.orders.last).order else { return XCTFail("no start") }
        XCTAssertEqual(req.key, "enhance:OVERSIRE-9")
        XCTAssertEqual(req.inPlace, true)
        XCTAssertEqual(req.title, "Enhance OVERSIRE-9")
        XCTAssertTrue(req.prompt.contains("oversire-result"))
        XCTAssertEqual(run.key, "enhance:OVERSIRE-9")
        XCTAssertEqual(run.session?.id, "term_1")
        XCTAssertEqual(run.pane, "tab-1:leaf-1")
        XCTAssertEqual(r.agent.states[item.id], .enhancing(run))
        XCTAssertEqual(EnhanceAgent.startKey(.intake(item), ref: ItemRef(project: project, id: "w1", key: "OVERSIRE", url: ref.url)), "enhance:in1",
                       "an intake item with no number uses its id")

        // The other app starts the same key: the daemon gives the live session.
        let other = try await host(r).launch(LaunchRequest(repo: "/Users/ada/Projects/towertail", agent: .claude, prompt: "x", inPlace: true,
                                                           key: "enhance:OVERSIRE-9"))
        XCTAssertEqual(other.paneKey, "tab-1:leaf-1")
        XCTAssertEqual(r.daemon.sessions.count, 1)
    }

    private func host(_ r: Rig) -> LocalMachineRuntime { r.host }

    func testOldDaemonAsksForAnUpdate() async throws {
        let d = FakeDaemon()
        d.runtime.runtimes = d.runtime.runtimes.map { var rt = $0; rt.capabilities.removeAll { $0 == "sessionKey" }; return rt }
        let r = try await make(d)
        XCTAssertTrue(r.agent.available, "the buttons show")
        XCTAssertFalse(r.agent.ready)
        r.agent.start(projectKey: "plane:ocral/OVERSIRE", target: .intake(item))
        XCTAssertEqual(r.agent.states[item.id], .failed("Update the daemon on mba to use Enhance.", kept: nil))
        XCTAssertTrue(d.runtime.orders.isEmpty, "no start")
    }

    func testRunMovesFromEnhancingToAskingToReady() async throws {
        let r = try await make()
        let run = try await launch(r)
        try await absorb(r)
        XCTAssertEqual(r.agent.states[item.id]?.run?.seen, true)
        XCTAssertNil(r.agents.agent("OVERSIRE-9"), "the Enhance session is not the work agent of the item")

        let q = SessionQuestion(id: QuestionID(rawValue: "fake:e1"), session: run.session!, origin: .session,
                                items: [QuestionItem(id: "q1", text: "Which sync?", kind: .single, options: [.init(label: "A")]),
                                        QuestionItem(id: "q2", text: "Which tests?", kind: .single, options: [.init(label: "B")])],
                                via: .form, askedAt: t0)
        r.hub.seed([QuestionBoard.Entry(question: q, state: .open, firstSeen: t0)], keys: [:])
        XCTAssertEqual(r.hub.key(q), "OVERSIRE-9", "the question of the session is about the intake item")
        XCTAssertTrue(r.hub.origin(q).isIntake)
        await MainActor.run { r.agent.sync() }
        guard case .asking(_, let n) = r.agent.states[item.id] else { return XCTFail("\(String(describing: r.agent.states[item.id]))") }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(r.agent.pill(.intake(item))?.text, "2 questions")

        r.hub.seed([], keys: [:])
        end(r, message: "clipped", history: block)
        try await absorb(r)
        await wait(r) { $0?.isReady == true }
        guard case .ready(let res, _) = r.agent.states[item.id] else { return XCTFail("\(String(describing: r.agent.states[item.id]))") }
        XCTAssertEqual(res.verdict, .vague)
        XCTAssertEqual(r.agent.pill(.intake(item))?.text, "Enhanced · High")
        XCTAssertNil(r.hub.key(q), "the session is no longer tracked")
        XCTAssertTrue(r.daemon.runtime.orders.contains { if case .history = $0.order { return true } else { return false } })
    }

    func testNoResultFailsAndKeepsTheText() async throws {
        let r = try await make()
        try await launch(r)
        end(r, message: "I could not finish.", history: "I could not finish. The tests do not run.")
        try await absorb(r)
        await wait(r) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(r.agent.states[item.id], .failed("The agent sent no result that OverSire can read. Its text is below.",
                                                         kept: "I could not finish. The tests do not run."))
    }

    func testProseQuestionAsks() async throws {
        let r = try await make()
        try await launch(r)
        end(r, message: "I read the sync code.\n\nWhich sync do you mean: Plane to Trebi, or Trebi to Plane?", history: nil)
        try await absorb(r)
        guard case .asking(_, let n) = r.agent.states[item.id] else { return XCTFail("\(String(describing: r.agent.states[item.id]))") }
        XCTAssertEqual(n, 1)
        XCTAssertFalse(r.daemon.runtime.orders.contains { if case .history = $0.order { return true } else { return false } }, "no result to read")
    }

    func testEndedSessionFails() async throws {
        let r = try await make()
        try await launch(r)
        try await absorb(r)
        r.daemon.sessions = []
        try await absorb(r)
        XCTAssertEqual(r.agent.states[item.id], .failed("The session ended with no result.", kept: nil))
    }

    func testUnseenSessionFailsAfterTheShowTime() async throws {
        let r = try await make()
        try await launch(r)
        r.daemon.sessions = []
        try await absorb(r)
        XCTAssertTrue(r.agent.states[item.id]?.isLive == true, "the daemon can list it late")
        await MainActor.run {
            r.agent.now = { self.t0.addingTimeInterval(EnhanceAgent.showTime + 1) }
            r.agent.sync()
        }
        XCTAssertEqual(r.agent.states[item.id], .failed("The session did not show on this Mac. Try again.", kept: nil))
    }

    func testTimeLimitCountsOnlyWork() async throws {
        let r = try await make()
        try await launch(r)
        try await absorb(r)
        await MainActor.run {
            r.agent.now = { self.t0.addingTimeInterval(EnhanceAgent.timeout + 1) }
            r.agent.sync()
        }
        XCTAssertEqual(r.agent.states[item.id], .failed("No result after 30 minutes of work. Open the session to look.", kept: nil))
    }

    func testTryAgainStopsTheOldSessionFirst() async throws {
        let r = try await make()
        let first = try await launch(r)
        end(r, message: "No result.", history: "No result.")
        try await absorb(r)
        await wait(r) { if case .failed = $0 { return true } else { return false } }
        let second = try await launch(r)
        XCTAssertNotEqual(second.pane, first.pane)
        let ops = r.daemon.runtime.orders.map(\.order.op)
        XCTAssertEqual(ops, [.sessionStart, .sessionHistory, .sessionStop, .sessionStart])
        XCTAssertEqual(r.daemon.sessions.map(\.id), [second.pane])
    }

    func testDiscardStopsTheSessionAndDoesNotFollowItAgain() async throws {
        let r = try await make()
        try await launch(r)
        try await absorb(r)
        await MainActor.run { r.agent.discard(.intake(item)) }
        XCTAssertNil(r.agent.states[item.id])
        let stopped = expectation(description: "stop")
        Task {
            while !r.daemon.runtime.orders.contains(where: { $0.order.op == .sessionStop }) { try await Task.sleep(for: .milliseconds(10)) }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(r.daemon.sessions.isEmpty)
    }

    func testOnlyThisMacOpensTheSession() async throws {
        let r = try await make()
        let agent = r.agent
        XCTAssertTrue(agent.canReveal)
        XCTAssertEqual(agent.place, "this Mac")
        let remote = MachineRuntime(machine: "mbp", client: DaemonClient(base: URL(string: "http://mbp:7690")!, token: "t", http: r.daemon))
        agent.host = { remote }
        XCTAssertFalse(agent.canReveal)
        XCTAssertEqual(agent.place, "mbp")
        XCTAssertEqual(EnhanceAgent.pill(.enhancing(run()), now: t0.addingTimeInterval(120), on: "mbp")?.text, "Enhancing on mbp · 2m")
        agent.host = { nil }
        XCTAssertEqual(agent.place, "no machine")
    }

    func testEditHasOnlyTheCheckedProperties() async throws {
        let agent = try await make().agent
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

    func testDuplicateNeedsItsCheck() async throws {
        let agent = try await make().agent
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
                                questions: QuestionHub(agents: AgentIndex(writes: nil), writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))),
                                agents: AgentIndex(writes: nil))
        let res = EnhanceResult(verdict: .clear, description: "", relations: [
            .init(kind: "blocked_by", key: "OVERSIRE-3", reason: ""), .init(kind: "blocks", key: "OVERSIRE-4", reason: ""),
            .init(kind: "relates_to", key: "OVERSIRE-5", reason: "")])
        let run = EnhanceAgent.Run(key: "enhance:OVERSIRE-9", item: ref(9), original: "x", since: Date())
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
        let daemon = FakeDaemon()
        let host = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: daemon), pause: { _ in })
        _ = try await host.refresh()
        let app = { () -> (EnhanceAgent, AgentIndex) in
            let agents = AgentIndex(writes: nil)
            agents.runtime = { host }
            agents.hold = true
            let a = EnhanceAgent(store: store, memory: ProjectMemory(writes: writes), questions: QuestionHub(agents: agents, writes: writes), agents: agents)
            a.host = { host }
            return (a, agents)
        }
        let (agent, agents) = await MainActor.run { app() }

        let target = EnhanceTarget.item(ticket)
        XCTAssertEqual(target.id, "item:" + ticket.id)
        let began = expectation(forNotification: EnhanceAgent.changed, object: agent) { _ in agent.state(target)?.run != nil }
        let spec = EnhanceAgent.Spec(kind: .ticket, ref: ticket, title: "Labels drop", url: ticket.url.absoluteString, body: "label sync is broken")
        await MainActor.run { agent.launch(target, spec, root: "/tmp") }
        await fulfillment(of: [began], timeout: 5)
        let result = ###"{"verdict":"vague","description":"## Problem\nThe sync drops labels.","relations":[{"kind":"blocked_by","key":"\###(blocker.key)"},{"kind":"duplicate","key":"\###(twin.key)"}]}"###
        var all = daemon.sessions
        all[0].state = .done
        all[0].lastMessage = "```oversire-result\n" + result + "\n```"
        daemon.sessions = all
        let ready = expectation(forNotification: EnhanceAgent.changed, object: agent) { _ in agent.state(target)?.isReady == true }
        let cards = try await host.workspaces()
        await MainActor.run { agents.absorb(cards) }
        await fulfillment(of: [ready], timeout: 5)

        // The other app finds the session by its key, and reads the same result.
        let (other, otherAgents) = await MainActor.run { app() }
        let found = expectation(forNotification: EnhanceAgent.changed, object: other) { _ in other.state(target)?.isReady == true }
        await MainActor.run { otherAgents.absorb(cards) }
        await fulfillment(of: [found], timeout: 5)
        XCTAssertEqual(other.state(target)?.run?.original, "label sync is broken")
        XCTAssertEqual(other.state(target)?.run?.key, "enhance:" + ticket.key)

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

        // The apply stops the session. The other app then drops its result.
        for _ in 0..<500 where !daemon.sessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(daemon.sessions.isEmpty)
        let gone = try await host.workspaces()
        await MainActor.run { otherAgents.absorb(gone) }
        XCTAssertNil(other.state(target))
    }
}
