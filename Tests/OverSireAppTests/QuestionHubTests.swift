import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class QuestionHubTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let item = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
                               id: "i1", key: "OVERSIRE-1", url: URL(string: "https://plane.example/OVERSIRE-1")!)

    private func hub() -> QuestionHub {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        return QuestionHub(agents: AgentIndex(writes: nil), writes: StoreWrites(store: LocalStore(dir: dir)))
    }

    private func question(_ session: SessionRef, _ id: String, origin: SessionQuestion.Origin, via: SessionQuestion.Via = .form,
                          count: Int = 1) -> SessionQuestion {
        let items = (1...count).map { QuestionItem(id: "q\($0)", text: "Which schema \($0)?", kind: .single, options: [.init(label: "A")]) }
        return SessionQuestion(id: QuestionID(rawValue: "fake:\(id)"), session: session, origin: origin, items: items, via: via, askedAt: t0)
    }

    func testOpenQuestionLeadsNeedsYouAndLeavesWhenAnswered() async {
        let ch = FakeQuestionChannel()
        let s = ch.session("s1")
        let board = QuestionBoard(channels: [ch], sessions: { [s] }, clock: ManualClock(), now: { self.t0 })
        let h = hub()
        h.tellAfter = { nil }
        h.attach(board)
        let q = question(s, "1", origin: .work(item), count: 2)
        ch.ask(q)
        await board.refresh()

        let rows = NeedsYou.questions(h)
        XCTAssertEqual(rows.map(\.kind), [.question])
        XCTAssertEqual(rows.first?.key, "OVERSIRE-1")
        XCTAssertEqual(rows.first?.act, .answer)
        XCTAssertEqual(rows.first?.route, .item("OVERSIRE-1", .session))
        XCTAssertEqual(h.count(key: "OVERSIRE-1"), 2, "a round of 2 is 2 questions")
        XCTAssertEqual(h.line(key: "OVERSIRE-1"), "✦ 2 questions")
        let input = NeedsYou(kind: .needsInput, key: "OVERSIRE-1", reason: "", at: t0.addingTimeInterval(60), route: .home)
        XCTAssertEqual(NeedsYou.merged(rows + [input]).map(\.kind), [.question], "the question row wins over the Orca row")

        ch.answerOutside(q.id, QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["A"])]))
        await board.refresh()
        XCTAssertTrue(NeedsYou.questions(h).isEmpty)
        XCTAssertEqual(h.count(key: "OVERSIRE-1"), 0)
        XCTAssertTrue(h.line(key: "OVERSIRE-1")?.hasPrefix("✓ Answered in ") == true, h.line(key: "OVERSIRE-1") ?? "nil")
    }

    func testSessionQuestionGetsTheKeyOfItsTerminal() {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "term-1")
        let h = hub()
        h.seed([QuestionBoard.Entry(question: question(s, "f", origin: .session, via: .waiting), state: .open, firstSeen: t0)],
               keys: [s: "OVERSIRE-7"])
        let rows = NeedsYou.questions(h)
        XCTAssertEqual(rows.map(\.key), ["OVERSIRE-7"])
        XCTAssertEqual(rows.first?.act, .answerInOrca("fake:f"), "a pause that OverSire cannot read gets its answer in Orca")
        XCTAssertEqual(h.line(key: "OVERSIRE-7"), "✦ 1 question · in Orca")
        XCTAssertTrue(rows.first?.reason.hasSuffix("this Mac") == true, rows.first?.reason ?? "")
    }

    func testIntakeQuestionOpensTheIntake() {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "term-2")
        let h = hub()
        h.seed([QuestionBoard.Entry(question: question(s, "i", origin: .intake(item)), state: .open, firstSeen: t0)], keys: [:])
        XCTAssertEqual(NeedsYou.questions(h).first?.route, .intake("OVERSIRE"))
    }

    // An Enhance session has no coordinator: a question in its last message is a card too.
    func testEnhanceSessionShowsItsTurnQuestion() {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "term-3")
        let h = hub()
        h.seed([QuestionBoard.Entry(question: question(s, "t", origin: .session, via: .turn), state: .open, firstSeen: t0),
                QuestionBoard.Entry(question: question(s, "f", origin: .session, via: .form), state: .open, firstSeen: t0)],
               keys: [:], intake: [s: item])
        XCTAssertEqual(Set(h.open.map(\.question.via)), [.turn, .form])
        XCTAssertTrue(h.open.allSatisfy { h.origin($0.question).isIntake })
    }

    func testPermissionRowsComeUnderTheQuestions() {
        let runner = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "oversire", id: "local"), id: "r1"), id: "s-1")
        let orca = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "term-1")
        let p = SessionQuestion(id: "runner:s-1:p-1", session: runner, origin: .session, items: [.approve(id: "permission", header: "Bash", text: "npm test")],
                                via: .permission, askedAt: t0.addingTimeInterval(60), expiresAt: t0.addingTimeInterval(600))
        let h = hub()
        h.seed([QuestionBoard.Entry(question: p, state: .open, firstSeen: t0),
                QuestionBoard.Entry(question: question(orca, "q", origin: .work(item)), state: .open, firstSeen: t0)], keys: [:])
        let rows = NeedsYou.ranked(NeedsYou.questions(h))
        XCTAssertEqual(rows.map(\.kind), [.question, .permission])
        XCTAssertEqual(rows[1].key, "Session")
        XCTAssertEqual(rows[1].route, .work(.worktrees), "a runner session with no item opens Work")
        XCTAssertTrue(rows[1].reason.hasPrefix("Allow Bash: npm test · OverSire runner"), rows[1].reason)
        XCTAssertEqual(rows[1].act, .answer)
    }

    func testMenuIconHasADotForQuestions() {
        let k = MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false, questions: 2)
        XCTAssertTrue(k.dot)
        XCTAssertTrue(k.label.hasSuffix("· 2 questions"), k.label)
        XCTAssertFalse(MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false).dot)
    }

    func testOneNotificationForEachQuestion() async {
        let ch = FakeQuestionChannel()
        let s = ch.session("s1")
        let board = QuestionBoard(channels: [ch], sessions: { [s] }, clock: ManualClock(), now: { self.t0 })
        let h = hub()
        var told: [String] = []
        let got = expectation(description: "notification")
        h.tellAfter = { 0 }
        h.notify = { _, title, _ in told.append(title); got.fulfill() }
        h.attach(board)
        ch.ask(question(s, "1", origin: .work(item)))
        await board.refresh()
        await fulfillment(of: [got], timeout: 2)
        await board.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(told, ["OVERSIRE-1 asks a question"])
    }

    func testNoticeSetting() {
        XCTAssertEqual(QuestionNotice.allCases.map(\.label), ["At once", "After 30 min", "Never"])
        XCTAssertEqual(QuestionNotice.later.delay, 1800)
        XCTAssertNil(QuestionNotice.never.delay)
        XCTAssertEqual(AgentsConfig().questionNotice, .later)
    }
}
