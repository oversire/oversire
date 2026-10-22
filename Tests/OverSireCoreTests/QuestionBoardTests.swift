import XCTest
import OverSireCore
import OverSireTestKit

final class QuestionBoardTests: XCTestCase {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var d: Date
        private var refs: [SessionRef]
        init(_ d: Date, _ refs: [SessionRef]) {
            self.d = d
            self.refs = refs
        }
        var date: Date {
            get { lock.withLock { d } }
            set { lock.withLock { d = newValue } }
        }
        var sessions: [SessionRef] {
            get { lock.withLock { refs } }
            set { lock.withLock { refs = newValue } }
        }
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let item = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
                       id: "i1", key: "OVERSIRE-1", url: URL(string: "https://plane.example/OVERSIRE-1")!)

    func question(_ ch: FakeQuestionChannel, _ id: String, session: String = "s1", via: SessionQuestion.Via = .askReply,
                  expiresAt: Date? = nil) -> SessionQuestion {
        SessionQuestion(id: QuestionID(rawValue: "fake:\(id)"), session: ch.session(session), origin: .work(item),
                        items: [QuestionItem(id: "q1", text: "Which schema?", kind: .single,
                                             options: [.init(label: "A"), .init(label: "B")])],
                        via: via, askedAt: t0, expiresAt: expiresAt)
    }

    func answer(_ q: SessionQuestion, _ label: String = "A") -> QuestionAnswer {
        QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: [label])])
    }

    func board(_ ch: FakeQuestionChannel, _ box: Box, store: (any Store)? = nil, clock: ManualClock = ManualClock()) -> QuestionBoard {
        QuestionBoard(channels: [ch], sessions: { box.sessions }, clock: clock, store: store, now: { box.date })
    }

    func testNewQuestionIsOpen() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .open)
        XCTAssertEqual(b.entries[q.id]?.firstSeen, t0)
        XCTAssertEqual(b.openCount, 1)
        XCTAssertEqual(b.open(for: item).map(\.id), [q.id])
    }

    func testMissingQuestionIsAnsweredElsewhere() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q1 = question(ch, "1"), q2 = question(ch, "2")
        ch.ask(q1)
        ch.ask(q2)
        await b.refresh()
        ch.answerOutside(q1.id, answer(q1, "B"))
        ch.answerOutside(q2.id, nil)
        await b.refresh()
        XCTAssertEqual(b.entries[q1.id]?.state, .answeredElsewhere(answer(q1, "B"), at: t0))
        XCTAssertEqual(b.entries[q2.id]?.state, .answeredElsewhere(nil, at: t0))
        XCTAssertEqual(b.openCount, 0)
    }

    func testMissingQuestionOfAStoppedSessionIsGone() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        box.sessions = []
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .gone(at: t0))
    }

    /// The channel names the same pause with a new id. The old entry goes, and no "gone" card shows.
    func testNewIdOfTheSamePauseDropsTheOld() async throws {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let old = question(ch, "screen")
        ch.ask(old)
        await b.refresh()
        ch.answerOutside(old.id, nil)
        ch.ask(question(ch, "tool"))
        await b.refresh()
        XCTAssertEqual(b.entries.keys.map(\.rawValue), ["fake:tool"])
        XCTAssertEqual(b.entries[QuestionID(rawValue: "fake:tool")]?.state, .open)

        let other = SessionQuestion(id: QuestionID(rawValue: "fake:later"), session: ch.session("s1"), origin: .work(item),
                                    items: old.items, via: .askReply, askedAt: t0.addingTimeInterval(60))
        ch.answerOutside(QuestionID(rawValue: "fake:tool"), answer(old))
        ch.ask(other)
        await b.refresh()
        XCTAssertEqual(Set(b.entries.keys.map(\.rawValue)), ["fake:tool", "fake:later"], "a question with an answer stays")
    }

    func testSendThatWins() async throws {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        try await b.answer(q.id, answer(q))
        XCTAssertEqual(b.entries[q.id]?.state, .answeredHere(answer(q), at: t0))
        XCTAssertEqual(ch.sent, [answer(q)])
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .answeredHere(answer(q), at: t0), "the next read keeps our answer")
    }

    func testSendThatLosesIsRaced() async throws {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        ch.answerOutside(q.id, nil)
        try await b.answer(q.id, answer(q))
        XCTAssertEqual(b.entries[q.id]?.state, .raced(at: t0))
        XCTAssertEqual(ch.sent, [])
    }

    func testSendThatThrowsGoesBackToOpen() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        ch.failSends(.transport("offline"))
        do {
            try await b.answer(q.id, answer(q))
            XCTFail("the send did not throw")
        } catch {}
        XCTAssertEqual(b.entries[q.id]?.state, .open)
        XCTAssertEqual(b.entries[q.id]?.error, "offline")
    }

    func testAnswerValidatesFirst() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1"), form = question(ch, "2", via: .waiting)
        ch.ask(q)
        ch.ask(form)
        await b.refresh()
        await XCTAssertThrowsAsync(try await b.answer(q.id, self.answer(q, "Z")))
        await XCTAssertThrowsAsync(try await b.answer(form.id, self.answer(form)))
        XCTAssertEqual(ch.sent, [])
        XCTAssertEqual(b.entries[q.id]?.state, .open)
    }

    func testFailedReadsKeepThenStale() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        ch.base.fail(.transport("down"))
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .open)
        XCTAssertEqual(b.entries[q.id]?.stale, false)
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .open, "a failed read never clears a question")
        XCTAssertEqual(b.entries[q.id]?.stale, true)
        ch.base.fail(nil)
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.stale, false)
    }

    func testPushReadsAtOnce() async throws {
        let ch = FakeQuestionChannel(pushes: true)
        let box = Box(t0, [ch.session("s1")])
        let clock = ManualClock()
        let b = board(ch, box, clock: clock)
        let seen = expectation(description: "the board reads after a push")
        let q = question(ch, "1")
        b.onChange = { entries in
            if entries.contains(where: { $0.id == q.id }) { seen.fulfill() }
        }
        b.start()
        try await clock.waitForSleepers()
        ch.ask(q)
        await fulfillment(of: [seen], timeout: 2)
        b.stop()
    }

    func testFoldAndDrop() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        ch.answerOutside(q.id, nil)
        await b.refresh()
        box.date = t0.addingTimeInterval(599)
        await b.refresh()
        XCTAssertNotNil(b.entries[q.id])
        box.date = t0.addingTimeInterval(600)
        await b.refresh()
        XCTAssertNil(b.entries[q.id])
    }

    func testDismiss() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1")
        ch.ask(q)
        await b.refresh()
        ch.answerOutside(q.id, nil)
        await b.refresh()
        b.dismiss(q.id)
        XCTAssertNil(b.entries[q.id])
    }

    func testExpiredPermissionIsGone() async {
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let b = board(ch, box)
        let q = question(ch, "1", via: .permission, expiresAt: t0.addingTimeInterval(300))
        ch.ask(q)
        await b.refresh()
        box.date = t0.addingTimeInterval(300)
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .gone(at: box.date))
        await b.refresh()
        XCTAssertEqual(b.entries[q.id]?.state, .gone(at: box.date), "an expired question does not open again")
    }

    func testRestartFromTheStore() async throws {
        let store = MemoryStore()
        let ch = FakeQuestionChannel()
        let box = Box(t0, [ch.session("s1")])
        let q1 = question(ch, "1"), q2 = question(ch, "2")
        ch.ask(q1)
        ch.ask(q2)
        let first = board(ch, box, store: store)
        await first.refresh()
        try await first.answer(q1.id, answer(q1))

        // The channel still lists q1 for a while after the restart.
        ch.ask(q1)
        box.date = t0.addingTimeInterval(60)
        let second = board(ch, box, store: store)
        await second.load()
        await second.refresh()
        XCTAssertEqual(second.entries[q1.id]?.state, .answeredHere(answer(q1), at: t0), "an answered question is not new")
        XCTAssertEqual(second.entries[q2.id]?.firstSeen, t0, "an open question keeps its first time")
    }

    func testValidateEachKind() {
        let opts: [QuestionItem.Option] = [.init(label: "A"), .init(label: "B")]
        let cases: [(QuestionItem, QuestionAnswer.Item, Bool)] = [
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts), .init(id: "s", choices: ["A"]), true),
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts), .init(id: "s"), false),
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts), .init(id: "s", choices: ["A", "B"]), false),
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts), .init(id: "s", choices: ["C"]), false),
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts), .init(id: "s", other: "mine"), false),
            (QuestionItem(id: "s", text: "?", kind: .single, options: opts, allowsOther: true), .init(id: "s", other: "mine"), true),
            (QuestionItem(id: "m", text: "?", kind: .multi, options: opts), .init(id: "m", choices: ["A", "B"]), true),
            (QuestionItem(id: "m", text: "?", kind: .multi, options: opts), .init(id: "m"), false),
            (QuestionItem(id: "m", text: "?", kind: .multi, options: opts, allowsOther: true), .init(id: "m", choices: ["A"], other: "and C"), true),
            (QuestionItem(id: "f", text: "?", kind: .free), .init(id: "f", other: "text"), true),
            (QuestionItem(id: "f", text: "?", kind: .free), .init(id: "f", other: "  "), false),
            (QuestionItem(id: "f", text: "?", kind: .free), .init(id: "f"), false),
            (QuestionItem.approve(id: "p", text: "Run rm?"), .init(id: "p", choices: [QuestionItem.deny]), true),
            (QuestionItem.approve(id: "p", text: "Run rm?"), .init(id: "p"), false),
        ]
        for (i, (item, a, ok)) in cases.enumerated() {
            XCTAssertEqual((try? item.validate(a)) != nil, ok, "case \(i): \(item.kind) \(a)")
        }
    }
}

func XCTAssertThrowsAsync<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("did not throw", file: file, line: line)
    } catch {}
}
