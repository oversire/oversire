import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class SyncedStoreTests: XCTestCase {
    var root: URL!
    let subject = SubjectRef.item(ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p", key: "OVERSIRE"),
                                          id: "i1", key: "OVERSIRE-1", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-1/")!))

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-synced-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    final class Wall: @unchecked Sendable {
        var ms: Double
        init(_ ms: Double) { self.ms = ms }
        var date: Date { Date(timeIntervalSince1970: ms / 1000) }
    }

    func client(_ name: String, _ hub: FakeStoreHub, wall: Wall = Wall(1_790_000_000_000)) -> SyncedStore {
        let dir = root.appendingPathComponent(name)
        return SyncedStore(local: LocalStore(dir: dir.appendingPathComponent("store")), replication: hub.replication(), device: name,
                           dir: dir.appendingPathComponent("sync"), cursors: CursorStore(url: dir.appendingPathComponent("cursors.json")),
                           now: { wall.date }, autoSync: false)
    }

    func note(_ text: String, id: String = "n1") -> Note { Note(id: id, subject: subject, text: text, at: Date(timeIntervalSince1970: 0)) }

    func testOfflineWritesSyncLater() async throws {
        let hub = FakeStoreHub()
        await hub.setOnline(false)
        let a = client("a", hub)
        try await a.put(note("offline"))
        let kept = try await a.get(Note.self, id: "n1")
        XCTAssertEqual(kept?.text, "offline", "the write is on disk at once")
        await a.sync()
        let pending = await a.pending
        let error = await a.lastError
        XCTAssertEqual(pending, 1)
        XCTAssertNotNil(error)

        await hub.setOnline(true)
        await a.sync()
        let after = await a.pending
        XCTAssertEqual(after, 0)
        let ops = await hub.ops()
        XCTAssertEqual(ops.map(\.collection), ["notes"])
        XCTAssertEqual(ops.first?.device, "a")
    }

    func testTwoClientsConverge() async throws {
        let hub = FakeStoreHub()
        let wa = Wall(1_790_000_000_000), wb = Wall(1_790_000_000_500)
        let a = client("a", hub, wall: wa), b = client("b", hub, wall: wb)
        // Both edit offline. b writes later.
        try await a.put(note("from a"))
        try await b.put(note("from b"))
        await b.sync()
        await a.sync()
        await b.sync()
        let ta = try await a.get(Note.self, id: "n1")?.text
        let tb = try await b.get(Note.self, id: "n1")?.text
        XCTAssertEqual(ta, "from b")
        XCTAssertEqual(tb, "from b")

        // The same millisecond: the device id decides, on each side.
        wa.ms = 1_790_000_010_000
        wb.ms = 1_790_000_010_000
        try await a.put(note("a again"))
        try await b.put(note("b again"))
        await a.sync()
        await b.sync()
        await a.sync()
        let ta2 = try await a.get(Note.self, id: "n1")?.text
        let tb2 = try await b.get(Note.self, id: "n1")?.text
        XCTAssertEqual(ta2, tb2)
    }

    func testTombstoneWinsOverAnOlderPut() async throws {
        let hub = FakeStoreHub()
        let wa = Wall(1_790_000_000_000), wb = Wall(1_790_000_000_000)
        let a = client("a", hub, wall: wa), b = client("b", hub, wall: wb)
        try await a.put(Pin(id: "p1", subject: subject, at: Date(timeIntervalSince1970: 0)))
        await a.sync()
        await b.sync()
        let got = try await b.get(Pin.self, id: "p1")
        XCTAssertNotNil(got)

        wb.ms += 10_000
        try await b.delete(Pin.self, id: "p1")
        // a edits later in its own time, but its clock is behind.
        wa.ms += 5_000
        try await a.put(Pin(id: "p1", subject: subject, at: Date(timeIntervalSince1970: 1)))
        await b.sync()
        await a.sync()
        await b.sync()
        let pa = try await a.get(Pin.self, id: "p1")
        let pb = try await b.get(Pin.self, id: "p1")
        XCTAssertNil(pa, "the delete is newer")
        XCTAssertNil(pb)
    }

    func testCursorResumes() async throws {
        let hub = FakeStoreHub()
        await hub.setPageSize(2)
        let a = client("a", hub)
        for i in 0..<5 { try await a.put(note("n\(i)", id: "n\(i)")) }
        await a.sync()

        let b = client("b", hub)
        await b.sync()
        let all = try await b.all(Note.self)
        XCTAssertEqual(all.count, 5, "b reads all pages")

        try await a.put(note("new", id: "n9"))
        await a.sync()
        let before = await hub.pulls
        // A restart of b: same files, same cursor.
        let b2 = client("b", hub)
        await b2.sync()
        let reads = await hub.pulls - before
        XCTAssertEqual(reads, 1, "b2 reads only the new op")
        let n9 = try await b2.get(Note.self, id: "n9")
        XCTAssertEqual(n9?.text, "new")
    }

    func testOutboxReplaysAfterACrash() async throws {
        let hub = FakeStoreHub()
        await hub.setOnline(false)
        let a = client("a", hub)
        try await a.put(note("before the crash"))
        try await a.put(QueueTrigger(key: "P-1", at: Date(timeIntervalSince1970: 0)))
        await hub.setOnline(true)

        let again = client("a", hub)
        let pending = await again.pending
        XCTAssertEqual(pending, 2)
        await again.sync()
        let ops = await hub.ops()
        XCTAssertEqual(Set(ops.map(\.collection)), ["notes", "queue-triggers"])
    }

    func testLocalCollectionsDoNotSync() async throws {
        let hub = FakeStoreHub()
        let a = client("a", hub)
        try await a.put(QueueLaneState(project: "plane/o/p", updatedAt: Date(timeIntervalSince1970: 0)))
        let pending = await a.pending
        XCTAssertEqual(pending, 0)
        let kept = try await a.get(QueueLaneState.self, id: "plane/o/p")
        XCTAssertNotNil(kept)
    }

    func testHubOnlyCollectionsComeDownAndNeverGoUp() async throws {
        let hub = FakeStoreHub()
        let state = BillingState(plan: "cloud", periodStart: Date(timeIntervalSince1970: 1_790_000_000), periodEnd: Date(timeIntervalSince1970: 1_792_600_000),
                                 grantMicroUSD: 2_000_000, balanceMicroUSD: 5_000_000, dailyCapMicroUSD: 500_000)
        _ = try await hub.replication().push([StoreOp(collection: BillingState.collection, id: "state", op: .put, record: try JSONValue(state),
                                                      hlc: "1790000000000-0000-hub", device: "hub")])
        // A Mac with a billing record from before the pairing.
        let dir = root.appendingPathComponent("a")
        try await LocalStore(dir: dir.appendingPathComponent("store")).put(BillingState(plan: "free", periodStart: .distantPast,
                                                                                        periodEnd: .distantPast, grantMicroUSD: 0, dailyCapMicroUSD: 0))
        let a = client("a", hub)
        await a.sync()
        let got = try await a.get(BillingState.self, id: "state")
        XCTAssertEqual(got?.balanceMicroUSD, 5_000_000)
        let ops = await hub.ops()
        XCTAssertEqual(ops.map(\.device), ["hub"], "the seed does not send a hub-only record")
        try await a.put(BillingState(plan: "free", periodStart: .distantPast, periodEnd: .distantPast, grantMicroUSD: 0, dailyCapMicroUSD: 0))
        let pending = await a.pending
        XCTAssertEqual(pending, 0, "a local write stays local")
    }

    func testRunnerSessionsComeDown() async throws {
        let hub = FakeStoreHub()
        let ref = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "oversire", id: "local"), id: "oversire/OVERSIRE-80"), id: "s-1")
        let s = RunnerSession(id: "s-1", runner: "D1", session: ref, order: "o1", agent: "claude", repo: "/src/oversire", state: .waitingPermission,
                              permission: PermissionPrompt(id: "p-1", tool: "Bash", text: "npm test", expiresAt: Date(timeIntervalSince1970: 1_790_000_600)),
                              startedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        _ = try await hub.replication().push([StoreOp(collection: RunnerSession.collection, id: s.id, op: .put, record: try JSONValue(s),
                                                      hlc: "1790000000000-0000-hub", device: "hub")])
        let a = client("a", hub)
        await a.sync()
        let got = try await a.get(RunnerSession.self, id: "s-1")
        XCTAssertEqual(got?.permission?.id, "p-1")
        XCTAssertEqual(got?.state, .waitingPermission)
    }

    func testSeedSendsOldRecordsAndKeepsTheServerCopy() async throws {
        let hub = FakeStoreHub()
        let b = client("b", hub, wall: Wall(1_790_000_000_000))
        try await b.put(note("server copy"))
        await b.sync()

        // A Mac with records from before the pairing.
        let dir = root.appendingPathComponent("a")
        let local = LocalStore(dir: dir.appendingPathComponent("store"))
        try await local.put(note("old local copy"))
        try await local.put(note("only here", id: "n2"))
        let a = client("a", hub, wall: Wall(1_790_000_100_000))
        await a.sync()
        let n1 = try await a.get(Note.self, id: "n1")?.text
        XCTAssertEqual(n1, "server copy")
        let ops = await hub.ops()
        XCTAssertEqual(ops.map(\.id).sorted(), ["n1", "n2"])
        XCTAssertEqual(ops.first { $0.id == "n1" }?.device, "b")
    }

    func testResetDropsRecordsThatAreGone() async throws {
        let hub = FakeStoreHub()
        let a = client("a", hub), b = client("b", hub, wall: Wall(1_790_000_001_000))
        try await a.put(note("keep", id: "n1"))
        try await a.put(note("goes", id: "n2"))
        await a.sync()
        await b.sync()
        try await a.delete(Note.self, id: "n2")
        try await a.put(note("new", id: "n3"))
        await a.sync()
        await hub.pruneTombstones()

        // b was away for more than 30 days.
        try await b.put(note("waits", id: "n4"))
        await b.sync()
        let ids = try await b.all(Note.self).map(\.id).sorted()
        XCTAssertEqual(ids, ["n1", "n3", "n4"])
    }

    func testChangesIncludeRemoteWrites() async throws {
        let hub = FakeStoreHub()
        let a = client("a", hub), b = client("b", hub)
        let stream = await b.changes()
        let remote = await b.remoteChanges()
        try await b.put(note("local", id: "n0"))
        try await a.put(note("hi"))
        await a.sync()
        await b.sync()
        let seen = await take(2, from: stream)
        XCTAssertEqual(seen, [StoreChange(collection: "notes", id: "n0", deleted: false),
                              StoreChange(collection: "notes", id: "n1", deleted: false)])
        let fromServer = await take(1, from: remote)
        XCTAssertEqual(fromServer, [StoreChange(collection: "notes", id: "n1", deleted: false)], "the own write is not remote")
    }
}
