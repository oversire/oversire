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

    // MARK: The plan of a project

    private final class Plan {
        let fake = FakeTracker()
        let clock = ManualSchedule()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relation-cache-\(UUID().uuidString)")
        let project = "plane/ocral/p1"
        var refs: [String: ItemRef] = [:]
        var keys: [String] = []
        var updated: [String: Date] = [:]
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var disk = RelationDisk(folder: folder)
        lazy var cache = RelationCache(tracker: { [fake] _ in fake }, ref: { [unowned self] in refs[$0] },
                                       now: { [unowned self] in now }, schedule: clock.schedule,
                                       disk: disk, project: { [unowned self] in refs[$0] == nil ? nil : project },
                                       updatedAt: { [unowned self] in updated[$0] })

        func make(_ n: Int) async throws {
            for i in 0..<n {
                let r = try await fake.create(ItemDraft(title: "Plan item \(i)"), in: fake.project)
                refs[r.key] = r
                keys.append(r.key)
            }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor
    func testPrimeShowsThenLoadReplaces() async throws {
        let p = Plan()
        try await p.make(2)
        let (a, b) = (p.keys[0], p.keys[1])
        try await p.fake.apply(RelationPatch(add: [ItemRelation(kind: .blockedBy, item: p.refs[b]!)]), to: p.refs[a]!)
        let old = p.now.addingTimeInterval(-3600)
        p.cache.prime(a, [], at: old)
        XCTAssertEqual(p.cache.relations(a)?.isEmpty, true, "the cached relations show at once")
        XCTAssertEqual(p.cache.read(a)?.state, .fresh(old))
        p.cache.load([a])
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.cache.relations(a)?.map(\.item.key), [b], "a load replaces a primed key, so it is not seeded")
        XCTAssertEqual(p.fake.relationReads, 1)
        p.cache.load([a])
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.fake.relationReads, 1, "after the first read the key is loaded")
    }

    @MainActor
    func testLoadPlanSkipsFresh() async throws {
        let p = Plan()
        try await p.make(1)
        let a = p.keys[0]
        let edit = p.now.addingTimeInterval(-7200)
        try p.disk.save(project: p.project, [a.uppercased(): RelationDisk.Entry(relations: [], at: p.now.addingTimeInterval(-3600), itemUpdatedAt: edit)])
        p.cache.loadPlan([a], updatedAt: { _ in edit })
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.fake.relationReads, 0)
        XCTAssertEqual(p.cache.relations(a)?.isEmpty, true, "the disk entry shows")
        XCTAssertEqual(p.cache.progress([a]).loaded, 1)

        p.now = p.now.addingTimeInterval(86_400)
        p.cache.loadPlan([a], updatedAt: { _ in edit })
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.fake.relationReads, 1, "an entry older than maxAge loads again")
    }

    @MainActor
    func testLoadPlanStaleByUpdatedAt() async throws {
        let p = Plan()
        try await p.make(2)
        let (a, b) = (p.keys[0], p.keys[1])
        try await p.fake.apply(RelationPatch(add: [ItemRelation(kind: .blockedBy, item: p.refs[b]!)]), to: p.refs[a]!)
        let edit = p.now.addingTimeInterval(-7200)
        try p.disk.save(project: p.project, [a.uppercased(): RelationDisk.Entry(relations: [], at: p.now.addingTimeInterval(-3600), itemUpdatedAt: edit)])
        let later = edit.addingTimeInterval(60)
        p.updated[a] = later
        p.cache.loadPlan([a], updatedAt: { _ in later })
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.fake.relationReads, 1)
        XCTAssertEqual(p.cache.relations(a)?.map(\.item.key), [b])

        XCTAssertEqual(p.disk.load(project: p.project)[a.uppercased()]?.relations.isEmpty, true, "the write waits 1 s")
        p.clock.advance(1)
        let e = p.disk.load(project: p.project)[a.uppercased()]
        XCTAssertEqual(e?.relations.map(\.item.key), [b])
        XCTAssertEqual(e?.at, p.now)
        XCTAssertEqual(e?.itemUpdatedAt, later)

        p.cache.loadPlan([a], updatedAt: { _ in later })
        await p.cache.read(a)?.settled()
        XCTAssertEqual(p.fake.relationReads, 1, "the new entry is fresh")
    }

    @MainActor
    func testLoadPlanPriority() async throws {
        let p = Plan()
        try await p.make(25)
        p.cache.loadPlan(p.keys, updatedAt: { _ in nil })
        await until(timeout: .seconds(5)) { p.fake.relationReads == 25 && p.cache.loading.isEmpty }
        let prios = p.fake.relationReadPriorities
        XCTAssertEqual(prios.filter { $0 == .user }.count, 20)
        XCTAssertEqual(prios.filter { $0 == .background }.count, 5)
        XCTAssertEqual(p.cache.progress(p.keys).loaded, 25)
    }

    @MainActor
    func testLoadPlanRunsOneBackgroundReadAtATime() async throws {
        let p = Plan()
        try await p.make(4)
        p.cache.loadPlan(p.keys, updatedAt: { _ in nil }, first: 1)
        XCTAssertEqual(p.cache.loading.count, 2, "one user read and one background read")
        await until(timeout: .seconds(5)) { p.fake.relationReads == 4 && p.cache.loading.isEmpty }
    }

    @MainActor
    func testProgressCounts() async throws {
        let p = Plan()
        try await p.make(6)
        for k in p.keys.prefix(3) {
            p.cache.load([k])
            await p.cache.read(k)?.settled()
        }
        p.fake.failRelationReads(times: 99)
        p.cache.load([p.keys[3]])
        await p.cache.read(p.keys[3])?.settled()
        let got = p.cache.progress(p.keys)
        XCTAssertEqual(got.loaded, 3)
        XCTAssertEqual(got.total, 6)
        XCTAssertEqual(got.failed, 1)
    }
}
