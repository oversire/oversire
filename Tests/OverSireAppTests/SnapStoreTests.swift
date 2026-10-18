import XCTest
@testable import OverSireApp

final class SnapStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-snap-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func shot(_ project: String, note: String = "", at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SnapShot {
        SnapShot(project: project, kind: .window, app: "Safari", windowTitle: "Jobs", pixelSize: CGSize(width: 200, height: 100),
                 scale: 2, note: note, marks: [SnapMark(rect: SnapRect(x: 1, y: 2, w: 3, h: 4), note: "a")], takenAt: at)
    }

    func testSaveAndLoadAgain() throws {
        let store = SnapStore(dir: dir)
        let a = shot("OVERSIRE", note: "first"), b = shot("OVERSIRE", note: "second")
        try store.add(a, png: Data([1, 2, 3]))
        var basket = try store.add(b, png: Data([4]))
        XCTAssertEqual(store.openBaskets.count, 1)
        basket.reorder(1, to: 0)
        try store.update(basket)
        try store.add(shot("SLING"), png: Data([5]))

        let again = SnapStore(dir: dir)
        XCTAssertEqual(again.openBaskets.count, 2)
        let loaded = try XCTUnwrap(again.basket(basket.id))
        XCTAssertEqual(loaded.shots.map(\.note), ["second", "first"])
        XCTAssertEqual(loaded.shots, basket.shots)
        XCTAssertEqual(again.png(of: a.id, in: basket.id), Data([1, 2, 3]))
        XCTAssertEqual(again.open(for: "oversire").id, basket.id, "the project key ignores case")
    }

    func testABadFileIsSkipped() throws {
        let store = SnapStore(dir: dir)
        let good = try store.add(shot("OVERSIRE"), png: Data([1]))
        let bad = dir.appendingPathComponent("2026-01-01-000000-bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: bad.appendingPathComponent("basket.json"))
        let shotFile = dir.appendingPathComponent(good.id).appendingPathComponent("shot-\(good.shots[0].id.uuidString).json")
        try store.add(shot("OVERSIRE", note: "kept"), png: Data([2]))
        try Data("[]".utf8).write(to: shotFile)

        let again = SnapStore(dir: dir)
        XCTAssertEqual(again.baskets.map(\.id), [good.id])
        XCTAssertEqual(again.baskets[0].shots.map(\.note), ["kept"])
    }

    func testStatesHistoryAndPurge() throws {
        let store = SnapStore(dir: dir)
        let old = try store.add(shot("OVERSIRE"), png: Data([1]))
        try store.markSent(old.id, key: "OVERSIRE-200", session: "t1")
        XCTAssertEqual(store.basket(old.id)?.state, .sent(key: "OVERSIRE-200", session: "t1"))
        XCTAssertTrue(store.openBaskets.isEmpty)
        let open = try store.add(shot("OVERSIRE"), png: Data([2]))
        XCTAssertNotEqual(open.id, old.id, "a sent basket takes no new shots")
        XCTAssertEqual(store.history().map(\.id), [old.id])

        store.purge(olderThan: Date().addingTimeInterval(-3600))
        XCTAssertEqual(store.baskets.count, 2, "both are new")
        store.purge(olderThan: Date().addingTimeInterval(3600))
        XCTAssertEqual(store.baskets.map(\.id), [open.id], "an open basket stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(old.id).path))
        XCTAssertEqual(SnapStore(dir: dir).baskets.map(\.id), [open.id])
    }

    func testRemoveTheLastShotDiscardsTheBasket() throws {
        let store = SnapStore(dir: dir)
        let b = try store.add(shot("OVERSIRE"), png: Data([1]))
        let changed = expectation(forNotification: SnapStore.changed, object: store)
        try store.remove(shot: b.shots[0].id)
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(store.baskets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(b.id).path))
    }
}
