import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// The merged background write of the project state, and the kept digests (OVERSIRE-499).
final class ProjectSaveTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    /// The merged writes that the store asked for. The test runs them.
    private final class Held { var work: [() -> Void] = [] }

    private var dir: URL!
    private var statePath: String { dir.path + "/state.json" }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("project-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(_ held: Held, _ fake: FakeTracker = FakeTracker()) -> ProjectStore {
        ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(),
                     statePath: statePath, activityPath: dir.path + "/activity.jsonl",
                     schedule: { _, f in held.work.append(f) })
    }

    private func disk() throws -> [String: Any] {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: statePath), "state.json exists")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCloseSavesMergeIntoOneWrite() throws {
        let held = Held()
        let s = store(held)
        s.markRead(itemId: "a")
        s.markRead(itemId: "b")
        XCTAssertEqual(held.work.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath))
        held.work.forEach { $0() }
        s.flush()
        XCTAssertEqual(Set(try disk()["readItems"] as? [String] ?? []), ["a", "b"])
    }

    func testFlushWritesTheDueStateNow() throws {
        let held = Held()
        let s = store(held)
        s.markActivityRead("x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath))
        s.flush()
        XCTAssertEqual(try disk()["readActivity"] as? [String], ["x"])
        held.work.forEach { $0() }
        s.flush()
        XCTAssertEqual(try disk()["readActivity"] as? [String], ["x"])
    }

    func testASaveAfterTheWriteSchedulesAgain() {
        let held = Held()
        let s = store(held)
        s.markRead(itemId: "a")
        held.work.forEach { $0() }
        s.markRead(itemId: "b")
        XCTAssertEqual(held.work.count, 2, "a save after the merged write needs its own write")
    }

    func testANewStoreReadsTheFlushedState() async throws {
        let held = Held()
        let fake = FakeTracker()
        _ = try await fake.create(ItemDraft(title: "One"), in: fake.project)
        let s = store(held, fake)
        let summary = try await fake.projects()[0]
        await MainActor.run { s.track([summary], live: []) }
        for _ in 0..<300 where await MainActor.run(body: { s.snapshot("FAKE") }) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await MainActor.run { s.flush() }
        let second = store(Held(), fake)
        XCTAssertEqual(second.snapshot("FAKE")?.items.count, 1)
    }

    func testApplyLocalSettingsKeepsTheChangeCheckQuiet() async throws {
        let fake = FakeTracker()
        _ = try await fake.create(ItemDraft(title: "One"), in: fake.project)
        let s = store(Held(), fake)
        let summary = try await fake.projects()[0]
        let key = summary.ref.storeKey
        await MainActor.run { s.track([summary], live: []) }
        for _ in 0..<300 where await MainActor.run(body: { s.snapshot("FAKE") }) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let saved = PROJECTS_CFG.settings["FAKE"]
        defer { PROJECTS_CFG.settings["FAKE"] = saved }
        var changes: [DataChange] = []
        await MainActor.run {
            s.onChange = { changes.append($0) }
            PROJECTS_CFG.settings["FAKE", default: ProjectLocalSettings()].categories["s-todo"] = .done
            s.applyLocalSettings()
            changes.removeAll()
        }
        await withCheckedContinuation { c in
            DispatchQueue.main.async { s.refresh([key], force: false) { _ in c.resume() } }
        }
        let named = await MainActor.run { changes.contains { $0.projects.contains(key) } }
        XCTAssertFalse(named, "the digest ignores the local category, as on main")
    }
}
