import Foundation
import OverSireCore
import XCTest

final class ItemNetTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testCloseFoldsStatusAndClosed() {
        var net = ItemNet()
        net.add([.status(from: "Todo", to: "Done"), .closed], at: t0)
        XCTAssertEqual(net.move, .closed)
        XCTAssertEqual(net.status?.from, "Todo")
        XCTAssertEqual(net.status?.to, "Done")
        XCTAssertEqual(net.closedAt, t0)
        XCTAssertFalse(net.isEmpty)
        XCTAssertFalse(net.noNetChange)
    }

    func testReopenThenCloseIsNoNetChange() {
        var net = ItemNet()
        net.add([.status(from: "Done", to: "In Progress"), .reopened], at: t0)
        net.add([.status(from: "In Progress", to: "Done"), .closed], at: t0 + 240)
        XCTAssertEqual(net.move, .closedAgain)
        XCTAssertEqual(net.status?.from, "Done")
        XCTAssertEqual(net.status?.to, "Done")
        XCTAssertEqual(net.status?.steps, 2)
        XCTAssertEqual(net.reopenedAt, t0)
        XCTAssertEqual(net.closedAt, t0 + 240)
        XCTAssertTrue(net.noNetChange)

        var back = ItemNet()
        back.add([.closed], at: t0)
        back.add([.reopened], at: t0 + 60)
        XCTAssertEqual(back.move, .reopenedAgain)
        XCTAssertTrue(back.noNetChange)
    }

    func testFieldThereAndBackDrops() {
        var net = ItemNet()
        net.add([.field(name: "Priority", from: "Low", to: "High"), .field(name: "Labels", from: nil, to: "bug")], at: t0)
        net.add([.field(name: "Priority", from: "High", to: "Low")], at: t0 + 30)
        XCTAssertEqual(net.fields.map(\.name), ["Labels"])
        net.add([.field(name: "Labels", from: "bug", to: nil)], at: t0 + 60)
        XCTAssertTrue(net.fields.isEmpty)
        XCTAssertTrue(net.isEmpty)
        XCTAssertFalse(net.noNetChange, "an empty net is not shown at all")
    }

    func testAssignThenUnassignIsEmpty() {
        var net = ItemNet()
        net.add([.assigned("ada")], at: t0)
        XCTAssertEqual(net.assigned, ["ada"])
        net.add([.unassigned("ada")], at: t0 + 10)
        XCTAssertTrue(net.assigned.isEmpty)
        XCTAssertTrue(net.unassigned.isEmpty)
        XCTAssertTrue(net.isEmpty)
        net.add([.unassigned("bea")], at: t0 + 20)
        XCTAssertEqual(net.unassigned, ["bea"])
    }

    func testCommentsSumAndKeepNewest() {
        let old = Comment(id: "c1", author: "ada", createdAt: t0, url: "u", body: "first")
        let new = Comment(id: "c3", author: "bea", createdAt: t0 + 90, url: "u", body: "third")
        var net = ItemNet()
        net.add([.comments(new: 1, last: old)], at: t0)
        net.add([.comments(new: 2, last: new), .mention], at: t0 + 100)
        XCTAssertEqual(net.comments?.count, 3)
        XCTAssertEqual(net.comments?.last.id, "c3")
        XCTAssertTrue(net.mention)
    }
}
