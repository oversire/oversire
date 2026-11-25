import XCTest
import OverSireCore
@testable import OverSireApp

/// The list shows first. Comments load in the background, and only for the items that need them (OVERSIRE-464).
final class ProjectCommentTests: XCTestCase {
    /// A tracker with lists and comments that the test sets. It logs each comment call, and it can hold calls.
    final class CommentTracker: Tracker, @unchecked Sendable {
        let id: ProviderID = "comment"
        let account: AccountID
        let capabilities: Set<Capability> = []
        let pollPolicy = PollPolicy(minInterval: .seconds(60), requestsPerHour: 60)
        let keyFormat = KeyFormat.projectDash

        private let lock = NSLock()
        private var lists: [String: [Item]] = [:]
        private var answers: [String: [Comment]] = [:]
        private var calls: [(item: String, lane: CallPriority)] = []
        private var holdsItems: Set<String> = []
        private var holdsComments = false
        private var parkedItems: [(project: String, go: CheckedContinuation<Void, Never>)] = []
        private var parkedComments: [CheckedContinuation<Void, Never>] = []
        private var itemCalls = 0
        var limited = false

        init(workspace: String = "ws") { account = AccountID(provider: "comment", id: workspace) }

        func setList(_ project: String, _ items: [Item]) { lock.withLock { lists[project] = items } }
        func setComments(_ item: String, _ list: [Comment]) { lock.withLock { answers[item] = list } }
        /// The ids of the items whose comments were read, in call order.
        var read: [String] { lock.withLock { calls.map(\.item) } }
        var lanes: [CallPriority] { lock.withLock { calls.map(\.lane) } }
        var listCalls: Int { lock.withLock { itemCalls } }
        func blocked(_ project: String) -> Int { lock.withLock { parkedItems.filter { $0.project == project }.count } }
        var blockedComments: Int { lock.withLock { parkedComments.count } }

        func holdList(_ project: String) { lock.withLock { _ = holdsItems.insert(project) } }
        func holdComments() { lock.withLock { holdsComments = true } }
        func releaseList(_ project: String) {
            lock.withLock { parkedItems.firstIndex { $0.project == project }.map { parkedItems.remove(at: $0) } }?.go.resume()
        }
        func releaseComments() {
            let all = lock.withLock { holdsComments = false; return parkedComments.splice() }
            all.forEach { $0.resume() }
        }
        /// Lets each parked call go, so no test leaks a continuation.
        func releaseAll() {
            let (a, b) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
                holdsItems = []
                holdsComments = false
                return (parkedItems.splice().map(\.go), parkedComments.splice())
            }
            (a + b).forEach { $0.resume() }
        }

