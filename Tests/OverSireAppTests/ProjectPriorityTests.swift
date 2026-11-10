import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

/// A user call goes in the user lane of the rate gate. A poll stays in the background lane (OVERSIRE-456).
final class ProjectPriorityTests: XCTestCase {
    /// Wraps a FakeTracker and keeps the call priority that each call sees.
    final class Probe: Tracker, IntakeTriaging, IntakeKeying, StatusTimeline, @unchecked Sendable {
        let fake = FakeTracker()
        private let lock = NSLock()
        private var seen: [(name: String, priority: CallPriority)] = []

        var id: ProviderID { fake.id }
        var account: AccountID { fake.account }
        var capabilities: Set<Capability> { fake.capabilities }
        var pollPolicy: PollPolicy { fake.pollPolicy }
        var keyFormat: KeyFormat { fake.keyFormat }
        var project: ProjectRef { fake.project }

        func priorities(_ name: String) -> [CallPriority] { lock.withLock { seen.filter { $0.name == name }.map(\.priority) } }
        func clear() { lock.withLock { seen = [] } }
        private func note(_ name: String) { lock.withLock { seen.append((name, CallPriority.current)) } }

        func probe() async throws -> Identity { try await fake.probe() }
        func poll(since: Cursor?) async throws -> EventPage { try await fake.poll(since: since) }
        func projects() async throws -> [ProjectSummary] { try await fake.projects() }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] { note("statuses"); return try await fake.statuses(p) }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
            note("items")
            return try await fake.items(p, since: since, limit: limit)
        }
        func detail(_ i: ItemRef) async throws -> ItemDetail { try await fake.detail(i) }
        func comments(_ i: ItemRef) async throws -> [Comment] { note("comments"); return try await fake.comments(i) }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { try await fake.create(d, in: p) }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws { note("update"); try await fake.update(i, patch) }
        func comment(_ i: ItemRef, markdown: String) async throws { try await fake.comment(i, markdown: markdown) }
        func intake(_ p: ProjectRef) async throws -> [IntakeItem] { note("intake"); return try await fake.intake(p) }
        func intakeDetail(_ i: IntakeItem, in p: ProjectRef) async throws -> IntakeDetail {
            note("intakeDetail")
            return try await fake.intakeDetail(i, in: p)
        }
        func triage(_ i: IntakeItem, in p: ProjectRef, _ a: IntakeAction) async throws {
            note("triage")
            try await fake.triage(i, in: p, a)
        }
        func intakeSequences(_ p: ProjectRef) async throws -> [String: Int] {
            note("intakeSequences")
            return Dictionary(try await fake.intake(p).map { ($0.workItemId, 7) }, uniquingKeysWith: { a, _ in a })
        }
        func timeline(_ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] {
            note("timeline")
            return []
        }
    }

    private final class Trackers: TrackerDirectory {
        let t: Probe
        init(_ t: Probe) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    private var probe: Probe!
    private var store: ProjectStore!
    private var summary: ProjectSummary!
    private var intake: IntakeItem!
    private var item: ItemRef!
    private var key: String { summary.ref.storeKey }

    override func setUp() async throws {
        probe = Probe()
        let made = try await probe.fake.createIntake(ItemDraft(title: "Ask"), in: probe.project)
        intake = made.intake
        item = made.item
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("priority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ProjectStore(trackers: Trackers(probe), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                             statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        summary = try await probe.projects()[0]
        let snap = ProjectSnapshot(summary: summary, statusOptions: try await probe.fake.statuses(probe.project),
                                   items: try await probe.fake.items(probe.project, since: nil, limit: 50), fetchedAt: Date(),
                                   intake: [intake])
        let store = store!
        await MainActor.run { store.seed(snap) }
    }

    private func until(_ what: String, _ ok: @escaping () -> Bool) async {
        for _ in 0..<300 where !ok() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ok(), what)
    }

    func testPageLoadsRunAsUserCalls() async throws {
        let store = store!, key = key, item = item!, intake = intake!, probe = probe!
        let itemKey = try XCTUnwrap(store.item(item.id)?.item.key)
        await MainActor.run {
            store.comments(key: itemKey) { _ in }
            store.timeline(itemId: item.id) { _ in }
            store.intakeDetail(projectKey: key, item: intake) { _ in }
            store.loadIntakeKeys(projectKey: key) {}
            store.update(itemId: item.id, ItemPatch(title: "New"), failure: "x") { _ in }
            store.triage(projectKey: key, item: intake, action: .snooze(until: Date().addingTimeInterval(60))) { _ in }
        }
        for name in ["comments", "timeline", "intakeDetail", "intakeSequences", "update", "triage"] {
            await until("\(name) ran") { !probe.priorities(name).isEmpty }
            XCTAssertEqual(probe.priorities(name), [.user], name)
        }
    }

    func testAutomaticIntakeDetailIsBackground() async throws {
        let store = store!, key = key, intake = intake!, probe = probe!
        await MainActor.run { store.intakeDetail(projectKey: key, item: intake, priority: .background) { _ in } }
        await until("intakeDetail ran") { !probe.priorities("intakeDetail").isEmpty }
        XCTAssertEqual(probe.priorities("intakeDetail"), [.background])
    }

    func testPollIsBackgroundAndForcedWriteRefreshIsUser() async throws {
        let store = store!, summary = summary!, key = key, item = item!, probe = probe!
        await MainActor.run { store.track([summary], live: []) }
        await until("the poll refresh ran") { !probe.priorities("items").isEmpty && !store.refreshing.contains(key) }
        XCTAssertEqual(probe.priorities("items"), [.background])
        probe.clear()
        await MainActor.run { store.update(itemId: item.id, ItemPatch(title: "New"), failure: "x") { _ in } }
        await until("the refresh after the write ran") { !probe.priorities("items").isEmpty }
        XCTAssertEqual(probe.priorities("update"), [.user])
        XCTAssertEqual(probe.priorities("items"), [.user])
    }
}
