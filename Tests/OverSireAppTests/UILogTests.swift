import XCTest
import OverSireCore
@testable import OverSireApp

final class UILogTests: XCTestCase {
    private let lines = IOLogTests.Lines()
    private var old: (any LogSink)!

    override func setUp() {
        old = UILog.sink
        UILog.sink = lines
    }

    override func tearDown() { UILog.sink = old }

    func testAClickWritesTheLabelAndThePage() {
        UILog.shown("Work")
        var ran = false
        ActionButton("Start session") { ran = true }.performClick(nil)
        XCTAssertTrue(ran)
        let e = lines.all.last
        XCTAssertEqual([e?.area.rawValue, e?.job, e?.subject, e?.message], ["ui", "Click", "Work", "Start session"])
        XCTAssertEqual(e?.level, .ok)
        XCTAssertNotEqual(e?.verbose, true, "the log keeps each action")
    }

    func testAFailureWritesAWarning() {
        UILog.shown("Work")
        UILog.failed("Start session did not work", "Not allowed: the repo")
        let e = lines.all.last
        XCTAssertEqual([e?.area.rawValue, e?.job, e?.subject, e?.message], ["ui", "Error", "Work", "Start session did not work: Not allowed: the repo"])
        XCTAssertEqual(e?.level, .warn)
    }

    func testAnIconButtonUsesItsAccessibilityLabel() {
        ActionButton("", symbol: "arrow.clockwise") {}.performClick(nil)
        XCTAssertEqual(lines.all.last?.message, "arrow.clockwise")
    }

    func testAPageChangeWritesOnce() {
        UILog.shown("Home")
        let n = lines.all.count
        UILog.shown("Runs")
        UILog.shown("Runs")
        XCTAssertEqual(lines.all.count, n + 1, "a refresh of the same page writes nothing")
        XCTAssertEqual(lines.all.last?.message, "Home → Runs")
    }

    func testAMenuActionWritesTheMenuAndTheItem() {
        UILog.watchMenus()
        let menu = NSMenu(title: "Session")
        let item = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
        menu.addItem(item)
        NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: menu, userInfo: ["MenuItem": item])
        XCTAssertEqual(lines.all.last?.job, "Menu")
        XCTAssertEqual(lines.all.last?.message, "Session › Stop")
    }
}
