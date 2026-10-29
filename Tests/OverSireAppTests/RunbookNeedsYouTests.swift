import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class RunbookNeedsYouTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let ref = ProjectRef(workspace: "ocral", id: "p1")
    private var item: ItemRef { ItemRef(project: ref, id: "i2", key: "OVERSIRE-2", url: URL(string: "https://plane.example/OVERSIRE-2")!) }
    private let term = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "daemon", id: "mba"), id: "wt-2"), id: "term-5")

    private func run(_ state: RunbookRun.State, current: String?, _ steps: [StepRun], reason: String? = nil, id: RunbookRunID = "rb_1") -> RunbookRun {
        let full = ProjectsConfig().runtime.defaultRunbooks[0]
        return RunbookRun(id: id, item: item, machine: "mba", runtime: "orca", repo: "/src", runbook: full, agents: [:], state: state, reason: reason,
                          current: current, steps: steps, started: t0, updated: t0.addingTimeInterval(600))
    }

    private func step(_ id: String, _ state: StepRun.State, round: Int = 1, note: String? = nil, session: SessionRef? = nil, ended: Double? = nil) -> StepRun {
        StepRun(step: id, round: round, state: state, session: session, note: note, ended: ended.map { t0.addingTimeInterval($0) })
    }

    private var planned: [StepRun] {
        [step("plan", .done, ended: 60), step("review-plan", .pass, note: "Each item has tests.", ended: 120), step("plan-fixes", .skipped)]
    }

    // MARK: Needs you rows

    func testAGateAsksToApprove() {
        let rows = NeedsYou.runbooks([run(.gate, current: "implement", planned + [step("implement", .waits)])])
        XCTAssertEqual(rows.map(\.kind), [.gate])
        let n = rows[0]
        XCTAssertEqual(n.key, "OVERSIRE-2")
        XCTAssertEqual(n.reason, "Approve to start Implement · Review Plan passed: “Each item has tests.”")
        XCTAssertEqual(n.act, .runbook("runbook.approve", key: "OVERSIRE-2", title: "Approve"))
        XCTAssertEqual(n.more, [.go(.item("OVERSIRE-2", .overview), "Open item")])
        XCTAssertEqual(n.route, .item("OVERSIRE-2", .runbook))
        XCTAssertEqual(n.tone.word, "Approve", "the word carries the meaning, not the color")
    }

    func testAReviewOverItsRoundLimitAsksForOneMoreRound() {
        let steps = planned + [step("implement", .done), step("review", .gaps, note: "Soft deletes skip the check."), step("fixes", .done),
                               step("review", .gaps, round: 2, note: "Still skips it.")]
        let n = NeedsYou.runbooks([run(.paused, current: "review", steps, reason: "Review still finds gaps after 1 round.")])
        XCTAssertEqual(n.map(\.kind), [.roundLimit])
        XCTAssertEqual(n.first?.reason, "Review Implementation: review still finds gaps · the fix round limit is 1. “Still skips it.”")
        XCTAssertEqual(n.first?.act?.title, "One more round")
        XCTAssertEqual(n.first?.more, [.runbook("runbook.skip", key: "OVERSIRE-2", step: "review", title: "Mark pass")])
    }

    func testAStepWithNoResultOffersMarkDoneAndRetry() {
        let ended = run(.paused, current: "implement", planned + [step("implement", .ended)], reason: "The session ended with no step done.")
        let n = NeedsYou.runbooks([ended])
        XCTAssertEqual(n.map(\.kind), [.stepEnded])
        XCTAssertEqual(n.first?.reason, "Implement: step ended with no result · The session ended with no step done.")
        XCTAssertEqual(n.first?.act, .markDone(key: "OVERSIRE-2", step: "implement", review: false))
        XCTAssertEqual(n.first?.act?.title, "Mark done ▾")
        XCTAssertEqual(n.first?.more.map(\.title), ["Retry step", "Open session"])

        let blocked = run(.paused, current: "implement", planned + [step("implement", .blocked, note: "Needs the VAULT_KEY.")])
        XCTAssertEqual(NeedsYou.runbooks([blocked]).first?.reason, "Implement is blocked · Needs the VAULT_KEY.")
        XCTAssertEqual(NeedsYou.runbooks([blocked]).first?.act?.title, "Retry step", "a blocked step takes no late verdict")

        let review = run(.paused, current: "review", planned + [step("implement", .done), step("review", .ended)])
        XCTAssertEqual(NeedsYou.runbooks([review]).first?.act?.title, "Mark pass ▾")
    }

    func testARunThatWorksOrThatYouPausedHasNoRow() {
        XCTAssertTrue(NeedsYou.runbooks([run(.running, current: "implement", planned + [step("implement", .working)])]).isEmpty)
        XCTAssertTrue(NeedsYou.runbooks([run(.paused, current: "implement", planned + [step("implement", .done)])]).isEmpty)
        XCTAssertTrue(NeedsYou.runbooks([run(.done, current: nil, planned)]).isEmpty)
    }

    func testTheBlockedFilterHasTheRunRows() {
        for k in [NeedsYou.Kind.gate, .stepEnded, .roundLimit] { XCTAssertTrue(NeedsYou.Filter.blocked.has(k)) }
        let gate = NeedsYou.runbooks([run(.gate, current: "implement", planned + [step("implement", .waits)])])
        let review = NeedsYou(kind: .review, key: "OVERSIRE-2", reason: "", at: t0, route: .prs)
        XCTAssertEqual(NeedsYou.merged(gate + [review]).map(\.kind), [.gate])
    }

    // MARK: Menu bar and notices

    func testTheMenuBarCountsTheRunsThatWait() {
        let k = MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false, runbooks: 1)
        XCTAssertTrue(k.dot)
        XCTAssertTrue(k.label.hasSuffix("· 1 runbook waits"), k.label)
    }

    func testOneNoticeForEachGateAfterTheDelay() {
        let book = RunbookBook(runtime: { nil }, bus: ChangeBus())
        var told: [String] = []
        book.notify = { key, title, _ in told.append("\(key)|\(title)") }
        book.tellAfter = { nil }
        book.set([run(.gate, current: "implement", planned + [step("implement", .waits)])])
        book.tellAfter = { 1800 }
        book.tell(now: t0.addingTimeInterval(600 + 60))
        XCTAssertEqual(told, [], "the delay of the question setting")
        book.tell(now: t0.addingTimeInterval(600 + 1800))
        book.tell(now: t0.addingTimeInterval(600 + 3600))
        XCTAssertEqual(told, ["OVERSIRE-2|OVERSIRE-2 needs you"])
        book.tellAfter = { nil }
        book.set([run(.paused, current: "implement", planned + [step("implement", .ended)], id: "rb_2")])
        book.tell(now: t0.addingTimeInterval(7200))
        XCTAssertEqual(told.count, 1, "Never: no notice")
    }

    // MARK: Questions

    func testAStepQuestionHasTheStepName() {
        let book = RunbookBook(runtime: { nil }, bus: ChangeBus())
        book.set([run(.running, current: "review", planned + [step("implement", .done), step("review", .asks, round: 2, session: term)])])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        let h = QuestionHub(agents: AgentIndex(writes: nil), writes: StoreWrites(store: LocalStore(dir: dir)))
        h.runs = book
        let q = SessionQuestion(id: "daemon:mba:q1", session: term, origin: .session,
                                items: [QuestionItem(id: "q1", text: "Keep the rows?", kind: .single, options: [.init(label: "Yes")])], via: .form, askedAt: t0)
        h.seed([QuestionBoard.Entry(question: q, state: .open, firstSeen: t0)], keys: [:])
        XCTAssertEqual(h.key(q), "OVERSIRE-2", "the run gives the item of a step session")
        XCTAssertEqual(h.step(q), "Review Implementation · round 2")
        XCTAssertTrue(NeedsYou.questions(h).first?.reason.hasPrefix("Review Implementation · round 2: Keep the rows?") == true)
    }

    func testTheStepOfASessionKey() {
        XCTAssertEqual(RunbookBook.parse("runbook:rb_1.review.2").map { "\($0.run)|\($0.step)|\($0.round)" }, "rb_1|review|2")
        XCTAssertEqual(RunbookBook.parse("runbook:rb.x.plan-fixes.1")?.run, "rb.x")
        XCTAssertNil(RunbookBook.parse("runbook:rb_1.review"))
        XCTAssertNil(RunbookBook.parse("work:OVERSIRE-2"))
        let book = RunbookBook(runtime: { nil }, bus: ChangeBus())
        book.set([run(.running, current: "plan", [step("plan", .working)])])
        XCTAssertEqual(book.step(session: nil, key: "runbook:rb_1.plan.1").map { RunbookBook.label($0.run, $0.step) }, "Plan & Refine")
        XCTAssertNil(book.step(session: nil, key: "runbook:rb_9.plan.1"))
    }

    // MARK: Queue

    func testPickTakesEntriesWithARunbookAsAnyEntry() {
        let lane = QueueLane(project: ref.storeKey, identifier: "OVERSIRE", entries: [
            QueueEntry(key: "OVERSIRE-2", title: "Two", added: t0, runbook: "full"), QueueEntry(key: "OVERSIRE-3", title: "Three", added: t0),
        ])
        var w = QueueWorld(busy: { _ in 0 }, slots: { _ in 1 }, ciPassed: { _ in true }, done: { _ in false }, now: t0)
        XCTAssertEqual(lane.pick(state: nil, world: w).entry?.runbook, "full")
        w.blockers = { $0 == "OVERSIRE-2" ? ["OVERSIRE-1"] : [] }
        XCTAssertEqual(lane.pick(state: nil, world: w).entry?.key, "OVERSIRE-3")
        w.busy = { _ in 1 }
        XCTAssertNil(lane.pick(state: nil, world: w).entry)
    }

    func testOnlyARunningRunHoldsASlotAndAStartCallsTheStarter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let it = Item(id: "2", key: "OVERSIRE-2", title: "Two", url: "", statusOptionId: "t", fields: [:], assignees: [], labels: [],
                      author: "ada", updatedBy: "ada", updatedAt: t0, activityAt: t0, commentCount: 0, lastComment: nil, mentionsMe: false)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [], items: [it], fetchedAt: t0, me: "ada")
        let disk: [String: Any] = ["snapshots": [ref.storeKey: try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap))],
                                   "readActivity": [], "readItems": []]
        try JSONSerialization.data(withJSONObject: disk).write(to: dir.appendingPathComponent("state.json"))

        await MainActor.run {
            let saved = PROJECTS_CFG
            defer { PROJECTS_CFG = saved }
            PROJECTS_CFG.runtime.runbooks = PROJECTS_CFG.runtime.defaultRunbooks
            PROJECTS_CFG.orca.roots[ref.storeKey] = "/src/oversire"
            let writes = StoreWrites(store: LocalStore(dir: dir))
            let projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                        statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
            let q = WorkQueue(writes: writes, store: projects, agents: AgentIndex(writes: writes))
            var runs: [RunbookRun] = []
            q.runs = { runs }
            var started: [String] = []
            q.startRun = { book, item, _, done in started.append("\(book.id)|\(item.key)"); done(nil) }
            let lane = QueueLane(project: ref.storeKey, identifier: "OVERSIRE")

            for (state, busy) in [(RunbookRun.State.running, 1), (.gate, 0), (.paused, 0)] {
                runs = [run(state, current: "implement", planned + [step("implement", state == .running ? .working : .waits)])]
                XCTAssertEqual(q.busy(lane), busy, "\(state)")
            }
            runs = []

            XCTAssertTrue(q.add(key: "OVERSIRE-2", runbook: "small"))
            XCTAssertEqual(q.lane(ref.storeKey)?.entries.first?.runbook, "small")
            XCTAssertNil(q.start("OVERSIRE-2", project: ref.storeKey))
            XCTAssertEqual(started, ["small|OVERSIRE-2"])
            XCTAssertFalse(q.contains("OVERSIRE-2"))

            XCTAssertTrue(q.add(key: "OVERSIRE-2", runbook: "gone"))
            XCTAssertNotNil(q.start("OVERSIRE-2", project: ref.storeKey), "a removed runbook does not start")
            XCTAssertEqual(started.count, 1)
            XCTAssertTrue(q.contains("OVERSIRE-2"))
        }
    }
}
