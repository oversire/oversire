import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import TrackerPlane
import TrackerBigTimer
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
        private var waiting: [(project: String, go: CheckedContinuation<Void, Never>)] = []
        private var count = 0
        private var seenLimits: [Int] = []
        private var seenLanes: [(project: String, lane: CallPriority)] = []
        var limited = false
        var failCreate = false
        private var itemList: [Item] = []
        var list: [Item] { get { lock.withLock { itemList } } set { lock.withLock { itemList = newValue } } }
        var limits: [Int] { lock.withLock { seenLimits } }
        var calls: Int { lock.withLock { count } }
        var blocked: Int { lock.withLock { waiting.count } }

        func release() { lock.withLock { waiting.removeFirst() }.go.resume() }
        func release(_ project: String) {
            lock.withLock { waiting.firstIndex { $0.project == project }.map { waiting.remove(at: $0) } }?.go.resume()
        }
        func blocked(_ project: String) -> Int { lock.withLock { waiting.filter { $0.project == project }.count } }
        /// The lane of each call of items() for a project, in call order.
        func lanes(_ project: String) -> [CallPriority] { lock.withLock { seenLanes.filter { $0.project == project }.map(\.lane) } }

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
            await withCheckedContinuation { c in lock.withLock {
                count += 1; seenLimits.append(limit); seenLanes.append((p.id, CallPriority.current)); waiting.append((p.id, c))
            } }
            return lock.withLock { itemList }
        }
        func detail(_ i: ItemRef) async throws -> ItemDetail { throw ProviderError.notFound }
        func comments(_ i: ItemRef) async throws -> [Comment] { [] }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef {
            if lock.withLock({ failCreate }) { throw ProviderError.notFound }
            let n = lock.withLock { created += 1; return created }
            return ItemRef(project: p, id: "i\(n)", key: "SLOW-\(n)", url: URL(string: "https://x/SLOW-\(n)")!)
        }
        private var created = 0
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

    private var lastState = ""

    private func store(_ t: any Tracker) throws -> ProjectStore { try store(Trackers(t)) }

    private func store(_ trackers: TrackerDirectory) throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastState = dir.path + "/state.json"
        return ProjectStore(trackers: trackers, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                            statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
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
        await until("the first refresh runs", timeout: .seconds(2)) { t.blocked == 1 }
        t.release()
        await until("one more refresh runs", timeout: .seconds(2)) { t.blocked == 1 && t.calls == 2 }
        t.release()
        await until("the three callers end with the second run", timeout: .seconds(2)) { finished == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls, 2, "3 forced refreshes during one give 1 more")
    }

    private func summary(_ id: String) -> ProjectSummary {
        let ref = ProjectRef(account: AccountID(provider: "slow", id: "ws"), id: id, key: id.uppercased())
        return ProjectSummary(ref: ref, identifier: id.uppercased(), title: id, url: "https://x/\(id)", closed: false)
    }

    /// A write waits for its own project only, not for the other projects of a poll.
    func testForcedUserRefreshTakesAProjectThatThePollDidNotRead() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let a = summary("a"), b = summary("b")
        var result: Bool?
        await MainActor.run { store.track([a, b], live: []) }
        await until("the poll reads a", timeout: .seconds(2)) { t.blocked("a") == 1 }
        await MainActor.run { store.refresh([b.ref.storeKey], force: true, priority: .user) { result = $0 } }
        await until("the write refresh reads b at once", timeout: .seconds(2)) { t.blocked("b") == 1 }
        t.release("b")
        await until("the write refresh ends while the poll reads a", timeout: .seconds(2)) { result == true }
        XCTAssertEqual(t.blocked("a"), 1)
        t.release("a")
        await until("the poll ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
        XCTAssertEqual(t.calls, 2, "the poll does not read b again")
    }

    // MARK: Writes (OVERSIRE-565)

    private func slowItem(_ id: String, status: String = "a", title: String = "T") -> Item {
        let at = Date(timeIntervalSince1970: 1000)
        return Item(id: id, key: "SLOW-\(id.dropFirst())", title: title, url: "https://x/\(id)", statusOptionId: status, fields: [:],
                    assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil,
                    mentionsMe: false)
    }

    private let robot = EventActor(type: .agent, name: "codex")

    /// A store with one read done: the snapshot holds item i1 with the status "a". No read runs.
    private func loaded(_ t: SlowTracker) async throws -> (store: ProjectStore, key: String) {
        t.list = [slowItem("i1")]
        let store = try store(t)
        let p = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let key = t.project.storeKey
        await MainActor.run { store.track([p], live: []) }
        await until("the first read runs", timeout: .seconds(2)) { t.blocked == 1 }
        t.release()
        await until("the first read ends", timeout: .seconds(2)) { store.refreshing.isEmpty && store.snapshots[key] != nil }
        return (store, key)
    }

    private func setStatus(_ store: ProjectStore, _ id: String, _ status: String, by actor: EventActor? = nil) async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.main.async { store.setStatus(itemId: id, optionId: status, by: actor ?? self.robot) { c.resume(returning: $0) } }
        }
    }

    func testWriteAnswersBeforeTheRefreshAndPatchesTheSnapshot() async throws {
        let t = SlowTracker()
        let (store, key) = try await loaded(t)
        let ok = await setStatus(store, "i1", "b")
        XCTAssertTrue(ok)
        await until("the refresh waits", timeout: .seconds(2)) { t.blocked == 1 }
        let seen = await MainActor.run { (store.snapshots[key]?.items.first?.statusOptionId, store.writeActors["i1"]) }
        XCTAssertEqual(seen.0, "b", "the view shows the write")
        XCTAssertEqual(seen.1, robot)
        await MainActor.run { store.flush() }
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: lastState))) as? [String: Any]
        let saved = ((disk?["snapshots"] as? [String: Any])?[key] as? [String: Any])?["items"] as? [[String: Any]]
        XCTAssertEqual(saved?.first?["statusOptionId"] as? String, "a", "the disk holds the base")
        t.list = [slowItem("i1", status: "c")]
        t.release()
        await until("the patch and the mark end", timeout: .seconds(2)) { store.writeActors.isEmpty }
        let after = await MainActor.run { store.snapshots[key]?.items.first?.statusOptionId }
        XCTAssertEqual(after, "c", "the read replaces the patch")
    }

    func testTwoWritesKeepTheMarkUntilTheLastRead() async throws {
        let t = SlowTracker()
        let (store, _) = try await loaded(t)
        let first = await setStatus(store, "i1", "b")
        XCTAssertTrue(first)
        await until("the first refresh waits", timeout: .seconds(2)) { t.blocked == 1 }
        let second = await setStatus(store, "i1", "c")
        XCTAssertTrue(second)
        t.release()
        await until("the second read waits", timeout: .seconds(2)) { t.blocked == 1 && t.calls == 3 }
        let kept = await MainActor.run { store.writeActors["i1"] }
        XCTAssertEqual(kept, robot, "the first read does not cover the second write")
        t.release()
        await until("the mark ends", timeout: .seconds(2)) { store.writeActors.isEmpty }
    }

    func testALocalWriteEndsAfterItsKeepTime() async throws {
        let t = SlowTracker()
        let (store, key) = try await loaded(t)
        await MainActor.run { store.localWriteKeep = 0.05 }
        let ok = await setStatus(store, "i1", "b")
        XCTAssertTrue(ok)
        await until("the write expires", timeout: .seconds(2)) {
            store.writeActors.isEmpty && store.snapshots[key]?.items.first?.statusOptionId == "a"
        }
    }

    func testAReadThatStartedBeforeTheWriteKeepsThePatch() async throws {
        let t = SlowTracker()
        let (store, key) = try await loaded(t)
        await MainActor.run { store.refresh([key], force: true, priority: .user) { _ in } }
        await until("the read runs", timeout: .seconds(2)) { t.blocked == 1 }
        let ok = await setStatus(store, "i1", "b")
        XCTAssertTrue(ok)
        t.release()
        await until("the rerun waits", timeout: .seconds(2)) { t.blocked == 1 && t.calls == 3 }
        let kept = await MainActor.run { store.snapshots[key]?.items.first?.statusOptionId }
        XCTAssertEqual(kept, "b", "the old read does not hide the write")
        t.release()
        await until("the next read replaces the patch", timeout: .seconds(2)) {
            store.writeActors.isEmpty && store.snapshots[key]?.items.first?.statusOptionId == "a"
        }
    }

    func testPatchedKeepsCreatedAtAndSetsDates() throws {
        let t = SlowTracker()
        var item = slowItem("i1")
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let ref = t.project
        let summary = ProjectSummary(ref: ref, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let snap = ProjectSnapshot(summary: summary, statusOptions: [], items: [item], fetchedAt: Date(), fields: [])
        let patch = ItemPatch(startDate: "2026-11-01", dueDate: "", estimate: "M")
        let changes = ProjectStore.localChanges(patch, in: snap)
        XCTAssertEqual(changes, [.field(name: Item.startField, value: "2026-11-01"), .field(name: Item.dueField, value: nil), .field(name: Item.estimateField, value: "M")])
        let w = LocalWrite(project: ref.storeKey, at: Date(), marks: [], items: ["i1": changes], epics: [])
        let out = ProjectStore.patched(snap, [w]).items[0]
        XCTAssertEqual(out.createdAt, item.createdAt)
        XCTAssertEqual(out.startDate, "2026-11-01")
        XCTAssertNil(out.dueDate)
        XCTAssertEqual(out.estimate, "M")
    }

    func testPatchedAppliesTheChangesInOrder() throws {
        let t = SlowTracker()
        var item = slowItem("i1")
        item.parentId = "p1"
        item.epicId = "e1"
        item.otherEpicIds = ["e2"]
        let ref = t.project
        let summary = ProjectSummary(ref: ref, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let snap = ProjectSnapshot(summary: summary, statusOptions: [], items: [item, slowItem("i2")], fetchedAt: Date(),
                                   fields: [ProjectField(id: "priority", name: "Priority", options: StatusOption.priorities)])
        let patch = ItemPatch(title: "New", status: "s2", priority: "urgent", labels: ["l"], parent: "", bodyMarkdown: "Body")
        XCTAssertEqual(ProjectStore.localChanges(patch, in: snap),
                       [.title("New"), .body("Body"), .status("s2"), .priority("Urgent"), .parent(nil)])
        XCTAssertEqual(ProjectStore.localChanges(ItemPatch(priority: "none"), in: snap), [.priority(nil)])
        XCTAssertEqual(ProjectStore.localChanges(ItemPatch(priority: "zzz", assignees: ["me"]), in: snap), [])
        let epic = Epic(id: "e3", title: "E", state: .active, url: "https://x/e3", project: ref)
        let w = LocalWrite(project: ref.storeKey, at: Date(), marks: [], items: [
            "i1": ProjectStore.localChanges(patch, in: snap) + [.status("s3"), .epic("e3")], "gone": [.status("x")]], epics: [epic])
        let out = ProjectStore.patched(snap, [w])
        let i1 = out.items[0]
        XCTAssertEqual(i1.title, "New")
        XCTAssertEqual(i1.body, "Body")
        XCTAssertEqual(i1.statusOptionId, "s3", "the last change wins")
        XCTAssertEqual(i1.fields["Priority"], "Urgent")
        XCTAssertNil(i1.parentId)
        XCTAssertEqual(i1.epicId, "e3")
        XCTAssertNil(i1.otherEpicIds)
        XCTAssertEqual(out.items[1], snap.items[1])
        XCTAssertEqual(out.items.count, 2)
        XCTAssertEqual(out.epics, [epic], "a nil epic list gets the epic")
        XCTAssertEqual(out.fetchedAt, snap.fetchedAt)
        XCTAssertEqual(snap.items[0].title, "T", "the base does not change")
        XCTAssertEqual(snap.items[0].parentId, "p1")
        let clear = ProjectStore.patched(i1, [.priority(nil)])
        XCTAssertNil(clear.fields["Priority"])
        var renamed = epic
        renamed.title = "E2"
        let again = ProjectStore.patched(out, [LocalWrite(project: ref.storeKey, at: Date(), marks: [], items: [:], epics: [renamed])])
        XCTAssertEqual(again.epics, [renamed], "the same id replaces the epic")
    }

    // MARK: Create (OVERSIRE-540)

    func testCreateAnswersBeforeTheRefresh() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let p = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let key = t.project.storeKey
        var made: Result<MadeItem, ProviderError>?
        await MainActor.run { store.track([p], live: []) }
        await until("the first read runs", timeout: .seconds(2)) { t.blocked == 1 }
        t.release()
        await until("the first read ends", timeout: .seconds(2)) { store.refreshing.isEmpty && store.snapshots[key] != nil }
        await MainActor.run { store.create(NewItem(projectKey: key, title: "T", body: "", fieldOptions: [:]), by: EventActor(type: .agent, name: "a")) { made = $0 } }
        await until("create answers", timeout: .seconds(2)) { made != nil }
        guard case .success(let m)? = made else { return XCTFail("\(String(describing: made))") }
        XCTAssertEqual(m.ref.key, "SLOW-1")
        await until("the refresh waits", timeout: .seconds(2)) { t.blocked == 1 }
        let marked = await MainActor.run { store.writeActors[m.ref.id] }
        XCTAssertNotNil(marked)
        let found = await MainActor.run { store.item(key: "slow-1")?.item.id }
        XCTAssertEqual(found, m.ref.id, "the stub answers before a snapshot has the item")
        t.release()
        await until("the mark ends with the refresh", timeout: .seconds(2)) { store.writeActors.isEmpty }
        let after = await MainActor.run { store.item(m.ref.id) }
        XCTAssertNotNil(after, "the stub stays until a snapshot holds the item or it expires")
    }

    func testCreateFailureStartsNoRefresh() async throws {
        let t = SlowTracker()
        t.failCreate = true
        let store = try store(t)
        let key = t.project.storeKey
        var made: Result<MadeItem, ProviderError>?
        await MainActor.run { store.absorb(snap(ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false), at: Date())) }
        await MainActor.run { store.create(NewItem(projectKey: key, title: "T", body: "", fieldOptions: [:])) { made = $0 } }
        await until("create answers", timeout: .seconds(2)) { made != nil }
        guard case .failure? = made else { return XCTFail("\(String(describing: made))") }
        XCTAssertNotNil(store.lastError)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls, 0)
    }

    // MARK: Page view, wake and watchdog (OVERSIRE-463)

    /// Swaps APP_LOG for the test.
    private func capture() -> (lines: IOLogTests.Lines, restore: () -> Void) {
        let lines = IOLogTests.Lines(), saved = APP_LOG
        APP_LOG = lines
        return (lines, { APP_LOG = saved })
    }

    private func pollLines(_ l: IOLogTests.Lines, _ level: LogLevel) -> [LogEntry] {
        l.all.filter { $0.job.hasSuffix(" poll") && $0.level == level }
    }

    private func snap(_ p: ProjectSummary, at: Date) -> ProjectSnapshot {
        ProjectSnapshot(summary: p, statusOptions: [], items: [], fetchedAt: at)
    }

    /// The poll reads a. A user refresh takes the key and its read parks. The call of the poll is still parked.
    private func takeA(_ t: SlowTracker, _ store: ProjectStore, _ a: ProjectSummary, done: @escaping (Bool) -> Void) async {
        await until("the poll reads a", timeout: .seconds(2)) { t.blocked("a") == 1 }
        await MainActor.run { store.refresh([a.ref.storeKey], force: true, priority: .user, done: done) }
        await until("the user read of a runs", timeout: .seconds(2)) { t.blocked("a") == 2 }
    }

    func testUserRefreshTakesTheKeyFromABackgroundRead() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let (lines, restore) = capture()
        defer { restore() }
        let a = summary("a"), b = summary("b")
        var result: Bool?
        await MainActor.run { store.track([a, b], live: []) }
        await takeA(t, store, a) { result = $0 }
        XCTAssertEqual(t.lanes("a"), [.background, .user])
        await until("the poll goes on to b without the old call of a", timeout: .seconds(2)) { t.blocked("b") == 1 }
        t.release("a")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.refreshing.contains(a.ref.storeKey), "the stale answer does not end the hold of the user")
        XCTAssertNil(result)
        t.release("a")
        await until("the caller ends", timeout: .seconds(2)) { result == true }
        t.release("b")
        await until("the poll ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
        XCTAssertEqual(t.calls, 3, "no fourth read of a")
        XCTAssertTrue(pollLines(lines, .error).isEmpty)
    }

    /// A user read is not cancelled. The second user refresh runs once more after it.
    func testRerunOfAUserReadStartsWhenItsReadEnds() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let a = summary("a")
        var first: Bool?, second: Bool?
        await MainActor.run { store.track([a], live: []) }
        await takeA(t, store, a) { first = $0 }
        t.release("a")
        await MainActor.run { store.refresh([a.ref.storeKey], force: true, priority: .user) { second = $0 } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.blocked("a"), 1, "no cancel")
        t.release("a")
        await until("the rerun runs", timeout: .seconds(2)) { t.blocked("a") == 1 && t.calls == 3 }
        t.release("a")
        await until("both callers end", timeout: .seconds(2)) { first != nil && second == true }
        await until("the refresh ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
    }

    private final class ProbeTrackers: TrackerDirectory {
        let t: ProjectPriorityTests.Probe
        init(_ t: ProjectPriorityTests.Probe) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    func testViewOfAStaleProjectReadsItAsAUserCall() async throws {
        let probe = ProjectPriorityTests.Probe()
        let store = try store(ProbeTrackers(probe))
        let p = try await probe.projects()[0]
        let key = p.ref.storeKey
        await MainActor.run { store.track([p], live: []) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        probe.clear()
        await MainActor.run { store.viewed(key) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(probe.priorities("items").isEmpty, "a fresh snapshot reads nothing")
        store.now = { Date() + 120 }
        await MainActor.run { store.viewed(key) }
        await until("the view reads once", timeout: .seconds(2)) { probe.priorities("items").count == 1 }
        XCTAssertEqual(probe.priorities("items"), [.user])
    }

    func testViewOfAFreshProjectReadsNothing() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        await MainActor.run { store.track([order], live: []) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        store.now = { Date() + 10 }
        await MainActor.run { store.viewed(key) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls.filter { $0 == "items" }.count, 1)
    }

    func testViewDuringAUserReadAddsNoRead() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let a = summary("a")
        await MainActor.run { store.track([a], live: []) }
        await takeA(t, store, a) { _ in }
        t.release("a")
        await MainActor.run { store.viewed(a.ref.storeKey) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.blocked("a"), 1)
        t.release("a")
        await until("the refresh ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls, 2, "no rerun")
    }

    func testViewOfAnUntrackedKeyDoesNothing() async throws {
        let t = SlowTracker()
        let store = try store(t)
        await MainActor.run { store.viewed("nope") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls, 0)
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testKeyForIdentifier() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let p = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        await MainActor.run { store.track([p], live: []) }
        XCTAssertEqual(store.key(identifier: "slow"), p.ref.storeKey)
        XCTAssertNil(store.key(identifier: "other"))
        await until("the poll reads", timeout: .seconds(2)) { t.blocked == 1 }
        t.release()
        await until("the poll ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
    }

    func testStuckReadLetsTheKeyGoAndWarns() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let (lines, restore) = capture()
        defer { restore() }
        let a = summary("a"), b = summary("b")
        let ka = a.ref.storeKey
        await MainActor.run { store.track([a, b], live: []) }
        await until("the poll reads a", timeout: .seconds(2)) { t.blocked("a") == 1 }
        store.now = { Date() + 200 }
        await MainActor.run { store.releaseStuckReads() }
        XCTAssertFalse(store.refreshing.contains(ka))
        XCTAssertNotNil(store.errors[ka])
        await until("the loop reads b", timeout: .seconds(2)) { t.blocked("b") == 1 }
        let warns = pollLines(lines, .warn)
        XCTAssertEqual(warns.count, 1)
        XCTAssertEqual([warns[0].area.rawValue, warns[0].job, warns[0].subject, warns[0].host], ["sync", "slow poll", "A", "ws"])
        await MainActor.run { store.poll() }
        await until("the poll reads a again", timeout: .seconds(2)) { t.blocked("a") == 2 }
        t.release("a")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.snapshots[ka], "the stale answer writes nothing")
        t.release("a")
        t.release("b")
        await until("all reads end", timeout: .seconds(2)) { store.refreshing.isEmpty }
        XCTAssertNotNil(store.snapshots[ka])
    }

    func testWatchdogKeepsAYoungRead() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let (lines, restore) = capture()
        defer { restore() }
        let a = summary("a")
        await MainActor.run { store.track([a], live: []) }
        await until("the poll reads a", timeout: .seconds(2)) { t.blocked("a") == 1 }
        store.now = { Date() + 100 }
        await MainActor.run { store.releaseStuckReads() }
        XCTAssertTrue(store.refreshing.contains(a.ref.storeKey))
        XCTAssertTrue(pollLines(lines, .warn).isEmpty)
        t.release("a")
        await until("the poll ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
    }

    func testWakeReadsTheShownProjectFirstThenTheOldest() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let a = summary("a"), b = summary("b"), c = summary("c")
        await MainActor.run { store.track([a, b, c], live: []) }
        for k in ["a", "b", "c"] {
            await until("the first sweep reads \(k)", timeout: .seconds(2)) { t.blocked(k) == 1 }
            t.release(k)
        }
        await until("the first sweep ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
        await MainActor.run {
            store.seed(snap(a, at: Date()))
            store.seed(snap(b, at: Date() - 3600))
            store.seed(snap(c, at: .distantPast))
            store.wake(first: a.ref.storeKey)
        }
        await until("a reads as a user call and c reads first", timeout: .seconds(2)) { t.blocked("a") == 1 && t.blocked("c") == 1 }
        XCTAssertEqual(t.lanes("a"), [.background, .user])
        XCTAssertEqual(t.lanes("c"), [.background, .background])
        XCTAssertEqual(t.blocked("b"), 0, "b waits for c")
        t.release("c")
        await until("b reads after c", timeout: .seconds(2)) { t.blocked("b") == 1 }
        XCTAssertEqual(t.lanes("b"), [.background, .background])
        t.release("a")
        t.release("b")
        await until("all reads end", timeout: .seconds(2)) { store.refreshing.isEmpty }
        XCTAssertEqual(t.lanes("a"), [.background, .user], "the sweep does not read a")
    }

    func testWakeLetsAReadFromBeforeTheSleepGo() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let (lines, restore) = capture()
        defer { restore() }
        let a = summary("a")
        await MainActor.run { store.track([a], live: []) }
        await until("the poll reads a", timeout: .seconds(2)) { t.blocked("a") == 1 }
        store.now = { Date() + 3600 }
        await MainActor.run { store.wake(first: nil) }
        await until("a reads again", timeout: .seconds(2)) { t.blocked("a") == 2 }
        XCTAssertEqual(pollLines(lines, .warn).count, 1)
        XCTAssertEqual(t.lanes("a"), [.background, .background])
        t.release("a")
        t.release("a")
        await until("the reads end", timeout: .seconds(2)) { store.refreshing.isEmpty }
    }

    func testOldestFirst() {
        let ps = ["a", "b", "c", "d"].map(summary)
        let t = Date()
        let snaps = [ps[0], ps[1], ps[3]].enumerated().reduce(into: [String: ProjectSnapshot]()) { m, e in
            m[e.element.ref.storeKey] = snap(e.element, at: e.element.identifier == "B" ? t - 3600 : t)
        }
        XCTAssertEqual(ProjectStore.oldestFirst(ps, snapshots: snaps).map(\.identifier), ["C", "B", "A", "D"])
    }

    func testSweepReadsTheOldestSnapshotFirst() async throws {
        let t = SlowTracker()
        let store = try store(t)
        let a = summary("a"), b = summary("b")
        await MainActor.run {
            store.seed(snap(a, at: Date()))
            store.seed(snap(b, at: Date() - 3600))
            store.track([a, b], live: [])
        }
        await until("b reads first", timeout: .seconds(2)) { t.blocked("b") == 1 && t.blocked("a") == 0 }
        t.release("b")
        await until("a reads next", timeout: .seconds(2)) { t.blocked("a") == 1 }
        t.release("a")
        await until("the sweep ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
    }

    func testRateLimitPausesTheWorkspace() async throws {
        let t = SlowTracker()
        t.limited = true
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        let key = summary.ref.storeKey
        await MainActor.run { store.track([summary], live: []) }
        await until("the refresh fails", timeout: .seconds(2)) { store.cooldown["ws"] != nil && !store.refreshing.contains(key) }
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
        await until("the poll refresh runs", timeout: .seconds(2)) { t.blocked == 1 }
        t.release()
        await until("the poll refresh ends", timeout: .seconds(2)) { store.refreshing.isEmpty }
        var result: Bool?
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: nil)]) { result = $0 } }
        XCTAssertEqual(result, true)
        XCTAssertEqual(t.calls, 1, "no refresh at once")
        await until("the refresh runs after the delay", timeout: .seconds(2)) { t.calls == 2 }
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

    private func refreshOnce(_ store: ProjectStore, _ key: String) async {
        await withCheckedContinuation { c in
            DispatchQueue.main.async { store.refresh([key], force: false) { _ in c.resume() } }
        }
    }

    func testARefreshWithTheSameDataPublishesNoProjectChange() async throws {
        let fake = FakeTracker()
        _ = try await fake.create(ItemDraft(title: "One"), in: fake.project)
        let store = try store(fake)
        let summary = try await fake.projects()[0]
        let key = summary.ref.storeKey
        var changes: [DataChange] = []
        await MainActor.run { store.onChange = { changes.append($0) }; store.track([summary], live: []) }
        await until("the first snapshot", timeout: .seconds(2)) { store.snapshots[key] != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let first = await MainActor.run { changes.filter { $0.projects.contains(key) }.count }
        XCTAssertGreaterThan(first, 0, "the first snapshot is a change")
        await refreshOnce(store, key)
        let after = await MainActor.run { changes.filter { $0.projects.contains(key) }.count }
        XCTAssertEqual(after, first, "the same data names no project")
    }

    func testARefreshAfterASeedPublishesTheChange() async throws {
        let fake = FakeTracker()
        _ = try await fake.create(ItemDraft(title: "One"), in: fake.project)
        let store = try store(fake)
        let summary = try await fake.projects()[0]
        let key = summary.ref.storeKey
        await MainActor.run { store.track([summary], live: []) }
        await until("the first snapshot", timeout: .seconds(2)) { store.snapshots[key] != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        var changes: [DataChange] = []
        await MainActor.run {
            // Same comment fields as the real data, a different body: the refresh restores the kept digest.
            let snap = store.snapshots[key]!
            store.seed(ProjectStore.withItems(snap, snap.items.map { var i = $0; i.body = "Other"; return i }))
            store.onChange = { changes.append($0) }
        }
        await refreshOnce(store, key)
        let named = await MainActor.run { changes.contains { $0.projects.contains(key) } }
        XCTAssertTrue(named, "the data differs from the seeded snapshot: a stale kept digest would hide it")
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

    func testGoneUsesBigTimerIndex() async throws {
        let http = CountingPlane()
        let row = { (n: Int) in
            #"{"uuid":"u\#(n)","version":1,"project_uuid":"p1","number":\#(n),"key":"BT-\#(n)","title":"Item \#(n)","status":"open","#
                + #""created_at":"2026-10-16T10:00:00Z","updated_at":"2026-10-16T1\#(n):00:00Z"}"#
        }
        http.on("/v1/me", #"{"member":{"uuid":"m1","name":"Ada","status":"active"},"team":{"name":"T"},"token":{"id":"t","kind":"personal","scopes":["read","write"]}}"#)
        http.on("/v1/members", #"{"items":[{"uuid":"m1","name":"Ada","status":"active"}]}"#)
        http.on("/v1/issues", #"{"items":[\#(row(1)),\#(row(2))],"next_cursor":null}"#)
        let t = BigTimerTracker(server: URL(string: "https://bt.example.com")!, account: AccountID(provider: .bigtimer, id: "bt.example.com"),
                                token: "tok", http: http)
        let summary = ProjectSummary(ref: ProjectRef(account: t.account, id: "p1", key: "BT"), identifier: "BT", title: "BT",
                                     url: "bigtimer://issues?project=BT", closed: false)
        let old = try await ProjectStore.snapshot(t, summary, limit: 50, previous: nil)
        XCTAssertEqual(old.index?.map(\.id).sorted(), ["u1", "u2"])
        var new = ProjectSnapshot(summary: old.summary, statusOptions: old.statusOptions, items: old.items.filter { $0.id != "u2" },
                                  fetchedAt: Date(), index: old.index)
        let before = http.count
        var gone = await ProjectStore.gone(t, old, new)
        XCTAssertTrue(gone.isEmpty, "u2 is in the index: it only left the item limit")
        new.index = new.index?.filter { $0.id != "u2" }
        gone = await ProjectStore.gone(t, old, new)
        XCTAssertEqual(gone, ["u2"], "u2 is not in the index: it is removed")
        XCTAssertEqual(http.count, before, "gone() makes no call")
        XCTAssertFalse(http.paths.contains { $0.hasPrefix("GET /v1/issues/") }, "no detail call")
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
        await until("the refresh fails", timeout: .seconds(2)) { store.errors[key] != nil && store.refreshing.isEmpty }
        XCTAssertEqual(store.errors[key], ProjectStore.noToken + " (no token in the Keychain)")
        let t = OrderTracker()
        dir.t = t
        await MainActor.run { store.poll() }
        await until("the poll loads the live project again", timeout: .seconds(2)) { t.calls.contains("items") && store.errors[key] == nil }
    }

    func testPollRefreshesOnlyAStaleLiveProject() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        store.relayIsLive = { true }
        await MainActor.run { store.track([order], live: [key]) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        let loads = { t.calls.filter { $0 == "items" }.count }
        await MainActor.run { store.poll() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(loads(), 1, "a fresh live project waits for its events")
        store.now = { Date().addingTimeInterval(3600) }
        await MainActor.run { store.poll() }
        await until("a stale live project polls", timeout: .seconds(2)) { loads() == 2 }
    }

    func testPollSkipsAFreshProjectOfALiveFeed() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        let account = order.ref.account
        store.relayIsLive = { false }
        store.feedIsLive = { $0 == account }
        await MainActor.run { store.track([order], live: []) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        await MainActor.run { store.poll() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.calls.filter { $0 == "items" }.count, 1, "a fresh feed project waits for its events")
        XCTAssertTrue(store.isLive(key))
        XCTAssertTrue(store.showsLive(key))
    }

    func testPollReadsAFeedProjectWhenTheFeedIsDown() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        store.relayIsLive = { false }
        store.feedIsLive = { _ in false }
        await MainActor.run { store.track([order], live: []) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        let loads = { t.calls.filter { $0 == "items" }.count }
        await MainActor.run { store.poll() }
        await until("the poll loads the project", timeout: .seconds(2)) { loads() == 2 }
        XCTAssertFalse(store.isLive(key))
        XCTAssertFalse(store.showsLive(key))
    }

    func testPollRefreshesAStaleFeedProject() async throws {
        let t = OrderTracker()
        let store = try store(t)
        let key = order.ref.storeKey
        let account = order.ref.account
        store.relayIsLive = { false }
        store.feedIsLive = { $0 == account }
        await MainActor.run { store.track([order], live: []) }
        await until("the first refresh ends", timeout: .seconds(2)) { store.snapshots[key] != nil && store.refreshing.isEmpty }
        store.now = { Date().addingTimeInterval(3600) }
        await MainActor.run { store.poll() }
        await until("a stale feed project polls", timeout: .seconds(2)) { t.calls.filter { $0 == "items" }.count == 2 }
    }

    func testLimitChangeDuringARefreshRunsAgain() async throws {
        let saved = PROJECTS_CFG.itemsPerProject
        defer { PROJECTS_CFG.itemsPerProject = saved }
        PROJECTS_CFG.itemsPerProject = 10
        let t = SlowTracker()
        let store = try store(t)
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "https://x/SLOW", closed: false)
        await MainActor.run { store.track([summary], live: []) }
        await until("the first refresh runs", timeout: .seconds(2)) { t.blocked == 1 }
        PROJECTS_CFG.itemsPerProject = 0
        await MainActor.run { store.track([summary], live: []) }
        t.release()
        await until("one more refresh runs with the new limit", timeout: .seconds(2)) { t.blocked == 1 && t.calls == 2 }
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
        let before = http.paths.count
        let second = try await ProjectStore.snapshot(p, summary, limit: 50, previous: previous)
        XCTAssertEqual(second.items.map(\.id).sorted(), ["i1", "i2", "i3", "i4"])
        XCTAssertFalse(http.paths.suffix(from: before).contains { $0.contains("/comments/") }, "the list makes no comment call")

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

    // MARK: Client mode (OVERSIRE-527)

    private actor DraftCount: EventOutlet {
        var drafts = 0
        func append(_ d: [EventDraft]) { drafts += d.count }
        func link(_ links: [ItemLink]) {}
    }

    private let mirrorRef = ProjectRef(account: AccountID(provider: "plane", id: "ws"), id: "p1", key: "ONE")

    private func mirrorItem(_ n: Int) -> Item {
        let at = Date()
        return Item(id: "i\(n)", key: "ONE-\(n)", title: "T\(n)", url: "u", statusOptionId: "t", fields: [:], assignees: [], labels: [],
                    author: nil, updatedBy: nil, updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil, mentionsMe: false, parentId: nil)
    }

    private func mirrorSnap(_ items: [Item] = []) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: mirrorRef, identifier: "ONE", title: "One", url: "", closed: false),
                        statusOptions: [StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")], items: items, fetchedAt: Date())
    }

    private func clientStore(notify: @escaping (String) -> Void = { _ in }) throws -> (ProjectStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore(trackers: Trackers(SlowTracker()), notifier: ProjectNotifier(post: { _, _, _, id in notify(id) }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        store.client = true
        return (store, dir.path)
    }

    @MainActor
    func testMirroredWritesNoEvents() async throws {
        let (store, _) = try clientStore()
        let outlet = DraftCount()
        store.events = EventDesk(outlet: outlet)
        var d = MirrorDelta()
        d.projects[mirrorRef.storeKey] = mirrorSnap()
        d.items[mirrorRef.storeKey] = [mirrorItem(1), mirrorItem(2)]
        d.activity = [ActivityEntry(id: "a1", projectKey: mirrorRef.storeKey, itemId: "i1", change: .added, actor: nil, text: "New", url: "", at: Date(), unread: true)]
        d.reset = true
        store.mirrored(d)
        try await Task.sleep(nanoseconds: 100_000_000)
        let drafts = await outlet.drafts
        XCTAssertEqual(drafts, 0)
        XCTAssertEqual(store.snapshots[mirrorRef.storeKey]?.items.count, 2)
        XCTAssertEqual(store.activityEntries.map(\.id), ["a1"])
    }

    @MainActor
    func testMirroredRunsNotifier() throws {
        var posted: [String] = []
        let (store, _) = try clientStore { posted.append($0) }
        var first = MirrorDelta()
        first.projects[mirrorRef.storeKey] = mirrorSnap()
        first.items[mirrorRef.storeKey] = [mirrorItem(1)]
        first.reset = true
        store.mirrored(first)
        XCTAssertTrue(posted.isEmpty, "the first read is quiet")

        var next = MirrorDelta()
        next.projects[mirrorRef.storeKey] = mirrorSnap()
        next.items[mirrorRef.storeKey] = [mirrorItem(2)]
        store.mirrored(next)
        XCTAssertEqual(posted, ["project:i2"])
    }

    @MainActor
    func testClientHasReadsTheCatalog() throws {
        let (store, _) = try clientStore()
        let snap = mirrorSnap()
        XCTAssertFalse(store.has(.links, in: snap))
        store.catalog = ClientCatalog(projects: [CatalogProject(summary: snap.summary, capabilities: [.links])], capabilities: [:], trackers: ["ws"])
        XCTAssertTrue(store.has(.links, in: snap))
        XCTAssertFalse(store.has(.relations, in: snap))
    }

    @MainActor
    func testTrackDoesNotPollOnClient() throws {
        let t = SlowTracker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore(trackers: Trackers(t), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        store.client = true
        let summary = ProjectSummary(ref: t.project, identifier: "SLOW", title: "Slow", url: "", closed: false)
        store.track([summary], live: [])
        XCTAssertEqual(store.tracked.map(\.identifier), ["SLOW"])
        XCTAssertEqual(t.calls, 0)
        XCTAssertEqual(t.blocked, 0)
    }
}
