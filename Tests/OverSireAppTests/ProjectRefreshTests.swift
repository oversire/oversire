import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane
@testable import OverSireApp

/// Fewer Plane calls: one refresh of a project at a time, a pause after a rate limit, no detail call for gone items (OVERSIRE-429).
final class ProjectRefreshTests: XCTestCase {
    /// A tracker whose items() waits until the test lets it go.
    final class SlowTracker: Tracker, @unchecked Sendable {
        let id: ProviderID = "slow"
        let account = AccountID(provider: "slow", id: "ws")
        let capabilities: Set<Capability> = []
        let pollPolicy = PollPolicy(minInterval: .seconds(60), requestsPerHour: 60)
        let keyFormat = KeyFormat.projectDash
        var project: ProjectRef { ProjectRef(account: account, id: "p1", key: "SLOW") }

        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var count = 0
        private var seenLimits: [Int] = []
        var limited = false
        var limits: [Int] { lock.withLock { seenLimits } }
        var calls: Int { lock.withLock { count } }
        var blocked: Int { lock.withLock { waiting.count } }

        func release() { lock.withLock { waiting.removeFirst() }.resume() }

        func probe() async throws -> Identity { Identity(person: PersonRef(id: "u1", name: "me")) }
        func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: Cursor(rawValue: "0")) }
        func projects() async throws -> [ProjectSummary] { [] }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] {
            if lock.withLock({ limited }) {
                lock.withLock { count += 1 }
                throw ProviderError.rateLimited(retryAfter: .seconds(5))
            }
            return []
        }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
            await withCheckedContinuation { c in lock.withLock { count += 1; seenLimits.append(limit); waiting.append(c) } }
            return []
        }
        func detail(_ i: ItemRef) async throws -> ItemDetail { throw ProviderError.notFound }
        func comments(_ i: ItemRef) async throws -> [Comment] { [] }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { throw ProviderError.notFound }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws {}
        func comment(_ i: ItemRef, markdown: String) async throws {}
    }

    private final class Trackers: TrackerDirectory {
        let t: any Tracker
        init(_ t: any Tracker) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    /// A directory whose tracker can come later, as after a failed Keychain read.
    private final class SwitchTrackers: TrackerDirectory {
        var t: (any Tracker)?
        var trackerIds: [String] { ["ws"] }
        func tracker(_ id: String) -> (any Tracker)? { id == "ws" ? t : nil }
        func trackerError(_ id: String) -> String? { t == nil ? "no token in the Keychain" : nil }
    }

    private func store(_ t: any Tracker) throws -> ProjectStore { try store(Trackers(t)) }

    private func store(_ trackers: TrackerDirectory) throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ProjectStore(trackers: trackers, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                            statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
    }

    private func until(_ what: String, _ ok: @escaping () -> Bool) async {
        for _ in 0..<200 where !ok() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ok(), what)
    }

    func testForcedRefreshesDuringOneGiveOneMore() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let key = summary.ref.storeKey
        var finished = 0
        await MainActor.run {
            store.track([summary], live: [])
            for _ in 0..<3 { store.refresh([key], force: true) { _ in finished += 1 } }
        }
        await until("the first refresh runs") { t.blocked == 1 }
        t.release()
        await until("one more refresh runs") { t.blocked == 1 && t.calls == 2 }
        t.release()
        await until("the three callers end with the second run") { finished == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls, 2, "3 forced refreshes during one give 1 more")
    }

    func testRateLimitPausesTheWorkspace() async throws {
        let t = SlowTracker()
        t.limited = true
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let key = summary.ref.storeKey
        await MainActor.run { store.track([summary], live: []) }
        await until("the refresh fails") { store.cooldown["ws"] != nil && !store.refreshing.contains(key) }
        let pause = store.cooldown["ws"]!.timeIntervalSinceNow
        XCTAssertGreaterThan(pause, 50, "at least cooldownMin")
        var result: Bool?
        await MainActor.run { store.refresh([key], force: true) { result = $0 } }
        XCTAssertEqual(result, false)
        XCTAssertEqual(t.calls, 1, "no call in the pause")
    }

    func testOtherMacWaitsForCloudEvents() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        store.leads = { false }
        store.otherMacDelay = 0.2
        await MainActor.run { store.track([summary], live: []) }
        await until("the poll refresh runs") { t.blocked == 1 }
        t.release()
        await until("the poll refresh ends") { store.refreshing.isEmpty }
        var result: Bool?
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: nil)]) { result = $0 } }
        XCTAssertEqual(result, true)
        XCTAssertEqual(t.calls, 1, "no refresh at once")
        await until("the refresh runs after the delay") { t.calls == 2 }
        t.release()
    }

    /// The intake list goes before the items, so the tracker knows the pending items when it walks the tree (OVERSIRE-456).
    final class OrderTracker: Tracker, IntakeTriaging, @unchecked Sendable {
        let id: ProviderID = "order"
        let account = AccountID(provider: "order", id: "ws")
        let capabilities: Set<Capability> = [.intake]
        let pollPolicy = PollPolicy(minInterval: .seconds(60), requestsPerHour: 60)
        let keyFormat = KeyFormat.projectDash
        private let lock = NSLock()
        private var seen: [String] = []
        var calls: [String] { lock.withLock { seen } }
        private func note(_ s: String) { lock.withLock { seen.append(s) } }

        func probe() async throws -> Identity { Identity(person: PersonRef(id: "u1", name: "me")) }
        func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: Cursor(rawValue: "0")) }
        func projects() async throws -> [ProjectSummary] { [] }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] { note("statuses"); return [] }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] { note("items"); return [] }
        func detail(_ i: ItemRef) async throws -> ItemDetail { throw ProviderError.notFound }
        func comments(_ i: ItemRef) async throws -> [Comment] { [] }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { throw ProviderError.notFound }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws {}
        func comment(_ i: ItemRef, markdown: String) async throws {}
        func intake(_ p: ProjectRef) async throws -> [IntakeItem] {
            note("intake")
            return [IntakeItem(id: "n1", workItemId: "w1", name: "Ask", priority: nil, createdAt: Date(), author: nil, source: nil)]
        }
        func intakeDetail(_ i: IntakeItem, in p: ProjectRef) async throws -> IntakeDetail { throw ProviderError.notFound }
        func triage(_ i: IntakeItem, in p: ProjectRef, _ a: IntakeAction) async throws {}
    }

    func testSnapshotReadsIntakeBeforeItems() async throws {
        let t = OrderTracker()
        let ref = ProjectRef(account: t.account, id: "p1", key: "ORD")
        let summary = ProjectSummary(ref: ref, identifier: "ORD", title: "Order", url: "https://x/ORD", closed: false)
        let snap = try await ProjectStore.snapshot(t, summary, limit: 10, previous: nil)
        XCTAssertEqual(t.calls, ["statuses", "intake", "items"])
        XCTAssertEqual(snap.intake?.map(\.workItemId), ["w1"])
    }

    // MARK: Plane

    /// Recorded Plane answers by method and path. Each request is counted.
    final class CountingPlane: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: String] = [:]
        private var broken: Set<String> = []
        private(set) var paths: [String] = []
        var count: Int { lock.withLock { paths.count } }

        func on(_ path: String, _ body: String) { lock.withLock { answers["GET " + path] = body } }
        func fail(_ path: String) { lock.withLock { _ = broken.insert("GET " + path) } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let key = (request.httpMethod ?? "GET") + " " + (request.url?.path(percentEncoded: false) ?? "")
            let (body, bad) = lock.withLock { paths.append(key); return (answers[key], broken.contains(key)) }
            let status = bad ? 500 : body == nil ? 404 : 200
            return (Data((body ?? #"{"detail":"none"}"#).utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let ws = "/api/v1/workspaces/acme"

    private func plane() -> (PlaneTracker, CountingPlane, ProjectSummary) {
        let http = CountingPlane()
        http.on("/api/v1/users/me/", #"{"id":"u1","display_name":"ada"}"#)
        http.on("\(ws)/members/", #"[{"member":{"id":"u1","display_name":"Ada"}}]"#)
        http.on("\(ws)/projects/P1/states/", ##"{"results":[{"id":"s1","name":"Todo","color":"#888888","group":"unstarted","sequence":1}]}"##)
        http.on("\(ws)/projects/P1/issues/", #"{"results":[{"id":"i1","name":"One","sequence_id":1,"state":"s1","updated_at":"2026-10-16T10:00:00Z","last_activity_at":"2026-10-16T10:00:00Z"},{"id":"i2","name":"Two","sequence_id":2,"state":"s1","parent":"i1","updated_at":"2026-10-16T11:00:00Z","last_activity_at":"2026-10-16T11:00:00Z"}],"next_page_results":false}"#)
        http.on("\(ws)/projects/P1/issues/i1/comments/", #"{"results":[]}"#)
        http.on("\(ws)/projects/P1/issues/i2/comments/", #"{"results":[]}"#)
        let p = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok", http: http)
        let summary = ProjectSummary(ref: ProjectRef(account: p.account, id: "P1", key: "ENG"), identifier: "ENG", title: "Engine",
                                     url: "https://app.plane.so/acme/projects/P1/issues/", closed: false)
        return (p, http, summary)
    }

    func testQuietRefreshMakesFewCalls() async throws {
        let (p, http, summary) = plane()
        let first = try await ProjectStore.snapshot(p, summary, limit: 50, previous: nil)
        XCTAssertEqual(first.items.count, 2)
        let before = http.count
        // A later poll: the index is old, nothing changed.
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await ProjectStore.snapshot(p, summary, limit: 50, previous: first)
        XCTAssertEqual(second.items.map(\.id).sorted(), ["i1", "i2"])
        let n = http.count - before
        XCTAssertLessThanOrEqual(n, 7, "calls of a quiet refresh: \(http.paths.suffix(n))")
        XCTAssertFalse(http.paths.suffix(n).contains { $0.hasSuffix("/states/") }, "the states are kept 10 minutes")
        let gone = await ProjectStore.gone(p, first, second)
        XCTAssertTrue(gone.isEmpty)
    }

    func testGoneUsesTheIndex() async throws {
        let (p, http, summary) = plane()
        let old = try await ProjectStore.snapshot(p, summary, limit: 50, previous: nil)
        var new = ProjectSnapshot(summary: old.summary, statusOptions: old.statusOptions, items: old.items.filter { $0.id != "i2" },
                                  fetchedAt: Date(), index: old.index)
        let before = http.count
        var gone = await ProjectStore.gone(p, old, new)
        XCTAssertTrue(gone.isEmpty, "i2 is in the index: it only left the item limit")
        new.index = new.index?.filter { $0.id != "i2" }
        gone = await ProjectStore.gone(p, old, new)
        XCTAssertEqual(gone, ["i2"])
        new.index = nil
        gone = await ProjectStore.gone(p, old, new)
        XCTAssertTrue(gone.isEmpty, "with no index, nothing is gone")
        XCTAssertEqual(http.count, before, "gone() makes no call")
    }

    func testFailedItemLoadKeepsTheOldItem() async throws {
        let (p, http, summary) = plane()
        p.indexMaxAge = 0
        let first = try await ProjectStore.snapshot(p, summary, limit: 50, previous: nil)
        // The index tells that i2 changed. Its load fails, so the old i2 stays.
        http.fail("\(ws)/projects/P1/issues/i2/")
        http.on("\(ws)/projects/P1/issues/", #"{"results":[{"id":"i1","name":"One","sequence_id":1,"state":"s1","updated_at":"2026-10-16T10:00:00Z","last_activity_at":"2026-10-16T10:00:00Z"},{"id":"i2","parent":"i1","state":"s1","last_activity_at":"2026-10-17T11:00:00Z"}],"next_page_results":false}"#)
        let second = try await ProjectStore.snapshot(p, summary, limit: 50, previous: first)
        XCTAssertEqual(second.items.map(\.id).sorted(), ["i1", "i2"], "no item drops out")
    }

    // MARK: Live projects and the item limit (OVERSIRE-457)

    private var order: ProjectSummary {
        ProjectSummary(ref: ProjectRef(account: AccountID(provider: "order", id: "ws"), id: "p1", key: "ORD"),
                       identifier: "ORD", title: "Order", url: "https://x/ORD", closed: false)
    }

    func testPollRetriesAFailedLiveProject() async throws {
        let dir = SwitchTrackers()
        let store = try store(dir)
        let key = order.ref.storeKey
        store.relayIsLive = { true }
        await MainActor.run { store.track([order], live: [key]) }
        await until("the refresh fails") { store.errors[key] != nil && store.refreshing.isEmpty }
        XCTAssertEqual(store.errors[key], ProjectStore.noToken + " (no token in the Keychain)")
        let t = OrderTracker()
        dir.t = t
        await MainActor.run { store.poll() }
        await until("the poll loads the live project again") { t.calls.contains("items") && store.errors[key] == nil }
    }

    func testPollRefreshesOnlyAStaleLiveProject() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        store.relayIsLive = { true }
        await MainActor.run { store.track([order], live: [key]) }
        await until("the first refresh ends") { store.snapshots[key] != nil && store.refreshing.isEmpty }
        let loads = { t.calls.filter { $0 == "items" }.count }
        await MainActor.run { store.poll() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(loads(), 1, "a fresh live project waits for its events")
        store.now = { Date().addingTimeInterval(3600) }
        await MainActor.run { store.poll() }
        await until("a stale live project polls") { loads() == 2 }
    }

    func testLimitChangeDuringARefreshRunsAgain() async throws {
        let saved = PROJECTS_CFG.itemsPerProject
        defer { PROJECTS_CFG.itemsPerProject = saved }
        PROJECTS_CFG.itemsPerProject = 10
        let t = SlowTracker()
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        await MainActor.run { store.track([summary], live: []) }
        await until("the first refresh runs") { t.blocked == 1 }
        PROJECTS_CFG.itemsPerProject = 0
        await MainActor.run { store.track([summary], live: []) }
        t.release()
        await until("one more refresh runs with the new limit") { t.blocked == 1 && t.calls == 2 }
        t.release()
        XCTAssertEqual(t.limits, [100, 200])
    }

    func testSnapshotLimitValues() {
        XCTAssertEqual(ProjectStore.snapshotLimit(itemsPerProject: 10), 100)
        XCTAssertEqual(ProjectStore.snapshotLimit(itemsPerProject: 25), 100)
        XCTAssertEqual(ProjectStore.snapshotLimit(itemsPerProject: 0), 200)
    }

    func testJoinedItemIsNotNews() async throws {
        let (p, http, summary) = plane()
        p.indexMaxAge = 0
        let first = try await ProjectStore.snapshot(p, summary, limit: 50, previous: nil)
        // i3 was in the index only. i4 is new.
        var previous = first
        previous.index = (first.index ?? []) + [ItemStub(id: "i3", parentId: nil, stateId: "s1", activityAt: nil)]
        let rows = [#"{"id":"i1","name":"One","sequence_id":1,"state":"s1","last_activity_at":"2026-10-16T10:00:00Z"}"#,
                    #"{"id":"i2","name":"Two","sequence_id":2,"state":"s1","parent":"i1","last_activity_at":"2026-10-16T11:00:00Z"}"#,
                    #"{"id":"i3","name":"Three","sequence_id":3,"state":"s1","last_activity_at":"2026-10-01T10:00:00Z"}"#,
                    #"{"id":"i4","name":"Four","sequence_id":4,"state":"s1","last_activity_at":"2026-10-17T10:00:00Z"}"#]
        http.on("\(ws)/projects/P1/issues/", #"{"results":[\#(rows.joined(separator: ","))],"next_page_results":false}"#)
        http.on("\(ws)/projects/P1/issues/i3/", rows[2])
        http.on("\(ws)/projects/P1/issues/i4/", rows[3])
        http.on("\(ws)/projects/P1/issues/i4/comments/", #"{"results":[]}"#)
        let second = try await ProjectStore.snapshot(p, summary, limit: 50, previous: previous)
        XCTAssertEqual(second.items.map(\.id).sorted(), ["i1", "i2", "i3", "i4"])
        XCTAssertFalse(http.paths.contains { $0.hasSuffix("/i3/comments/") }, "a joined item loads no comments")
        XCTAssertTrue(http.paths.contains { $0.hasSuffix("/i4/comments/") }, "a new item loads its comments")

        let store = try store(p)
        await MainActor.run {
            store.absorb(previous)
            store.absorb(second)
        }
        let added = store.activity(limit: 50, project: summary.ref.storeKey).filter {
            if case .added = $0.change { return true } else { return false }
        }.map(\.itemId)
        XCTAssertEqual(added, ["i4"], "only the new item is news")
    }
}
