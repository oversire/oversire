import XCTest
import OverSireCore
@testable import OverSireSync

final class MirrorReaderTests: XCTestCase {
    /// A home feed that the test fills. It pages like the daemon.
    private final class Feed: MirrorFetch, @unchecked Sendable {
        private let lock = NSLock()
        var epoch = "e1"
        var ready = true
        var pageSize = 500
        var appVersion = "1.42"
        private var docs: [MirrorDoc] = []

        func add(_ d: MirrorDoc) {
            lock.withLock {
                var d = d
                d.seq = Int64(docs.count + 1)
                docs.append(d)
            }
        }

        func newEpoch(_ e: String, ready: Bool) {
            lock.withLock { epoch = e; self.ready = ready; docs = [] }
        }

        func head() async throws -> MirrorHead {
            lock.withLock { MirrorHead(epoch: epoch, head: Int64(docs.count), floor: 0, ready: ready, appVersion: appVersion) }
        }

        func page(after: Int64, limit: Int, epoch sent: String?) async throws -> MirrorPage {
            lock.withLock {
                if let sent, sent != epoch { return MirrorPage(epoch: epoch, docs: [], next: 0, more: false, reset: true) }
                let rest = docs.filter { $0.seq > after }
                let take = Array(rest.prefix(min(limit, pageSize)))
                return MirrorPage(epoch: epoch, docs: take, next: take.last?.seq ?? after, more: rest.count > take.count, reset: false)
            }
        }
    }

    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let ref = ProjectRef(account: AccountID(provider: "plane", id: "ws"), id: "p1", key: "ONE")

    private func doc<T: Encodable>(_ kind: MirrorKind, _ id: String, _ value: T, v: Int = MirrorCodec.version) -> MirrorDoc {
        MirrorDoc(kind: kind, id: id, v: v, hash: UUID().uuidString, at: at, body: try! MirrorCodec.body(value))
    }

    private func gone(_ kind: MirrorKind, _ id: String) -> MirrorDoc { MirrorDoc(kind: kind, id: id, v: 1, at: at, deleted: true) }

    private func item(_ n: Int) -> Item {
        Item(id: "i\(n)", key: "ONE-\(n)", title: "T\(n)", url: "u", statusOptionId: "t", fields: [:], assignees: [], labels: [],
             author: nil, updatedBy: nil, updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil, mentionsMe: false, parentId: nil)
    }

