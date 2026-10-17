import AppKit
import XCTest
@testable import OverSireApp

final class ColumnLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "oversire-columns-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func make() -> ColumnLayout {
        ColumnLayout(id: "t", columns: [
            TableColumn(id: "key", title: "ID", width: 100, min: 60),
            TableColumn(id: "title", title: "Title", width: 200, min: 160, flexible: true),
            TableColumn(id: "when", title: "When", width: 60, min: 40, optional: true),
        ], defaults: defaults)
    }

    func testClampsToMin() {
        let l = make()
        l.setWidth("key", 10)
        XCTAssertEqual(l.width("key"), 60)
    }

    func testFlexibleColumnKeepsItsWidth() {
        let l = make()
        l.setWidth("title", 500)
        XCTAssertEqual(l.width("title"), 200)
    }

    func testSaveAndLoad() {
        let l = make()
        l.setWidth("key", 134.4)
        l.hidden = ["when"]
        let again = make()
        XCTAssertEqual(again.width("key"), 134)
        XCTAssertEqual(again.hidden, ["when"])
        XCTAssertFalse(again.isVisible("when"))
    }

    func testHiddenKeepsOnlyOptionalColumns() {
        defaults.set(["key", "when", "gone"], forKey: "table.t.hidden")
        XCTAssertEqual(make().hidden, ["when"])
    }

    func testReset() {
        let l = make()
        l.setWidth("key", 150)
        l.hidden = ["when"]
        l.reset()
        XCTAssertEqual(l.width("key"), 100)
        XCTAssertTrue(l.hidden.isEmpty)
        XCTAssertEqual(make().width("key"), 100)
    }

    @MainActor
    func testRowsFollowAWidthChange() {
        let l = make()
        let row = TableRow(l, cells: ["key": NSTextField.text("OVERSIRE-20", mono: true), "title": NSTextField.text("A title")])
        l.setWidth("key", 140)
        let c = row.cells.boxes["key"]?.constraints.first { $0.firstAttribute == .width && $0.relation == .equal }
        XCTAssertEqual(c?.constant, 140)
        l.hidden = ["when"]
        XCTAssertEqual(row.cells.boxes["when"]?.isHidden, true)
    }

    @MainActor
    func testFitTakesTheWidestCell() {
        let l = make()
        let rows = ["A-1", "OVERSIRE-1127"].map { TableRow(l, cells: ["key": NSTextField.text($0, mono: true)]) }
        l.fit("key")
        let want = ceil(NSTextField.text("OVERSIRE-1127", mono: true).intrinsicContentSize.width)
        XCTAssertEqual(l.width("key"), max(60, want))
        XCTAssertEqual(rows.count, 2)
    }
}
