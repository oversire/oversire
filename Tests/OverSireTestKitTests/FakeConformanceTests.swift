import XCTest
import OverSireCore
@testable import OverSireTestKit

final class FakeConformanceTests: XCTestCase {
    func testFakesPassProviderConformance() async {
        let tracker = await ProviderConformance.run { s in
            let t = FakeTracker()
            _ = try await t.create(ItemDraft(title: "Seed"), in: t.project)
            if s == .unauthorized { t.base.fail(.unauthorized) }
            return t
        }
        XCTAssertTrue(tracker.passed, tracker.description)
        let host = await ProviderConformance.run { s in
            let h = FakeCodeHost()
            if s == .unauthorized { h.base.fail(.unauthorized) }
            return h
        }
        XCTAssertTrue(host.passed, host.description)
        let ci = await ProviderConformance.run { s in
            let c = FakeCI()
            if s == .unauthorized { c.base.fail(.unauthorized) }
            return c
        }
        XCTAssertTrue(ci.passed, ci.description)
        let rt = await ProviderConformance.run { s in
            let r = FakeRuntime()
            if s == .unauthorized { r.base.fail(.unauthorized) }
            return r
        }
        XCTAssertTrue(rt.passed, rt.description)
    }

    func testFakesPassTheirLayerSuites() async {
        let tracker = await TrackerConformance.run { FakeTracker() }
        XCTAssertTrue(tracker.passed, tracker.description)
        let host = await CodeHostConformance.run { FakeCodeHost() }
        XCTAssertTrue(host.passed, host.description)
        let readOnly = await CodeHostConformance.run { FakeCodeHost(capabilities: []) }
        XCTAssertTrue(readOnly.passed, "a host without changeActions refuses actions: \(readOnly)")
        let ci = await CIConformance.run(repo: FakeCI().repo) { FakeCI() }
        XCTAssertTrue(ci.passed, ci.description)
        let noCancel = await CIConformance.run(repo: FakeCI().repo) { FakeCI(capabilities: [.rerun, .logs]) }
        XCTAssertTrue(noCancel.passed, noCancel.description)
        let rt = await RuntimeConformance.run(repo: "/fake/app") { FakeRuntime() }
        XCTAssertTrue(rt.passed, rt.description)
    }

    func testBrokenFakesFail() async {
        let logs = ProviderConformance.capabilities(FakeCodeHost(capabilities: [.changeActions, .logs]))
        XCTAssertEqual(logs.problems, ["capability logs needs LogReading"])
        let mute = ProviderConformance.capabilities(FakeRuntime(capabilities: []))
        XCTAssertEqual(Set(mute.problems), ["SessionIO needs the capability sessionInput", "SessionIO needs the capability sessionTail",
                                            "Revealing needs the capability reveal", "HostFileWriting needs the capability hostFiles",
                                            "SessionHistoryReading needs the capability sessionHistory"])
        let tailOnly = ProviderConformance.capabilities(FakeRuntime(capabilities: [.sessionTail, .reveal, .hostFiles, .sessionHistory]))
        XCTAssertTrue(tailOnly.passed, "one SessionIO capability is enough: \(tailOnly)")

        // A fake that accepts any token.
        let open = await ProviderConformance.run { _ in FakeCI() }
        XCTAssertEqual(open.problems, ["probe with a refused token did not throw", "poll with a refused token did not throw"])
        // A tracker that loses the update.
        let lossy = await TrackerConformance.run { LossyTracker() }
        XCTAssertEqual(lossy.problems, ["update did not change the title"])
    }

    func testFakeQuestionChannelPassesItsSuite() async {
        let r = await QuestionChannelConformance.run(sessions: [FakeQuestionChannel().session("s1")]) {
            let ch = FakeQuestionChannel()
            for (id, via) in [("1", SessionQuestion.Via.askReply), ("2", .form)] {
                ch.ask(SessionQuestion(id: QuestionID(rawValue: "fake:\(id)"), session: ch.session("s1"), origin: .session,
                                       items: [QuestionItem(id: "q1", text: "Which?", kind: .multi, options: [.init(label: "A")])],
                                       via: via, askedAt: Date(timeIntervalSince1970: 1)))
            }
            return ch
        }
        XCTAssertTrue(r.passed, r.description)
        let empty = await QuestionChannelConformance.run(sessions: []) { FakeQuestionChannel() }
        XCTAssertEqual(empty.problems, ["no answerable question to test"])
    }

    func testPollGivesEachEventOnce() async throws {
        let t = FakeTracker()
        let ref = try await t.create(ItemDraft(title: "A"), in: t.project)
        let first = try await t.poll(since: nil)
        try await t.comment(ref, markdown: "hi")
        let next = try await t.poll(since: first.cursor)
        XCTAssertEqual(first.events.map(\.action), ["created"])
        XCTAssertEqual(next.events.map(\.kind), [.comment])
        let none = try await t.poll(since: next.cursor)
        XCTAssertTrue(none.events.isEmpty)
    }

    func testMemoryStore() async throws {
        let store = MemoryStore()
        let stream = await store.changes()
        try await store.put(Pin(id: "p1", subject: .project(FakeTracker().project), at: Date(timeIntervalSince1970: 1)))
        try await store.delete(Pin.self, id: "p1")
        let all = try await store.all(Pin.self)
        XCTAssertEqual(all, [])
        var seen: [Bool] = []
        for await c in stream {
            seen.append(c.deleted)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [false, true])
    }
}

/// Drops each update.
final class LossyTracker: Tracker, @unchecked Sendable {
    let inner = FakeTracker()
    var id: ProviderID { inner.id }
    var account: AccountID { inner.account }
    var capabilities: Set<Capability> { inner.capabilities }
    var pollPolicy: PollPolicy { inner.pollPolicy }
    var keyFormat: KeyFormat { inner.keyFormat }
    func probe() async throws -> Identity { try await inner.probe() }
    func poll(since: Cursor?) async throws -> EventPage { try await inner.poll(since: since) }
    func projects() async throws -> [ProjectSummary] { try await inner.projects() }
    func statuses(_ p: ProjectRef) async throws -> [StatusOption] { try await inner.statuses(p) }
    func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] { try await inner.items(p, since: since, limit: limit) }
    func detail(_ i: ItemRef) async throws -> ItemDetail { try await inner.detail(i) }
    func comments(_ i: ItemRef) async throws -> [Comment] { try await inner.comments(i) }
    func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { try await inner.create(d, in: p) }
    func update(_ i: ItemRef, _ patch: ItemPatch) async throws {}
    func comment(_ i: ItemRef, markdown: String) async throws { try await inner.comment(i, markdown: markdown) }
}
