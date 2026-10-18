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
        XCTAssertEqual(SequenceCard.state(open: ["OVERSIRE-80"], total: 2),
                       "Waits on 1 open blocker. The queue holds this item until OVERSIRE-80 is done.")
        XCTAssertEqual(SequenceCard.state(open: [], total: 2), "All 2 blockers are done. The queue can start this item.")
        XCTAssertEqual(SequenceCard.state(open: [], total: 0), "No blockers. The queue can start this item.")
    }
}
