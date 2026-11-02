import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

/// A Done parent with open sub-items goes back to an open state (OVERSIRE-397).
final class ParentGuardTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    private var fake: FakeTracker!
    private var store: ProjectStore!
    private var guardian: ParentGuard!
    private var parent: ItemRef!
    private var child: ItemRef!
    private var dir: URL!

    override func setUp() async throws {
        fake = FakeTracker()
        parent = try await fake.create(ItemDraft(title: "Parent"), in: fake.project)
        child = try await fake.create(ItemDraft(title: "Child", parent: parent.id), in: fake.project)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("parent-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                             statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        guardian = ParentGuard(path: dir.path + "/parent-guard.json", store: store)
        guardian.enabled = { true }
    }

    private func snap() async throws -> ProjectSnapshot {
        ProjectSnapshot(summary: try await fake.projects()[0], statusOptions: try await fake.statuses(fake.project),
                        items: try await fake.items(fake.project, since: nil, limit: 50), fetchedAt: Date())
    }

    /// Sets the state in the tracker, then runs one check with a fresh snapshot.
    private func poll(_ state: String? = nil, _ ref: ItemRef? = nil) async throws {
        if let state { try await fake.update(ref ?? parent, ItemPatch(status: state)) }
        let s = try await snap()
        let store = store!, g = guardian!
        await MainActor.run {
            store.seed(s)
            g.check([s])
        }
    }

    private func state(_ ref: ItemRef) async throws -> String? { try await fake.detail(ref).item.statusOptionId }

    /// The state after the async write, or the old state after 1 s.
    private func settled(_ ref: ItemRef, from old: String?) async throws -> String? {
        for _ in 0..<50 {
            let s = try await state(ref)
            if s != old, try await !fake.detail(ref).comments.isEmpty { return s }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await state(ref)
    }

    func testReopensToTheLastOpenStateWithOneComment() async throws {
        try await poll("s-review")
        try await poll("s-done")
        let s = try await settled(parent, from: "s-done")
        XCTAssertEqual(s, "s-review")
        let comments = try await fake.detail(parent).comments
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.body,
                       "OverSire moved this item back to In Review. 1 sub-item is open: \(child.key). Close it first, or close this item again to keep it Done.")
    }

    func testFallsBackToTheFirstStartedState() async throws {
        try await poll("s-done")
        let s = try await settled(parent, from: "s-done")
        XCTAssertEqual(s, "s-doing")
    }

    func testSecondCloseStays() async throws {
        try await poll("s-done")
        _ = try await settled(parent, from: "s-done")
        try await poll("s-done")
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-done", "one reopen for each close")
        let n = try await fake.detail(parent).comments.count
        XCTAssertEqual(n, 1)
    }

    func testMarkEndsWhenTheItemIsFinished() async throws {
        try await poll("s-done")
        _ = try await settled(parent, from: "s-done")
        XCTAssertNotNil(guardian.memory.reopened[parent.id])
        try await poll("s-done", child)
        try await poll("s-done")
        XCTAssertNil(guardian.memory.reopened[parent.id], "parent and child are closed")
    }

    func testNoWriteWithoutTheLease() async throws {
        guardian.mayAct = { false }
        try await poll("s-done")
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-done")
    }

    func testNoWriteWhenOff() async throws {
        guardian.enabled = { false }
        try await poll("s-done")
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-done")
    }

    func testOldCloseIsSkipped() async throws {
        guardian.now = { Date().addingTimeInterval(8 * 86400) }
        try await poll("s-done")
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-done")
    }

    func testMemoryPersists() async throws {
        try await poll("s-review")
        let again = ParentGuard(path: dir.path + "/parent-guard.json", store: store)
        XCTAssertEqual(again.memory.lastOpen[parent.id], "s-review")
    }
}