    private func project(_ title: String = "One") -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "ONE", title: title, url: "", closed: false),
                        statusOptions: [StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")], items: [], fetchedAt: at)
    }

    private func run(_ id: String) -> Run {
        Run(id: id, name: "ci", displayTitle: "ci", status: "completed", conclusion: "success", headBranch: "main", headSha: "abc", event: "push",
            url: "u", updatedAt: "2026-01-01T00:00:00Z", createdAt: "2026-01-01T00:00:00Z", startedAt: nil, number: 1, workflowName: "ci", actorLogin: nil)
    }

    private func cache(_ name: String = UUID().uuidString) -> MirrorCache {
        MirrorCache(dir: FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(name)").path, debounce: 0)
    }

    func testPullsAfterCursor() async throws {
        let feed = Feed()
        feed.pageSize = 2
        feed.add(doc(.project, ref.storeKey, project()))
        feed.add(doc(.item, MirrorCodec.itemID(project: ref.storeKey, item: "i1"), item(1)))
        feed.add(doc(.item, MirrorCodec.itemID(project: ref.storeKey, item: "i2"), item(2)))
        feed.add(doc(.runs, "acme/web", MirrorRuns(runs: [run("r1")])))
        let reader = MirrorReader(fetch: feed, cache: cache())
        let d = try await reader.pull()
        XCTAssertEqual(d.projects.keys.sorted(), [ref.storeKey])
        XCTAssertEqual(d.items[ref.storeKey]?.map(\.id), ["i1", "i2"])
        XCTAssertEqual(d.runs?["acme/web"]?.map(\.id), ["r1"])
        XCTAssertTrue(d.reset, "the first read is the whole feed")
        let pos = await reader.position
        XCTAssertEqual(pos.epoch, "e1")
        XCTAssertEqual(pos.cursor, 4)

        feed.add(doc(.item, MirrorCodec.itemID(project: ref.storeKey, item: "i3"), item(3)))
        let next = try await reader.pull()
        XCTAssertFalse(next.reset)
        XCTAssertEqual(next.items[ref.storeKey]?.map(\.id), ["i3"])
        let idle = try await reader.pull()
        XCTAssertTrue(idle.isEmpty)
    }

    func testResetWaitsForReady() async throws {
        let feed = Feed()
        feed.add(doc(.project, ref.storeKey, project("Old")))
        let reader = MirrorReader(fetch: feed, cache: cache())
        _ = try await reader.pull()

        feed.newEpoch("e2", ready: false)
        feed.add(doc(.project, ref.storeKey, project("New")))
        let wait = try await reader.pull()
        XCTAssertTrue(wait.isEmpty, "the old data stays until the new feed is ready")
        var pos = await reader.position
        XCTAssertEqual(pos.epoch, "e1")

        feed.ready = true
        let swap = try await reader.pull()
        XCTAssertTrue(swap.reset)
        XCTAssertEqual(swap.projects[ref.storeKey]?.summary.title, "New")
        pos = await reader.position
        XCTAssertEqual(pos.epoch, "e2")
    }

    func testTombstoneRemovesItem() async throws {
        let feed = Feed()
        let id = MirrorCodec.itemID(project: ref.storeKey, item: "i1")
        feed.add(doc(.project, ref.storeKey, project()))
        feed.add(doc(.item, id, item(1)))
        let reader = MirrorReader(fetch: feed, cache: cache())
        _ = try await reader.pull()
        feed.add(gone(.item, id))
        let d = try await reader.pull()
        XCTAssertEqual(d.removedItems[ref.storeKey], ["i1"])
        XCTAssertTrue(d.items.isEmpty)
    }

    func testUnknownVersionNeedsUpdate() async throws {
        let feed = Feed()
        feed.add(doc(.project, ref.storeKey, project()))
        feed.add(doc(.item, MirrorCodec.itemID(project: ref.storeKey, item: "i1"), item(1), v: 2))
        let reader = MirrorReader(fetch: feed, cache: cache())
        let d = try await reader.pull()
        XCTAssertEqual(d.needsUpdate, "1.42")
        XCTAssertNil(d.items[ref.storeKey], "a doc of a newer version does not apply")
        XCTAssertNotNil(d.projects[ref.storeKey])
    }

    func testCacheSurvivesRestart() async throws {
        let feed = Feed()
        let store = cache()
        feed.add(doc(.project, ref.storeKey, project()))
        feed.add(doc(.runs, "acme/web", MirrorRuns(runs: [run("r1")])))
        let first = MirrorReader(fetch: feed, cache: store)
        _ = try await first.pull()

        let second = MirrorReader(fetch: feed, cache: store)
        let pos = await second.position
        XCTAssertEqual(pos.epoch, "e1")
        XCTAssertEqual(pos.cursor, 2)
        let cached = await second.cached()
        XCTAssertEqual(cached.runs?["acme/web"]?.map(\.id), ["r1"])
        let updated = await second.updatedAt
        XCTAssertNotNil(updated)
        let idle = try await second.pull()
        XCTAssertTrue(idle.isEmpty, "the cursor is at the head: nothing to read")
    }

    func testCatalogDecodes() async throws {
        let feed = Feed()
        let summary = ProjectSummary(ref: ref, identifier: "ONE", title: "One", url: "", closed: false)
        let catalog = ClientCatalog(projects: [CatalogProject(summary: summary, capabilities: [.links])], capabilities: ["tracker": [.links]], trackers: ["ws"])
        feed.add(doc(.catalog, MirrorCodec.catalogID, catalog))
        let reader = MirrorReader(fetch: feed, cache: cache())
        let d = try await reader.pull()
        XCTAssertEqual(d.catalog?.projects.first?.summary.identifier, "ONE")
        XCTAssertEqual(d.catalog?.projects.first?.capabilities, [.links])
        XCTAssertEqual(d.catalog?.trackers, ["ws"])
    }
}
