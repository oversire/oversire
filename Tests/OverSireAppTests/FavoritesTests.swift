import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

/// Favorite items show first in each list, also when Done (OVERSIRE-433).
@MainActor
final class FavoritesTests: XCTestCase {
    private var root: URL!
    private let hub = FakeStoreHub()
    private let now = Date(timeIntervalSince1970: 1_793_922_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("favorites-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store(_ name: String) throws -> SyncedStore {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SyncedStore(local: LocalStore(dir: dir.appendingPathComponent("store")), replication: hub.replication(), device: name,
                           dir: dir.appendingPathComponent("sync"), cursors: CursorStore(url: dir.appendingPathComponent("cursors.json")),
                           autoSync: false)
    }

    private let project = ProjectRef(workspace: "w", id: "p")
    private func ref(_ key: String) -> ItemRef { ItemRef(project: project, id: key.lowercased(), key: key, url: URL(string: "https://plane.so/\(key)")!) }

    private func item(_ id: String, _ state: String, parent: String? = nil, updated: TimeInterval = 0, mine: Bool = false) -> Item {
        let at = now.addingTimeInterval(updated)
        return Item(id: id, key: "A-\(id)", title: "T\(id)", url: "u", statusOptionId: state, fields: [:], assignees: mine ? ["me"] : [], labels: [],
                    author: nil, updatedBy: nil, updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil,
                    mentionsMe: false, parentId: parent)
    }

    private let todo = StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")
    private let doing = StatusOption(id: "p", name: "In Progress", color: "", group: "started")
    private let done = StatusOption(id: "d", name: "Done", color: "", group: "completed")

    private func snap(_ items: [Item]) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: project, identifier: "A", title: "A", url: "", closed: false),
                        statusOptions: [todo, doing, done], items: items, fetchedAt: now)
    }

    // MARK: The model

    func testAFavoriteSyncsToTheOtherMac() async throws {
        let mba = try store("mba"), mini = try store("mini")
        let a = Favorites(writes: StoreWrites(store: mba)), bw = StoreWrites(store: mini), b = Favorites(writes: bw)
        var notes = 0
        let o = NotificationCenter.default.addObserver(forName: Favorites.changed, object: b, queue: .main) { _ in notes += 1 }
        defer { NotificationCenter.default.removeObserver(o) }

        XCTAssertTrue(a.set(ref("a-7"), on: true, now: now))
        XCTAssertTrue(a.contains("A-7"), "the key is not case-sensitive")
        XCTAssertFalse(a.set(ref("A-7"), on: true), "a second add changes nothing")

        for _ in 0..<100 where !b.contains("A-7") {
            await mba.sync(); await mini.sync()
            bw.changed(Pin.collection)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(b.keys, ["A-7"])
        XCTAssertEqual(notes, 1)
        let pin = try XCTUnwrap(bw.load(Pin.self).first)
        XCTAssertEqual(pin.id, "item:A-7")
        XCTAssertEqual(pin.subject, .item(ref("a-7")))

        XCTAssertTrue(b.set(ref("A-7"), on: false))
        XCTAssertFalse(b.contains("A-7"))
        XCTAssertFalse(b.set(ref("A-7"), on: false), "a second remove changes nothing")
    }

    func testFirstSplitsAndKeepsTheOrder() throws {
        let f = Favorites(writes: StoreWrites(store: try store("mba")))
        f.set(ref("A-2"), on: true)
        f.set(ref("A-4"), on: true)
        let split = f.first(["A-1", "A-2", "A-3", "A-4"]) { $0 }
        XCTAssertEqual(split.favorites, ["A-2", "A-4"])
        XCTAssertEqual(split.rest, ["A-1", "A-3"])
    }

    // MARK: The lists

    func testTheProjectPageShowsFavoritesFirstAlsoWhenDone() {
        let old = -30 * 86400.0
        let s = snap([item("1", "p"), item("2", "d", updated: old), item("3", "t"), item("4", "d", updated: old)])
        let fav: Set = ["A-2", "A-3"]
        let groups = ProjectPage.statusGroups(s, s.rootItems, showDone: false, hideDoneAfterDays: 7, favorite: fav.contains)
        XCTAssertEqual(groups.first?.0.id, Favorites.groupId)
        XCTAssertEqual(groups.first?.0.name, "Favorites")
        XCTAssertEqual(groups.first?.1.map(\.id), ["3", "2"], "open first, then the old Done favorite that Hide Done does not hide")
        let ids = Dictionary(uniqueKeysWithValues: groups.dropFirst().map { ($0.0.id, $0.1.map(\.id)) })
        XCTAssertEqual(ids["t"], [], "a favorite shows only in Favorites")
        XCTAssertEqual(ids["p"], ["1"])
        XCTAssertEqual(ids["d"], [], "the old Done item that is not a favorite hides")
    }

    func testNoFavoritesGivesNoGroup() {
        let s = snap([item("1", "p")])
        XCTAssertEqual(Set(ProjectPage.statusGroups(s, s.rootItems, showDone: true, hideDoneAfterDays: 0).map(\.0.id)), ["t", "p", "d"])
    }

    func testWorkFavoritesCoverAllItemsOpenFirst() {
        let s = snap([item("1", "d", updated: 10), item("2", "p", updated: 5), item("3", "t", parent: "2", updated: 20), item("4", "t")])
        let fav: Set = ["A-1", "A-2", "A-3"]
        XCTAssertEqual(WorkPage.favorites([s], favorite: fav.contains).map(\.item.id), ["3", "2", "1"],
                       "sub-items and items of other people too; open by last activity, then Done")
        XCTAssertEqual(WorkPage.Section.allCases.first, .favorites)
    }

    func testTheRowMenuAddsAndRemoves() throws {
        let f = Favorites(writes: StoreWrites(store: try store("mba")))
        XCTAssertEqual(RowMenu.favorite("A-1", favorites: f), .action("Add to Favorites", .favorite(key: "A-1", true)))
        f.set(ref("A-1"), on: true)
        XCTAssertEqual(RowMenu.favorite("A-1", favorites: f), .action("Remove from Favorites", .favorite(key: "A-1", false)))
        let a = try XCTUnwrap(RowCommand.favorite(key: "A-1", false).action { _ in nil })
        XCTAssertEqual(a.id, "item.favorite")
        XCTAssertEqual(a.args, ["key": .string("A-1"), "on": .bool(false)])
    }

    func testThePaletteListsFavoritesFirstWithLabels() {
        func e(_ title: String, fav: Bool = false) -> CommandPalette.Entry {
            CommandPalette.Entry(title: title, detail: "", symbol: "", kind: "Item", key: title, favorite: fav) {}
        }
        let all = [e("daemon logs"), e("daemon owns runtimes", fav: true), e("install daemon"), e("free daemon line", fav: true)]
        let got = CommandPalette.labeled(CommandPalette.match(all, query: "daemon", picking: false))
        XCTAssertEqual(got.map(\.title), ["FAVORITES", "daemon owns runtimes", "free daemon line", "RESULTS", "daemon logs", "install daemon"])
        XCTAssertEqual(got.map(\.isLabel), [true, false, false, true, false, false])
        XCTAssertEqual(CommandPalette.match(all, query: "", picking: false).map(\.title), ["daemon owns runtimes", "free daemon line"],
                       "the empty query shows the favorites")
        XCTAssertEqual(CommandPalette.labeled([e("x")]).map(\.title), ["x"], "no labels without a favorite")
    }
}
