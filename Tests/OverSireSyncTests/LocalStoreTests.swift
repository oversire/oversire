import XCTest
import OverSireCore
@testable import OverSireSync

final class LocalStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-store-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testPutAllGetDelete() async throws {
        let store = LocalStore(dir: dir)
        let empty = try await store.all(IgnoredFailure.self)
        XCTAssertEqual(empty, [], "no file yet")
        let a = IgnoredFailure(id: "https://x/runs/1#1", at: Date(timeIntervalSince1970: 1_000_000))
        let b = IgnoredFailure(id: "https://x/runs/2#1", at: Date(timeIntervalSince1970: 2_000_000))
        try await store.put(a)
        try await store.put(b)
        let all = try await store.all(IgnoredFailure.self)
        XCTAssertEqual(Set(all), [a, b])
        let got = try await store.get(IgnoredFailure.self, id: a.id)
        XCTAssertEqual(got, a)
        try await store.delete(IgnoredFailure.self, id: a.id)
        let gone = try await store.get(IgnoredFailure.self, id: a.id)
        XCTAssertNil(gone)

        let file = try String(contentsOf: dir.appendingPathComponent("ignored-failures.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(#""at" : "1970-01-24T03:33:20Z""#), file)

        let again = LocalStore(dir: dir)
        let kept = try await again.all(IgnoredFailure.self)
        XCTAssertEqual(kept, [b], "a new instance reads the file")
    }

    func testChanges() async throws {
        let store = LocalStore(dir: dir)
        let stream = await store.changes()
        let lane = QueueLane(project: "plane/o/p", identifier: "P", entries: [QueueEntry(key: "P-1", title: "One", added: Date())])
        try await store.put(lane)
        try await store.put(lane)
        try await store.delete(QueueLane.self, id: lane.id)
        try await store.delete(QueueLane.self, id: lane.id)
        try await store.put(QueueTrigger(key: "P-2", at: Date()))
        var seen: [StoreChange] = []
        for await c in stream {
            seen.append(c)
            if seen.count == 3 { break }
        }
        XCTAssertEqual(seen, [StoreChange(collection: "queue-lanes", id: "plane/o/p", deleted: false),
                              StoreChange(collection: "queue-lanes", id: "plane/o/p", deleted: true),
                              StoreChange(collection: "queue-triggers", id: "P-2", deleted: false)],
                       "a put with the same data and a delete of a missing id send no change")
    }

    func testBadRecordIsSkippedAndKept() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"bad":{"id":"bad"},"ok":{"id":"ok","at":"2026-10-01T00:00:00Z"}}"#.utf8)
            .write(to: dir.appendingPathComponent("ignored-failures.json"))
        let store = LocalStore(dir: dir)
        let all = try await store.all(IgnoredFailure.self)
        XCTAssertEqual(all.map(\.id), ["ok"])
        try await store.put(IgnoredFailure(id: "new", at: Date()))
        let file = try String(contentsOf: dir.appendingPathComponent("ignored-failures.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(#""bad""#), "the bad record stays in the file")
    }
}

final class StoreMigrationTests: XCTestCase {
    // queue.json of an older app: default JSONEncoder, so dates are seconds since 2001.
    static let oldQueue = #"""
        {"lanes":[{"project":"plane/ocral/b1","identifier":"TOWERTAIL","lastStarted":"TOWERTAIL-1",
          "entries":[{"key":"TOWERTAIL-2","title":"Login","condition":"ciPassed","added":800000000,"source":"label"}]}],
         "seen":["TOWERTAIL-2","TOWERTAIL-9"]}
        """#

    func testMigratesOldDefaultsAndQueue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(dir: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.put(QueueTrigger(key: "TOWERTAIL-9", at: Date(timeIntervalSince1970: 1)))

        let m = StoreMigration(defaults: ["ignoredFailures": ["https://x/runs/1#1", "https://x/runs/2#3"], "other": 1],
                               queueFile: Data(Self.oldQueue.utf8), now: now)
        XCTAssertTrue(m.hasWork)
        try await m.run(into: store)

        let ignored = try await store.all(IgnoredFailure.self)
        XCTAssertEqual(Set(ignored.map(\.id)), ["https://x/runs/1#1", "https://x/runs/2#3"])
        let lanes = try await store.all(QueueLane.self)
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lanes.first?.entries.first?.condition, .ciPassed)
        XCTAssertEqual(lanes.first?.entries.first?.source, .label)
        XCTAssertEqual(lanes.first?.entries.first?.added, Date(timeIntervalSinceReferenceDate: 800_000_000))
        let old = try await store.get(QueueTrigger.self, id: "TOWERTAIL-9")
        XCTAssertEqual(old?.at, Date(timeIntervalSince1970: 1), "a record in the store stays")
        let triggers = try await store.all(QueueTrigger.self)
        XCTAssertEqual(triggers.count, 2)
        let state = try await store.get(QueueLaneState.self, id: "plane/ocral/b1")
        XCTAssertEqual(state?.lastStarted, "TOWERTAIL-1", "the lane state of queue.json moves too")

        XCTAssertFalse(StoreMigration(defaults: ["other": 1], queueFile: nil).hasWork)
    }

    func testBadQueueFileThrows() async throws {
        let m = StoreMigration(defaults: [:], queueFile: Data("nope".utf8))
        let store = LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("oversire-mig-\(UUID().uuidString)"))
        do { try await m.run(into: store); XCTFail("bad file") } catch {
            guard case .decoding(let m)? = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertTrue(m.hasPrefix("queue.json"), m)
        }
    }

    // A store folder of version 1: the lanes hold lastStarted and error.
    func testSplitsLaneStateOfAnOldStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"""
            {"plane/ocral/b1":{"project":"plane/ocral/b1","identifier":"TOWERTAIL","lastStarted":"TOWERTAIL-1",
               "entries":[{"key":"TOWERTAIL-2","title":"Login","condition":"ciPassed","added":"2026-10-01T09:00:00Z","source":"you"}]},
             "plane/ocral/c3":{"project":"plane/ocral/c3","identifier":"OVERSIRE","entries":[],"error":"No repo folder"},
             "plane/ocral/d4":{"project":"plane/ocral/d4","identifier":"TREBI","entries":[]}}
            """#.utf8).write(to: dir.appendingPathComponent("queue-lanes.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = StoreMigration(defaults: [:], queueFile: nil, now: now)
        XCTAssertFalse(m.hasWork, "the split runs without old copies to remove")
        try await m.run(into: LocalStore(dir: dir))

        let store = LocalStore(dir: dir)
        let lanes = try await store.all(QueueLane.self)
        XCTAssertEqual(lanes.count, 3, "no lane is lost")
        let b1 = try await store.get(QueueLane.self, id: "plane/ocral/b1")
        XCTAssertEqual(b1?.entries.map(\.key), ["TOWERTAIL-2"])
        let states = try await store.all(QueueLaneState.self).sorted { $0.project < $1.project }
        XCTAssertEqual(states, [QueueLaneState(project: "plane/ocral/b1", lastStarted: "TOWERTAIL-1", updatedAt: now),
                                QueueLaneState(project: "plane/ocral/c3", error: "No repo folder", updatedAt: now)])
        let file = try String(contentsOf: dir.appendingPathComponent("queue-lanes.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("lastStarted") || file.contains("No repo folder"), "the lanes lose the old fields")

        // A second run changes nothing.
        try await StoreMigration(defaults: [:], queueFile: nil, now: now.addingTimeInterval(60)).run(into: store)
        let again = try await store.all(QueueLaneState.self)
        XCTAssertEqual(again.map(\.updatedAt), [now, now])
    }
}
