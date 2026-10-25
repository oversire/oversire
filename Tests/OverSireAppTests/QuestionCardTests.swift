import OverSireCore
import XCTest
@testable import OverSireApp

final class QuestionCardTests: XCTestCase {
    private let session = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "t1")
    private let single = QuestionItem(id: "q1", text: "Which store?", kind: .single, options: [.init(label: "SQLite"), .init(label: "JSON")],
                                      allowsOther: true)
    private let multi = QuestionItem(id: "q2", text: "Which tests?", kind: .multi, options: [.init(label: "Unit"), .init(label: "uishots"), .init(label: "Live")])

    @MainActor
    private func card(_ items: [QuestionItem], via: SessionQuestion.Via = .form, sent: ((QuestionAnswer) -> Void)? = nil) -> QuestionCard {
        let q = SessionQuestion(id: "orca:local:m1", session: session, origin: .session, items: items, via: via, askedAt: Date())
        var a = QuestionCard.Actions()
        if let sent { a.send = sent }
        a.reveal = {}
        return QuestionCard(QuestionBoard.Entry(question: q, state: .open, firstSeen: Date()), place: QuestionPlace(runtime: "Orca", host: "this Mac"),
                            checkedAt: nil, actions: a)
    }

    @MainActor
    func testSendIsOffUntilEachItemIsValid() {
        var got: [QuestionAnswer] = []
        let c = card([single, multi]) { got.append($0) }
        XCTAssertEqual(c.sendButton?.isEnabled, false)
        c.pick(0, of: "q1")
        XCTAssertEqual(c.sendButton?.isEnabled, false)
        c.send()
        XCTAssertTrue(got.isEmpty)
        c.pick(2, of: "q2")
        XCTAssertEqual(c.sendButton?.isEnabled, true)
        c.send()
        XCTAssertEqual(got.first?.items.map(\.choices), [["SQLite"], ["Live"]])
    }

    @MainActor
    func testMultiKeepsMoreThanOneChoice() {
        let c = card([multi])
        c.pick(0, of: "q2")
        c.pick(1, of: "q2")
        XCTAssertEqual(c.draft.choices["q2"], ["Unit", "uishots"])
        c.pick(0, of: "q2")
        XCTAssertEqual(c.draft.choices["q2"], ["uishots"])
    }

    @MainActor
    func testSingleKeepsOneChoiceAndOtherTextReplacesIt() {
        let c = card([single])
        c.pick(0, of: "q1")
        c.pick(1, of: "q1")
        XCTAssertEqual(c.draft.choices["q1"], ["JSON"])
        c.write("Postgres", in: "q1")
        XCTAssertEqual(c.draft.choices["q1"], [])
        XCTAssertTrue(c.canSend)
        XCTAssertEqual(c.draft.answer(c.question).items.first?.other, "Postgres")
    }

    @MainActor
    func testWaitingHasNoSend() {
        var got: [QuestionAnswer] = []
        let c = card([single], via: .waiting) { got.append($0) }
        XCTAssertNil(c.sendButton)
        c.pick(0, of: "q1")
        c.send()
        XCTAssertTrue(got.isEmpty)
        XCTAssertFalse(c.canSend)
    }

    @MainActor
    func testApproveSendsOnPick() {
        var got: [QuestionAnswer] = []
        let c = card([.approve(id: "p", text: "npm test")], via: .permission) { got.append($0) }
        c.pick(1, of: "p")
        XCTAssertEqual(got.first?.items.first?.choices, [QuestionItem.deny])
    }

    @MainActor
    func testDraftStaysWhenTheBoardRedraws() {
        let c = card([single])
        c.pick(0, of: "q1")
        var e = c.entry
        e.stale = true
        c.update(e, checkedAt: Date())
        XCTAssertEqual(c.draft.choices["q1"], ["SQLite"])
        XCTAssertTrue(c.canSend)
    }

    @MainActor
    func testAnswerToAnOfflineRunnerSaysSent() {
        let q = SessionQuestion(id: "runner:s1:m1", session: session, origin: .session, items: [single], via: .runnerInput, askedAt: Date())
        let answered = QuestionBoard.Entry(question: q, state: .answeredHere(QuestionAnswer(question: q.id, items: []), at: Date()), firstSeen: Date())
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        let place = QuestionPlace(runtime: "OverSire runner", host: "mba", local: false)
        var offline = place
        offline.offline = true
        XCTAssertTrue(texts(QuestionCard(answered, place: offline, checkedAt: nil, actions: .init())).contains("Sent, the runner is offline"))
        XCTAssertTrue(texts(QuestionCard(answered, place: place, checkedAt: nil, actions: .init())).contains("Session works"))
    }

    func testSpan() {
        XCTAssertEqual(QuestionCard.span(20), "now")
        XCTAssertEqual(QuestionCard.span(4 * 60), "4 min")
        XCTAssertEqual(QuestionCard.span(65 * 60), "1 h 5 min")
        XCTAssertEqual(QuestionCard.span(120 * 60), "2 h")
    }
}
