import XCTest
import OverSireCore
import OverSireAI
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

/// The owner app writes the AI results to the synced store. The other app shows them and makes no AI call (OVERSIRE-327).
@MainActor
final class AIOutputBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var root: URL!
    private let hub = FakeStoreHub()

    private struct App {
        let store: SyncedStore
        let writes: StoreWrites
        let book: AIOutputBook
        let engine: FakeAIEngine
        let sums: ItemSummaries
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-outputs-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func app(_ name: String) throws -> App {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SyncedStore(local: LocalStore(dir: dir.appendingPathComponent("store")), replication: hub.replication(), device: name,
                                dir: dir.appendingPathComponent("sync"), cursors: CursorStore(url: dir.appendingPathComponent("cursors.json")),
                                autoSync: false)
        let writes = StoreWrites(store: store)
        let engine = FakeAIEngine()
        engine.on(.itemSummary, .success(#"{"gist":"The page shows the status.","points":["a"],"open":[]}"#))
        let sums = ItemSummaries(path: dir.path + "/sums.json") { AIClient(cfg: AIConfig(), router: AIRouter(engines: [engine])) }
        let book = AIOutputBook(writes: writes)
        sums.outputs = book
        return App(store: store, writes: writes, book: book, engine: engine, sums: sums)
    }

    private func item(_ body: String) -> Item {
        Item(id: "A-1", key: "A-1", title: "Title", url: "", statusOptionId: nil, fields: [:], assignees: [], labels: [], author: nil,
             updatedBy: nil, updatedAt: now, activityAt: now.addingTimeInterval(-3600), commentCount: 0, lastComment: nil, mentionsMe: false, body: body)
    }

    private func summarize(_ a: App, _ body: String) async {
        let done = expectation(forNotification: ItemSummaries.changed, object: a.sums) { _ in a.sums.busy.isEmpty && a.sums.summary("A-1")?.hash == ItemSummary.hash(body) }
        a.sums.tick([(item(body), true)], now: now)
        await fulfillment(of: [done], timeout: 5)
    }

    /// Waits for the queued store writes, sends them, and reads them in `to` as the watch of a remote change does.
    private func sync(_ from: App, _ to: App, hash: String) async throws {
        for _ in 0..<100 {
            if try await from.store.local.all(AIOutput.self).contains(where: { $0.hash == hash }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await from.store.sync()
        await to.store.sync()
        let got = expectation(forNotification: ItemSummaries.changed, object: to.sums) { _ in to.sums.summary("A-1")?.hash == hash }
        to.writes.changed(AIOutput.collection)
        await fulfillment(of: [got], timeout: 5)
    }

    func testTheOtherAppShowsTheSummaryWithNoAICall() async throws {
        let owner = try app("mbp"), other = try app("mba")
        let body = String(repeating: "A long description. ", count: 100) + "End."
        await summarize(owner, body)
        XCTAssertEqual(owner.engine.tasks.count, 1)

        try await sync(owner, other, hash: ItemSummary.hash(body))
        XCTAssertEqual(other.sums.summary("A-1")?.gist, "The page shows the status.")
        other.sums.tick([(item(body), true)], now: now)
        XCTAssertEqual(other.engine.tasks.count, 0, "the record matches the text: no AI call")

        let changed = body + " More."
        XCTAssertTrue(other.sums.isStale("A-1", body: changed))
        await summarize(owner, changed)
        XCTAssertEqual(owner.engine.tasks.count, 2, "a new body hash runs the job again")
        try await sync(owner, other, hash: ItemSummary.hash(changed))
        XCTAssertFalse(other.sums.isStale("A-1", body: changed))
    }

    func testTheOtherAppShowsTheDigestAndKeepsItsDismiss() async throws {
        let owner = try app("mbp"), other = try app("mba")
        let a = CIAssist(path: root.path + "/mbp/ci.json", ai: { nil }), b = CIAssist(path: root.path + "/mba/ci.json", ai: { nil })
        a.outputs = owner.book
        b.outputs = other.book
        a.makeDigest(facts: ["2 runs failed."])
        for _ in 0..<100 {
            if try await owner.store.local.all(AIOutput.self).contains(where: { $0.kind == "ci-digest" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await owner.store.sync()
        await other.store.sync()
        let got = expectation(forNotification: CIAssist.changed, object: b) { _ in b.digest != nil }
        other.writes.changed(AIOutput.collection)
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(b.digest?.facts, ["2 runs failed."])

        b.dismissDigest()
        other.writes.changed(AIOutput.collection)
        XCTAssertEqual(b.digest?.facts, [], "a dismiss stays on this Mac")
    }

    func testTheLocalFileGoesToTheStoreOnce() async throws {
        let a = try app("mbp")
        let body = String(repeating: "A long description. ", count: 100) + "End."
        await summarize(a, body)
        let b = try app("mbp")   // the same folder: a new start with the file
        XCTAssertTrue(b.book.contains(.itemSummary, "A-1"))
        XCTAssertNotNil(b.sums.summary("A-1"))
    }
}
