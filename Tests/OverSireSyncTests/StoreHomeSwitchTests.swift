import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// SyncedStore changes its replica on a 409 and on a group change, and loses no op.
final class StoreHomeSwitchTests: XCTestCase {
    var root: URL!
    let subject = SubjectRef.item(ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p", key: "OVERSIRE"),
                                          id: "i1", key: "OVERSIRE-1", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-1/")!))

    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-home-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func client(_ replica: StoreReplica?, rehome: @escaping @Sendable (StoreNotHome) async -> StoreReplica? = { _ in nil }) -> SyncedStore {
        SyncedStore(local: LocalStore(dir: root.appendingPathComponent("store")), replica: replica, device: "app", dir: root.appendingPathComponent("sync"),
                    cursors: CursorStore(url: root.appendingPathComponent("cursors.json")), autoSync: false, rehome: rehome)
    }

    func note(_ text: String, id: String = "n1") -> Note { Note(id: id, subject: subject, text: text, at: Date(timeIntervalSince1970: 0)) }

    func replica(_ id: String, _ hub: FakeStoreHub) -> StoreReplica { StoreReplica(id: id, replication: hub.replication()) }

    func testA409MovesToTheNewHomeWithNoLostOp() async throws {
        let mbp = FakeStoreHub(), mba = FakeStoreHub()
        let asked = Locked<[StoreNotHome]>([])
        let s = client(replica("member:g/mbp", mbp)) { e in
            asked.with { $0.append(e) }
            return e.home == "mba" ? StoreReplica(id: "member:g/mba", replication: mba.replication()) : nil
        }
        try await s.put(note("first"))
        await s.sync()
        await mbp.setNotHome(StoreNotHome(home: "mba", message: "mba is home"))
        try await s.put(note("second", id: "n2"))
        await s.sync()

        XCTAssertEqual(asked.get().map(\.home), ["mba"])
        let id = await s.replicaID
        XCTAssertEqual(id, "member:g/mba")
        let pending = await s.pending
        XCTAssertEqual(pending, 0)
        let ids = await mba.ops().map(\.id).sorted()
        XCTAssertEqual(ids, ["n1", "n2"], "the new home gets the new op and the full store")
        let kept = await mbp.ops().map(\.id)
        XCTAssertEqual(kept, ["n1"])
    }

    func testA409WithNoNewHomeKeepsTheOps() async throws {
        let hub = FakeStoreHub()
        let s = client(replica("member:g/mbp", hub))
        await hub.setNotHome(StoreNotHome(cloud: true, message: "the cloud is home"))
        try await s.put(note("kept"))
        await s.sync()
        let id = await s.replicaID
        XCTAssertNil(id, "local only")
        let pending = await s.pending
        XCTAssertEqual(pending, 1)
        let error = await s.lastError
        XCTAssertEqual(error, "the cloud is home")
    }

    func testGroupChangeKeepsTheOpsOfTheOfflineTime() async throws {
        let mbp = FakeStoreHub(), mba = FakeStoreHub()
        let s = client(replica("member:g/mbp", mbp))
        try await s.put(note("synced"))
        await s.sync()
        // The home goes offline: local only.
        await s.use(nil)
        try await s.put(note("offline", id: "n2"))
        try await s.delete(Note.self, id: "n1")
        await s.sync()
        let waiting = await s.pending
        XCTAssertEqual(waiting, 2)

        // The group moves home to mba while the old home was offline.
        await s.use(replica("member:g/mba", mba))
        await s.sync()
        let pending = await s.pending
        XCTAssertEqual(pending, 0)
        let ops = await mba.ops().sorted { $0.id < $1.id }
        XCTAssertEqual(ops.map(\.id), ["n1", "n2"])
        XCTAssertEqual(ops.map(\.op), [.delete, .put], "the tombstone goes with its hlc")
    }

    func testTheFullPushKeepsTheHLC() async throws {
        let mbp = FakeStoreHub(), mba = FakeStoreHub()
        let s = client(replica("member:g/mbp", mbp))
        try await s.put(note("one"))
        await s.sync()
        let before = await mbp.ops().first?.hlc
        await s.use(replica("member:g/mba", mba))
        await s.sync()
        let after = await mba.ops().first?.hlc
        XCTAssertEqual(after, before)
    }

    func testAnotherAppReadsTheNewHome() async throws {
        let mba = FakeStoreHub()
        let a = client(replica("member:g/mba", mba))
        try await a.put(note("from a"))
        await a.sync()
        let other = root.appendingPathComponent("b")
        let b = SyncedStore(local: LocalStore(dir: other.appendingPathComponent("store")), replica: nil, device: "b",
                            dir: other.appendingPathComponent("sync"), cursors: CursorStore(url: other.appendingPathComponent("cursors.json")),
                            autoSync: false)
        await b.sync()
        await b.use(replica("member:g/mba", mba))
        await b.sync()
        let got = try await b.get(Note.self, id: "n1")
        XCTAssertEqual(got?.text, "from a")
    }

    func testThe409BodyOfADaemon() {
        XCTAssertEqual(CloudReplication.notHome(Data(#"{"error":"mba is home","home":"mba"}"#.utf8)),
                       StoreNotHome(home: "mba", message: "mba is home"))
        XCTAssertEqual(CloudReplication.notHome(Data(#"{"error":"the cloud is home","cloud":{"hub":"https://h","account":"a"}}"#.utf8)),
                       StoreNotHome(cloud: true, message: "the cloud is home"))
    }

    func testMemberCallsOnLoopbackSendNoToken() async throws {
        let http = RecordedHTTP()
        http.on("GET", "http://127.0.0.1:7690/v1/store/ops?after=0&limit=500", 409, #"{"error":"mba is home","home":"mba"}"#)
        do {
            _ = try await CloudReplication(base: URL(string: "http://127.0.0.1:7690")!, token: nil, http: http).pull(after: nil)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? StoreNotHome, StoreNotHome(home: "mba", message: "mba is home"))
        }
        XCTAssertNil(http.requests[0].value(forHTTPHeaderField: "Authorization"))
    }
}

final class HomeMoveTests: XCTestCase {
    func testDecode() throws {
        let full = try JSONDecoder().decode(HomeMove.self, from: Data(#"{"ok":true,"records":12,"offline":true}"#.utf8))
        XCTAssertEqual(full, HomeMove(records: 12, offline: true))
        XCTAssertNotNil(full.warning)
        let short = try JSONDecoder().decode(HomeMove.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(short, HomeMove())
        XCTAssertNil(short.warning)
    }
}
