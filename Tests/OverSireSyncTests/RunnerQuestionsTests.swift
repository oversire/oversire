import XCTest
import OverSireCore
@testable import OverSireSync
import OverSireTestKit

final class RunnerQuestionsTests: XCTestCase {
    /// Records each answer and clears the question or prompt on the record, as the hub does.
    final class FakeHub: RunnerAnswerSending, @unchecked Sendable {
        let store: MemoryStore
        private let lock = NSLock()
        private var log: [String] = []
        init(_ store: MemoryStore) { self.store = store }
        var sent: [String] { lock.withLock { log } }

        func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult {
            guard var r = try await store.get(RunnerSession.self, id: session), r.question?.id == answer.id else { return .alreadyAnswered }
            lock.withLock { log.append("answer \(answer.id) \(answer.items.flatMap(\.choices))") }
            r.question = nil
            r.state = .working
            try await store.put(r)
            return .sent
        }

        func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult {
            guard var r = try await store.get(RunnerSession.self, id: session), r.permission?.id == permission.id else { return .alreadyAnswered }
            lock.withLock { log.append("permission \(permission.id) \(permission.allow)") }
            r.permission = nil
            try await store.put(r)
            return .sent
        }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let item = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "APP"),
                              id: "i1", key: "APP-2", url: URL(string: "https://plane.example/APP-2")!)

    static func ref(_ id: String) -> SessionRef {
        SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "oversire", id: "local"), id: "app/APP-2"), id: id)
    }

    static func record(_ id: String, question: Bool = true, permission: Bool = false, state: RunnerSession.State = .waitingInput) -> RunnerSession {
        RunnerSession(id: id, runner: "r1", session: ref(id), order: "o1", agent: "claude", repo: "/src/app", item: item, state: state,
                      permission: permission ? PermissionPrompt(id: "p-1", tool: "Bash", text: "npm test", expiresAt: t0.addingTimeInterval(600)) : nil,
                      question: question ? RunnerQuestion(id: "toolu_1", items: [QuestionItem(id: "q1", text: "Which rule?", kind: .single,
                                                                                               options: [.init(label: "Fixed")], allowsOther: true)],
                                                          askedAt: t0) : nil,
                      startedAt: t0, updatedAt: t0)
    }

    static func channel(_ records: [RunnerSession]) async throws -> (RunnerQuestions, FakeHub) {
        let store = MemoryStore()
        for r in records { try await store.put(r) }
        let hub = FakeHub(store)
        return (RunnerQuestions(store: store, sender: hub, now: { Self.t0 }), hub)
    }

    func testQuestionAndPermissionGiveTwo() async throws {
        let (ch, _) = try await Self.channel([Self.record("s-1", permission: true), Self.record("s-2", question: false, state: .working),
                                         Self.record("s-3", state: .done)])
        let qs = try await ch.openQuestions(in: ["s-1", "s-2", "s-3"].map(Self.ref))
        XCTAssertEqual(qs.map(\.id.rawValue), ["runner:s-1:toolu_1", "runner:s-1:p-1"])
        XCTAssertEqual(qs.map(\.via), [.runnerInput, .permission])
        XCTAssertEqual(qs[0].origin, .work(Self.item))
        XCTAssertEqual(qs[1].items, [.approve(id: "permission", header: "Bash", text: "npm test")])
        XCTAssertEqual(qs[1].expiresAt, Self.t0.addingTimeInterval(600))
        let none = try await ch.openQuestions(in: [Self.ref("s-9")])
        XCTAssertEqual(none, [])
    }

    func testAnswerWithNoQuestionSendsNothing() async throws {
        let (ch, hub) = try await Self.channel([Self.record("s-1")])
        let q = try await ch.openQuestions(in: [Self.ref("s-1")])[0]
        try await hub.store.put(Self.record("s-1", question: false, state: .working))
        let a = QuestionChannelConformance.answer(for: q)
        let r = try await ch.answer(q, a)
        XCTAssertEqual(r, .alreadyAnswered)
        XCTAssertEqual(hub.sent, [])
    }

    func testPermissionAnswer() async throws {
        let (ch, hub) = try await Self.channel([Self.record("s-1", question: false, permission: true, state: .waitingPermission)])
        let q = try await ch.openQuestions(in: [Self.ref("s-1")])[0]
        let r = try await ch.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "permission", choices: [QuestionItem.deny])]))
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(hub.sent, ["permission p-1 false"])
    }

    func testChangesFollowTheStore() async throws {
        let (ch, hub) = try await Self.channel([])
        var it = ch.changes!.makeAsyncIterator()
        try await hub.store.put(Pin(id: "x", subject: .item(Self.item), at: Self.t0))
        try await hub.store.put(Self.record("s-1"))
        let got: Void? = await it.next()
        XCTAssertNotNil(got)
    }

    func testConformance() async {
        let r = await QuestionChannelConformance.run(sessions: [Self.ref("s-1")]) {
            try await Self.channel([Self.record("s-1", permission: true)]).0
        }
        XCTAssertTrue(r.passed, r.description)
    }
}
