import XCTest
@testable import OverSireApp

final class SnapBasketPanelTests: XCTestCase {
    private var dir: URL!
    private var store: SnapStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-panel-\(UUID().uuidString)")
        store = SnapStore(dir: dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func add(_ project: String, note: String) throws -> SnapShot {
        let s = SnapShot(project: project, kind: .area, app: "", windowTitle: "", pixelSize: CGSize(width: 10, height: 10), scale: 1, note: note)
        try store.add(s, png: Data([1]))
        return s
    }

    func testReorderRemoveAndRenumber() throws {
        let a = try add("SLING", note: "a"), _ = try add("SLING", note: "b"), c = try add("SLING", note: "c")
        var b = try XCTUnwrap(store.openBaskets.first)
        b.reorder(2, to: 0)
        try store.update(b)
        XCTAssertEqual(SnapStore(dir: dir).openBaskets.first?.shots.map(\.note), ["c", "a", "b"], "the order is on disk")
        try store.remove(shot: a.id)
        let shots = try XCTUnwrap(store.openBaskets.first?.shots)
        XCTAssertEqual(shots.map(\.note), ["c", "b"])
        XCTAssertEqual(shots.firstIndex { $0.id == c.id }.map { $0 + 1 }, 1, "the numbers come from the order")
        XCTAssertEqual(SnapTicket.markdown(store.openBaskets[0]).components(separatedBy: "### Shot").count - 1, 2)
    }

    func testStateForZeroOneAndTwoBaskets() throws {
        var s = SnapBasketState(baskets: store.openBaskets, project: nil)
        XCTAssertTrue(s.isHidden)

        _ = try add("SLING", note: "a")
        s = SnapBasketState(baskets: store.openBaskets, project: "OTHER")
        XCTAssertEqual(s.current?.project, "SLING", "the newest basket when the project has none")
        s.open = true
        XCTAssertFalse(s.showsChips)
        XCTAssertTrue(s.others.isEmpty)

        _ = try add("TREBI", note: "t")
        _ = try add("TREBI", note: "u")
        s = SnapBasketState(baskets: store.openBaskets, project: "SLING")
        XCTAssertEqual(s.current?.project, "SLING")
        XCTAssertEqual(s.others.map(\.project), ["TREBI"])
        XCTAssertEqual(s.shotCount, 3)
        XCTAssertFalse(s.showsChips, "collapsed shows +N basket, not chips")
        s.open = true
        XCTAssertTrue(s.showsChips)
    }

    func testSentBasketIsNotShown() throws {
        _ = try add("SLING", note: "a")
        let b = try XCTUnwrap(store.openBaskets.first)
        try store.markSent(b.id, key: "SLING-1", session: nil)
        XCTAssertTrue(SnapBasketState(baskets: store.baskets, project: "SLING").isHidden)
        var s = SnapBasketState(baskets: store.baskets, project: "SLING")
        s.notice = .init(text: "Created SLING-1 with 1 shot.")
        XCTAssertFalse(s.isHidden, "the result line stays after the basket leaves")
        XCTAssertNil(s.current)
    }

    func testPlaceStaysOnScreen() {
        let v = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let size = NSSize(width: 310, height: 60)
        XCTAssertEqual(BasketPanel.origin(saved: nil, size: size, in: v), CGPoint(x: 12, y: 37))
        XCTAssertEqual(BasketPanel.origin(saved: CGPoint(x: 2000, y: -50), size: size, in: v), CGPoint(x: 1130, y: 25))
        XCTAssertEqual(BasketPanel.origin(saved: CGPoint(x: 500, y: 400), size: size, in: v), CGPoint(x: 500, y: 400))
    }
}
