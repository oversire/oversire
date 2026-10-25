import OverSireAI
import OverSireCore
import OverSireSync
import OverSireTestKit
import RuntimeDaemon
import XCTest
@testable import OverSireApp

/// One keyed Groom session for each project: the plan, the input file, the review, Apply and the Enhance hand-off (OVERSIRE-339).
final class GroomAgentTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    struct Rig {
        let agent: GroomAgent
        let enhance: EnhanceAgent
        let daemon: FakeDaemon
        let host: LocalMachineRuntime
        let agents: AgentIndex
        let queue: WorkQueue
        let fake: FakeTracker
        let pk: String
        let hub: QuestionHub
        let snap: ProjectSnapshot
    }

    private var saved: (Bool, String?)!

    override func tearDown() async throws {
        if let saved {
            AI_CFG.intakeAgent = saved.0
            PROJECTS_CFG.orca.roots[FakeTracker().project.storeKey] = saved.1
        }
    }

    /// FAKE-1 to FAKE-3 are Todo, FAKE-4 is in progress, FAKE-5 is done, FAKE-6 and FAKE-7 wait in the intake.
    func make(_ daemon: FakeDaemon = FakeDaemon()) async throws -> Rig {
        let fake = FakeTracker()
        fake.addStatus(StatusOption(id: "s-cancel", name: "Cancelled", color: "#9CA3AF", group: "cancelled"))
        for n in 1...3 { _ = try await fake.create(ItemDraft(title: "Item \(n)", bodyMarkdown: "Body \(n)", labels: n == 1 ? ["bug"] : []), in: fake.project) }
        _ = try await fake.create(ItemDraft(title: "Doing", status: "s-doing"), in: fake.project)
        _ = try await fake.create(ItemDraft(title: "Shipped", status: "s-done"), in: fake.project)
        for n in 6...7 { _ = try await fake.createIntake(ItemDraft(title: "Note \(n)", bodyMarkdown: "A note"), in: fake.project) }
        let summary = try await fake.projects()[0]
        let snap = ProjectSnapshot(summary: summary, statusOptions: try await fake.statuses(fake.project),
                                   items: try await fake.items(fake.project, since: nil, limit: 50), fetchedAt: Date(), me: "me",
                                   intake: try await fake.intake(fake.project))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writes = StoreWrites(store: LocalStore(dir: dir))
        let host = LocalMachineRuntime(machine: "mba", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: daemon), pause: { _ in })
        _ = try await host.refresh()
        let pk = fake.project.storeKey
        saved = (AI_CFG.intakeAgent, PROJECTS_CFG.orca.roots[pk])
        AI_CFG.intakeAgent = true
        PROJECTS_CFG.orca.roots[pk] = "/Users/ada/Projects/fake"
        return await MainActor.run {
            let store = ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                     statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
            store.seed(snap)
            let agents = AgentIndex(writes: nil)
            agents.runtime = { host }
            agents.hold = true
            let hub = QuestionHub(agents: agents, writes: writes)
            hub.tellAfter = { nil }
            let memory = ProjectMemory(writes: writes)
            let queue = WorkQueue(writes: writes, store: store, agents: agents)
            let enhance = EnhanceAgent(store: store, memory: memory, questions: hub, agents: agents)
            enhance.host = { host }
            let agent = GroomAgent(store: store, memory: memory, questions: hub, agents: agents, queue: queue, enhance: enhance,
                                   journal: GroomJournal(store: writes.store))
            agent.host = { host }
            agent.outputs = AIOutputBook(writes: writes)
            return Rig(agent: agent, enhance: enhance, daemon: daemon, host: host, agents: agents, queue: queue, fake: fake, pk: pk, hub: hub, snap: snap)
        }
    }

    private func absorb(_ r: Rig) async throws {
        let cards = try await r.host.workspaces()
        await MainActor.run { r.agents.absorb(cards) }
    }

    private func wait(_ r: Rig, until ok: @escaping (GroomAgent.State?) -> Bool) async {
        let pk = r.pk
        guard !ok(r.agent.states[pk]) else { return }
        let e = expectation(forNotification: GroomAgent.changed, object: r.agent) { _ in ok(r.agent.states[pk]) }
        await fulfillment(of: [e], timeout: 5)
    }

    private func end(_ r: Rig, _ text: String) {
        var all = r.daemon.sessions
        let i = all.firstIndex { $0.key?.hasPrefix("groom:") == true }!
        all[i].state = .done
        all[i].stateSince = (all[i].startedAt ?? Date()).addingTimeInterval(600)
        all[i].lastMessage = "clipped"
        r.daemon.sessions = all
        r.daemon.runtime.history(all[i].terminal ?? "", text)
    }

    private let block = """
        I read 6 items.

        ```oversire-result
        {"proposals":[
          {"kind":"merge","keys":["FAKE-1","FAKE-2","FAKE-6"],"keep":"FAKE-1","title":"Same","reason":"Same cause.","confidence":"sure","description":"## New\\nOne."},
          {"kind":"done","keys":["FAKE-3"],"reason":"Shipped.","evidence":["a41f9c2"],"confidence":"maybe"},
          {"kind":"obsolete","keys":["FAKE-4"],"reason":"Not in the input.","confidence":"sure"},
          {"kind":"vague","keys":["FAKE-7"],"reason":"Only a title.","confidence":"sure"}
        ]}
        ```
        """

    private func start(_ r: Rig, _ o: GroomAgent.Options = .init()) async {
        await MainActor.run { r.agent.start(projectKey: r.pk, options: o) }
        await wait(r) { if case .grooming = $0 { return true } else { return false } }
    }

    func testPlanCountsAndSkips() async throws {
        let r = try await make()
        await MainActor.run { _ = r.queue.add(key: "FAKE-2") }
        let all = try XCTUnwrap(r.agent.plan(r.pk, .init()))
        XCTAssertEqual(all.backlog.map(\.key).sorted(), ["FAKE-1", "FAKE-3"])
        XCTAssertEqual(all.intake.count, 2)
        XCTAssertEqual(all.skipped, ["FAKE-2", "FAKE-4"], "a lane item and a started item; the done item is not open")
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.minutes, 1...3)
        XCTAssertFalse(all.tooMany)
        let intake = try XCTUnwrap(r.agent.plan(r.pk, .init(scope: .intake)))
        XCTAssertEqual(intake.count, 2)
        XCTAssertTrue(intake.backlog.isEmpty)
        let label = try XCTUnwrap(r.agent.plan(r.pk, .init(label: "BUG")))
        XCTAssertEqual(label.backlog.map(\.key), ["FAKE-1"])
    }

    func testStartWritesTheFileAndOneKeyedSessionInPlace() async throws {
        let r = try await make()
        await start(r)
        let files = r.daemon.runtime.files
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].map(\.name), ["groom-fake.jsonl"])
        let lines = String(decoding: files[0][0].data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains(#""intake":true"#), String(lines[0]))
        guard case .start(let req) = try XCTUnwrap(r.daemon.runtime.orders.last).order else { return XCTFail("no start") }
        XCTAssertEqual(req.key, "groom:FAKE")
        XCTAssertEqual(req.inPlace, true)
        XCTAssertEqual(req.repo, "/Users/ada/Projects/fake")
        XCTAssertEqual(req.title, "Groom FAKE")
        XCTAssertTrue(req.prompt.contains("/Users/ada/.oversire/files/"), req.prompt)
        XCTAssertTrue(req.prompt.contains("FAKE-4"), "the prompt names the skipped items")
        XCTAssertEqual(r.agent.states[r.pk]?.run?.keys.sorted(), ["FAKE-1", "FAKE-2", "FAKE-3", "FAKE-6", "FAKE-7"])
        XCTAssertEqual(r.agent.pill(r.pk)?.text, "Grooming · 1m")
    }

    func testOldDaemonAsksForAnUpdate() async throws {
        let d = FakeDaemon()
        d.runtime.runtimes = d.runtime.runtimes.map { var rt = $0; rt.capabilities.removeAll { $0 == "sessionKey" }; return rt }
        let r = try await make(d)
        XCTAssertTrue(r.agent.available)
        XCTAssertFalse(r.agent.ready)
        r.agent.start(projectKey: r.pk, options: .init())
        XCTAssertEqual(r.agent.states[r.pk], .failed("Update the daemon on mba to use Groom.", kept: nil))
        XCTAssertTrue(d.runtime.orders.isEmpty)
    }

    func testReviewSelectsTheSureLinesOfTheInput() async throws {
        let r = try await make()
        await start(r)
        try await absorb(r)
        end(r, block)
        try await absorb(r)
        await wait(r) { if case .ready = $0 { return true } else { return false } }
        guard case .ready(let review, let run) = r.agent.states[r.pk] else { return XCTFail() }
        XCTAssertNotNil(run)
        XCTAssertEqual(review.changes.map(\.kind), [.merge, .done], "FAKE-4 is not in the input")
        XCTAssertEqual(review.vague.map(\.keys), [["FAKE-7"]])
        XCTAssertEqual(r.agent.selected[r.pk], [review.changes[0].id], "a maybe line starts cleared")
        XCTAssertEqual(r.agent.pill(r.pk)?.text, "Groomed · 2 changes")
        XCTAssertEqual(review.intake.keys.sorted(), ["FAKE-6", "FAKE-7"])
        r.agent.toggle(r.pk, review.changes[1])
        XCTAssertEqual(r.agent.selected[r.pk]?.count, 2)
        r.agent.toggle(r.pk, review.result.proposals[2])
        XCTAssertEqual(r.agent.selected[r.pk]?.count, 2, "a line that cannot apply has no check box")
    }

    func testApplyWritesThenEnhanceTakesTheVagueItems() async throws {
        let r = try await make()
        await start(r)
        try await absorb(r)
        end(r, block)
        try await absorb(r)
        await wait(r) { if case .ready = $0 { return true } else { return false } }
        await MainActor.run { r.agent.apply(r.pk, enhance: true) }
        await wait(r) { $0?.isApplied == true }
        guard case .applied(_, let out) = r.agent.states[r.pk] else { return XCTFail() }
        XCTAssertEqual(out.written.count, 1)
        XCTAssertEqual(out.vague, ["FAKE-7"])
        XCTAssertTrue(r.agent.undoable.contains(r.pk))
        XCTAssertEqual(r.agent.pill(r.pk)?.text, "Written 1 of 1")
        let two = try await r.fake.items(r.fake.project, since: nil, limit: 50).first { $0.key == "FAKE-2" }
        XCTAssertEqual(two?.statusOptionId, "s-cancel")
        XCTAssertEqual(r.fake.triages.map(\.action).last, .duplicate(of: "i1"))
        XCTAssertFalse(r.daemon.sessions.contains { $0.key == "groom:FAKE" }, "Apply stops the Groom session")
        for _ in 0..<100 where !r.daemon.sessions.contains(where: { $0.key == "enhance:FAKE-7" }) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(r.daemon.sessions.contains { $0.key == "enhance:FAKE-7" }, "\(r.daemon.sessions.map(\.key))")
        XCTAssertNil(r.agent.outputs?.all(.groomReview, as: GroomAgent.Review.self).first, "the review goes after Apply")
    }

    func testAskAgainSendsATurnAndWaitsForANewResult() async throws {
        let r = try await make()
        await start(r)
        try await absorb(r)
        end(r, block)
        try await absorb(r)
        await wait(r) { if case .ready = $0 { return true } else { return false } }
        let resent = Date().addingTimeInterval(3600)
        r.agent.now = { resent }
        r.agent.askAgain(r.pk)
        guard case .grooming(let run) = r.agent.states[r.pk] else { return XCTFail("\(String(describing: r.agent.states[r.pk]))") }
        XCTAssertEqual(run.rounds, 2)
        for _ in 0..<100 where !r.daemon.runtime.orders.contains(where: { if case .send = $0.order { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(r.daemon.runtime.orders.contains { if case .send = $0.order { return true } else { return false } })
        try await absorb(r)
        XCTAssertEqual(r.agent.states[r.pk]?.isLive, true, "the old done phase is the old result")
    }

    func testTooManyItemsDoNotStart() async throws {
        let r = try await make()
        var plan = try XCTUnwrap(r.agent.plan(r.pk, .init()))
        plan.backlog = Array(repeating: plan.backlog[0], count: GroomInput.limit)
        XCTAssertTrue(plan.tooMany)
        XCTAssertTrue(GroomInput.TooMany(count: plan.count).description.contains("Select Intake only or a label"))
    }
}
