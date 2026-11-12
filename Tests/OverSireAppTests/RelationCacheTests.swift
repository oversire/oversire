import AppKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class RelationCacheTests: XCTestCase {
    private func wait(_ cache: RelationCache, until ok: @escaping () -> Bool) {
        let e = expectation(description: "relations")
        func check() { if ok() { e.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check) } }
        DispatchQueue.main.async(execute: check)
        wait(for: [e], timeout: 5)
    }

    func testAddAndRemoveGoThroughTheTracker() throws {
        let fake = FakeTracker()
        var made: [ItemRef] = []
        let e = expectation(description: "items")
        Task {
            made.append(try await fake.create(ItemDraft(title: "Queue gate"), in: fake.project))
            made.append(try await fake.create(ItemDraft(title: "Plane relations"), in: fake.project))
            e.fulfill()
        }
        wait(for: [e], timeout: 5)
        let (a, b) = (made[0], made[1])
        let refs = [a.key: a, b.key: b]
        let cache = RelationCache(tracker: { _ in fake }, ref: { refs[$0] })
        XCTAssertTrue(cache.supports(a.key))
        var err: String?? = .none
        cache.apply(RelationPatch(add: [ItemRelation(kind: .blockedBy, item: b)]), to: a.key) { err = .some($0) }
        wait(cache) { err != nil && cache.relations(a.key) != nil }
        XCTAssertEqual(err, .some(nil))
        XCTAssertEqual(cache.relations(a.key)?.map(\.item.key), [b.key])
        XCTAssertEqual(cache.blockers(of: a.key) { _ in false }, [b.key])
        XCTAssertEqual(cache.blockers(of: a.key) { $0 == b.key }, [], "a done blocker does not hold")

        err = .none
        cache.apply(RelationPatch(remove: [ItemRelation(kind: .blockedBy, item: b)]), to: a.key) { err = .some($0) }
        wait(cache) { err != nil && cache.loading.isEmpty && cache.relations(a.key)?.isEmpty == true }
        XCTAssertEqual(cache.blockers(of: a.key) { _ in false }, [])
        var back: [ItemRelation]?
        let e2 = expectation(description: "back")
        Task { back = try await fake.relations(of: b); e2.fulfill() }
        wait(for: [e2], timeout: 5)
        XCTAssertEqual(back?.isEmpty, true, "the fake removed the relation on both items")
    }

    func testStateLine() {
        XCTAssertEqual(PlannerCard.state(open: ["OVERSIRE-80"], total: 2),
                       "Waits on 1 open blocker. The queue holds this item until OVERSIRE-80 is done.")
        XCTAssertEqual(PlannerCard.state(open: [], total: 2), "All 2 blockers are done. The queue can start this item.")
        XCTAssertEqual(PlannerCard.state(open: [], total: 0), "No blockers. The queue can start this item.")
    }

    // MARK: A failed read

    private struct Rig {
        let fake: FakeTracker
        let cache: RelationCache
        let ref: ItemRef
        let clock: ManualSchedule
        var key: String { ref.key }
    }

    private func rig() async throws -> Rig {
        let fake = FakeTracker()
        let a = try await fake.create(ItemDraft(title: "Queue gate"), in: fake.project)
        let clock = ManualSchedule()
        let cache = RelationCache(tracker: { _ in fake }, ref: { $0 == a.key ? a : nil }, schedule: clock.schedule)
        return Rig(fake: fake, cache: cache, ref: a, clock: clock)
    }

    private func texts(_ v: NSView) -> [String] {
        (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts)
    }

    private func buttons(_ v: NSView) -> [NSButton] {
        (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons)
    }

    private func card(_ r: Rig) -> PlannerCard {
        PlannerCard(read: r.cache.read(r.key)?.last, part: r.cache.part(r.key), store: TestAppData().projectStore, openBlockers: [], areas: nil,
                    actions: PlannerCard.Actions(open: { _ in }, add: { _ in }, remove: { _ in }, editAreas: {}))
    }

    @MainActor
    func testAFailedFirstReadShowsTheErrorNotASkeleton() async throws {
        let r = try await rig()
        r.fake.failRelationReads(times: 99)
        r.cache.load([r.key])
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.read(r.key)?.state, .failed("Plane did not answer."))
        XCTAssertEqual(r.cache.errors[r.key.uppercased()], "Plane did not answer.")
        XCTAssertNil(r.cache.relations(r.key), "no relations, so no empty list")
        let c = card(r)
        XCTAssertEqual(c.accessibilityLabel(), "Planner. The relations did not load.")
        XCTAssertTrue(texts(c).contains("The relations did not load."))
        XCTAssertTrue(texts(c).contains("Plane did not answer."))
        XCTAssertTrue(buttons(c).contains { $0.title == "Try again" })
    }

    @MainActor
    func testTheSkeletonShowsOnlyBeforeTheFirstRead() async throws {
        let r = try await rig()
        XCTAssertEqual(card(r).accessibilityLabel(), "Planner. Loading the relations.")
        r.cache.load([r.key])
        XCTAssertTrue(r.cache.loading.contains(r.key.uppercased()), "the state is busy when load returns")
        XCTAssertEqual(card(r).accessibilityLabel(), "Planner. Loading the relations.")
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.isEmpty, true)
        XCTAssertNotEqual(card(r).accessibilityLabel(), "Planner. Loading the relations.")
    }

    @MainActor
    func testTryAgainAfterAFailureReadsAgainAndShowsTheData() async throws {
        let r = try await rig()
        r.fake.failRelationReads(times: 1)
        r.cache.load([r.key])
        await r.cache.read(r.key)?.settled()
        XCTAssertTrue(r.cache.read(r.key)?.state.didFail == true)
        let again = buttons(card(r)).first { $0.title == "Try again" }
        XCTAssertNotNil(again)
        again?.performClick(nil)
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.isEmpty, true)
        XCTAssertNil(r.cache.errors[r.key.uppercased()])
        XCTAssertFalse(texts(card(r)).contains("The relations did not load."))
    }

    @MainActor
    func testAFailedReadTriesAgainByItself() async throws {
        let r = try await rig()
        r.fake.failRelationReads(times: 1)
        r.cache.load([r.key])
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.part(r.key)?.retry?.k, 1)
        r.clock.advance(5)
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.isEmpty, true)
        XCTAssertEqual(r.fake.relationReads, 2)
    }

    @MainActor
    func testAFailedReadDoesNotReadOnEachLoad() async throws {
        let r = try await rig()
        r.fake.failRelationReads(times: 99)
        for _ in 0..<5 {
            r.cache.load([r.key])
            await r.cache.read(r.key)?.settled()
        }
        XCTAssertEqual(r.fake.relationReads, 1)
    }

    @MainActor
    func testAProjectRefreshReadsFailedKeysAgain() async throws {
        let r = try await rig()
        r.fake.failRelationReads(times: 1)
        r.cache.load([r.key])
        await r.cache.read(r.key)?.settled()
        r.cache.refresh(changed: [r.key])
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.isEmpty, true)
        XCTAssertEqual(r.fake.relationReads, 2)
    }

    @MainActor
    func testAFailedNewReadKeepsTheOldRelations() async throws {
        let r = try await rig()
        let other = try await r.fake.create(ItemDraft(title: "Other"), in: r.fake.project)
        try await r.fake.apply(RelationPatch(add: [ItemRelation(kind: .blockedBy, item: other)]), to: r.ref)
        r.cache.load([r.key])
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.map(\.item.key), [other.key])
        r.fake.failRelationReads(times: 99)
        r.cache.load([r.key], force: true)
        await r.cache.read(r.key)?.settled()
        XCTAssertEqual(r.cache.relations(r.key)?.map(\.item.key), [other.key], "the old value stays")
        guard case .stale = r.cache.read(r.key)?.state else { return XCTFail("the state is stale") }
        XCTAssertEqual(r.cache.byKey[r.key.uppercased()]?.count, 1)
        let c = card(r)
        XCTAssertTrue(texts(c).contains { $0.hasPrefix("Read failed") })
        XCTAssertTrue(buttons(c).contains { $0.title == "Try again" })
        XCTAssertTrue(texts(c).contains(other.key), "the rows still show")
    }
}
