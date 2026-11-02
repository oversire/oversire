import XCTest
import OverSireCore
import OverSireAssistant
import OverSireTestKit
@testable import OverSireApp

/// OverSire does not close a parent with open sub-items without `force` (OVERSIRE-396).
final class CloseGuardTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    private var fake: FakeTracker!
    private var store: ProjectStore!
    private var parent: ItemRef!
    private var child: ItemRef!

    override func setUp() async throws {
        fake = FakeTracker()
        parent = try await fake.create(ItemDraft(title: "Parent"), in: fake.project)
        child = try await fake.create(ItemDraft(title: "Child", parent: parent.id), in: fake.project)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("close-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                             statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let snap = ProjectSnapshot(summary: try await fake.projects()[0], statusOptions: try await fake.statuses(fake.project),
                                   items: try await fake.items(fake.project, since: nil, limit: 50), fetchedAt: Date())
        let store = store!
        await MainActor.run { store.seed(snap) }
    }

    private func setStatus(_ ref: ItemRef, force: Bool = false) async -> Bool {
        let store = store!
        return await withCheckedContinuation { c in
            DispatchQueue.main.async { store.setStatus(itemId: ref.id, optionId: "s-done", force: force) { c.resume(returning: $0) } }
        }
    }

    private func state(_ ref: ItemRef) async throws -> String? { try await fake.detail(ref).item.statusOptionId }

    func testParentWithOpenSubItemDoesNotClose() async throws {
        let ok = await setStatus(parent)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.lastError, "\(parent.key) has 1 open sub-item. Close it first.")
        let s = try await state(parent)
        XCTAssertEqual(s, "s-todo", "no write")
    }

    func testForceClosesTheParent() async throws {
        _ = await setStatus(parent, force: true)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-done")
    }

    func testLeafCloses() async throws {
        _ = await setStatus(child)
        let s = try await state(child)
        XCTAssertEqual(s, "s-done")
    }

    func testUpdateWithAClosedStateIsBlocked() async throws {
        let store = store!, parent = parent!
        let ok = await withCheckedContinuation { c in
            DispatchQueue.main.async { store.update(itemId: parent.id, ItemPatch(status: "s-done"), failure: "x") { c.resume(returning: $0) } }
        }
        XCTAssertFalse(ok)
        let s = try await state(parent)
        XCTAssertEqual(s, "s-todo")
    }

    func testDialogText() {
        let one = CloseGuard.spec(key: "A-1", state: "Done", open: 1)
        XCTAssertEqual(one.title, "A-1 has 1 open sub-item")
        XCTAssertEqual(one.buttons, ["Close sub-item too", "Close anyway", "Cancel"])
        let three = CloseGuard.spec(key: "A-1", state: "Done", open: 3)
        XCTAssertEqual(three.info, "Done closes A-1. Close the open sub-items too, or close A-1 anyway and keep them open.")
        XCTAssertEqual(CloseGuard.Choice(rawValue: 2), .cancel, "the last button cancels")
    }
}