        func probe() async throws -> Identity { Identity(person: PersonRef(id: "u1", name: "me")) }
        func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: Cursor(rawValue: "0")) }
        func projects() async throws -> [ProjectSummary] { [] }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] {
            [StatusOption(id: "s1", name: "Todo", color: "#888888", group: "unstarted"),
             StatusOption(id: "s2", name: "Doing", color: "#F59E0B", group: "started")]
        }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
            lock.withLock { itemCalls += 1 }
            if lock.withLock({ holdsItems.contains(p.id) }) {
                await withCheckedContinuation { c in
                    let park = lock.withLock { () -> Bool in
                        guard holdsItems.contains(p.id) else { return false }
                        parkedItems.append((p.id, c))
                        return true
                    }
                    if !park { c.resume() }
                }
            }
            return lock.withLock { lists[p.id] ?? [] }
        }
        func detail(_ i: ItemRef) async throws -> ItemDetail { throw ProviderError.notFound }
        func comments(_ i: ItemRef) async throws -> [Comment] {
            lock.withLock { calls.append((i.id, CallPriority.current)) }
            if lock.withLock({ holdsComments }) {
                await withCheckedContinuation { c in
                    let park = lock.withLock { () -> Bool in
                        guard holdsComments else { return false }
                        parkedComments.append(c)
                        return true
                    }
                    if !park { c.resume() }
                }
            }
            if lock.withLock({ limited }) { throw ProviderError.rateLimited(retryAfter: .seconds(5)) }
            return lock.withLock { answers[i.id] ?? [] }
        }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { throw ProviderError.notFound }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws {}
        func comment(_ i: ItemRef, markdown: String) async throws {}
    }

    final class Directory: TrackerDirectory {
        let t: any Tracker
        init(_ t: any Tracker) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    /// Notifications that the store posts.
    final class Posts: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var tracker: CommentTracker!
    private var posts = Posts()

    override func setUp() { tracker = CommentTracker() }
    override func tearDown() { tracker.releaseAll() }

    private func store(_ t: any Tracker) throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let posts = posts
        return ProjectStore(trackers: Directory(t), notifier: ProjectNotifier(post: { posts.add($0.body) }),
                            statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
    }

    private func settle(_ store: ProjectStore) async {
        await until("the reads end") { store.refreshing.isEmpty && !store.commentsPending }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await until("the reads still ended") { store.refreshing.isEmpty && !store.commentsPending }
    }

    private func summary(_ id: String = "p1") -> ProjectSummary {
        let ref = ProjectRef(account: tracker.account, id: id, key: id.uppercased())
        return ProjectSummary(ref: ref, identifier: id.uppercased(), title: "Project \(id)", url: "https://x/\(id)", closed: false)
    }

    private func item(_ id: String, at: Date, mine: Bool = true, status: String = "s1", body: String? = nil) -> Item {
        var i = Item(id: id, key: "P1-\(id)", title: "Item \(id)", url: "https://x/P1-\(id)", statusOptionId: status, fields: [:],
                     assignees: mine ? ["me"] : ["bob"], labels: [], author: mine ? "me" : "bob", updatedBy: nil, updatedAt: at, activityAt: at,
                     commentCount: 0, lastComment: nil, mentionsMe: false)
        i.body = body
        return i
    }

    private func comment(_ id: String, at: Date, body: String = "Hello") -> Comment {
        Comment(id: id, author: "ada", createdAt: at, url: "https://x/c/\(id)", body: body)
    }

    private func snap(_ items: [Item], fetchedAt: Date? = nil, index: [ItemStub]? = nil) -> ProjectSnapshot {
        ProjectSnapshot(summary: summary(), statusOptions: [], items: items, fetchedAt: fetchedAt ?? t0, me: "me", index: index)
    }

    /// Tracks the project, and waits for its first read. The first read makes no comment call.
    private func start(_ store: ProjectStore, _ keys: [String] = ["p1"], live: Bool = false) async {
        let projects = keys.map { summary($0) }
        await MainActor.run { store.track(projects, live: live ? Set(projects.map(\.ref.storeKey)) : []) }
        await until("the first read ends") { projects.allSatisfy { store.snapshots[$0.ref.storeKey] != nil } && store.refreshing.isEmpty }
    }

    private func comments(_ store: ProjectStore) -> [ActivityEntry] {
        store.activity(limit: 50, project: key).filter { if case .comments = $0.change { return true }; return false }
    }

    private var key: String { summary().ref.storeKey }

    // OVERSIRE-528
    func testRemoteCommentsOnClient() async throws {
        final class Seen: @unchecked Sendable { var calls: [(String, JSONValue)] = [] }
        let seen = Seen()
        let s = try store(tracker)
        let answer = try MirrorCodec.body(MirrorRows(rows: [comment("c1", at: t0, body: "From mbp")]))
        await MainActor.run {
            s.remote = { what, args in seen.calls.append((what, args)); return answer }
        }
        let r: Result<[Comment], ProviderError> = await withCheckedContinuation { c in
            DispatchQueue.main.async { s.comments(key: "P1-a") { c.resume(returning: $0) } }
        }
        XCTAssertEqual(try r.get().map(\.body), ["From mbp"])
        XCTAssertEqual(seen.calls.map(\.0), ["comments"])
        XCTAssertEqual(seen.calls.first?.1["item"], .string("P1-a"))
        XCTAssertEqual(tracker.read, [], "a client asks no tracker")
    }

    func testRemoteFailureGivesAFailure() async throws {
        let s = try store(tracker)
        await MainActor.run { s.remote = { _, _ in throw ProviderError.vendor(code: "503", message: "The OverSire app on mbp is not open.") } }
        let r: Result<[Comment], ProviderError> = await withCheckedContinuation { c in
            DispatchQueue.main.async { s.comments(key: "P1-a") { c.resume(returning: $0) } }
        }
        guard case .failure(let e) = r else { return XCTFail("no failure") }
        XCTAssertEqual(e.message, "The OverSire app on mbp is not open.")
    }

    // MARK: Snapshot makes no calls

    func testSnapshotReadsNoComments() async throws {
        let now = Date()
        var i1 = item("i1", at: t0)
        i1.commentCount = 2
        i1.lastComment = comment("c2", at: t0)
        i1.commentsAt = t0
        let previous = snap([i1], fetchedAt: now - 100)
        tracker.setList("p1", [item("i1", at: t0 + 50), item("i2", at: now - 10)])
        let next = try await ProjectStore.snapshot(tracker, summary(), limit: 50, previous: previous)
        XCTAssertTrue(tracker.read.isEmpty, "no comment call")
        let a = try XCTUnwrap(next.items.first { $0.id == "i1" }), b = try XCTUnwrap(next.items.first { $0.id == "i2" })
        XCTAssertEqual(a.commentCount, 2)
        XCTAssertEqual(a.lastComment?.id, "c2")
        XCTAssertEqual(a.commentsAt, t0)
        XCTAssertTrue(a.commentsDue)
        XCTAssertEqual(b.commentsAt, previous.fetchedAt, "a new item: its comments are news from the last read")

        let first = try await ProjectStore.snapshot(tracker, summary(), limit: 50, previous: nil)
        XCTAssertEqual(first.items.map(\.commentsAt), first.items.map(\.activityAt), "a first snapshot has no news")
        XCTAssertTrue(tracker.read.isEmpty)
    }

    func testNewItemBodyMentionIsNews() async throws {
        let previous = snap([item("i1", at: t0)], fetchedAt: t0 + 10)
        tracker.setList("p1", [item("i1", at: t0), item("i2", at: t0 + 20, body: "ping @Me please")])
        let next = try await ProjectStore.snapshot(tracker, summary(), limit: 50, previous: previous)
        XCTAssertEqual(next.items.first { $0.id == "i2" }?.mentionsMe, true)
        let store = try store(tracker)
        await MainActor.run {
            store.absorb(previous)
            store.absorb(next)
        }
        let kinds = store.activity(limit: 10, project: nil).filter { $0.itemId == "i2" }.map(\.change)
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertTrue(kinds.contains(.mention))
        XCTAssertTrue(tracker.read.isEmpty)
    }

    func testOldSavedItemCountsAsRead() async throws {
        let old = item("i1", at: t0)
        XCTAssertNil(old.commentsAt)
        XCTAssertFalse(old.commentsDue)
        tracker.setList("p1", [item("i1", at: t0)])
        let next = try await ProjectStore.snapshot(tracker, summary(), limit: 50, previous: snap([old]))
        XCTAssertEqual(next.items[0].commentsAt, t0)
        XCTAssertFalse(next.items[0].commentsDue)
        XCTAssertTrue(tracker.read.isEmpty)
        // An old item with new activity is due, also when the stamp is nil.
        tracker.setList("p1", [item("i1", at: t0 + 60)])
        let later = try await ProjectStore.snapshot(tracker, summary(), limit: 50, previous: snap([old]))
        XCTAssertTrue(later.items[0].commentsDue)
    }

    // MARK: Diff rule

    func testDiffUsesTheCommentStamp() {
        let t1 = t0 + 100, t2 = t0 + 200, t3 = t0 + 300
        var prev = item("i1", at: t1)
        prev.commentsAt = t1
        var new = item("i1", at: t3)
        new.lastComment = comment("c1", at: t2)
        new.commentCount = 1
        new.commentsAt = t3
        let old = snap([prev], fetchedAt: t3)
        let changes = ProjectStore.diff(old, snap([new], fetchedAt: t3)).map(\.1)
        XCTAssertEqual(changes, [.comments(new: 1, last: comment("c1", at: t2))], "t1 < comment < old.fetchedAt")

        new.lastComment = comment("c0", at: t0)
        XCTAssertTrue(ProjectStore.diff(old, snap([new], fetchedAt: t3)).isEmpty, "a comment before the stamp is not news")

        var plain = prev
        plain.commentsAt = nil
        new.lastComment = comment("c2", at: t2)
        XCTAssertTrue(ProjectStore.diff(snap([plain], fetchedAt: t3), snap([new], fetchedAt: t3)).isEmpty,
                      "with no stamp, an old comment that loads late is quiet")
    }

    // MARK: List first

    func testListShowsBeforeComments() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a0)])
        await start(store)
        tracker.setList("p1", [item("i1", at: a1)])
        tracker.setComments("i1", [comment("c1", at: a1)])
        tracker.holdComments()
        await MainActor.run { store.poll() }
        await until("the comment call waits") { self.tracker.blockedComments == 1 }
        XCTAssertEqual(store.snapshots[key]?.items.first?.activityAt, a1, "the list is in")
        XCTAssertTrue(store.refreshing.isEmpty)
        XCTAssertTrue(comments(store).isEmpty)
        tracker.releaseComments()
        await until("the comment line") { self.comments(store).count == 1 }
        XCTAssertEqual(tracker.lanes, [.background])
        XCTAssertEqual(store.snapshots[key]?.items.first?.commentCount, 1)
        XCTAssertFalse(store.snapshots[key]?.items.first?.commentsDue ?? true)
        await settle(store)
    }

    func testCommentsWaitForTheListReadsOfOtherProjects() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("a", [item("a1", at: a0)])
        tracker.setList("b", [item("b1", at: a0)])
        await start(store, ["a", "b"])
        tracker.setList("a", [item("a1", at: a1)])
        tracker.setList("b", [item("b1", at: a1)])
        tracker.holdList("b")
        await MainActor.run { store.poll() }
        await until("the read of b waits") { self.tracker.blocked("b") == 1 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(tracker.read.isEmpty, "no comment call while a list read holds a key")
        tracker.releaseAll()
        await until("the comments follow") { self.tracker.read.contains("a1") && self.tracker.read.contains("b1") }
        await settle(store)
    }

    // MARK: Which items

    func testPollingReadsOnlyMyChangedItems() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a0), item("i2", at: a0, mine: false), item("i3", at: a0)])
        await start(store)
        tracker.setList("p1", [item("i1", at: a1), item("i2", at: a1, mine: false), item("i3", at: a0)])
        await MainActor.run { store.poll() }
        await until("one read") { self.tracker.read.count == 1 }
        await settle(store)
        XCTAssertEqual(tracker.read, ["i1"])
    }

    func testPollingCapsAndCarriesOver() async throws {
        let store = try store(tracker)
        store.commentCap = 20
        let a0 = Date() - 1000, a1 = Date() - 100
        let ids = (1...25).map { "i\($0)" }
        tracker.setList("p1", ids.map { item($0, at: a0) })
        await start(store)
        tracker.setList("p1", ids.enumerated().map { item($1, at: a1 + Double($0)) })
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertEqual(tracker.read.count, 20)
        XCTAssertEqual(Set(tracker.read), Set(ids.suffix(20)), "the 20 newest")
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertEqual(tracker.read.count, 25)
        XCTAssertEqual(Set(tracker.read.suffix(5)), Set(ids.prefix(5)), "the rest")
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertEqual(tracker.read.count, 25, "nothing is left")
    }

    private func hint(_ item: String?) -> CommentHint { CommentHint(workspace: "ws", project: "p1", item: item) }

    /// Items i1 and i2 (not mine) change after the first read, and i3 does not. The relay is live.
    private func liveStore() async throws -> ProjectStore {
        let store = try store(tracker)
        store.relayIsLive = { true }
        let a0 = Date() - 1000
        tracker.setList("p1", [item("i1", at: a0, mine: false), item("i2", at: a0, mine: false), item("i3", at: a0, mine: false)])
        await start(store, live: true)
        let a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a1, mine: false), item("i2", at: a1 + 1, mine: false), item("i3", at: a0, mine: false)])
        return store
    }

    func testLiveReadsOnlyEventNamedItems() async throws {
        let store = try await liveStore()
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")], comments: [hint("i2")]) { _ in } }
        await until("one read") { self.tracker.read.count == 1 }
        await settle(store)
        XCTAssertEqual(tracker.read, ["i2"])
    }

    func testFeedLiveReadsOnlyNamedComments() async throws {
        let store = try store(tracker)
        let account = summary().ref.account
        store.relayIsLive = { false }
        store.feedIsLive = { $0 == account }
        let a0 = Date() - 1000
        tracker.setList("p1", [item("i1", at: a0, mine: false), item("i2", at: a0, mine: false), item("i3", at: a0, mine: false)])
        await start(store)
        let a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a1, mine: false), item("i2", at: a1 + 1, mine: false), item("i3", at: a0, mine: false)])
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")], comments: [hint("i2")]) { _ in } }
        await until("one read") { self.tracker.read.count == 1 }
        await settle(store)
        XCTAssertEqual(tracker.read, ["i2"])
    }

    func testLiveCommentEventWithoutItemReadsTheChangedItems() async throws {
        let store = try await liveStore()
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")], comments: [hint(nil)]) { _ in } }
        await until("two reads") { self.tracker.read.count == 2 }
        await settle(store)
        XCTAssertEqual(Set(tracker.read), ["i1", "i2"], "not only my items, and not the unchanged item")
    }

    func testLiveHintDuringTheReadWaitsForTheRerun() async throws {
        let store = try store(tracker)
        store.relayIsLive = { true }
        let a0 = Date() - 1000
        tracker.setList("p1", [item("i1", at: a0, mine: false), item("i2", at: a0, mine: false), item("i3", at: a0, mine: false)])
        await start(store, live: true)
        let a1 = Date() - 100
        tracker.setList("p1", [item("i1", at: a1, mine: false), item("i2", at: a1, mine: false), item("i3", at: a0, mine: false)])
        tracker.holdList("p1")
        await MainActor.run { store.refresh([key], force: true) { _ in } }
        await until("the read waits") { self.tracker.blocked("p1") == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")], comments: [hint(nil)]) { _ in } }
        tracker.releaseList("p1")
        await until("the rerun waits") { self.tracker.blocked("p1") == 1 }
        XCTAssertTrue(tracker.read.isEmpty, "the first read keeps the hint for the rerun")
        let a2 = Date() - 50
        tracker.setList("p1", [item("i1", at: a2, mine: false), item("i2", at: a2, mine: false), item("i3", at: a0, mine: false)])
        tracker.releaseList("p1")
        await until("two reads") { self.tracker.read.count == 2 }
        await settle(store)
        XCTAssertEqual(Set(tracker.read), ["i1", "i2"])
    }

    func testLiveWithoutCommentEventsReadsNoComments() async throws {
        let store = try await liveStore()
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")]) { _ in } }
        await settle(store)
        let a2 = Date() - 5
        tracker.setList("p1", [item("i1", at: a2, mine: true), item("i2", at: a2, mine: true), item("i3", at: a2, mine: true)])
        store.now = { Date() + 3600 }
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertTrue(tracker.read.isEmpty, "a live project reads no comment without a comment event")
    }

    func testOtherMacKeepsTheCommentHint() async throws {
        let store = try await liveStore()
        store.leads = { false }
        store.otherMacDelay = 0.2
        let before = tracker.listCalls
        await MainActor.run { store.refreshForEvents([(workspace: "ws", project: "p1")], comments: [hint("i2")]) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tracker.listCalls, before, "no read at once")
        await until("the read after the delay names i2") { self.tracker.read == ["i2"] }
        await settle(store)
        XCTAssertEqual(tracker.read, ["i2"])
    }

    // MARK: Merge safety

    func testMergeSkipsAnItemWithNewerActivity() {
        var i = item("i1", at: t0 + 200)
        i.commentsAt = t0
        let cur = snap([i])
        XCTAssertNil(ProjectStore.merged(cur, ["i1": (t0 + 100, [comment("c1", at: t0 + 150)])]))
        XCTAssertNil(ProjectStore.merged(cur, ["other": (t0 + 200, [])]), "an item that is gone")
        let m = ProjectStore.merged(cur, ["i1": (t0 + 200, [comment("c1", at: t0 + 150, body: "hi @me")])])
        XCTAssertEqual(m?.items[0].commentCount, 1)
        XCTAssertEqual(m?.items[0].mentionsMe, true)
        XCTAssertEqual(m?.items[0].commentsAt, t0 + 200)
    }

    func testListReadKeepsACommentMergeFromDuringIt() {
        var merged = item("i1", at: t0 + 100)
        merged.commentCount = 3
        merged.lastComment = comment("c3", at: t0 + 90)
        merged.commentsAt = t0 + 100
        var fresh = item("i1", at: t0 + 200)
        fresh.commentCount = 1
        fresh.commentsAt = t0
        let out = ProjectStore.carried(snap([fresh, item("i2", at: t0)]), from: snap([merged]))
        XCTAssertEqual(out.items[0].commentCount, 3)
        XCTAssertEqual(out.items[0].lastComment?.id, "c3")
        XCTAssertEqual(out.items[0].commentsAt, t0 + 100)
        XCTAssertTrue(out.items[0].commentsDue, "the newer activity is still due")
        XCTAssertNil(out.items[1].commentsAt)

        var saved = merged
        saved.commentsAt = nil
        let old = ProjectStore.carried(snap([fresh]), from: snap([saved]))
        XCTAssertEqual(old.items[0].commentsAt, saved.activityAt, "a nil stamp counts as read at its activity")
        XCTAssertTrue(old.items[0].commentsDue)
    }

    func testNoSecondCommentLine() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a0)])
        await start(store)
        tracker.setList("p1", [item("i1", at: a1)])
        tracker.setComments("i1", [comment("c1", at: a1)])
        await MainActor.run { store.poll() }
        await until("the comment line") { self.comments(store).count == 1 }
        await settle(store)
        for _ in 0..<2 {
            await MainActor.run { store.poll() }
            await settle(store)
        }
        XCTAssertEqual(comments(store).count, 1)
        XCTAssertEqual(tracker.read, ["i1"])
    }

    func testCommentsReadFailureKeepsTheItemDue() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a0)])
        await start(store)
        tracker.setList("p1", [item("i1", at: a1)])
        tracker.limited = true
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertEqual(store.snapshots[key]?.items.first?.commentsDue, true)
        tracker.limited = false
        tracker.setComments("i1", [comment("c1", at: a1)])
        await MainActor.run { store.poll() }
        await until("the comment line") { self.comments(store).count == 1 }
        await settle(store)
    }

    func testStuckCommentReadStopsAfterMaxRead() async throws {
        let store = try store(tracker)
        let a0 = Date() - 1000, a1 = Date() - 10
        tracker.setList("p1", [item("i1", at: a0)])
        await start(store)
        tracker.setList("p1", [item("i1", at: a1)])
        tracker.setComments("i1", [comment("c1", at: a1)])
        tracker.holdComments()
        await MainActor.run { store.poll() }
        await until("the comment call waits") { self.tracker.blockedComments == 1 }
        XCTAssertTrue(store.commentsPending)
        store.now = { Date() + 200 }
        await MainActor.run { store.releaseStuckReads() }
        XCTAssertFalse(store.commentsPending, "the stuck read stops")
        tracker.releaseComments()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(comments(store).isEmpty, "the late answer of a stopped read is ignored")
        XCTAssertEqual(store.snapshots[key]?.items.first?.commentsDue, true)
        await settle(store)
    }

    // MARK: Long break

    private func twoDays(_ items: [Item], _ store: ProjectStore) async {
        await MainActor.run { store.absorb(snap(items, fetchedAt: Date() - 2 * 86400)) }
    }

    func testLongBreakWritesOneAwayEntry() async throws {
        let store = try store(tracker)
        let a0 = Date() - 3 * 86400, a1 = Date() - 100
        let before = [item("i1", at: a0), item("i2", at: a0), item("i3", at: a0), item("i4", at: a0)]
        await twoDays(before, store)
        XCTAssertTrue(store.activity(limit: 10, project: nil).isEmpty)
        tracker.setList("p1", [item("i1", at: a1, status: "s2"), item("i2", at: a1), item("i3", at: a1), item("i4", at: a0)])
        await MainActor.run { store.track([summary()], live: []) }
        await settle(store)
        let rows = store.activity(limit: 10, project: nil)
        XCTAssertEqual(rows.map(\.change), [.away(items: 3)])
        XCTAssertEqual(rows[0].itemId, "")
        XCTAssertEqual(rows[0].title, "Project p1")
        XCTAssertEqual(store.unreadCount(), 0, "an away line is not an unread item")
        XCTAssertTrue(posts.all.isEmpty, "no notification")
        XCTAssertTrue(tracker.read.isEmpty, "no comment read")
        XCTAssertFalse(store.snapshots[key]?.items.contains { $0.commentsDue } ?? true, "the stamps settled")
        await MainActor.run { store.poll() }
        await settle(store)
        XCTAssertTrue(tracker.read.isEmpty)
        XCTAssertEqual(store.activity(limit: 10, project: nil).count, 1)
        await MainActor.run { store.markRead(itemId: "") }
        XCTAssertEqual(store.unreadCount(), 0)
    }

    func testShortBreakHasNoAwayEntry() async throws {
        let store = try store(tracker)
        let a0 = Date() - 7200, a1 = Date() - 100
        await MainActor.run { store.absorb(snap([item("i1", at: a0)], fetchedAt: Date() - 7200)) }
        tracker.setList("p1", [item("i1", at: a1, status: "s2")])
        await MainActor.run { store.track([summary()], live: []) }
        await settle(store)
        let rows = store.activity(limit: 10, project: nil)
        XCTAssertEqual(rows.count, 1)
        if case .status = rows[0].change {} else { XCTFail("\(rows)") }
        XCTAssertFalse(rows.contains { if case .away = $0.change { return true }; return false })
        XCTAssertEqual(posts.all.count, 1, "the notification as before")
    }
}

private extension Array {
    /// Removes and returns all elements.
    mutating func splice() -> [Element] {
        defer { removeAll() }
        return self
    }
}
